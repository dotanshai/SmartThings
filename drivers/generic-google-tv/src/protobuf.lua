-- Minimal protobuf wire-format helpers.
--
-- We don't need a general protobuf library -- every message in the Android
-- TV Remote v2 protocol (both pairingmessage.proto and remotemessage.proto)
-- only uses two wire types: varint (0) for ints/bools/enums, and
-- length-delimited (2) for strings/bytes/embedded messages. So this file
-- just implements those two, keyed by field number, which is enough to
-- both build and parse every message we need.
local M = {}

local WIRETYPE_VARINT = 0
local WIRETYPE_LEN = 2
M.WIRETYPE_VARINT = WIRETYPE_VARINT
M.WIRETYPE_LEN = WIRETYPE_LEN

local function encode_varint(n)
  local out = {}
  -- Protobuf varints are unsigned for our purposes (field numbers, enums,
  -- small non-negative counters); negative numbers are never sent by this
  -- driver.
  repeat
    local byte = n % 128
    n = math.floor(n / 128)
    if n > 0 then byte = byte + 128 end
    out[#out + 1] = string.char(byte)
  until n == 0
  return table.concat(out)
end
M.encode_varint = encode_varint

-- Decodes a varint starting at 1-based position `pos`. Returns the value
-- and the position of the next byte after it.
local function decode_varint(data, pos)
  local result, shift = 0, 0
  while true do
    local b = data:byte(pos)
    pos = pos + 1
    result = result + ((b % 128) * (2 ^ shift))
    if b < 128 then break end
    shift = shift + 7
  end
  return math.floor(result), pos
end
M.decode_varint = decode_varint

local function encode_tag(field_number, wiretype)
  return encode_varint((field_number * 8) + wiretype)
end

-- Encodes a varint-typed field (int32/uint32/bool/enum).
function M.field_varint(field_number, n)
  if type(n) == 'boolean' then n = n and 1 or 0 end
  return encode_tag(field_number, WIRETYPE_VARINT) .. encode_varint(n)
end

-- Encodes a length-delimited field (string/bytes/embedded message). `value`
-- must already be a raw byte string.
function M.field_bytes(field_number, value)
  return encode_tag(field_number, WIRETYPE_LEN) .. encode_varint(#value) .. value
end

-- Concatenates any number of already-encoded fields into one message body.
function M.message(...)
  return table.concat({ ... })
end

-- Parses a message body into a list of { field = n, wiretype = w, value = v }
-- (value is a number for varints, a raw byte string for length-delimited
-- fields). Caller matches on `field` to interpret each entry.
function M.parse(data)
  local entries = {}
  local pos = 1
  local len = #data
  while pos <= len do
    local tag
    tag, pos = decode_varint(data, pos)
    local field_number = math.floor(tag / 8)
    local wiretype = tag % 8
    if wiretype == WIRETYPE_VARINT then
      local value
      value, pos = decode_varint(data, pos)
      entries[#entries + 1] = { field = field_number, wiretype = wiretype, value = value }
    elseif wiretype == WIRETYPE_LEN then
      local vlen
      vlen, pos = decode_varint(data, pos)
      local value = data:sub(pos, pos + vlen - 1)
      pos = pos + vlen
      entries[#entries + 1] = { field = field_number, wiretype = wiretype, value = value }
    else
      error('unsupported wiretype ' .. tostring(wiretype) .. ' (this driver only speaks varint/length-delimited fields)')
    end
  end
  return entries
end

-- Convenience: parse a message body and return a plain { [field_number] = value }
-- map, keeping only the *last* occurrence of each field (fine for all the
-- non-repeated fields we care about; repeated fields like PairingOption's
-- input_encodings are handled by the caller iterating M.parse directly).
function M.parse_map(data)
  local map = {}
  for _, entry in ipairs(M.parse(data)) do
    map[entry.field] = entry.value
  end
  return map
end

return M
