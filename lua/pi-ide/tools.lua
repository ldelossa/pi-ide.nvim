local M = {}

local diff = require("pi-ide.diff")

local ERR_INVALID_PARAMS = -32602
local ERR_METHOD_NOT_FOUND = -32601
local ERR_INTERNAL = -32000

local function input_schema(properties, required)
	return {
		type = "object",
		properties = properties,
		required = required,
		additionalProperties = false,
		["$schema"] = "http://json-schema.org/draft-07/schema#",
	}
end

local function require_params(params, keys)
	for _, key in ipairs(keys) do
		if not params[key] then
			error({ code = ERR_INVALID_PARAMS, message = "Missing required parameter: " .. key })
		end
	end
end

local function uri_to_bufnr(uri)
	if not uri or uri == "" then return nil end
	local path = vim.uri_to_fname(uri)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
			return buf
		end
	end
	return nil
end

local function bufnr_to_uri(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then return nil end
	return vim.uri_from_fname(name)
end

local tools = {}

tools["openDiff"] = {
	schema = {
		description = "Open a diff view comparing existing file content with proposed content. Blocks until user saves (accept) or closes (reject).",
		inputSchema = input_schema({
			old_file_path = { type = "string", description = "Path to existing file" },
			new_file_path = { type = "string", description = "Path for the proposed file" },
			new_file_contents = { type = "string", description = "Contents for the proposed version" },
			tab_name = { type = "string", description = "Stable identifier for this diff" },
		}, { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }),
	},
	requires_coroutine = true,
	handler = function(params)
		require_params(params, { "old_file_path", "new_file_path", "new_file_contents", "tab_name" })
		local co, is_main = coroutine.running()
		if not co or is_main then
			error({ code = ERR_INTERNAL, message = "openDiff must run in coroutine context" })
		end
		local ok, result = pcall(diff.open_blocking, params)
		if not ok then
			if type(result) == "table" and result.code then error(result) end
			error({ code = ERR_INTERNAL, message = "Error opening diff", data = tostring(result) })
		end
		return result
	end,
}

tools["close_tab"] = {
	schema = {
		description = "Close a diff tab previously opened with openDiff. No-op if the tab is already closed.",
		inputSchema = input_schema({
			tab_name = { type = "string", description = "Identifier of the diff tab to close" },
		}, { "tab_name" }),
	},
	handler = function(params)
		require_params(params, { "tab_name" })
		diff.close_tab(params.tab_name)
		return { content = { { type = "text", text = "TAB_CLOSED" } } }
	end,
}

local SEVERITY_NAMES = { "Error", "Warning", "Information", "Hint" }

local function diagnostics_for_buf(bufnr)
	local items = {}
	for _, d in ipairs(vim.diagnostic.get(bufnr)) do
		items[#items + 1] = {
			severity = SEVERITY_NAMES[d.severity] or "Unknown",
			message = d.message,
			source = d.source,
			code = d.code,
			range = {
				start = { line = d.lnum, character = d.col },
				["end"] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col },
			},
		}
	end
	return items
end

tools["getDiagnostics"] = {
	schema = {
		description = "Get LSP diagnostics. If `uri` is given, returns diagnostics for that file only; otherwise returns diagnostics for all loaded buffers.",
		inputSchema = input_schema({
			uri = { type = "string", description = "File URI (file://...) to filter. Omit for workspace-wide diagnostics." },
		}),
	},
	handler = function(params)
		local out = {}
		if params.uri then
			local bufnr = uri_to_bufnr(params.uri)
			out[params.uri] = bufnr and diagnostics_for_buf(bufnr) or {}
		else
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(buf) then
					local uri = bufnr_to_uri(buf)
					if uri then
						local items = diagnostics_for_buf(buf)
						if #items > 0 then out[uri] = items end
					end
				end
			end
		end
		return { content = { { type = "text", text = vim.json.encode(out) } } }
	end,
}

tools["getOpenEditorTabs"] = {
	schema = {
		description = "List buffers visible in the current tabpage (the editor's open tabs).",
		inputSchema = input_schema({}),
	},
	handler = function()
		local seen = {}
		local out = {}
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			local buf = vim.api.nvim_win_get_buf(win)
			if not seen[buf] and vim.bo[buf].buflisted then
				local uri = bufnr_to_uri(buf)
				if uri then
					out[#out + 1] = {
						uri = uri,
						isActive = (win == vim.api.nvim_get_current_win()),
						isDirty = vim.bo[buf].modified,
						languageId = vim.bo[buf].filetype,
					}
					seen[buf] = true
				end
			end
		end
		return { content = { { type = "text", text = vim.json.encode(out) } } }
	end,
}

function M.get_tool_list()
	local out = {}
	for name, tool in pairs(tools) do
		if tool.schema then
			out[#out + 1] = {
				name = name,
				description = tool.schema.description,
				inputSchema = tool.schema.inputSchema,
			}
		end
	end
	return out
end

local function wrap_pcall(ok, result)
	if ok then return { result = result } end
	if type(result) == "table" and result.code then
		return { error = { code = result.code, message = result.message, data = result.data } }
	end
	return { error = { code = ERR_INTERNAL, message = tostring(result) } }
end

function M.handle_invoke(client, params)
	local tool_name = params.name
	local tool = tools[tool_name]
	if not tool then
		return { error = { code = ERR_METHOD_NOT_FOUND, message = "Tool not found: " .. tool_name } }
	end
	local input = params.arguments or {}

	if tool.requires_coroutine then
		local co = coroutine.create(function() return tool.handler(input) end)
		local ok, result = coroutine.resume(co)
		if coroutine.status(co) == "suspended" then
			return { _deferred = true, coroutine = co, client = client }
		end
		return wrap_pcall(ok, result)
	end

	return wrap_pcall(pcall(tool.handler, input))
end

return M
