-- Pure Lua 5.3 SHA-256 (standard FIPS 180-4 algorithm). Uses Lua 5.3's
-- native 64-bit integers and bitwise operators (&, |, ~, <<, >>), which
-- SmartThings Edge's Lua runtime (5.3) supports natively -- no bundled
-- crypto/digest module is assumed to exist, so this is self-contained.
local M = {}

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local MASK32 = 0xFFFFFFFF

local function rrotate(x, n)
  x = x & MASK32
  return ((x >> n) | (x << (32 - n))) & MASK32
end

-- Pads the message per FIPS 180-4 and returns it as a byte string whose
-- length is a multiple of 64.
local function pad(msg)
  local len_bits = #msg * 8
  local padded = msg .. '\128'
  while (#padded % 64) ~= 56 do
    padded = padded .. '\0'
  end
  -- 64-bit big-endian length. Our inputs (cert key material + a couple of
  -- bytes) are always tiny, so the high 32 bits are always zero.
  for i = 7, 0, -1 do
    padded = padded .. string.char((len_bits >> (i * 8)) & 0xFF)
  end
  return padded
end

-- Computes the SHA-256 digest of `msg` (a Lua byte string) and returns it
-- as a 32-byte raw byte string.
function M.digest(msg)
  local h0, h1, h2, h3, h4, h5, h6, h7 =
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  local padded = pad(msg)
  local n_blocks = #padded / 64

  for block = 0, n_blocks - 1 do
    local base = block * 64
    local w = {}
    for t = 0, 15 do
      local o = base + t * 4
      w[t] = (padded:byte(o + 1) << 24) | (padded:byte(o + 2) << 16) |
             (padded:byte(o + 3) << 8) | padded:byte(o + 4)
    end
    for t = 16, 63 do
      local s0 = rrotate(w[t - 15], 7) ~ rrotate(w[t - 15], 18) ~ (w[t - 15] >> 3)
      local s1 = rrotate(w[t - 2], 17) ~ rrotate(w[t - 2], 19) ~ (w[t - 2] >> 10)
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & MASK32
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for t = 0, 63 do
      local S1 = rrotate(e, 6) ~ rrotate(e, 11) ~ rrotate(e, 25)
      local ch = (e & f) ~ ((~e & MASK32) & g)
      local temp1 = (h + S1 + ch + K[t + 1] + w[t]) & MASK32
      local S0 = rrotate(a, 2) ~ rrotate(a, 13) ~ rrotate(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local temp2 = (S0 + maj) & MASK32
      h = g
      g = f
      f = e
      e = (d + temp1) & MASK32
      d = c
      c = b
      b = a
      a = (temp1 + temp2) & MASK32
    end

    h0 = (h0 + a) & MASK32
    h1 = (h1 + b) & MASK32
    h2 = (h2 + c) & MASK32
    h3 = (h3 + d) & MASK32
    h4 = (h4 + e) & MASK32
    h5 = (h5 + f) & MASK32
    h6 = (h6 + g) & MASK32
    h7 = (h7 + h) & MASK32
  end

  local out = {}
  for _, v in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
    out[#out + 1] = string.char((v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
  end
  return table.concat(out)
end

return M
