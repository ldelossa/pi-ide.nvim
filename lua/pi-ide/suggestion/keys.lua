local M = {}

-- Defaults mirror copilot.vim's canonical bindings so users coming from
-- copilot.vim can swap in pi-ide.nvim without remapping. Accept-line and
-- accept-word are intentionally unbound here (copilot.vim ships them
-- unbound as well); set them yourself via <Plug>(PiSuggestAcceptLine) and
-- <Plug>(PiSuggestAcceptWord).
local DEFAULTS = {
	["<Plug>(PiSuggest)"] = "<M-\\>",
	["<Plug>(PiSuggestNext)"] = "<M-]>",
	["<Plug>(PiSuggestPrev)"] = "<M-[>",
	["<Plug>(PiSuggestAccept)"] = "<Tab>",
	["<Plug>(PiSuggestDismiss)"] = "<C-]>",
}

function M.setup(actions, opts)
	opts = opts or {}
	local function plug(name, fn)
		vim.keymap.set("i", name, fn, { silent = true, desc = "pi-ide: " .. name })
	end
	plug("<Plug>(PiSuggest)", actions.trigger)
	plug("<Plug>(PiSuggestNext)", actions.cycle_next)
	plug("<Plug>(PiSuggestPrev)", actions.cycle_prev)
	plug("<Plug>(PiSuggestAccept)", actions.accept_all)
	plug("<Plug>(PiSuggestAcceptLine)", actions.accept_line)
	plug("<Plug>(PiSuggestAcceptWord)", actions.accept_word)
	plug("<Plug>(PiSuggestDismiss)", actions.dismiss)
	if opts.default_keys == false then return end
	for lhs, rhs in pairs(DEFAULTS) do
		vim.keymap.set("i", rhs, lhs, { silent = true, remap = true })
	end
end

return M
