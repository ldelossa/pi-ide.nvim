---@brief WebSocket handshake handling (RFC 6455)
local utils = require("pi-ide.server.utils")

local M = {}

local AUTH_MIN_LEN = 10
local AUTH_MAX_LEN = 500

---Check if an HTTP request is a valid WebSocket upgrade request
---@param request string The HTTP request string
---@param expected_auth_token string|nil Expected authentication token for validation
---@return boolean valid True if it's a valid WebSocket upgrade request
---@return table|string headers_or_error Headers table if valid, error message if not
local function validate_upgrade_request(request, expected_auth_token)
  local headers = utils.parse_http_headers(request)

  if not headers["upgrade"] or headers["upgrade"]:lower() ~= "websocket" then
    return false, "Missing or invalid Upgrade header"
  end
  if not headers["connection"] or not headers["connection"]:lower():find("upgrade") then
    return false, "Missing or invalid Connection header"
  end
  if not headers["sec-websocket-key"] then
    return false, "Missing Sec-WebSocket-Key header"
  end
  if not headers["sec-websocket-version"] or headers["sec-websocket-version"] ~= "13" then
    return false, "Missing or unsupported Sec-WebSocket-Version header"
  end

  -- Base64-encoded 16 bytes = 24 characters
  if #headers["sec-websocket-key"] ~= 24 then
    return false, "Invalid Sec-WebSocket-Key format"
  end

  if expected_auth_token then
    if type(expected_auth_token) ~= "string" or expected_auth_token == "" then
      return false, "Server configuration error: invalid expected authentication token"
    end

    -- Accept either pi-ide's header or claude-code's, since auth token (not
    -- header name) is the access control. claude-code only finds the server
    -- when the user explicitly enables claude_code_compatibility, which
    -- drops a lockfile in ~/.claude/ide/.
    local auth_header = headers["x-pi-ide-authorization"]
      or headers["x-claude-code-ide-authorization"]
    if not auth_header then
      return false, "Missing authentication header"
    end
    if #auth_header < AUTH_MIN_LEN then
      return false, "Authentication token too short (min " .. AUTH_MIN_LEN .. " characters)"
    end
    if #auth_header > AUTH_MAX_LEN then
      return false, "Authentication token too long (max " .. AUTH_MAX_LEN .. " characters)"
    end
    if auth_header ~= expected_auth_token then
      return false, "Invalid authentication token"
    end
  end

  return true, headers
end

---Generate a WebSocket handshake response
---@param client_key string The client's Sec-WebSocket-Key header value
---@param protocol string|nil Optional subprotocol to accept
---@return string|nil response The HTTP response string, or nil on error
local function create_handshake_response(client_key, protocol)
  local accept_key = utils.generate_accept_key(client_key)
  if not accept_key then return nil end

  local response_lines = {
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. accept_key,
  }
  if protocol then
    table.insert(response_lines, "Sec-WebSocket-Protocol: " .. protocol)
  end
  table.insert(response_lines, "")
  table.insert(response_lines, "")

  return table.concat(response_lines, "\r\n")
end

---Check if the request is for a WebSocket endpoint
---@param request string The HTTP request string
---@return boolean valid True if the request looks like a valid WebSocket upgrade target
local function is_websocket_endpoint(request)
  local first_line = request:match("^([^\r\n]+)")
  if not first_line then return false end
  local method, _, version = first_line:match("^(%S+)%s+(%S+)%s+(%S+)$")
  -- WebSocket upgrade is HTTP/1.1-only (RFC 6455 §1.7).
  return method == "GET" and version ~= nil and version:match("^HTTP/1%.1") ~= nil
end

---Create a WebSocket handshake error response
---@param code number HTTP status code
---@param message string Error message
---@return string response The HTTP error response
local function create_error_response(code, message)
  local status_text = {
    [400] = "Bad Request",
    [404] = "Not Found",
    [426] = "Upgrade Required",
    [500] = "Internal Server Error",
  }
  local status = status_text[code] or "Error"

  local response_lines = {
    "HTTP/1.1 " .. code .. " " .. status,
    "Content-Type: text/plain",
    "Content-Length: " .. #message,
    "Connection: close",
    "",
    message,
  }
  return table.concat(response_lines, "\r\n")
end

---Process a complete WebSocket handshake
---@param request string The HTTP request string
---@param expected_auth_token string|nil Expected authentication token for validation
---@return boolean success True if handshake was successful
---@return string response The HTTP response to send
---@return table|nil headers The parsed headers if successful
---@return string|nil error_message Reason for failure when success is false
function M.process_handshake(request, expected_auth_token)
  if not is_websocket_endpoint(request) then
    local msg = "WebSocket endpoint not found"
    return false, create_error_response(404, msg), nil, msg
  end

  local is_valid_upgrade, validation_payload = validate_upgrade_request(request, expected_auth_token) ---@type boolean, table|string
  if not is_valid_upgrade then
    local error_message = validation_payload ---@cast error_message string
    return false, create_error_response(400, "Bad WebSocket upgrade request: " .. error_message), nil, error_message
  end

  local headers_table = validation_payload ---@cast headers_table table
  local client_key = headers_table["sec-websocket-key"]
  local protocol = headers_table["sec-websocket-protocol"]

  local response = create_handshake_response(client_key, protocol)
  if not response then
    local msg = "Failed to generate WebSocket handshake response"
    return false, create_error_response(500, msg), nil, msg
  end

  return true, response, headers_table, nil
end

---Check if a request buffer contains a complete HTTP request
---@param buffer string The request buffer
---@return boolean complete True if the request is complete
---@return string|nil request The complete request if found
---@return string remaining Any remaining data after the request
function M.extract_http_request(buffer)
  -- Look for the end of HTTP headers (double CRLF)
  local header_end = buffer:find("\r\n\r\n")
  if not header_end then
    return false, nil, buffer
  end

  -- For WebSocket upgrade, there should be no body
  local request = buffer:sub(1, header_end + 3) -- Include the final CRLF
  local remaining = buffer:sub(header_end + 4)

  return true, request, remaining
end

return M
