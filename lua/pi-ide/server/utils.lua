---@brief Utility functions for WebSocket server implementation
local M = {}

local bit = require("bit")
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local bnot = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift
local rol = bit.rol

local function add32(a, b)
  return band(a + b, 0xFFFFFFFF)
end

---Base64 encode a string
---@param data string The data to encode
---@return string encoded The base64 encoded string
function M.base64_encode(data)
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local result = {}
  local padding = ""

  local pad_len = 3 - (#data % 3)
  if pad_len ~= 3 then
    data = data .. string.rep("\0", pad_len)
    padding = string.rep("=", pad_len)
  end

  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local bitmap = a * 65536 + b * 256 + c
    local i1 = math.floor(bitmap / 262144) + 1
    local i2 = math.floor((bitmap % 262144) / 4096) + 1
    local i3 = math.floor((bitmap % 4096) / 64) + 1
    local i4 = (bitmap % 64) + 1
    result[#result + 1] = chars:sub(i1, i1)
    result[#result + 1] = chars:sub(i2, i2)
    result[#result + 1] = chars:sub(i3, i3)
    result[#result + 1] = chars:sub(i4, i4)
  end

  local encoded = table.concat(result)
  return encoded:sub(1, #encoded - #padding) .. padding
end

---Pure Lua SHA-1 implementation
---@param data string The data to hash
---@return string|nil hash The SHA-1 hash in binary format, or nil on error
function M.sha1(data)
  if type(data) ~= "string" then return nil end
  if #data > 10 * 1024 * 1024 then return nil end

  local h0 = 0x67452301
  local h1 = 0xEFCDAB89
  local h2 = 0x98BADCFE
  local h3 = 0x10325476
  local h4 = 0xC3D2E1F0

  local msg = data .. string.char(0x80)
  while (#msg % 64) ~= 56 do
    msg = msg .. string.char(0x00)
  end

  -- 64-bit big-endian length. Inputs are capped at 10 MB above, so bit_len
  -- always fits in 32 bits; the high four bytes are zero. The split is
  -- necessary because LuaJIT bit.rshift masks the shift count to 5 bits, so
  -- bit.rshift(x, 32) returns x rather than 0.
  local bit_len = #data * 8
  for i = 7, 0, -1 do
    local byte = i >= 4 and 0 or band(rshift(bit_len, i * 8), 0xFF)
    msg = msg .. string.char(byte)
  end

  for chunk_start = 1, #msg, 64 do
    local w = {}

    for i = 0, 15 do
      local offset = chunk_start + i * 4
      w[i] = bor(
        bor(bor(lshift(msg:byte(offset), 24), lshift(msg:byte(offset + 1), 16)), lshift(msg:byte(offset + 2), 8)),
        msg:byte(offset + 3)
      )
    end

    for i = 16, 79 do
      w[i] = rol(bxor(bxor(bxor(w[i - 3], w[i - 8]), w[i - 14]), w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4

    for i = 0, 79 do
      local f, k
      if i <= 19 then
        f = bor(band(b, c), band(bnot(b), d))
        k = 0x5A827999
      elseif i <= 39 then
        f = bxor(bxor(b, c), d)
        k = 0x6ED9EBA1
      elseif i <= 59 then
        f = bor(bor(band(b, c), band(b, d)), band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(bxor(b, c), d)
        k = 0xCA62C1D6
      end

      local temp = add32(add32(add32(add32(rol(a, 5), f), e), k), w[i])
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = temp
    end

    h0 = add32(h0, a)
    h1 = add32(h1, b)
    h2 = add32(h2, c)
    h3 = add32(h3, d)
    h4 = add32(h4, e)
  end

  local result = ""
  for _, h in ipairs({ h0, h1, h2, h3, h4 }) do
    result = result
      .. string.char(band(rshift(h, 24), 0xFF), band(rshift(h, 16), 0xFF), band(rshift(h, 8), 0xFF), band(h, 0xFF))
  end

  return result
end

---Generate WebSocket accept key from client key
---@param client_key string The client's WebSocket-Key header value
---@return string|nil accept_key The WebSocket accept key, or nil on error
function M.generate_accept_key(client_key)
  -- RFC 6455: concatenate Sec-WebSocket-Key with magic string, SHA-1, base64.
  local magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  local hash = M.sha1(client_key .. magic_string)
  if not hash then return nil end
  return M.base64_encode(hash)
end

---Parse HTTP headers from request string
---@param request string The HTTP request string
---@return table headers Table of header name -> value pairs (names lowercased)
function M.parse_http_headers(request)
  local headers = {}
  local first = true
  for line in request:gmatch("[^\r\n]+") do
    if first then
      first = false
    else
      local name, value = line:match("^([^:]+):%s*(.+)$")
      if name and value then
        headers[name:lower()] = value
      end
    end
  end
  return headers
end

---Check if a string contains valid UTF-8
---@param str string The string to check
---@return boolean valid True if the string is valid UTF-8
function M.is_valid_utf8(str)
  local i = 1
  while i <= #str do
    local byte = str:byte(i)
    local char_len = 1

    if byte >= 0x80 then
      if byte >= 0xF0 then
        char_len = 4
      elseif byte >= 0xE0 then
        char_len = 3
      elseif byte >= 0xC0 then
        char_len = 2
      else
        return false
      end

      for j = 1, char_len - 1 do
        if i + j > #str then return false end
        local cont_byte = str:byte(i + j)
        if cont_byte < 0x80 or cont_byte >= 0xC0 then return false end
      end
    end

    i = i + char_len
  end

  return true
end

---Convert a 16-bit number to big-endian bytes
---@param num number The number to convert
---@return string bytes The big-endian byte representation
function M.uint16_to_bytes(num)
  return string.char(math.floor(num / 256), num % 256)
end

---Convert a 64-bit number to big-endian bytes
---@param num number The number to convert
---@return string bytes The big-endian byte representation
function M.uint64_to_bytes(num)
  local bytes = {}
  for i = 8, 1, -1 do
    bytes[i] = num % 256
    num = math.floor(num / 256)
  end
  return string.char(unpack(bytes))
end

---Convert big-endian bytes to a 16-bit number
---@param bytes string The byte string (2 bytes)
---@return number num The converted number
function M.bytes_to_uint16(bytes)
  if #bytes < 2 then return 0 end
  return bytes:byte(1) * 256 + bytes:byte(2)
end

---Convert big-endian bytes to a 64-bit number
---@param bytes string The byte string (8 bytes)
---@return number num The converted number
function M.bytes_to_uint64(bytes)
  if #bytes < 8 then return 0 end
  local num = 0
  for i = 1, 8 do
    num = num * 256 + bytes:byte(i)
  end
  return num
end

---Apply XOR mask to payload data
---@param data string The data to mask/unmask
---@param mask string The 4-byte mask
---@return string masked The masked/unmasked data
function M.apply_mask(data, mask)
  local m1, m2, m3, m4 = mask:byte(1, 4)
  local mask_bytes = { m1, m2, m3, m4 }
  local result = {}
  for i = 1, #data do
    result[i] = string.char(bxor(data:byte(i), mask_bytes[((i - 1) % 4) + 1]))
  end
  return table.concat(result)
end

return M
