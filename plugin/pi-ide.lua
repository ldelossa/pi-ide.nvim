if vim.g.loaded_pi_ide then return end
vim.g.loaded_pi_ide = true

vim.api.nvim_create_user_command("PiStart", function() require("pi-ide").start() end, {})
vim.api.nvim_create_user_command("PiStop", function() require("pi-ide").stop() end, {})
vim.api.nvim_create_user_command("PiStatus", function() require("pi-ide").status() end, {})

vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		pcall(function() require("pi-ide").stop() end)
	end,
})
