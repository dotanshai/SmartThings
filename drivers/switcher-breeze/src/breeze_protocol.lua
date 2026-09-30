-- breeze_protocol.lua — Switcher Breeze (Type-2) TCP protocol for SmartThings Edge.
-- v2: IR codes come from the packed all-remotes module (codes_all.lua), selected
-- at runtime by the device's reported remote_id. Covers every AC in the DB.

local socket = require "cosock.socket"
local log = require "log"
local d2 = require "pack_decode3"   -- v3: bucketed, inline-para pack
local PACK = require "codes_all"

local protocol = {}

local PORT = 10000
local PKEY_HEX = string.rep("00", 16)
local PAD_72_ZEROS = string.rep("0", 72)

-- ---- IR code source: decode one remote on demand, cache the small result ----
-- d2.load = open(decompress ~476 KB) + codes(one remote) + discard the stream,
-- so only the per-remote map (tens of KB) stays resident.
local function count_keys(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local code_cache = {}
local function codes_for(remote_id)
  if remote_id == nil or remote_id == "" then
    log.warn("Breeze codes_for: empty remote_id")
    return nil
  end
  if code_cache[remote_id] == nil then
    log.debug("Breeze decoding IR codes for remote_id=" .. tostring(remote_id))
    local t0 = socket.gettime()
    local ok, map = pcall(d2.load, PACK, remote_id)
    if ok and map then
      log.info(string.format("Breeze decoded %d IR keys for remote %s in %.2fs",
        count_keys(map), remote_id, socket.gettime() - t0))
      code_cache[remote_id] = map
    else
      log.warn("Breeze no IR codes for remote_id=" .. tostring(remote_id)
        .. (ok and " (not in DB)" or (": " .. tostring(map))))
      code_cache[remote_id] = false
    end
  end
  return code_cache[remote_id] or nil
end

-- ---- hex helpers ----------------------------------------------------------
local function hex_to_bytes(h) return (h:gsub("..", function(c) return string.char(tonumber(c, 16)) end)) end
local function bytes_to_hex(b) return (b:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)) end
local function ascii_to_hex(s) return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)) end
local function le_u32_hex(n)
  n = math.floor(tonumber(n) or 0)
  return string.format("%02x%02x%02x%02x", n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff)
end

-- ---- CRC signing ----------------------------------------------------------
local function crc_hqx(hex)
  local b, crc = hex_to_bytes(hex), 0x1021
  for i = 1, #b do
    crc = crc ~ (string.byte(b, i) << 8)
    for _ = 1, 8 do
      if (crc & 0x8000) ~= 0 then crc = ((crc << 1) ~ 0x1021) & 0xffff else crc = (crc << 1) & 0xffff end
    end
  end
  return crc & 0xffff
