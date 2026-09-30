-- dolphin_api.lua
-- Uses ST Edge native socket + ssl modules (no cosock.asyncify needed).
-- ST Edge socket docs: https://developer.smartthings.com/docs/edge-device-drivers/socket.html
-- ST Edge ssl docs:    https://developer.smartthings.com/docs/edge-device-drivers/ssl.html

local log    = require("log")
local json   = require("dkjson")
local socket = require("socket")
local ssl    = require("ssl")

local M = {}
local BASE_HOST = "api.dolphinboiler.com"
local BASE_IP   = "3.234.198.59"
local BASE_PORT = 443
local key_cache = {}

local function urlencode(str)
  return tostring(str):gsub("([^%w%-%.%_%~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end):gsub(" ", "+")
end

-----------------------------------------------------------------------
-- HTTPS POST via ST Edge native socket + ssl
-----------------------------------------------------------------------
local function post(path, params)
  local parts = {}
  for k, v in pairs(params) do
    parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(v)
  end
  local body = table.concat(parts, "&")

  local request = table.concat({
    "POST " .. path .. " HTTP/1.1",
    "Host: " .. BASE_HOST,
    "Content-Type: application/x-www-form-urlencoded",
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body
  }, "\r\n")

  -- Connect TCP
  local sock = socket.tcp()
  sock:settimeout(15)

  local ok, err = sock:connect(BASE_IP, BASE_PORT)
  if not ok then
    -- handle non-blocking timeout
    if err == "timeout" then
      socket.select({}, {sock})
      ok, err = sock:connect(BASE_IP, BASE_PORT)
    end
    if not ok and err ~= "already connected" then
      sock:close()
      return nil, "TCP connect failed: " .. tostring(err)
    end
  end

  -- Wrap TLS
  local tls, terr = ssl.wrap(sock, {
    mode     = "client",
    protocol = "any",
    verify   = "none",
    options  = {"all", "no_sslv2", "no_sslv3"},
  })
  if not tls then
    sock:close()
    return nil, "TLS wrap failed: " .. tostring(terr)
  end

  tls:settimeout(15)

  -- Handshake
  local hs, herr = tls:dohandshake()
  if not hs then
    if herr == "timeout" then
      socket.select({tls}, {tls})
      hs, herr = tls:dohandshake()
    end
    if not hs then
      tls:close()
      return nil, "TLS handshake failed: " .. tostring(herr)
    end
  end

  -- Send
  local sent, serr = tls:send(request)
  if not sent then
    tls:close()
    return nil, "Send failed: " .. tostring(serr)
  end

  -- Receive
  local chunks = {}
  while true do
    local chunk, rerr = tls:receive(4096)
    if chunk then
      chunks[#chunks + 1] = chunk
    elseif rerr == "timeout" then
      socket.select({tls})
    else
      break
    end
  end
  tls:close()

  local full = table.concat(chunks)
  if full == "" then return nil, "Empty response" end

  -- Parse HTTP
  local header_end = full:find("\r\n\r\n")
  if not header_end then return nil, "Malformed HTTP response" end

  local header_part = full:sub(1, header_end - 1)
  local resp_body   = full:sub(header_end + 4)
  local code        = tonumber(header_part:match("HTTP/%d+%.%d+ (%d+)"))

  log.debug("[Dolphin API] " .. path .. " status=" .. tostring(code) .. " body=" .. resp_body)

  if code ~= 200 then return nil, "HTTP " .. tostring(code) end

  local parsed = json.decode(resp_body)
  if not parsed then return { raw = resp_body }, nil end
  return parsed, nil
end

-----------------------------------------------------------------------
-- Auth
-----------------------------------------------------------------------
function M.get_key(device, email, password)
  local data, err = post("/HA/V1/getAPIkey.php", { email = email, password = password })
  if err then return nil, err end

  local key = data.API_Key or data.api_key
  if not key and data.raw then key = data.raw:match("^%s*(.-)%s*$") end
  if not key or key == "" then
    return nil, "No API key in response: " .. (data.raw or json.encode(data))
  end

  key_cache[device.id] = key
  log.info("[Dolphin API] Key cached for " .. device.id)
  return key, nil
end

function M.ensure_key(device, email, password)
  if key_cache[device.id] then return key_cache[device.id], nil end
  return M.get_key(device, email, password)
end

function M.get_cached_key(device) return key_cache[device.id] end
function M.clear_key(device) key_cache[device.id] = nil end

-----------------------------------------------------------------------
-- Status
-----------------------------------------------------------------------
local function normalise(raw)
  local d = {}
  d.currentTemperature = raw.currentTemperature or raw.CurrentTemperature or raw.temperature or raw.temp
  d.targetTemperature  = raw.targetTemperature  or raw.TargetTemperature  or raw.setTemperature or raw.setTemp
  d.isHeating = raw.isHeating or raw.IsHeating or raw.heating

  if     raw.mode       then d.mode = raw.mode:lower()
  elseif raw.Mode       then d.mode = raw.Mode:lower()
  elseif raw.boilerMode then d.mode = raw.boilerMode:lower()
  else
    if   raw.shabbatEnabled  or raw.ShabbatEnabled   then d.mode = "shabbat"
    elseif raw.fixedTempEnabled or raw.FixedTempEnabled then d.mode = "fixed"
    elseif raw.isOn or raw.IsOn                       then d.mode = "manual"
    else d.mode = "off" end
  end

  d.shabbatEnabled   = raw.shabbatEnabled   or raw.ShabbatEnabled   or (d.mode == "shabbat")
  d.fixedTempEnabled = raw.fixedTempEnabled  or raw.FixedTempEnabled  or (d.mode == "fixed")
  return d
end

function M.get_status(deviceName, email, api_key)
  local data, err = post("/HA/V1/getMainScreenData.php", {
    deviceName = deviceName, email = email, API_Key = api_key
  })
  if err then return nil, err end
  return normalise(data), nil
end

-----------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------
function M.send_command(deviceName, email, api_key, command, extra)
  local params = { deviceName = deviceName, email = email, API_Key = api_key, command = command }
  if extra then for k,v in pairs(extra) do params[k] = v end end

  local data, err = post("/HA/V1/" .. command .. ".php", params)
  if err then
    data, err = post("/HA/V1/sendCommand.php", params)
    if err then return false, err end
  end
  return true, nil
end

return M
