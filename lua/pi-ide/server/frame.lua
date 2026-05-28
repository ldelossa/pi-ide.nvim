---@brief WebSocket frame encoding and decoding (RFC 6455)
local utils = require("pi-ide.server.utils")

local M = {}

-- WebSocket opcodes
M.OPCODE = {
  CONTINUATION = 0x0,
  TEXT = 0x1,
  BINARY = 0x2,
  CLOSE = 0x8,
  PING = 0x9,
  PONG = 0xA,
}

---@class WebSocketFrame
---@field fin boolean Final fragment flag
---@field opcode number Frame opcode
---@field masked boolean Mask flag
---@field payload_length number Length of payload data
---@field mask string|nil 4-byte mask (if masked)
---@field payload string Frame payload data

local VALID_OPCODES = {
  [M.OPCODE.CONTINUATION] = true,
  [M.OPCODE.TEXT] = true,
  [M.OPCODE.BINARY] = true,
  [M.OPCODE.CLOSE] = true,
  [M.OPCODE.PING] = true,
  [M.OPCODE.PONG] = true,
}

---Parse a WebSocket frame from binary data.
---On error, the third return value distinguishes:
---  nil  -> incomplete frame, caller should wait for more data
---  string -> protocol violation, caller should close with 1002
---@param data string The binary frame data
---@return WebSocketFrame|nil frame The parsed frame, or nil if incomplete/invalid
---@return number bytes_consumed Number of bytes consumed from input
---@return string|nil err Reason when frame is malformed; nil when incomplete
function M.parse_frame(data)
  if type(data) ~= "string" then return nil, 0, "non-string input" end
  if #data < 2 then return nil, 0, nil end

  local pos = 1
  local byte1 = data:byte(pos)
  local byte2 = data:byte(pos + 1)
  pos = pos + 2

  local fin = math.floor(byte1 / 128) == 1
  local rsv1 = math.floor((byte1 % 128) / 64) == 1
  local rsv2 = math.floor((byte1 % 64) / 32) == 1
  local rsv3 = math.floor((byte1 % 32) / 16) == 1
  local opcode = byte1 % 16

  local masked = math.floor(byte2 / 128) == 1
  local payload_len = byte2 % 128

  if not VALID_OPCODES[opcode] then
    return nil, 0, "invalid opcode: " .. opcode
  end
  if rsv1 or rsv2 or rsv3 then
    return nil, 0, "reserved bits set"
  end

  -- Control frames: must have fin=1 and payload <= 125 (RFC 6455 Section 5.5)
  if opcode >= M.OPCODE.CLOSE and (not fin or payload_len > 125) then
    return nil, 0, "fragmented or oversized control frame"
  end

  local actual_payload_len = payload_len
  if payload_len == 126 then
    if #data < pos + 1 then return nil, 0, nil end
    actual_payload_len = utils.bytes_to_uint16(data:sub(pos, pos + 1))
    pos = pos + 2
  elseif payload_len == 127 then
    if #data < pos + 7 then return nil, 0, nil end
    actual_payload_len = utils.bytes_to_uint64(data:sub(pos, pos + 7))
    pos = pos + 8
    if actual_payload_len > 100 * 1024 * 1024 then
      return nil, 0, "payload exceeds 100MB cap"
    end
  end

  local mask = nil
  if masked then
    if #data < pos + 3 then return nil, 0, nil end
    mask = data:sub(pos, pos + 3)
    pos = pos + 4
  end

  if #data < pos + actual_payload_len - 1 then return nil, 0, nil end

  local payload = data:sub(pos, pos + actual_payload_len - 1)
  pos = pos + actual_payload_len

  if masked then
    payload = utils.apply_mask(payload, mask)
  end

  if opcode == M.OPCODE.TEXT and not utils.is_valid_utf8(payload) then
    return nil, 0, "invalid UTF-8 in text frame"
  end

  if opcode == M.OPCODE.CLOSE and actual_payload_len > 0 then
    if actual_payload_len == 1 then
      return nil, 0, "close frame with 1-byte payload"
    end
    if actual_payload_len > 2 and not utils.is_valid_utf8(payload:sub(3)) then
      return nil, 0, "invalid UTF-8 in close reason"
    end
  end

  return {
    fin = fin,
    opcode = opcode,
    masked = masked,
    payload_length = actual_payload_len,
    mask = mask,
    payload = payload,
  }, pos - 1, nil
end

---Create a WebSocket frame
---@param opcode number Frame opcode
---@param payload string Frame payload
---@param fin boolean|nil Final fragment flag (default: true)
---@param masked boolean|nil Whether to mask the frame (default: false for server)
---@return string frame_data The encoded frame data
function M.create_frame(opcode, payload, fin, masked)
  fin = fin ~= false -- Default to true
  masked = masked == true -- Default to false

  local frame_data = {}

  -- First byte: FIN + RSV + Opcode
  local byte1 = opcode
  if fin then
    byte1 = byte1 + 128 -- Set FIN bit (0x80)
  end
  table.insert(frame_data, string.char(byte1))

  -- Payload length and mask bit
  local payload_len = #payload
  local byte2 = 0
  if masked then
    byte2 = byte2 + 128 -- Set MASK bit (0x80)
  end

  if payload_len < 126 then
    byte2 = byte2 + payload_len
    table.insert(frame_data, string.char(byte2))
  elseif payload_len < 65536 then
    byte2 = byte2 + 126
    table.insert(frame_data, string.char(byte2))
    table.insert(frame_data, utils.uint16_to_bytes(payload_len))
  else
    byte2 = byte2 + 127
    table.insert(frame_data, string.char(byte2))
    table.insert(frame_data, utils.uint64_to_bytes(payload_len))
  end

  -- Add mask + masked payload if needed
  if masked then
    local mask = string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))
    table.insert(frame_data, mask)
    payload = utils.apply_mask(payload, mask)
  end
  table.insert(frame_data, payload)

  return table.concat(frame_data)
end

---Create a text frame
---@param text string The text to send
---@param fin boolean|nil Final fragment flag (default: true)
---@return string frame_data The encoded frame data
function M.create_text_frame(text, fin)
  return M.create_frame(M.OPCODE.TEXT, text, fin, false)
end

---Create a close frame
---@param code number|nil Close code (default: 1000)
---@param reason string|nil Close reason (default: empty)
---@return string frame_data The encoded frame data
function M.create_close_frame(code, reason)
  code = code or 1000
  reason = reason or ""

  local payload = utils.uint16_to_bytes(code) .. reason
  return M.create_frame(M.OPCODE.CLOSE, payload, true, false)
end

---Create a ping frame
---@param data string|nil Ping data (default: empty)
---@return string frame_data The encoded frame data
function M.create_ping_frame(data)
  data = data or ""
  return M.create_frame(M.OPCODE.PING, data, true, false)
end

---Create a pong frame
---@param data string|nil Pong data (should match ping data)
---@return string frame_data The encoded frame data
function M.create_pong_frame(data)
  data = data or ""
  return M.create_frame(M.OPCODE.PONG, data, true, false)
end

return M
