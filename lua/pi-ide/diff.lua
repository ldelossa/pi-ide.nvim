local M = {}

local active = {}

local function find_main_editor_window()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		local cfg = vim.api.nvim_win_get_config(win)
		local floating = cfg.relative and cfg.relative ~= ""
		local buftype = vim.bo[buf].buftype
		if not floating and buftype ~= "terminal" and buftype ~= "prompt" then
			return win
		end
	end
	return nil
end

local function send_result(co, result)
	vim.schedule(function()
		local ok, resume_result = coroutine.resume(co, result)
		local key = tostring(co)
		if _G.pi_ide_deferred_responses and _G.pi_ide_deferred_responses[key] then
			if ok then
				_G.pi_ide_deferred_responses[key](resume_result)
			else
				_G.pi_ide_deferred_responses[key]({
					error = { code = -32603, message = "Internal error", data = tostring(resume_result) },
				})
			end
			_G.pi_ide_deferred_responses[key] = nil
		end
	end)
end

local function resolve_saved(tab_name)
	local data = active[tab_name]
	if not data or data.status ~= "pending" then return end
	local lines = vim.api.nvim_buf_get_lines(data.new_buf, 0, -1, false)
	local content = table.concat(lines, "\n")
	if vim.bo[data.new_buf].eol then content = content .. "\n" end
	data.status = "saved"
	pcall(function() vim.bo[data.new_buf].modified = false end)
	send_result(data.co, {
		content = { { type = "text", text = "FILE_SAVED" }, { type = "text", text = content } },
	})
end

local function resolve_rejected(tab_name)
	local data = active[tab_name]
	if not data or data.status ~= "pending" then return end
	data.status = "rejected"
	send_result(data.co, {
		content = { { type = "text", text = "DIFF_REJECTED" }, { type = "text", text = tab_name } },
	})
end

local function setup_autocmds(tab_name)
	local data = active[tab_name]
	local group_name = "PiIdeDiff_" .. tab_name:gsub("[^%w_]", "_")
	local group = vim.api.nvim_create_augroup(group_name, { clear = true })
	data.augroup = group

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = data.new_buf,
		callback = function()
			resolve_saved(tab_name)
			vim.schedule(function() M.cleanup(tab_name) end)
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(args)
			local closed = tonumber(args.match)
			if closed == data.original_win or closed == data.new_win then
				resolve_rejected(tab_name)
				vim.schedule(function() M.cleanup(tab_name) end)
				return
			end
			if not vim.api.nvim_win_is_valid(data.original_win)
				or not vim.api.nvim_win_is_valid(data.new_win) then
				resolve_rejected(tab_name)
				vim.schedule(function() M.cleanup(tab_name) end)
			end
		end,
	})

	vim.api.nvim_create_autocmd("TabClosed", {
		group = group,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(data.tabpage) then
				resolve_rejected(tab_name)
				vim.schedule(function() M.cleanup(tab_name) end)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		buffer = data.new_buf,
		callback = function()
			resolve_rejected(tab_name)
			vim.schedule(function() M.cleanup(tab_name) end)
		end,
	})
end

function M.open_blocking(params)
	local tab_name = params.tab_name

	if active[tab_name] then
		resolve_rejected(tab_name)
		M.cleanup(tab_name)
	end

	if not find_main_editor_window() then
		error({ code = -32000, message = "No suitable editor window for diff" })
	end

	vim.cmd("tabnew")
	local tabpage = vim.api.nvim_get_current_tabpage()
	local tabnew_buf = vim.api.nvim_get_current_buf()

	local old_exists = vim.fn.filereadable(params.old_file_path) == 1
	if old_exists then
		vim.cmd("edit " .. vim.fn.fnameescape(params.old_file_path))
	else
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, params.old_file_path)
		vim.api.nvim_set_current_buf(buf)
	end
	local original_win = vim.api.nvim_get_current_win()
	local original_buf = vim.api.nvim_get_current_buf()
	-- :tabnew creates an empty unnamed buffer that lingers in the bufferlist.
	-- Drop it now (skipped if :edit reused it as original_buf).
	if tabnew_buf ~= original_buf and vim.api.nvim_buf_is_valid(tabnew_buf) then
		pcall(vim.api.nvim_buf_delete, tabnew_buf, { force = true })
	end
	vim.cmd("diffthis")

	vim.cmd("vsplit")
	local new_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(new_buf, params.new_file_path .. " [pi-proposed]")
	vim.bo[new_buf].buftype = "acwrite"
	vim.api.nvim_set_current_buf(new_buf)
	local lines = vim.split(params.new_file_contents, "\n", { plain = true })
	if lines[#lines] == "" then lines[#lines] = nil end
	vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)
	vim.bo[new_buf].modified = false
	local ft = vim.bo[original_buf].filetype
	if ft == nil or ft == "" then
		ft = vim.filetype.match({ filename = params.new_file_path })
			or vim.filetype.match({ filename = params.old_file_path })
			or ""
	end
	if ft ~= "" then
		pcall(function() vim.bo[new_buf].filetype = ft end)
		if vim.bo[original_buf].filetype == "" then
			pcall(function() vim.bo[original_buf].filetype = ft end)
		end
	end
	vim.cmd("diffthis")
	local new_win = vim.api.nvim_get_current_win()

	pcall(vim.api.nvim_set_option_value, "winfixbuf", true, { scope = "local", win = original_win })
	pcall(vim.api.nvim_set_option_value, "winfixbuf", true, { scope = "local", win = new_win })

	active[tab_name] = {
		tabpage = tabpage,
		new_buf = new_buf,
		new_win = new_win,
		original_win = original_win,
		original_buf = original_buf,
		original_existed = old_exists,
		file_path = params.new_file_path,
		status = "pending",
		co = coroutine.running(),
	}
	setup_autocmds(tab_name)

	return coroutine.yield()
end

function M.cleanup(tab_name)
	local data = active[tab_name]
	if not data then return end
	active[tab_name] = nil

	if data.augroup then pcall(vim.api.nvim_del_augroup_by_id, data.augroup) end

	if data.original_win and vim.api.nvim_win_is_valid(data.original_win) then
		pcall(vim.api.nvim_set_option_value, "winfixbuf", false, { scope = "local", win = data.original_win })
	end
	if data.new_win and vim.api.nvim_win_is_valid(data.new_win) then
		pcall(vim.api.nvim_set_option_value, "winfixbuf", false, { scope = "local", win = data.new_win })
	end

	if data.tabpage and vim.api.nvim_tabpage_is_valid(data.tabpage) then
		local num = vim.api.nvim_tabpage_get_number(data.tabpage)
		pcall(vim.cmd, "tabclose " .. num)
	end

	if data.new_buf and vim.api.nvim_buf_is_valid(data.new_buf) then
		pcall(vim.api.nvim_buf_delete, data.new_buf, { force = true })
	end

	if not data.original_existed and data.original_buf and vim.api.nvim_buf_is_valid(data.original_buf) then
		pcall(vim.api.nvim_buf_delete, data.original_buf, { force = true })
	end

	if data.file_path then
		local abs = vim.fn.fnamemodify(data.file_path, ":p")
		vim.defer_fn(function()
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == abs then
					vim.api.nvim_buf_call(buf, function() pcall(vim.cmd, "silent! checktime") end)
				end
			end
		end, 300)
	end
end

function M.close_tab(tab_name)
	local data = active[tab_name]
	if data and data.status == "pending" then resolve_rejected(tab_name) end
	M.cleanup(tab_name)
end

function M.close_all()
	for tab_name, _ in pairs(active) do M.close_tab(tab_name) end
end

return M
