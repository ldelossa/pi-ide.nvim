local M = {}

local logger = require("pi-ide.logger")
local tcp_server = require("pi-ide.server.tcp")
local tools = require("pi-ide.tools")

local MCP_PROTOCOL_VERSION = "2024-11-05"
local SERVER_NAME = "pi-ide-neovim"
local SERVER_VERSION = "0.1.0"

M.state = { server = nil, port = nil, ping_timer = nil, auth_token = nil, handlers = nil }

local function register_handlers()
	M.state.handlers = {
		["initialize"] = function()
			return {
				protocolVersion = MCP_PROTOCOL_VERSION,
				capabilities = { logging = vim.empty_dict(), tools = { listChanged = true } },
				serverInfo = { name = SERVER_NAME, version = SERVER_VERSION },
			}
		end,
		["notifications/initialized"] = function() end,
		["tools/list"] = function() return { tools = tools.get_tool_list() } end,
		["tools/call"] = function(client, params)
			local r = tools.handle_invoke(client, params)
			if r and r._deferred then return r end
			if r.error then return nil, r.error end
			if r.result then return r.result, nil end
			return nil, { code = -32603, message = "Internal error", data = "Tool handler returned unexpected format" }
		end,
	}
end

function M.start(opts)
	if M.state.server then return false, "Server already running" end

	M.state.auth_token = opts.auth_token
	register_handlers()

	local config = {
		host = "127.0.0.1",
		port_range = { min = 10000, max = 65535 },
	}
	local callbacks = {
		on_message = function(client, message) M._handle_message(client, message) end,
		on_connect = function(client) logger.debug("server", "client connected:", client.id) end,
		on_disconnect = function(client, code, reason)
			logger.debug("server", "client disconnected:", client.id, "(code:", code, ", reason:", reason or "N/A", ")")
		end,
		on_error = function(error_msg) logger.error("server", "server error:", error_msg) end,
	}

	local server, err = tcp_server.create_server(config, callbacks, M.state.auth_token)
	if not server then return false, err or "Unknown server creation error" end

	M.state.server = server
	M.state.port = server.port
	M.state.ping_timer = tcp_server.start_ping_timer(server, 30000)

	return true, server.port
end

function M.stop()
	if not M.state.server then return false, "Server not running" end
	if M.state.ping_timer then
		M.state.ping_timer:stop()
		M.state.ping_timer:close()
		M.state.ping_timer = nil
	end
	tcp_server.stop_server(M.state.server)
	_G.pi_ide_deferred_responses = {}
	M.state.server = nil
	M.state.port = nil
	M.state.auth_token = nil
	return true
end

function M._handle_message(client, message)
	local ok, parsed = pcall(vim.json.decode, message)
	if not ok then
		M.send_response(client, nil, nil, { code = -32700, message = "Parse error", data = "Invalid JSON" })
		return
	end
	if type(parsed) ~= "table" or parsed.jsonrpc ~= "2.0" then
		M.send_response(client, parsed and parsed.id, nil, {
			code = -32600, message = "Invalid Request", data = "Not a valid JSON-RPC 2.0 message",
		})
		return
	end
	if parsed.id then M._handle_request(client, parsed) else M._handle_notification(client, parsed) end
end

function M._handle_request(client, request)
	local method = request.method
	local params = request.params or {}
	local id = request.id

	local handler = M.state.handlers[method]
	if not handler then
		M.send_response(client, id, nil, {
			code = -32601, message = "Method not found", data = "Unknown method: " .. tostring(method),
		})
		return
	end

	local success, result, error_data = pcall(handler, client, params)
	if success then
		if result and result._deferred then
			M._setup_deferred_response({
				client = result.client, id = id, coroutine = result.coroutine,
			})
			return
		end
		if error_data then
			M.send_response(client, id, nil, error_data)
		else
			M.send_response(client, id, result, nil)
		end
	else
		M.send_response(client, id, nil, { code = -32603, message = "Internal error", data = tostring(result) })
	end
end

function M._handle_notification(client, notification)
	local handler = M.state.handlers[notification.method]
	if handler then pcall(handler, client, notification.params or {}) end
end

function M._setup_deferred_response(info)
	local co = info.coroutine
	local response_sender = function(result)
		if result and result.content then
			M.send_response(info.client, info.id, result, nil)
		elseif result and result.error then
			M.send_response(info.client, info.id, nil, result.error)
		else
			M.send_response(info.client, info.id, nil, {
				code = -32603, message = "Internal error", data = "Deferred response had unexpected format",
			})
		end
	end
	_G.pi_ide_deferred_responses = _G.pi_ide_deferred_responses or {}
	_G.pi_ide_deferred_responses[tostring(co)] = response_sender
end

function M.send_response(client, id, result, error_data)
	if not M.state.server then return false end
	local response = { jsonrpc = "2.0", id = id }
	if error_data then response.error = error_data else response.result = result end
	tcp_server.send_to_client(M.state.server, client.id, vim.json.encode(response))
	return true
end

function M.broadcast(method, params)
	if not M.state.server then return false end
	local message = { jsonrpc = "2.0", method = method, params = params or vim.empty_dict() }
	tcp_server.broadcast(M.state.server, vim.json.encode(message))
	return true
end

function M.get_status()
	if not M.state.server then return { running = false } end
	return {
		running = true,
		port = M.state.port,
		client_count = tcp_server.get_client_count(M.state.server),
	}
end

return M