end
local function crc_le(hex) local c = crc_hqx(hex); return string.format("%02x%02x", c & 0xff, (c >> 8) & 0xff) end
local function set_len(hex)
  local total = math.floor(#hex / 2) + 4
  return "fef0" .. string.format("%02x%02x", total & 0xff, (total >> 8) & 0xff) .. hex:sub(9)
end
local function sign(hex)
  hex = set_len(hex)
  local pc = crc_le(hex)
  return hex .. pc .. crc_le(pc .. PKEY_HEX)
end

-- ---- framed TCP over cosock ------------------------------------------------
local function wait_readable(sock, t) local r = socket.select({ sock }, {}, t or 5); return r and #r > 0 end
local function wait_writable(sock, t) local _, w = socket.select({}, { sock }, t or 5); return w and #w > 0 end

local function read_exact(sock, n)
  local out, tot = {}, 0
  while tot < n do
    local d, err, part = sock:receive(n - tot)
    local g = d or part
    if g and #g > 0 then out[#out + 1] = g; tot = tot + #g end
    if tot >= n then break end
    if err == "timeout" then
      if not wait_readable(sock, 5) then error("recv timeout " .. tot .. "/" .. n) end
    elseif err then
      error("recv failed: " .. tostring(err))
    end
  end
  return table.concat(out)
end

local function read_pkt(sock)
  local h = read_exact(sock, 4)
  local len = string.byte(h, 3) + string.byte(h, 4) * 256
  if len < 4 or len > 2048 then error("bad response length " .. len) end
  return h .. read_exact(sock, len - 4)
end

local function send_all(sock, payload)
  local i = 1
  while i <= #payload do
    local sent, err, partial = sock:send(payload, i)
    if sent then i = sent + 1
    elseif err == "timeout" then
      if partial and partial > 0 then i = partial + 1 end
      if not wait_writable(sock, 5) then error("send timeout") end
    else error("send failed: " .. tostring(err)) end
  end
end

local function send_signed(sock, hex)
  send_all(sock, hex_to_bytes(sign(hex)))
  return read_pkt(sock)
end

local function connect(ip)
  log.debug("Breeze TCP connect " .. tostring(ip) .. ":" .. PORT)
  local tcp = assert(socket.tcp())
  tcp:settimeout(5)
  local ok, err = tcp:connect(ip, PORT)
  if not ok and (err == "timeout" or err == "Operation already in progress") then
    log.debug("Breeze connect in progress (" .. tostring(err) .. "), waiting for writable")
    if wait_writable(tcp, 5) then ok, err = tcp:connect(ip, PORT) end
  end
  if ok or err == "already connected" then return tcp end
  pcall(function() tcp:close() end)
  error("connect failed to " .. tostring(ip) .. ":" .. PORT .. " - " .. tostring(err))
end

-- ---- packet builders ------------------------------------------------------
local function login_pkt(ts, id)
  return "fef030000305a600" .. "00000000" .. "ff0301000000" .. "0000" .. "00000000"
      .. ts .. "00000000000000000000f0fe" .. id .. "00"
end
local function getstate_pkt(sess, ts, id)
  return "fef0300003050103" .. sess .. "390001000000000000000000"
      .. ts .. "00000000000000000000f0fe" .. id .. "00"
end
local function command_pkt(sess, ts, id, length, command)
  return "fef0000003050102" .. sess .. "000001000000000000000000"
      .. ts .. "00000000000000000000f0fe" .. id .. PAD_72_ZEROS .. "3701" .. length .. command
end

-- ---- state parse (TCP response offsets) -----------------------------------
local MODES = { ["01"] = "auto", ["02"] = "dry", ["03"] = "fan", ["04"] = "cool", ["05"] = "heat" }
local FANS  = { ["0"] = "auto", ["1"] = "low", ["2"] = "medium", ["3"] = "high" }
local function parse_state(resp)
  local h = bytes_to_hex(resp)
  local remote = (resp:sub(85, 92):gsub("%z+$", ""))   -- bytes[84:92]
  return {
    power  = (h:sub(157, 158) == "00") and "off" or "on",
    mode   = MODES[h:sub(159, 160)] or "cool",
    target = tonumber(h:sub(161, 162), 16) or 24,
    fan    = FANS[h:sub(163, 163)] or "auto",
    swing  = (h:sub(164, 164) == "0") and "off" or "on",
    room   = (tonumber(h:sub(155, 156) .. h:sub(153, 154), 16) or 0) / 10,
    remote_id = remote,
  }
end

-- ---- IR key building (mirrors aioswitcher build_command + fallback) --------
local MODE_CODE = { auto = "aa", dry = "ad", fan = "aw", cool = "ar", heat = "ah" }
local FAN_CODE  = { auto = "f0", low = "f1", medium = "f2", high = "f3" }

local function resolve_key(codes, parts)
  while #parts > 1 do
    local k = table.concat(parts)
    if codes[k] then return k end
    table.remove(parts)
  end
  local k = table.concat(parts)
  return codes[k] and k or nil
end

function protocol.build_key(codes, d)
  if d.power == "off" then return codes["off"] and "off" or nil end
  local parts = {}
  if d.mode == "auto" or d.mode == "dry" or d.mode == "fan" then
    parts[#parts + 1] = MODE_CODE[d.mode]
    parts[#parts + 1] = "_" .. (FAN_CODE[d.fan] or "f0")
  else
    parts[#parts + 1] = MODE_CODE[d.mode] or "ar"
    parts[#parts + 1] = tostring(d.target)
    parts[#parts + 1] = "_" .. (FAN_CODE[d.fan] or "f0")
  end
  if d.swing == "on" then parts[#parts + 1] = "_d1" end
  return resolve_key(codes, parts)
end

local function build_command(entry)
  local command = "00000000" .. ascii_to_hex(entry.Para .. "|" .. entry.HexCode)
  local length = string.format("%x", #command / 2)
  while #length < 4 do length = length .. "0" end
  return length, command
end

-- ---- public API -----------------------------------------------------------
local function login(sock, id)
  local ts = le_u32_hex(os.time())
  local resp = send_signed(sock, login_pkt(ts, id))
  local sess = bytes_to_hex(resp):sub(17, 24)
  log.debug("Breeze login ok: session=" .. sess .. " ts=" .. ts .. " resp_bytes=" .. #resp)
  return sess, ts
end

function protocol.get_state(ip, id)
  local sock = connect(ip)
  local ok, result = pcall(function()
    local sess, ts = login(sock, id)
    local st = parse_state(send_signed(sock, getstate_pkt(sess, ts, id)))
    log.debug(string.format("Breeze get_state: remote=%s power=%s mode=%s fan=%s swing=%s target=%s room=%.1f",
      tostring(st.remote_id), st.power, st.mode, st.fan, st.swing, tostring(st.target), st.room))
    return st
  end)
  pcall(function() sock:close() end)
  if not ok then error(result) end
  return result
end

-- Warm the per-remote code cache (call off the click path, e.g. at init).
-- Returns true if codes are available for remote_id.
function protocol.ensure_codes(remote_id)
  return codes_for(remote_id) ~= nil
end

-- desired: {power, mode, target, fan, swing}. remote_id may be passed in (from a
-- prior get_state) to skip the pre-send read; if nil it is read on the wire.
-- Sends one full-state IR command, then reads the resulting state.
function protocol.apply(ip, id, remote_id, desired)
  log.info(string.format("Breeze apply: want power=%s mode=%s target=%s fan=%s swing=%s (remote=%s)",
    tostring(desired.power), tostring(desired.mode), tostring(desired.target),
    tostring(desired.fan), tostring(desired.swing), tostring(remote_id)))
  local t_start = socket.gettime()
  local sock = connect(ip)
  local t_conn = socket.gettime()
  local ok, result = pcall(function()
    local sess, ts = login(sock, id)
    local t_login = socket.gettime()

    if not remote_id or remote_id == "" then
      remote_id = parse_state(send_signed(sock, getstate_pkt(sess, ts, id))).remote_id
      log.debug("Breeze apply: learned remote_id=" .. tostring(remote_id) .. " via pre-read")
    end
    local t_pre = socket.gettime()

    local codes = codes_for(remote_id)
    if not codes then error("unsupported remote_id '" .. tostring(remote_id) .. "'") end
    local key = protocol.build_key(codes, desired)
    if not key then error("no IR code for desired state (mode=" .. tostring(desired.mode)
        .. " temp=" .. tostring(desired.target) .. " fan=" .. tostring(desired.fan) .. ")") end
    local length, command = build_command(codes[key])
    local t_codes = socket.gettime()

    local ack = send_signed(sock, command_pkt(sess, ts, id, length, command))
    log.info(string.format("Breeze sent key=%s (remote=%s) | timing: connect=%.2f login=%.2f preread=%.2f decode=%.2f send=%.2f total=%.2fs",
      key, tostring(remote_id), t_conn - t_start, t_login - t_conn, t_pre - t_login,
      t_codes - t_pre, socket.gettime() - t_codes, socket.gettime() - t_start))
    log.debug("Breeze command ACK (" .. #ack .. "B): " .. bytes_to_hex(ack):sub(1, 40))

    socket.sleep(1.5)
    local after = parse_state(send_signed(sock, getstate_pkt(sess, ts, id)))
    log.info(string.format("Breeze post-command state: power=%s mode=%s fan=%s target=%s swing=%s room=%.1f",
      after.power, after.mode, after.fan, tostring(after.target), after.swing, after.room))
    after.sent_key = key
    return after
  end)
  pcall(function() sock:close() end)
  if not ok then error(result) end
  return result
end

return protocol
