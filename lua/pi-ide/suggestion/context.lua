local M = {}

local BEFORE_LINES = 20
local AFTER_LINES = 10
local MAX_OUTLINE_CHARS = 6000
local MAX_SIGNATURE_CHARS = 240
local OUTLINE_NEARBY_LINES = 200

local outline_cache = {}

local FUNCTION_NODE_TYPES = {
	function_declaration = true,
	function_definition = true,
	function_item = true,
	method_declaration = true,
	method_definition = true,
	constructor_declaration = true,
	arrow_function = true,
	local_function = true,
	function_expression = true,
	method = true,
	singleton_method = true,
}

local SCOPE_NODE_TYPES = {
	function_declaration = true,
	function_definition = true,
	function_item = true,
	method_declaration = true,
	method_definition = true,
	constructor_declaration = true,
	arrow_function = true,
	local_function = true,
	function_expression = true,
	class_declaration = true,
	class_definition = true,
	class_item = true,
	struct_declaration = true,
	struct_item = true,
	record_declaration = true,
	type_declaration = true,
	type_alias_declaration = true,
	interface_declaration = true,
	annotation_type_declaration = true,
	enum_declaration = true,
	enum_item = true,
	struct_specifier = true,
	class_specifier = true,
	enum_specifier = true,
	union_specifier = true,
	type_definition = true,
	alias_declaration = true,
	template_declaration = true,
	concept_definition = true,
	trait_declaration = true,
	trait_item = true,
	impl_item = true,
	module_declaration = true,
	namespace_declaration = true,
	namespace_definition = true,
	object_declaration = true,
	method = true,
	singleton_method = true,
	class = true,
	module = true,
}

local OUTLINE_NODE_TYPES = {}
for node_type in pairs(SCOPE_NODE_TYPES) do OUTLINE_NODE_TYPES[node_type] = true end

-- These declarations are useful at module/class scope but become noise inside
-- function bodies. Function signatures are retained while their bodies are
-- intentionally skipped.
local TOP_LEVEL_OUTLINE_NODE_TYPES = {
	import_statement = true,
	import_declaration = true,
	import_from_statement = true,
	future_import_statement = true,
	use_declaration = true,
	preproc_include = true,
	preproc_def = true,
	preproc_function_def = true,
	declaration = true,
	lexical_declaration = true,
	variable_declaration = true,
	var_declaration = true,
	const_declaration = true,
	constant_declaration = true,
	const_item = true,
	static_item = true,
	field_declaration = true,
	property_declaration = true,
}

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

local function collect_outline_entries(root, bufnr)
	local entries = {}
	local seen = {}
	local function walk(node, outline_depth, inside_function)
		local node_type = node:type()
		local include = OUTLINE_NODE_TYPES[node_type]
			or (TOP_LEVEL_OUTLINE_NODE_TYPES[node_type] and not inside_function)
		local next_depth = outline_depth
		if include then
			local start_row = node:range()
			local signature = declaration_signature(node, bufnr)
			local key = string.format("%d:%d:%s", start_row, outline_depth, signature)
			if not seen[key] then
				seen[key] = true
				entries[#entries + 1] = {
					line = start_row + 1,
					depth = outline_depth,
					text = signature,
				}
			end
			next_depth = outline_depth + 1
		end
		-- Function bodies and value initializers dominate syntax trees but add no
		-- declaration-level context. Their signatures already carry the useful
		-- symbol information, so avoid traversing implementation nodes.
		if FUNCTION_NODE_TYPES[node_type] or TOP_LEVEL_OUTLINE_NODE_TYPES[node_type] then return end
		local child_inside_function = inside_function or FUNCTION_NODE_TYPES[node_type] == true
		for child in node:iter_children() do
			if child:named() then walk(child, next_depth, child_inside_function) end
		end
	end
	walk(root, 0, false)
	table.sort(entries, function(a, b)
		if a.line == b.line then return a.depth < b.depth end
		return a.line < b.line
	end)
	return entries
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
	local tick = vim.b[bufnr].changedtick or 0
	local cached = outline_cache[bufnr]
	if not cached or cached.tick ~= tick then
		local lang = ts_lang(bufnr)
		local parser = lang and get_parser(bufnr, lang) or nil
		local tree = parser and parser:parse()[1] or nil
		cached = { tick = tick, entries = tree and collect_outline_entries(tree:root(), bufnr) or {} }
		outline_cache[bufnr] = cached
	end
	return render_outline(cached.entries, cursor_row)
end

function M.enclosing_scope(bufnr, row)
	local lang = ts_lang(bufnr)
	if not lang then return "" end
	local parser = get_parser(bufnr, lang)
	if not parser then return "" end
	local tree = parser:parse()[1]
	if not tree then return "" end
	local root = tree:root()
	local node = root:named_descendant_for_range(row, 0, row, 0)
	local parts = {}
	while node do
		if SCOPE_NODE_TYPES[node:type()] then
			local text = vim.treesitter.get_node_text(node, bufnr)
			local first = text:match("([^\n]*)")
			if first and first ~= "" then parts[#parts + 1] = first end
		end
		node = node:parent()
	end
	if #parts == 0 then return "" end
	local out = {}
	for i = #parts, 1, -1 do out[#out + 1] = parts[i] end
	return table.concat(out, "\n")
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
	local enclosing = M.enclosing_scope(bufnr, row)
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
	outline_cache[bufnr] = nil
end

return M
