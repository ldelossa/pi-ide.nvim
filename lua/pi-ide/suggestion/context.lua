local M = {}

local BEFORE_LINES = 20
local AFTER_LINES = 10
local MAX_OUTLINE_CHARS = 6000
local MAX_SIGNATURE_CHARS = 240
local OUTLINE_NEARBY_LINES = 200
local CACHE_REGION_LINES = 32
local MAX_QUERY_CAPTURES = 2000
local QUERY_CORE_RADIUS = 32
local QUERY_CORE_BUDGET = 1000
local QUERY_NEARBY_BUDGET = 700
local QUERY_HEADER_BUDGET = MAX_QUERY_CAPTURES - QUERY_CORE_BUDGET - QUERY_NEARBY_BUDGET
local TOP_LEVEL_HEADER_COUNT = 64
local TOP_LEVEL_NEARBY_RADIUS = 96

-- Parsed semantic records are cached per changedtick. Language knowledge comes
-- from the parser's standard `locals` query; a compact top-level traversal is
-- retained as a parser-only fallback when that query is absent or incomplete.
local semantic_cache = {}

local function ts_lang(bufnr)
	local ft = vim.bo[bufnr].filetype
	if ft == "" then return nil end
	local ok, lang = pcall(vim.treesitter.language.get_lang, ft)
	if ok and lang then return lang end
	return ft
end

local function get_parser(bufnr, lang)
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
	if not ok or not parser then return nil end
	return parser
end

function M.has_treesitter(bufnr)
	local lang = ts_lang(bufnr)
	if not lang then return false end
	return get_parser(bufnr, lang) ~= nil
end

function M.has_lsp(bufnr)
	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	return #clients > 0
end

