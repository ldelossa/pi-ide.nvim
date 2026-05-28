local M = {}

local DEBOUNCE_MS = 100

local state = { server = nil, enabled = false, timer = nil, latest = nil, augroup = nil }

local function cancel_timer()
	if state.timer and not state.timer:is_closing() then
		state.timer:stop()
		state.timer:close()
	end
	state.timer = nil
end

local function current_selection()
	local mode = vim.api.nvim_get_mode().mode
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if file_path == "" then return nil end

	local is_visual = mode:sub(1, 1) == "v" or mode:sub(1, 1) == "V" or mode:sub(1, 1) == "\22"

	if is_visual then
		local s = vim.fn.getpos("v")
		local e = vim.fn.getpos(".")
		if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
			s, e = e, s
		end
		local start_line = s[2] - 1
		local start_col = s[3] - 1
		local end_line = e[2] - 1
		local end_col = e[3]
		local lines = {}
		local ok = pcall(function()
			lines = vim.api.nvim_buf_get_text(bufnr, start_line, start_col, end_line, end_col, {})
		end)
		if not ok then lines = {} end
		return {
			text = table.concat(lines, "\n"),
			filePath = file_path,
			selection = {
				start = { line = start_line, character = start_col },
				["end"] = { line = end_line, character = end_col },
				isEmpty = false,
			},
		}
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = cursor[1] - 1
	local char = cursor[2]
	return {
		text = "",
		filePath = file_path,
		selection = {
			start = { line = line, character = char },
			["end"] = { line = line, character = char },
			isEmpty = true,
		},
	}
end

local function selection_changed(a, b)
	if not a then return b ~= nil end
	if not b then return true end
	if a.filePath ~= b.filePath or a.text ~= b.text then return true end
	local s1, s2 = a.selection, b.selection
	return s1.start.line ~= s2.start.line
		or s1.start.character ~= s2.start.character
		or s1["end"].line ~= s2["end"].line
		or s1["end"].character ~= s2["end"].character
end

function M.update()
	if not state.enabled or not state.server then return end
	local sel = current_selection()
	if not selection_changed(state.latest, sel) then return end
	state.latest = sel
	if sel then state.server.broadcast("selection_changed", sel) end
end

function M.setup(server)
	if state.enabled then return end
	state.server = server
	state.enabled = true
	state.augroup = vim.api.nvim_create_augroup("PiIdeSelection", { clear = true })

	vim.api.nvim_create_autocmd(
		{ "CursorMoved", "CursorMovedI", "BufEnter", "ModeChanged", "TextChanged" },
		{
			group = state.augroup,
			callback = function()
				cancel_timer()
				state.timer = vim.defer_fn(M.update, DEBOUNCE_MS)
			end,
		}
	)
end

function M.disable()
	if not state.enabled then return end
	cancel_timer()
	if state.augroup then pcall(vim.api.nvim_del_augroup_by_id, state.augroup) end
	state.augroup = nil
	state.enabled = false
	state.latest = nil
	state.server = nil
end

return M
