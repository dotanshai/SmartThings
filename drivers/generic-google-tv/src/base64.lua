-- Minimal base64 decoder (no external deps), used to turn PEM bodies into raw DER bytes.
local M = {}

local B = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local DECODE = {}
for i = 1, #B do
  DECODE[B:sub(i, i)] = i - 1
end

-- Decodes a base64 string (whitespace/newlines are ignored) into raw bytes.
--
-- Uses Lua 5.3 native integer bitwise ops rather than floating-point math --
-- an earlier float-based version silently corrupted output after ~8
-- characters once the accumulator exceeded double-precision's exact-integer
-- range. `buffer` is masked back down to just the unconsumed bits after
-- every byte extraction so it never grows past a handful of bits.
function M.decode(data)
  data = data:gsub('[^%w%+%/%=]', '')
  local out = {}
  local buffer, bits = 0, 0
  for i = 1, #data do
    local c = data:sub(i, i)
    if c ~= '=' then
      local v = DECODE[c]
      if v then
        buffer = (buffer << 6) | v
        bits = bits + 6
        if bits >= 8 then
          bits = bits - 8
          local byte = (buffer >> bits) & 0xFF
          out[#out + 1] = string.char(byte)
          buffer = buffer & ((1 << bits) - 1)
        end
      end
    end
  end
  return table.concat(out)
end

-- Extracts the base64 body from a PEM block (any "-----BEGIN ...-----" / "-----END ...-----" pair)
-- and returns the decoded raw DER bytes.
function M.pem_to_der(pem)
  local body = pem:match('-----BEGIN [^-]+-----(.-)-----END [^-]+-----')
  if not body then
    return nil, 'not a PEM block'
  end
  return M.decode(body)
end

return M
