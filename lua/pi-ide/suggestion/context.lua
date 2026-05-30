local M = {}

local BEFORE_LINES = 20
local AFTER_LINES = 10
-- Hard cap on the serialized treesitter outline. The full sexpr of a large
-- file can run several thousand tokens; truncate to keep the request cheap.
local MAX_OUTLINE_CHARS = 12000

local outline_cache = {}

local SCOPE_NODE_TYPES = {
	function_declaration = true,
	function_definition = true,
	function_item = true,
	method_declaration = true,
	method_definition = true,
	arrow_function = true,
	local_function = true,
	function_expression = true,
	class_declaration = true,
	class_definition = true,
	class_item = true,
	struct_declaration = true,
	struct_item = true,
	type_declaration = true,
	type_alias_declaration = true,
	interface_declaration = true,
	impl_item = true,
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

-- Serialize the parsed tree as an indented sexpr-ish outline. Named nodes
-- only; leaf named nodes are followed by their source text in quotes so the
-- LLM sees identifier names alongside structure.
local function serialize_tree(root, bufnr)
	local buf = {}
	local total = 0
	local truncated = false
	local open_depth = 0
	local function emit(text)
		if truncated then return end
		if total + #text > MAX_OUTLINE_CHARS then
			buf[#buf + 1] = "\n... <truncated>\n"
			for d = open_depth - 1, 0, -1 do
				buf[#buf + 1] = string.rep("  ", d) .. ")\n"
			end
			truncated = true
			return
		end
		buf[#buf + 1] = text
		total = total + #text
	end
	local function walk(node, depth)
		if truncated then return end
		local indent = string.rep("  ", depth)
		local has_named_child = false
		for child in node:iter_children() do
			if child:named() then has_named_child = true; break end
		end
		if not has_named_child then
			local text = vim.treesitter.get_node_text(node, bufnr) or ""
			text = text:gsub("\n.*", "")
			if #text > 80 then text = text:sub(1, 80) .. "…" end
			emit(indent .. "(" .. node:type() .. " " .. string.format("%q", text) .. ")\n")
			return
		end
		emit(indent .. "(" .. node:type() .. "\n")
		open_depth = open_depth + 1
		for child in node:iter_children() do
			if child:named() then walk(child, depth + 1) end
		end
		emit(indent .. ")\n")
		open_depth = open_depth - 1
	end
	walk(root, 0)
	return table.concat(buf)
end

function M.outline(bufnr)
	local tick = vim.b[bufnr].changedtick or 0
	local cached = outline_cache[bufnr]
	if cached and cached.tick == tick then return cached.text end
	local lang = ts_lang(bufnr)
	if not lang then
		outline_cache[bufnr] = { tick = tick, text = "" }
		return ""
	end
	local parser = get_parser(bufnr, lang)
	if not parser then
		outline_cache[bufnr] = { tick = tick, text = "" }
		return ""
	end
	local tree = parser:parse()[1]
	if not tree then
		outline_cache[bufnr] = { tick = tick, text = "" }
		return ""
	end
	local text = serialize_tree(tree:root(), bufnr)
	outline_cache[bufnr] = { tick = tick, text = text }
	return text
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
	local outline = M.outline(bufnr)
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
