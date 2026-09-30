-- pack_decode3.lua — runtime decoder for the v3 packed IR module (codes_all.lua).
-- v3 = Strategy C: inline paras + bucketing. The header (dict + ids + remote->unique
-- map) is decompressed once at open(); each remote's codes come from decompressing
-- ONLY its bucket, so warm-up is sub-second instead of decoding the whole DB.
--
--   local h = M.open(pack)                 -- decompress header only
--   local codes = M.codes(h, "USP07979")   -- decompress that remote's bucket, decode

local M = {}

-- base64 decode (gsub-based; C string buffer, not a huge Lua table)
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = {}
for i = 1, #B64 do DEC[B64:sub(i, i)] = i - 1 end
local function b64decode(data)
  data = data:gsub("[^%w%+/]", "")
  local rem = #data % 4
  local main = data:sub(1, #data - rem)
  local out = main:gsub("(.)(.)(.)(.)", function(a, b, c, d)
    local v = (DEC[a] << 18) | (DEC[b] << 12) | (DEC[c] << 6) | DEC[d]
    return string.char((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
  end)
  if rem == 2 then
    local v = (DEC[data:sub(-2, -2)] << 18) | (DEC[data:sub(-1, -1)] << 12)
    out = out .. string.char((v >> 16) & 0xff)
  elseif rem == 3 then
    local v = (DEC[data:sub(-3, -3)] << 18) | (DEC[data:sub(-2, -2)] << 12) | (DEC[data:sub(-1, -1)] << 6)
    out = out .. string.char((v >> 16) & 0xff, (v >> 8) & 0xff)
  end
  return out
end

-- LZSS decompress (64KB output chunks bound the char table)
local CHUNK = 65536
local function lzss(src, rawlen)
  local chunks, cur, curbase = {}, {}, 0
  local function byteat(q)
    if q > curbase then return cur[q - curbase] end
    local ci = (q - 1) // CHUNK + 1
    return string.byte(chunks[ci], (q - 1) % CHUNK + 1)
  end
  local function push(b)
    cur[#cur + 1] = b
    if #cur == CHUNK then
      local t = {}
      for j = 1, CHUNK do t[j] = string.char(cur[j]) end
      chunks[#chunks + 1] = table.concat(t); cur = {}; curbase = curbase + CHUNK
    end
  end
  local i = 1
  while curbase + #cur < rawlen do
    local flags = string.byte(src, i); i = i + 1
    if not flags then break end
    for b = 0, 7 do
      if curbase + #cur >= rawlen then break end
      if (flags & (1 << b)) ~= 0 then
        push(string.byte(src, i)); i = i + 1
      else
        local lo, hi, ln = string.byte(src, i, i + 2); i = i + 3
        local off, len = lo | (hi << 8), ln + 4
        local pos = curbase + #cur - off
        for _ = 1, len do push(byteat(pos + 1)); pos = pos + 1 end
      end
    end
  end
  local t = {}
  for j = 1, #cur do t[j] = string.char(cur[j]) end
  chunks[#chunks + 1] = table.concat(t)
  return table.concat(chunks)
end

local function block(entry)
  local blob = type(entry.blob) == "table" and table.concat(entry.blob) or entry.blob
  return lzss(b64decode(blob), entry.rawlen)
end
local function split(s)
  local t = {}
  for line in s:gmatch("([^\n]+)") do t[#t + 1] = line end
  return t
end
local function tohex(bytes) return (bytes:gsub(".", function(c) return string.format("%02X", string.byte(c)) end)) end

-- decompress + parse the header directory
function M.open(pack)
  local s = block(pack.header)
  if s:sub(1, 2) ~= "P3" then return nil, "bad magic" end
  local pos = 5
  local function u16() local lo, hi = string.byte(s, pos, pos + 1); pos = pos + 2; return lo | (hi << 8) end
  local function u32() local a, b, c, d = string.byte(s, pos, pos + 3); pos = pos + 4; return a | (b << 8) | (c << 16) | (d << 24) end
  local function blk() local n = u32(); local v = s:sub(pos, pos + n - 1); pos = pos + n; return v end

  local h = { pack = pack, bcache = {} }
  h.dict = split(blk())
  local ids = split(blk())
  local nRemotes = u16()
  h.map = {}
  for i = 1, nRemotes do h.map[i] = u16() end
  h.k = u16()
  h.byId = {}
  for i, id in ipairs(ids) do h.byId[id] = i end
  h.bmLen = (#h.dict + 7) // 8
  return h
end

local function bucket_stream(h, b) -- b is 0-based
  if not h.bcache[b] then h.bcache[b] = block(h.pack.buckets[b + 1]) end
  return h.bcache[b]
end

-- decode one remote's codes (decompresses only its bucket)
function M.codes(h, remote_id)
  local ri = h.byId[remote_id]
  if not ri then return nil end
  local u = h.map[ri]
  local s = bucket_stream(h, u % h.k)
  local pos = 1
  local function u16() local lo, hi = string.byte(s, pos, pos + 1); pos = pos + 2; return lo | (hi << 8) end
  local function u32() local a, b, c, d = string.byte(s, pos, pos + 3); pos = pos + 4; return a | (b << 8) | (c << 16) | (d << 24) end

  -- walk to our blob (the (u//k)-th in the bucket)
  for _ = 1, (u // h.k) do local bl = u32(); pos = pos + bl end
  u32() -- our blob's length prefix (unused; we parse structurally)

  local mode = string.byte(s, pos); pos = pos + 1
  local vary, width, template = {}, 0, nil
  if mode == 0 then
    local nv = string.byte(s, pos); pos = pos + 1
    for i = 1, nv do vary[i] = string.byte(s, pos); pos = pos + 1 end
    width = string.byte(s, pos); pos = pos + 1
    template = s:sub(pos, pos + width - 1); pos = pos + width
  end
  local nlp = string.byte(s, pos); pos = pos + 1
  local paraStrs = {}
  for i = 1, nlp do local ln = u16(); paraStrs[i] = s:sub(pos, pos + ln - 1); pos = pos + ln end
  local bitmap = s:sub(pos, pos + h.bmLen - 1); pos = pos + h.bmLen

  local present = {}
  for i = 0, #h.dict - 1 do
    if (string.byte(bitmap, (i >> 3) + 1) & (1 << (i & 7))) ~= 0 then present[#present + 1] = h.dict[i + 1] end
  end
  local n = #present
  local paraCol
  if nlp > 1 then paraCol = {}; for i = 1, n do paraCol[i] = string.byte(s, pos); pos = pos + 1 end end
  local function paraOf(i) return paraStrs[(paraCol and paraCol[i] or 0) + 1] end

  local result = {}
  if mode == 0 then
    local codes = {}
    for i = 1, n do codes[i] = { string.byte(template, 1, width) } end
    for _, vp in ipairs(vary) do
      local prev = 0
      for i = 1, n do prev = (prev + string.byte(s, pos)) & 0xff; pos = pos + 1; codes[i][vp + 1] = prev end
    end
    for i = 1, n do
      local chars = {}
      for j = 1, width do chars[j] = string.char(codes[i][j]) end
      result[present[i]] = { Para = paraOf(i), HexCode = tohex(table.concat(chars)) }
    end
  else
    for i = 1, n do
      local ln = u16()
      result[present[i]] = { Para = paraOf(i), HexCode = tohex(s:sub(pos, pos + ln - 1)) }
      pos = pos + ln
    end
  end
  return result
end

function M.load(pack, remote_id)
  local h, err = M.open(pack)
  if not h then return nil, err end
  return M.codes(h, remote_id)
end

return M
