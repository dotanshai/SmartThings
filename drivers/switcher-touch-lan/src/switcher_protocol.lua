local socket = require "cosock.socket"
local cosock = require "cosock"
local log = require "log"

local protocol = {}

local PORT = 9957
local PAD_72_ZEROS = string.rep("0", 72)
local P_SESSION = "00000000"
local PKEY_HEX = string.rep("00", 16)
local NO_TIMER = "00000000"

local DISCOVERY_DNI_PREFIX = "sw-touch-lan-tcp-"
local REQUEST_FORMAT_TYPE1_SUFFIX = "340001000000000000000000%s00000000000000000000f0fe"

local function hex_to_bytes(hex)
  return (hex:gsub("..", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

local function bytes_to_hex(bytes)
  return (bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local function trim_nulls(str)
  str = tostring(str or "")
  str = str:gsub("%z", "")
  str = str:gsub("^%s+", "")
  str = str:gsub("%s+$", "")
  return str
end

local function rpad(s, len, ch)
  ch = ch or "0"
  if #s >= len then return s end
  return s .. string.rep(ch, len - #s)
end

local function le_u32_hex(num)
  num = tonumber(num or 0) or 0
  if num < 0 then num = 0 end
  num = math.floor(num)
  local b1 = num & 0xff
  local b2 = (num >> 8) & 0xff
  local b3 = (num >> 16) & 0xff
  local b4 = (num >> 24) & 0xff
  return string.format("%02x%02x%02x%02x", b1, b2, b3, b4)
end

local function timestamp_hex()
  return le_u32_hex(os.time())
end

local function minutes_to_hex_seconds(minutes)
  return le_u32_hex((tonumber(minutes) or 0) * 60)
end

local function crc_hqx(hex)
  local bytes = hex_to_bytes(hex)
  local crc = 0x1021

  for i = 1, #bytes do
    crc = crc ~ (string.byte(bytes, i) << 8)
    for _ = 1, 8 do
      if (crc & 0x8000) ~= 0 then
        crc = ((crc << 1) ~ 0x1021) & 0xffff
      else
        crc = (crc << 1) & 0xffff
      end
    end
  end

  return crc & 0xffff
end

local function crc_le_hex(hex)
  local crc = crc_hqx(hex)
  local lo = crc & 0xff
  local hi = (crc >> 8) & 0xff
  return string.format("%02x%02x", lo, hi)
end

local function set_message_length(hex_packet)
  hex_packet = string.lower(tostring(hex_packet or ""))

  if string.sub(hex_packet, 1, 4) ~= "fef0" or #hex_packet < 8 then
    return hex_packet
  end

  -- Switcher frames store the total message length in bytes after fef0.
  -- The length includes the 4 CRC bytes that sign_packet appends later.
  local total_length = math.floor((#hex_packet / 2) + 4)
  local lo = total_length & 0xff
  local hi = (total_length >> 8) & 0xff

  return "fef0" .. string.format("%02x%02x", lo, hi) .. string.sub(hex_packet, 9)
end

local function sign_packet(hex_packet)
  -- Matches the Python test:
  -- packet_crc = crc_hqx(packet, 0x1021), appended little-endian
  -- key_crc = crc_hqx(packet_crc_le + 16 zero bytes, 0x1021), appended little-endian
  hex_packet = set_message_length(hex_packet)
  local packet_crc = crc_le_hex(hex_packet)
  local key_crc = crc_le_hex(packet_crc .. PKEY_HEX)
  return hex_packet .. packet_crc .. key_crc
end

local function wait_for_read(sock, timeout)
  local timeout_seconds = tonumber(timeout or 5) or 5
  local readable = socket.select({sock}, {}, timeout_seconds)
  return readable and #readable > 0
end

local function wait_for_write(sock, timeout)
  local timeout_seconds = tonumber(timeout or 5) or 5
  local _, writable = socket.select({}, {sock}, timeout_seconds)
  return writable and #writable > 0
end

local function read_exact(sock, n)
  local chunks = {}
  local total = 0

  while total < n do
    local need = n - total
    local data, err, partial = sock:receive(need)

    if partial and #partial > 0 then
      table.insert(chunks, partial)
      total = total + #partial
    end

    if data and #data > 0 then
      table.insert(chunks, data)
      total = total + #data
    end

    if total >= n then
      break
    end

    if err == "timeout" then
      if not wait_for_read(sock, 5) then
        error("receive timeout waiting for " .. tostring(n) .. " bytes, got=" .. tostring(total))
      end
    elseif err then
      error("receive failed: " .. tostring(err) .. " partial_total=" .. tostring(total))
    end
  end

  return table.concat(chunks)
end

local function read_packet(sock)
  local header = read_exact(sock, 4)
  local b3 = string.byte(header, 3)
  local b4 = string.byte(header, 4)
  local length = b3 + (b4 * 256)

  if length < 4 or length > 2048 then
    error("bad response length: " .. tostring(length))
  end

  local rest = read_exact(sock, length - 4)
  return header .. rest
end

local function send_all(sock, payload)
  local index = 1

  while index <= #payload do
    local sent, err, partial_sent = sock:send(payload, index)
    if sent then
      index = sent + 1
    elseif err == "timeout" then
      if partial_sent and partial_sent > 0 then
        index = partial_sent + 1
      end
      if not wait_for_write(sock, 5) then
        error("send timeout")
      end
    else
      error("send failed: " .. tostring(err))
    end
  end
end

local function send_packet(sock, name, packet_hex)
  local signed = sign_packet(packet_hex)
  send_all(sock, hex_to_bytes(signed))
  local response = read_packet(sock)
  return response
end

local function connect(ip, timeout)
  timeout = tonumber(timeout or 5) or 5

  if not ip or tostring(ip) == "" then
    error("host or service not provided, or not known")
  end

  local tcp = assert(socket.tcp())
  tcp:settimeout(timeout)

  local ok, err = tcp:connect(ip, PORT)
  if ok then
    return tcp
  end

  -- SmartThings Edge sockets are non-blocking. A TCP connect can return
  -- nil, "timeout" while the connection is still in progress. Wait for the
  -- socket to become writable, then complete/verify the connection.
  if err == "timeout" or err == "Operation already in progress" or err == "already in progress" then
    if wait_for_write(tcp, timeout) then
      ok, err = tcp:connect(ip, PORT)
      if ok or err == "already connected" or err == "is connected" then
        return tcp
      end
    end
  end

  pcall(function() tcp:close() end)
  error("connect failed to " .. tostring(ip) .. ":" .. tostring(PORT) .. " - " .. tostring(err))
end

local DEVICE_TYPE_NAMES = {
  ["030f"] = "Switcher Mini",
  ["01a8"] = "Switcher Power Plug",
  ["030b"] = "Switcher Touch",
  ["01a7"] = "Switcher V2 (esp)",
  ["01a1"] = "Switcher V2 (qualcomm)",
  ["0317"] = "Switcher V4",
  ["0e01"] = "Switcher Breeze",
  ["0c01"] = "Switcher Runner",
  ["0c02"] = "Switcher Runner Mini",
  ["0f01"] = "Switcher Runner S11",
  ["0f02"] = "Switcher Runner S12",
  ["0f04"] = "Switcher Light SL01",
  ["0f07"] = "Switcher Light SL01 Mini",
  ["0f05"] = "Switcher Light SL02",
  ["0f08"] = "Switcher Light SL02 Mini",
  ["0f06"] = "Switcher Light SL03",
  ["031f"] = "Switcher Heater",
}

-- Device types supported by this driver.
-- Public aioswitcher maps these as Type 1 / WATER_HEATER / no-token devices.
-- Only 030b was tested by us end-to-end; the rest are accepted as experimental.
local SUPPORTED_WATER_HEATER_TYPE1 = {
  ["030b"] = { name = "Switcher Touch", status = "tested" },
  ["030f"] = { name = "Switcher Mini", status = "experimental" },
  ["01a7"] = { name = "Switcher V2 (esp)", status = "experimental" },
  ["01a1"] = { name = "Switcher V2 (qualcomm)", status = "experimental" },
  ["0317"] = { name = "Switcher V4", status = "experimental" },
}

local function water_heater_support(type_hex)
  type_hex = string.lower(tostring(type_hex or ""))
  return SUPPORTED_WATER_HEATER_TYPE1[type_hex]
end

local function device_type_name_from_code(type_hex)
  type_hex = string.lower(tostring(type_hex or ""))

  if type_hex == "" or type_hex == "0000" or #type_hex ~= 4 then
    return nil
  end

  return DEVICE_TYPE_NAMES[type_hex] or ("Unknown " .. type_hex)
end

local function assert_supported_water_heater(type_hex, context)
  local support = water_heater_support(type_hex)
  if support then
    return support
  end

  error(
    "unsupported Switcher device type for this driver"
    .. ", context=" .. tostring(context or "unknown")
    .. ", type_hex=" .. tostring(type_hex or "")
    .. ", known_type=" .. tostring(device_type_name_from_code(type_hex) or "Unknown")
  )
end

local function normalize_device_key(device_key)
  device_key = tostring(device_key or "")
  device_key = string.lower(device_key:gsub("[^0-9a-fA-F]", ""))
  if #device_key == 1 then
    device_key = "0" .. device_key
  end
  if #device_key < 2 then
    return "00"
  end
  return string.sub(device_key, 1, 2)
end

local function login_packet(device_key)
  local key = normalize_device_key(device_key)
  local ts = timestamp_hex()
  local packet =
      "fef052000232a100"
      .. P_SESSION
      .. string.format(REQUEST_FORMAT_TYPE1_SUFFIX, ts)
      .. key
      .. "00"
      .. PAD_72_ZEROS

  return packet, ts, key
end

local function is_switcher_like_login_response(response)
  if not response or #response < 20 then
    return false
  end

  local hx = bytes_to_hex(response)
  if string.sub(hx, 1, 4) ~= "fef0" then
    return false
  end

  local b3 = string.byte(response, 3) or 0
  local b4 = string.byte(response, 4) or 0
  local declared_length = b3 + (b4 * 256)
  if declared_length ~= #response then
    return false
  end

  return string.sub(hx, 9, 16) == "023ca100"
end

local function parse_device_id_from_login(response)
  local hx = bytes_to_hex(response)
  local dev = string.sub(hx, 37, 42) -- bytes 19..21, verified from TCP login response, also present in SHORT replies
  if dev and #dev == 6 and dev ~= "000000" and dev ~= "ffffff" then
    return string.lower(dev)
  end
  return nil
end

local function parse_session_id_from_login(response)
  local hx = bytes_to_hex(response)

  -- Proven working Switcher Touch login responses store the session id at
  -- bytes 25..28, immediately after the 3-byte device id and three zero bytes.
  local session_id = string.sub(hx, 49, 56)

  if session_id and #session_id == 8 and session_id ~= "00000000" then
    return string.lower(session_id)
  end

  return P_SESSION
end

local function parse_identity_from_login(response, attempted_key)
  if not is_switcher_like_login_response(response) then
    return nil
  end

  local hx = bytes_to_hex(response)
  local key = normalize_device_key(attempted_key)
  local device_id = parse_device_id_from_login(response)
  local start = 1

  while true do
    local idx = string.find(hx, "f0fe", start, true)
    if not idx then
      return nil
    end

    -- Full Type-1 identity block layout:
    -- f0fe <device_key> 00 <device_name 32 bytes> <device_type 2 bytes> ...
    local min_end = idx + 4 + 2 + 2 + (32 * 2) + 4 - 1
    if min_end <= #hx then
      local identity_key = string.sub(hx, idx + 4, idx + 5)
      local separator = string.sub(hx, idx + 6, idx + 7)
      local name_hex = string.sub(hx, idx + 8, idx + 8 + (32 * 2) - 1)
      local type_hex = string.sub(hx, idx + 8 + (32 * 2), idx + 8 + (32 * 2) + 3)
      local name = ""

      pcall(function()
        name = trim_nulls(hex_to_bytes(name_hex))
      end)

      if separator == "00" and identity_key == key and name ~= "" and DEVICE_TYPE_NAMES[type_hex] then
        local support = water_heater_support(type_hex)
        return {
          device_key = identity_key,
          device_id = device_id,
          name = name,
          model = DEVICE_TYPE_NAMES[type_hex],
          device_type = DEVICE_TYPE_NAMES[type_hex],
          type_hex = type_hex,
          support_status = support and support.status or "unsupported",
          supported = support ~= nil,
        }
      end
    end

    start = idx + 4
  end
end

local function login_probe_on_socket(sock, device_key)
  local packet, ts, normalized_key = login_packet(device_key)
  local rx = send_packet(sock, "LOGIN_" .. normalized_key, packet)

  if not is_switcher_like_login_response(rx) then
    error("not a Switcher Type-1 login response")
  end

  local device_id = parse_device_id_from_login(rx)
  if not device_id then
    error("failed to parse device_id from login response")
  end

  local identity = parse_identity_from_login(rx, normalized_key)
  return {
    ts = ts,
    key = normalized_key,
    response = rx,
    switcher_like = true,
    full_identity = identity ~= nil,
    device_id = device_id,
    identity = identity,
  }
end

local function login(sock, device_key)
  local probe = login_probe_on_socket(sock, device_key)
  local identity = probe.identity

  if not identity then
    error("login returned SHORT response only; valid device_key is required")
  end

  local support = assert_supported_water_heater(identity.type_hex, "login")
  local session_id = parse_session_id_from_login(probe.response) or P_SESSION

  return session_id,
    probe.ts,
    identity.device_id,
    identity.device_type or support.name,
    identity.type_hex,
    identity.device_key,
    identity.name,
    support.status
end

local function get_state_packet(session_id, ts, device_id)
  local request_part = session_id .. string.format(REQUEST_FORMAT_TYPE1_SUFFIX, ts)
  return "fef0300002320103" .. request_part .. device_id .. "00"
end

local function control_packet(session_id, ts, device_id, command, timer_hex)
  local request_part = session_id .. string.format(REQUEST_FORMAT_TYPE1_SUFFIX, ts)
  return "fef05d0002320102"
      .. request_part
      .. device_id
      .. PAD_72_ZEROS
      .. "000106000"
      .. command
      .. "00"
      .. timer_hex
end

local function le_u32_from_tail(tail, byte_index)
  local start = (byte_index * 2) + 1
  local part = string.sub(tail, start, start + 7)
  if #part < 8 then return 0 end
  local b1 = tonumber(string.sub(part, 1, 2), 16) or 0
  local b2 = tonumber(string.sub(part, 3, 4), 16) or 0
  local b3 = tonumber(string.sub(part, 5, 6), 16) or 0
  local b4 = tonumber(string.sub(part, 7, 8), 16) or 0
  return b1 + (b2 << 8) + (b3 << 16) + (b4 << 24)
end

local function parse_name_from_state_hex(hx)
  local payload_idx = string.find(hx, "f0fe", 1, true)
  if not payload_idx then return nil end

  local name_hex = string.sub(hx, payload_idx + 4, payload_idx + 4 + (32 * 2) - 1)
  if not name_hex or #name_hex < 2 then return nil end

  local ok, name = pcall(function()
    return trim_nulls(hex_to_bytes(name_hex))
  end)

  if ok and name and name ~= "" then
    return name
  end

  return nil
end

local function parse_state_info(response)
  local hx = bytes_to_hex(response)
  local idx = string.find(hx, "031c00", 1, true)

  if not idx then
    return nil
  end

  local tail = string.sub(hx, idx + 6)
  local state_byte = string.sub(tail, 1, 2)
  local state = state_byte == "01" and "on" or "off"

  -- Observed Switcher Touch state packet after marker 03 1c 00:
  -- byte 0       = switch state, 01 on / 00 off
  -- bytes 2-5   = current power consumption in watts, uint32 little-endian
  -- bytes 6-9   = cumulative/energy-like value, not current watts
  -- bytes 14-17 = remaining seconds LE
  -- bytes 18-21 = elapsed seconds LE
  -- bytes 22-25 = configured/default timer seconds LE, often 7200
  local power_watts = le_u32_from_tail(tail, 2)
  local remaining_seconds = le_u32_from_tail(tail, 14)
  local elapsed_seconds = le_u32_from_tail(tail, 18)

  -- For runtime display, current run total is remaining + elapsed.
  -- The packet's bytes 22-25 are the device default/max timer, not the active one for 60s tests.
  local active_total_seconds = remaining_seconds + elapsed_seconds

  if state ~= "on" then
    remaining_seconds = 0
    elapsed_seconds = 0
    active_total_seconds = 0
    power_watts = 0
  end

  if power_watts < 0 or power_watts > 10000 then
    power_watts = 0
  end

  return {
    state = state,
    name = parse_name_from_state_hex(hx) or "Switcher Water Heater",
    remaining_seconds = remaining_seconds,
    elapsed_seconds = elapsed_seconds,
    total_seconds = active_total_seconds,
    power_watts = power_watts,
  }
end

local function get_state_on_socket(sock, session_id, ts, device_id)
  local rx = send_packet(sock, "GET_STATE", get_state_packet(session_id, ts, device_id))
  local info = parse_state_info(rx)
  if not info then
    error("failed to parse state response")
  end
  return info
end

function protocol.get_state(ip, device_id, device_key)
  local sock = connect(ip, 5)
  local ok, result = pcall(function()
    local session_id, ts, login_device_id, device_type_name, device_type_hex, login_device_key, name, support_status = login(sock, device_key)

    if not device_id or device_id == "" or device_id == "000000" then
      device_id = login_device_id
    end

    if string.lower(tostring(device_id or "")) ~= string.lower(tostring(login_device_id or "")) then
      error("device_id mismatch: expected=" .. tostring(device_id) .. ", got=" .. tostring(login_device_id))
    end

    local support = assert_supported_water_heater(device_type_hex, "get_state")
    local info = get_state_on_socket(sock, session_id, ts, device_id)
    info.device_id = login_device_id
    info.device_key = login_device_key
    info.device_type = device_type_name or support.name
    info.device_type_hex = device_type_hex
    info.type_hex = device_type_hex
    info.name = info.name or name
    info.support_status = support_status or support.status
    return info
  end)

  pcall(function() sock:close() end)
  if not ok then error(result) end
  return result
end

function protocol.set_power(ip, device_id, device_key, power, minutes)
  local sock = connect(ip, 5)
  local ok, result = pcall(function()
    local session_id, ts, login_device_id, _, device_type_hex = login(sock, device_key)
    assert_supported_water_heater(device_type_hex, "set_power")

    if not device_id or device_id == "" or device_id == "000000" then
      device_id = login_device_id
    end

    if string.lower(tostring(device_id or "")) ~= string.lower(tostring(login_device_id or "")) then
      error("device_id mismatch: expected=" .. tostring(device_id) .. ", got=" .. tostring(login_device_id))
    end

    local command = power == "on" and "1" or "0"
    local timer = NO_TIMER
    if power == "on" and tonumber(minutes or 0) > 0 then
      timer = minutes_to_hex_seconds(tonumber(minutes))
    end

    send_packet(sock, "CONTROL_" .. string.upper(power) .. "_" .. tostring(minutes or 0),
      control_packet(session_id, ts, device_id, command, timer))

    return true
  end)

  pcall(function() sock:close() end)
  if not ok then error(result) end
  return result
end

function protocol.identify(ip, device_key, timeout_seconds)
  local sock = connect(ip, timeout_seconds or 5)
  local ok, result = pcall(function()
    local _, _, device_id, device_type_name, device_type_hex, login_device_key, name, support_status = login(sock, device_key)
    local support = water_heater_support(device_type_hex)

    return {
      ip = ip,
      device_id = device_id,
      device_key = login_device_key,
      name = name,
      model = device_type_name,
      device_type = device_type_name,
      type_hex = device_type_hex,
      supported = support ~= nil,
      support_status = support_status or (support and support.status or "unsupported"),
    }
  end)

  pcall(function() sock:close() end)
  if not ok then error(result) end
  return result
end

local function key_scan_order()
  local keys = {}
  for i = 0, 255 do
    table.insert(keys, string.format("%02x", i))
  end
  return keys
end

local function same_socket_key_scan(ip, expected_device_id, delay_ms, timeout_seconds)
  local sock = connect(ip, timeout_seconds or 5)
  local ok, result = pcall(function()
    local expected = string.lower(tostring(expected_device_id or ""))
    local keys = key_scan_order()
    local delay = tonumber(delay_ms or 10) or 10
    local attempts = 0

    for _, key in ipairs(keys) do
      attempts = attempts + 1
      if attempts > 1 and delay > 0 then
        socket.sleep(delay / 1000)
      end

      local probe = login_probe_on_socket(sock, key)
      local identity = probe.identity

      if identity and identity.supported then
        if expected == "" or string.lower(tostring(identity.device_id or "")) == expected then
          identity.ip = ip
          identity.device_key = key
          identity.attempts = attempts
          log.warn("Switcher key scan found FULL identity: ip=" .. tostring(ip) .. ", device_id=" .. tostring(identity.device_id) .. ", key=" .. tostring(key) .. ", attempts=" .. tostring(attempts))
          return identity
        end
      end
    end

    return nil
  end)

  pcall(function() sock:close() end)
  if not ok then error(result) end
  return result
end

function protocol.find_key_for_device_at_ip(ip, expected_device_id, delay_ms)
  return same_socket_key_scan(ip, expected_device_id, delay_ms or 10, 5)
end

local function ip_token(ip)
  return tostring(ip or "unknown"):gsub("%.", "_")
end

function protocol.is_supported_water_heater_type(type_hex)
  return water_heater_support(type_hex) ~= nil
end

function protocol.support_status(type_hex)
  local support = water_heater_support(type_hex)
  return support and support.status or "unsupported"
end

function protocol.discovery_dni(info)
  -- Stable public-release DNI: keep SmartThings identity tied to the
  -- Switcher device id only. The IP address is saved separately by init.lua
  -- and can change without creating a duplicate SmartThings device.
  return DISCOVERY_DNI_PREFIX .. tostring(info.device_id or "000000")
end

function protocol.parse_discovery_dni(dni)
  dni = tostring(dni or "")

  local prefixes = {
    DISCOVERY_DNI_PREFIX,
  }

  local rest = nil
  for _, prefix in ipairs(prefixes) do
    if string.sub(dni, 1, #prefix) == prefix then
      rest = string.sub(dni, #prefix + 1)
      break
    end
  end

  if not rest then
    return nil
  end

  local sep = string.find(rest, "-", 1, true)
  local device_id = rest
  local ip = ""

  -- Backward compatibility for older private builds:
  -- sw-touch-lan-tcp-<device_id>-<ip_with_underscores>
  if sep then
    device_id = string.sub(rest, 1, sep - 1)
    local token = string.sub(rest, sep + 1)
    local a, b, c, d = string.match(token, "^(%d+)_(%d+)_(%d+)_(%d+)$")
    if a then
      ip = table.concat({a, b, c, d}, ".")
    end
  end

  if not string.match(device_id, "^[0-9a-fA-F]+$") then
    return nil
  end

  return {
    ip = ip,
    device_id = string.lower(device_id),
    device_key = "",
  }
end

local function get_local_ipv4()
  local udp = socket.udp()
  if not udp then return nil end

  udp:settimeout(0.2)

  local ok, ip_or_err, port = pcall(function()
    assert(udp:setsockname("*", 0))
    local ip, local_port = udp:getsockname()
    return ip, local_port
  end)

  pcall(function() udp:close() end)

  if ok and ip_or_err and tostring(ip_or_err) ~= "0.0.0.0" and tostring(ip_or_err) ~= "*" then
    return tostring(ip_or_err)
  end

  return nil
end

local function subnet_prefix_from_ip(ip)
  ip = tostring(ip or "")
  local a, b, c = string.match(ip, "^(%d+)%.(%d+)%.(%d+)%.%d+$")
  if a and b and c then
    return string.format("%s.%s.%s.", a, b, c)
  end
  return nil
end

local function probe_ip(ip, probe_key)
  local sock = socket.tcp()
  if not sock then return nil end

  sock:settimeout(0.8)

  local ok_connect = pcall(function()
    assert(sock:connect(ip, PORT))
  end)

  if not ok_connect then
    pcall(function() sock:close() end)
    return nil
  end

  local ok, info_or_err = pcall(function()
    local probe = login_probe_on_socket(sock, probe_key or "00")
    return {
      ip = ip,
      device_id = probe.device_id,
      device_key = probe.identity and probe.identity.device_key or nil,
      name = probe.identity and probe.identity.name or nil,
      model = probe.identity and probe.identity.model or nil,
      device_type = probe.identity and probe.identity.device_type or nil,
      type_hex = probe.identity and probe.identity.type_hex or nil,
      support_status = probe.identity and probe.identity.support_status or nil,
      supported = probe.identity and probe.identity.supported or nil,
      full_identity = probe.full_identity,
      switcher_like = probe.switcher_like,
      mac = "",
    }
  end)

  pcall(function() sock:close() end)

  if ok and type(info_or_err) == "table" and info_or_err.device_id then
    log.warn("Switcher TCP discovery probe: ip=" .. tostring(ip) .. ", device_id=" .. tostring(info_or_err.device_id) .. ", full_identity=" .. tostring(info_or_err.full_identity))
    return info_or_err
  end

  if not ok then
    log.debug("Switcher TCP discovery probe failed for " .. tostring(ip) .. ": " .. tostring(info_or_err))
  end
  return nil
end

function protocol.discover(timeout_seconds, scan_prefix_override, opts)
  timeout_seconds = tonumber(timeout_seconds or 40) or 40
  if timeout_seconds < 5 then timeout_seconds = 5 end
  if timeout_seconds > 90 then timeout_seconds = 90 end
  opts = type(opts) == "table" and opts or {}

  local local_ip = get_local_ipv4()
  local prefix = scan_prefix_override
  if not prefix or prefix == "" then
    prefix = subnet_prefix_from_ip(local_ip)
  end

  if not prefix or prefix == "" then
    log.warn("Switcher TCP discovery skipped - no local subnet prefix was detected")
    return {}
  end

  if not string.match(prefix, "%.$") then
    prefix = prefix .. "."
  end

  log.warn("Switcher TCP discovery start, prefix=" .. tostring(prefix))

  local results = {}
  local seen = {}
  local next_host = 1
  local workers = tonumber(opts.workers or 16) or 16
  if workers < 1 then workers = 1 end
  if workers > 32 then workers = 32 end
  local active_workers = workers
  local deadline = socket.gettime() + timeout_seconds
  local probe_key = opts.probe_key or "00"
  local key_scan_delay_ms = tonumber(opts.key_scan_delay_ms or 10) or 10

  local function candidate_should_be_skipped(candidate)
    if type(opts.on_candidate) ~= "function" then
      return false
    end

    local ok_callback, action = pcall(opts.on_candidate, candidate)
    if not ok_callback then
      log.warn("Switcher discovery on_candidate callback failed: " .. tostring(action))
      return false
    end

    return action == false or action == "skip" or action == "existing"
  end

  local function worker(worker_id)
    while socket.gettime() < deadline do
      local host = next_host
      next_host = next_host + 1

      if host > 254 then
        break
      end

      local ip = prefix .. tostring(host)
      local candidate = probe_ip(ip, probe_key)

      if candidate and candidate.device_id then
        if seen[candidate.device_id] then
          log.warn("Switcher TCP discovery duplicate candidate skipped inside scan: device_id=" .. tostring(candidate.device_id) .. ", ip=" .. tostring(ip))
        elseif candidate_should_be_skipped(candidate) then
          seen[candidate.device_id] = true
          log.warn("Switcher TCP discovery candidate already handled by existing device: device_id=" .. tostring(candidate.device_id) .. ", ip=" .. tostring(ip))
        else
          local info = nil

          if candidate.full_identity and candidate.supported then
            info = candidate
          else
            local ok_scan, scan_or_err = pcall(function()
              return same_socket_key_scan(ip, candidate.device_id, key_scan_delay_ms, 5)
            end)

            if ok_scan then
              info = scan_or_err
            else
              log.warn("Switcher TCP discovery key scan failed for ip=" .. tostring(ip) .. ": " .. tostring(scan_or_err))
            end
          end

          if info and info.device_id and info.supported and water_heater_support(info.type_hex) then
            seen[info.device_id] = true
            log.warn("Switcher TCP discovery found supported water heater: device_id=" .. tostring(info.device_id) .. ", ip=" .. tostring(info.ip) .. ", key=" .. tostring(info.device_key) .. ", type_hex=" .. tostring(info.type_hex))
            table.insert(results, info)
          elseif info and info.device_id then
            log.warn("Switcher TCP discovery unsupported device skipped after identity: device_id=" .. tostring(info.device_id) .. ", ip=" .. tostring(ip) .. ", type_hex=" .. tostring(info.type_hex or ""))
          end
        end
      end
    end

    active_workers = active_workers - 1
  end

  for i = 1, workers do
    cosock.spawn(function()
      worker(i)
    end, "switcher-tcp-scan-" .. tostring(i))
  end

  -- Give spawned workers one scheduler tick before waiting.
  socket.sleep(0.1)

  while socket.gettime() < deadline and active_workers > 0 do
    socket.sleep(0.1)
  end

  log.warn("Switcher TCP discovery done, found=" .. tostring(#results) .. ", next_host=" .. tostring(next_host) .. ", active_workers=" .. tostring(active_workers))
  return results
end

function protocol.rediscover_known_device(wanted_device_id, known_device_key, timeout_seconds, scan_prefix_override)
  wanted_device_id = string.lower(tostring(wanted_device_id or ""))
  known_device_key = normalize_device_key(known_device_key)

  if wanted_device_id == "" or known_device_key == "" then
    return nil
  end

  timeout_seconds = tonumber(timeout_seconds or 30) or 30
  if timeout_seconds < 5 then timeout_seconds = 5 end
  if timeout_seconds > 90 then timeout_seconds = 90 end

  local local_ip = get_local_ipv4()
  local prefix = scan_prefix_override
  if not prefix or prefix == "" then
    prefix = subnet_prefix_from_ip(local_ip)
  end
  if not prefix or prefix == "" then
    log.warn("Switcher known-device rediscovery skipped - no local subnet prefix was detected")
    return nil
  end
  if not string.match(prefix, "%.$") then
    prefix = prefix .. "."
  end

  log.warn("Switcher known-device rediscovery start, device_id=" .. tostring(wanted_device_id) .. ", prefix=" .. tostring(prefix))

  local found = nil
  local next_host = 1
  local workers = 16
  local active_workers = workers
  local deadline = socket.gettime() + timeout_seconds

  local function worker(worker_id)
    while socket.gettime() < deadline and not found do
      local host = next_host
      next_host = next_host + 1
      if host > 254 then break end

      local ip = prefix .. tostring(host)
      local ok, identity_or_err = pcall(function()
        return protocol.identify(ip, known_device_key, 0.8)
      end)

      if ok and identity_or_err and string.lower(tostring(identity_or_err.device_id or "")) == wanted_device_id then
        identity_or_err.ip = ip
        found = identity_or_err
        log.warn("Switcher known-device rediscovery found IP=" .. tostring(ip) .. ", device_id=" .. tostring(wanted_device_id))
        break
      end
    end
    active_workers = active_workers - 1
  end

  for i = 1, workers do
    cosock.spawn(function()
      worker(i)
    end, "switcher-known-rediscovery-" .. tostring(i))
  end

  socket.sleep(0.1)
  while socket.gettime() < deadline and active_workers > 0 and not found do
    socket.sleep(0.1)
  end

  log.warn("Switcher known-device rediscovery done, found=" .. tostring(found ~= nil) .. ", next_host=" .. tostring(next_host) .. ", active_workers=" .. tostring(active_workers))
  return found
end

return protocol