local function truncate_utf8(text, max_bytes)
	if #text <= max_bytes then return text end
	local ellipsis = "…"
	local cut = math.max(0, max_bytes - #ellipsis)
	while cut > 0 do
		local next_byte = text:byte(cut + 1)
		if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then break end
		cut = cut - 1
	end
	return text:sub(1, cut) .. ellipsis
end

local function declaration_signature(node, bufnr)
	local text = vim.treesitter.get_node_text(node, bufnr) or ""
	text = text:match("([^\r\n]*)") or ""
	text = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
	if text == "" then text = node:type() end
	return truncate_utf8(text, MAX_SIGNATURE_CHARS)
end

local function node_record(node, bufnr)
	local start_row, start_col, end_row, end_col = node:range()
	return {
		node = node,
		start_row = start_row,
		start_col = start_col,
		end_row = end_row,
		end_col = end_col,
		line = start_row + 1,
		text = declaration_signature(node, bufnr),
	}
end

local function same_range(a, b)
	return a.start_row == b.start_row and a.start_col == b.start_col
		and a.end_row == b.end_row and a.end_col == b.end_col
end

local function range_contains(outer, inner)
	local starts_before = outer.start_row < inner.start_row
		or (outer.start_row == inner.start_row and outer.start_col <= inner.start_col)
	local ends_after = outer.end_row > inner.end_row
		or (outer.end_row == inner.end_row and outer.end_col >= inner.end_col)
	return starts_before and ends_after
end

local function range_contains_position(range, row, col)
	local starts_before = range.start_row < row or (range.start_row == row and range.start_col <= col)
	local ends_after = range.end_row > row or (range.end_row == row and range.end_col >= col)
	return starts_before and ends_after
end

local function range_size(range)
	return (range.end_row - range.start_row) * 1000000 + math.max(0, range.end_col - range.start_col)
end

local function meaningful_signature(text)
	return text ~= "" and text:find("[%w_\128-\255]") ~= nil
end

local function definition_kind(capture)
	if capture == "local.definition" or capture == "definition" then return "symbol" end
	return capture:match("^local%.definition%.(.+)$") or capture:match("^definition%.(.+)$")
end

local function collect_query_records(root, bufnr, lang, cursor_row)
	local ok_query, query = pcall(vim.treesitter.query.get, lang, "locals")
	if not ok_query or not query then return {}, {}, false, false end
	local scopes, definitions = {}, {}
	local seen_scopes, seen_definitions = {}, {}
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local region_start = math.floor((cursor_row or 0) / OUTLINE_NEARBY_LINES) * OUTLINE_NEARBY_LINES
	local nearby_start = math.max(0, region_start - OUTLINE_NEARBY_LINES)
	local nearby_end = math.min(line_count, region_start + OUTLINE_NEARBY_LINES * 2)
	local ranges = {}
	local function add_range(start_row, end_row, budget)
		if start_row >= end_row then return end
		for _, range in ipairs(ranges) do
			if range.start_row == start_row and range.end_row == end_row then
				range.budget = math.min(MAX_QUERY_CAPTURES, range.budget + budget)
				return
			end
		end
		ranges[#ranges + 1] = { start_row = start_row, end_row = end_row, budget = budget }
	end
	add_range(
		math.max(0, (cursor_row or 0) - QUERY_CORE_RADIUS),
		math.min(line_count, (cursor_row or 0) + QUERY_CORE_RADIUS + 1),
		QUERY_CORE_BUDGET
	)
	add_range(nearby_start, nearby_end, QUERY_NEARBY_BUDGET)
	add_range(0, math.min(line_count, OUTLINE_NEARBY_LINES), QUERY_HEADER_BUDGET)

	local query_truncated = false
	local ok_iter = pcall(function()
		for _, range in ipairs(ranges) do
			local range_count = 0
			for capture_id, node in query:iter_captures(root, bufnr, range.start_row, range.end_row) do
				range_count = range_count + 1
				if range_count > range.budget then query_truncated = true; break end
				local capture = query.captures[capture_id] or query.captures[capture_id + 1] or ""
				local record = node_record(node, bufnr)
				local range_key = string.format("%d:%d:%d:%d", record.start_row, record.start_col, record.end_row, record.end_col)
				if capture == "local.scope" or capture == "scope" then
					if not seen_scopes[range_key] then
						seen_scopes[range_key] = true
						scopes[#scopes + 1] = record
					end
				else
					local kind = definition_kind(capture)
					if kind then
						local key = kind .. ":" .. range_key
						if not seen_definitions[key] then
							seen_definitions[key] = true
							record.kind = kind
							definitions[#definitions + 1] = record
						end
					end
				end
			end
		end
	end)
	if not ok_iter then return {}, {}, false, false end
	return scopes, definitions, true, query_truncated
end

local function node_has_name_field(node)
	local ok, names = pcall(node.field, node, "name")
	return ok and type(names) == "table" and #names > 0
end

local function subtree_has_name_field(node, remaining_depth)
	if node_has_name_field(node) then return true end
	if remaining_depth <= 0 then return false end
	for child in node:iter_children() do
		if child:named() and subtree_has_name_field(child, remaining_depth - 1) then return true end
	end
	return false
end

local function selected_top_level_children(root, cursor_row)
	local count = root:named_child_count()
	if count == 0 then return {} end
	local selected = {}
	local function add(index)
		if index >= 0 and index < count then selected[index] = true end
	end
	for index = 0, math.min(count, TOP_LEVEL_HEADER_COUNT) - 1 do add(index) end

	local low, high = 0, count - 1
	local center
	while low <= high do
		local mid = math.floor((low + high) / 2)
		local child = root:named_child(mid)
		local start_row, _, end_row = child:range()
		if end_row < cursor_row then
			low = mid + 1
		elseif start_row > cursor_row then
			high = mid - 1
		else
			center = mid
			break
		end
	end
	center = center or math.min(count - 1, low)
	for index = center - TOP_LEVEL_NEARBY_RADIUS, center + TOP_LEVEL_NEARBY_RADIUS do add(index) end

	local indices = {}
	for index in pairs(selected) do indices[#indices + 1] = index end
	table.sort(indices)
	local children = {}
	for _, index in ipairs(indices) do children[#children + 1] = root:named_child(index) end
	return children
end

local function collect_top_level_records(root, bufnr, definitions, query_available, cursor_row)
	local records = {}
	for _, child in ipairs(selected_top_level_children(root, cursor_row or 0)) do
		if not child:type():find("comment", 1, true) then
			local record = node_record(child, bufnr)
			local contains_definition = false
			for _, definition in ipairs(definitions) do
				if range_contains(record, definition) then contains_definition = true; break end
			end
			local structural = record.end_row > record.start_row or subtree_has_name_field(child, 2) or contains_definition
			if meaningful_signature(record.text) and (not query_available or structural) then
				record.top_level = true
				records[#records + 1] = record
			end
		end
	end
	return records
end

local function add_scope(scopes, seen, record, root_record)
	if same_range(record, root_record) or not meaningful_signature(record.text) then return end
	local key = string.format("%d:%d:%d:%d", record.start_row, record.start_col, record.end_row, record.end_col)
	if seen[key] then return end
	seen[key] = true
	scopes[#scopes + 1] = record
end

local function find_declaration_scope(definition, scopes)
	local name = definition.text
	local best
	for _, scope in ipairs(scopes) do
		if range_contains(scope, definition) and scope.text:find(name, 1, true) then
			if not best or range_size(scope) < range_size(best) then best = scope end
		end
	end
	return best
end

local function is_top_level_definition(definition, top_level)
	for _, record in ipairs(top_level) do
		if definition.line == record.line and range_contains(record, definition) then return true end
	end
	return false
end

local function semantic_depth(record, scopes, declaration_scope)
	local depth = 0
	for _, scope in ipairs(scopes) do
		if range_contains(scope, record) then depth = depth + 1 end
	end
	if declaration_scope then depth = math.max(0, depth - 1) end
	return math.min(depth, 6)
end

local function add_outline_entry(entries, seen, line, depth, text, name)
	if text == "" then return end
	if name and name ~= "" then
		for _, existing in ipairs(entries) do
			if existing.line == line and existing.text:find(name, 1, true) then return end
		end
	end
	local key = string.format("%d:%d:%s", line, depth, text)
	if seen[key] then return end
	seen[key] = true
	entries[#entries + 1] = { line = line, depth = depth, text = text }
end

local function collect_semantic_records(root, bufnr, lang, cursor_row)
	local root_record = node_record(root, bufnr)
	local query_scopes, definitions, query_available, query_truncated = collect_query_records(
		root,
		bufnr,
		lang,
		cursor_row
	)
	local top_level = collect_top_level_records(root, bufnr, definitions, query_available, cursor_row)
	local scopes, seen_scopes = {}, {}
	for _, record in ipairs(top_level) do
		if record.end_row > record.start_row then add_scope(scopes, seen_scopes, record, root_record) end
	end
	for _, record in ipairs(query_scopes) do add_scope(scopes, seen_scopes, record, root_record) end

	local entries, seen_entries = {}, {}
	for _, record in ipairs(top_level) do
		add_outline_entry(entries, seen_entries, record.line, 0, record.text)
	end
	for _, definition in ipairs(definitions) do
		local kind = definition.kind
		local local_kind = kind == "var" or kind == "symbol" or kind == "associated"
		local skip = kind == "parameter" or (local_kind and not is_top_level_definition(definition, top_level))
		if not skip then
			local scope = find_declaration_scope(definition, scopes)
			local text = scope and scope.text or ((kind:gsub("[._]", " ")) .. " " .. definition.text)
			local line = scope and scope.line or definition.line
			local depth = semantic_depth(definition, scopes, scope)
			add_outline_entry(entries, seen_entries, line, depth, text, definition.text)
		end
	end
	table.sort(entries, function(a, b)
		if a.line == b.line then
			if a.depth == b.depth then return a.text < b.text end
			return a.depth < b.depth
		end
		return a.line < b.line
	end)
	return entries, scopes, root_record, query_available, query_truncated
end

local function get_semantic_context(bufnr, cursor_row)
	local tick = vim.b[bufnr].changedtick or 0
	cursor_row = cursor_row or 0
	local region_key = math.floor(cursor_row / CACHE_REGION_LINES)
	local semantic_cursor_row = region_key * CACHE_REGION_LINES + math.floor(CACHE_REGION_LINES / 2)
	local lang = ts_lang(bufnr)
	local cached = semantic_cache[bufnr]
	if cached and cached.tick == tick and cached.region_key == region_key and cached.lang == lang then
		if cached.query_available then return cached end
		-- Parser/query packages can be loaded at runtime without changing the
		-- buffer. Re-probe an unavailable query instead of pinning the fallback.
		local ok_query, query = false, nil
		if lang then ok_query, query = pcall(vim.treesitter.query.get, lang, "locals") end
		if not ok_query or not query then return cached end
	end
	local parser = lang and get_parser(bufnr, lang) or nil
	local tree = parser and parser:parse()[1] or nil
	if not tree or not lang then
		cached = {
			tick = tick,
			region_key = region_key,
			lang = lang,
			query_available = false,
			query_truncated = false,
			entries = {},
			scopes = {},
			root = nil,
		}
	else
		local entries, scopes, root, query_available, query_truncated = collect_semantic_records(
			tree:root(),
			bufnr,
			lang,
			semantic_cursor_row
		)
		cached = {
			tick = tick,
			region_key = region_key,
			lang = lang,
			query_available = query_available,
			query_truncated = query_truncated,
			entries = entries,
			scopes = scopes,
			root = root,
		}
	end
	semantic_cache[bufnr] = cached
	return cached
end

local function format_outline_entry(entry)
	return string.rep("  ", entry.depth) .. string.format("L%d %s\n", entry.line, entry.text)
end

local function render_outline(entries, cursor_row)
	local rendered = {}
	local total = 0
	for i, entry in ipairs(entries) do
		local text = format_outline_entry(entry)
		rendered[i] = text
		total = total + #text
	end
	if total <= MAX_OUTLINE_CHARS then return table.concat(rendered) end

	local cursor_line = (cursor_row or 0) + 1
	local candidates = {}
	for i, entry in ipairs(entries) do
		local distance = math.abs(entry.line - cursor_line)
		local priority = distance <= OUTLINE_NEARBY_LINES and 0 or (entry.depth == 0 and 1 or 2)
		candidates[#candidates + 1] = { index = i, priority = priority, distance = distance, line = entry.line }
	end
	table.sort(candidates, function(a, b)
		if a.priority ~= b.priority then return a.priority < b.priority end
		if a.distance ~= b.distance then return a.distance < b.distance end
		return a.line < b.line
	end)

	local header = string.format("... semantic outline truncated; declarations nearest line %d prioritized ...\n", cursor_line)
	local selected = {}
	total = #header
	for _, candidate in ipairs(candidates) do
		local text = rendered[candidate.index]
		if total + #text <= MAX_OUTLINE_CHARS then
			selected[candidate.index] = true
			total = total + #text
		end
	end

	local out = { header }
	for i, text in ipairs(rendered) do
		if selected[i] then out[#out + 1] = text end
	end
	return table.concat(out)
end

function M.outline(bufnr, cursor_row)
	return render_outline(get_semantic_context(bufnr, cursor_row).entries, cursor_row)
end

local function generic_ancestor_scopes(root_record, bufnr, row, col)
	if not root_record then return {} end
	local ok, node = pcall(root_record.node.named_descendant_for_range, root_record.node, row, col, row, col)
	if not ok or not node then return {} end
	local scopes, seen = {}, {}
	while node do
		local record = node_record(node, bufnr)
		if not same_range(record, root_record) and record.end_row > record.start_row
			and meaningful_signature(record.text) and not node:type():find("comment", 1, true) then
			local key = string.format("%d:%s", record.line, record.text)
			if not seen[key] then
				seen[key] = true
				scopes[#scopes + 1] = record
			end
		end
		node = node:parent()
	end
	return scopes
end

function M.enclosing_scope(bufnr, row, col)
	local cached = get_semantic_context(bufnr, row)
	if not cached.root then return "" end
	col = col or 0
	local containing = {}
	for _, scope in ipairs(cached.scopes) do
		if range_contains_position(scope, row, col) then containing[#containing + 1] = scope end
	end
	if not cached.query_available or cached.query_truncated or #containing == 0 then
		for _, scope in ipairs(generic_ancestor_scopes(cached.root, bufnr, row, col)) do
			containing[#containing + 1] = scope
		end
	end
	if #containing == 0 then return "" end
	table.sort(containing, function(a, b)
		if range_size(a) == range_size(b) then return a.line < b.line end
		return range_size(a) > range_size(b)
	end)
	local parts, seen = {}, {}
	for _, scope in ipairs(containing) do
		local key = string.format("%d:%s", scope.line, scope.text)
		if not seen[key] then
			seen[key] = true
			parts[#parts + 1] = scope.text
		end
	end
	return table.concat(parts, "\n")
end

function M.cursor_region(bufnr, row, col)
	local total = vim.api.nvim_buf_line_count(bufnr)
	local start_row = math.max(0, row - BEFORE_LINES)
	local end_row = math.min(total - 1, row + AFTER_LINES)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
	local cursor_in_lines = row - start_row + 1
	local cursor_line = lines[cursor_in_lines] or ""
	local before_lines = {}
	for i = 1, cursor_in_lines - 1 do before_lines[#before_lines + 1] = lines[i] end
	local after_lines = {}
	for i = cursor_in_lines + 1, #lines do after_lines[#after_lines + 1] = lines[i] end
	local before = table.concat(before_lines, "\n")
	if #before_lines > 0 then before = before .. "\n" end
	before = before .. cursor_line:sub(1, col)
	local after = cursor_line:sub(col + 1)
	if #after_lines > 0 then after = after .. "\n" .. table.concat(after_lines, "\n") end
	return before, after
end

local function pattern_escape(text)
	return text:gsub("([^%w])", "%%%1")
end

local function capture_is_comment(capture)
	if type(capture) == "string" then return capture:find("comment") ~= nil end
	if type(capture) ~= "table" then return false end
	local name = capture.capture or capture.name
	return type(name) == "string" and name:find("comment") ~= nil
end

local function cursor_in_comment_from_treesitter_captures(bufnr, row, col)
	if not vim.treesitter.get_captures_at_pos then return false end
	for _, check_col in ipairs({ col, math.max(0, col - 1) }) do
		local ok, captures = pcall(vim.treesitter.get_captures_at_pos, bufnr, row, check_col)
		if ok and captures then
			for _, capture in ipairs(captures) do
				if capture_is_comment(capture) then return true end
			end
		end
	end
	return false
end

local function cursor_in_comment_from_treesitter_nodes(bufnr, row, col)
	local lang = ts_lang(bufnr)
	if not lang then return false end
	local parser = get_parser(bufnr, lang)
	if not parser then return false end
	local tree = parser:parse()[1]
	if not tree then return false end
	for _, check_col in ipairs({ col, math.max(0, col - 1) }) do
		local node = tree:root():named_descendant_for_range(row, check_col, row, check_col)
		while node do
			if node:type():find("comment") then return true end
			node = node:parent()
		end
	end
	return false
end

local function cursor_in_comment_from_commentstring(bufnr, row, col)
	local commentstring = vim.bo[bufnr].commentstring or ""
	local marker_start, marker_end = commentstring:find("%%s")
	if not marker_start then return false end
	local prefix = commentstring:sub(1, marker_start - 1):gsub("%s+$", "")
	if prefix == "" then return false end
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local before = line:sub(1, col)
	return before:match("^%s*" .. pattern_escape(prefix)) ~= nil
end

function M.is_cursor_in_comment(bufnr, row, col)
	return cursor_in_comment_from_treesitter_captures(bufnr, row, col)
		or cursor_in_comment_from_treesitter_nodes(bufnr, row, col)
		or cursor_in_comment_from_commentstring(bufnr, row, col)
end

function M.gather(bufnr, row, col, opts)
	opts = opts or {}
	local outline = M.outline(bufnr, row)
	local enclosing = M.enclosing_scope(bufnr, row, col)
	local before, after = M.cursor_region(bufnr, row, col)
	local params = {
		filePath = vim.api.nvim_buf_get_name(bufnr),
		language = ts_lang(bufnr) or vim.bo[bufnr].filetype or "",
		outline = outline,
		enclosingScope = enclosing,
		cursorBefore = before,
		cursorAfter = after,
		suggestionCount = 3,
		cursorInComment = M.is_cursor_in_comment(bufnr, row, col),
	}
	if opts.model and opts.model ~= "" then params.model = opts.model end
	return params
end

function M.invalidate(bufnr)
	semantic_cache[bufnr] = nil
end

return M
