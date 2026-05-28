local M = {}

local function lock_dir()
	local override = os.getenv("PI_IDE_LOCK_DIR")
	if override and override ~= "" then return vim.fn.expand(override) end
	return vim.fn.expand("~/.pi/ide")
end

M.lock_dir = lock_dir()
local CLAUDE_LOCK_DIR = vim.fn.expand("~/.claude/ide")

local function lock_dirs(opts)
	local dirs = { M.lock_dir }
	if opts and opts.claude_code_compat then
		table.insert(dirs, CLAUDE_LOCK_DIR)
	end
	return dirs
end

local random_initialized = false
local function generate_auth_token()
	if not random_initialized then
		math.randomseed(os.time() + vim.fn.getpid() + ((vim.loop.hrtime() or 0) % 1000000))
		for _ = 1, 10 do math.random() end
		random_initialized = true
	end
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return (template:gsub("[xy]", function(c)
		local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
		return string.format("%x", v)
	end))
end

M.generate_auth_token = generate_auth_token

local function get_lsp_clients()
	if vim.lsp and vim.lsp.get_clients then return vim.lsp.get_clients() end
	if vim.lsp and vim.lsp.get_active_clients then return vim.lsp.get_active_clients() end
	return {}
end

local function get_workspace_folders()
	local folders = { vim.fn.getcwd() }
	for _, client in pairs(get_lsp_clients()) do
		if client.config and client.config.workspace_folders then
			for _, ws in ipairs(client.config.workspace_folders) do
				local path = vim.uri_to_fname(ws.uri)
				local seen = false
				for _, f in ipairs(folders) do if f == path then seen = true break end end
				if not seen then folders[#folders + 1] = path end
			end
		end
	end
	return folders
end

function M.create(port, auth_token, opts)
	if type(port) ~= "number" or port < 1 or port > 65535 then
		return false, "Invalid port: " .. tostring(port)
	end
	auth_token = auth_token or generate_auth_token()
	local content = vim.json.encode({
		pid = vim.fn.getpid(),
		workspaceFolders = get_workspace_folders(),
		ideName = "Neovim",
		transport = "ws",
		authToken = auth_token,
	})

	local written = {}
	for _, dir in ipairs(lock_dirs(opts)) do
		vim.fn.mkdir(dir, "p")
		local path = dir .. "/" .. port .. ".lock"
		local file = io.open(path, "w")
		if not file then
			for _, p in ipairs(written) do pcall(os.remove, p) end
			return false, "Failed to open lockfile: " .. path
		end
		file:write(content)
		file:close()
		written[#written + 1] = path
	end
	return true, written[1], auth_token
end

function M.remove(port, opts)
	if type(port) ~= "number" then return false, "Invalid port" end
	for _, dir in ipairs(lock_dirs(opts)) do
		local path = dir .. "/" .. port .. ".lock"
		if vim.fn.filereadable(path) == 1 then
			pcall(os.remove, path)
		end
	end
	return true
end

return M
