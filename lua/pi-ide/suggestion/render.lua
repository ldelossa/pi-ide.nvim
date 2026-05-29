local M = {}

local NAMESPACE = "pi-ide-suggestion"
local HIGHLIGHT = "Comment"
local INDICATOR_HIGHLIGHT = "NonText"

local namespace = nil

local function ns()
	if not namespace then namespace = vim.api.nvim_create_namespace(NAMESPACE) end
	return namespace
end

function M.clear(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
	vim.api.nvim_buf_clear_namespace(bufnr, ns(), 0, -1)
end

function M.show(bufnr, row, col, text, index, total)
	M.clear(bufnr)
	if not text or text == "" then return end
	local lines = vim.split(text, "\n", { plain = true })
	local indicator = (total and total > 1)
		and { string.format(" [%d/%d]", index, total), INDICATOR_HIGHLIGHT }
		or nil
	local virt_text = { { lines[1], HIGHLIGHT } }
	local opts = {
		virt_text = virt_text,
		virt_text_pos = "inline",
		hl_mode = "combine",
	}
	if #lines > 1 then
		local virt_lines = {}
		for i = 2, #lines do
			virt_lines[#virt_lines + 1] = { { lines[i], HIGHLIGHT } }
		end
		if indicator then
			-- Append to the bottom-most line of the suggestion, pinned right.
			local last = virt_lines[#virt_lines]
			last[#last + 1] = indicator
		end
		opts.virt_lines = virt_lines
	elseif indicator then
		virt_text[#virt_text + 1] = indicator
	end
	vim.api.nvim_buf_set_extmark(bufnr, ns(), row, col, opts)
end

return M
