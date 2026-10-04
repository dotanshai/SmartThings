local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local cosock = require "cosock"
local socket = cosock.socket

local PROBE_PORTS = { 62078, 80, 443, 8080, 7000 }
local CONNECT_TIMEOUT = 2
local SCAN_TIMEOUT = 1
local SCAN_BATCH = 64
local LEARN_IDLE = 240
local MAX_IPS = 6
local DEFAULT_IP = "0.0.0.0"

local function valid_ip(ip)
  if type(ip) ~= "string" or ip == DEFAULT_IP then return false end
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, v in ipairs({ a, b, c, d }) do
    if tonumber(v) > 255 then return false end
  end
  return true
end

local function emit_ips(device, list)
  local ok, cap = pcall(function() return capabilities["perfectworld33337.learnedIps"] end)
  if not ok or not cap then
    log.warn("learnedIps capability not available: " .. tostring(cap))
    return false
  end
  local labels = {} for pair in tostring(device.preferences.ipLabels or ""):gmatch("[^,]+") do local k, v = pair:match("^%s*([%d%.]+)%s*=%s*(.-)%s*$") if k and v ~= "" then labels[k] = v end end local prefix = list[1] and list[1]:match("^(%d+%.%d+%.%d+%.)") local same = prefix ~= nil for _, ip in ipairs(list) do if ip:sub(1, #(prefix or "")) ~= prefix then same = false end end local shown = {} for _, ip in ipairs(list) do local last = ip:match("(%d+)$") local lbl = labels[ip] or labels[last] local part = same and last or ip if lbl then part = part .. " " .. lbl end table.insert(shown, part) end local text = (#shown > 0) and ((same and (prefix .. "x: ") or "") .. table.concat(shown, ", ")) or "none - use Learn phone" if #text > 200 then text = text:sub(1, 197) .. "..." end
  log.info(device.label .. ": emit learnedIps = " .. text)
  local ok2, err = pcall(function()
    device:emit_component_event(device.profile.components["learn"], cap.ips(text))
  end)
  if not ok2 then log.warn("emit learnedIps failed: " .. tostring(err)) end
  return ok2
end

local function emit_status(device, text)
  local ok, cap = pcall(function() return capabilities["perfectworld33337.learnStatus"] end)
  if not ok or not cap then return end
  log.info(device.label .. ": status = " .. text)
  pcall(function()
    device:emit_component_event(device.profile.components["learn"], cap.message(text))
  end)
end

local function learned_ips(device)
  local list = {}
  local s = device:get_field("learned_ips")
  if type(s) == "string" then
    for ip in s:gmatch("[^,]+") do
      if valid_ip(ip) then table.insert(list, ip) end
    end
  end
  return list
end

local function save_learned_ip(device, ip)
  local list = { ip }
  for _, v in ipairs(learned_ips(device)) do
    if v ~= ip and #list < MAX_IPS then table.insert(list, v) end
  end
  device:set_field("learned_ips", table.concat(list, ","), { persist = true })
  return list
end

local function effective_ips(device)
  local ips = {}
  local function add(ip)
    if not valid_ip(ip) then return end
    for _, x in ipairs(ips) do if x == ip then return end end
    table.insert(ips, ip)
  end
  for p in tostring(device.preferences.ipAddress or ""):gmatch("[^,%s]+") do add(p) end
  for _, v in ipairs(learned_ips(device)) do add(v) end
  return ips
end

local function probe_port(ip, port, timeout)
  local sock, err = socket.tcp()
  if not sock then return false, tostring(err) end
  sock:settimeout(timeout or CONNECT_TIMEOUT)
  local ok, cerr = sock:connect(ip, port)
  sock:close()
  if ok then return true, "open" end
  local e = string.lower(tostring(cerr))
  if e:find("refused") then return true, "refused" end
  return false, e
end

local function is_online(ip)
  local last = ""
  for _, port in ipairs(PROBE_PORTS) do
    local alive, info = probe_port(ip, port)
    if alive then return true, port .. ":" .. info end
    last = port .. ":" .. info
    if info:find("unreachable") or info:find("no route") then break end
  end
  return false, last
end

local function get_hub_ip()
  local s = socket.udp()
  if not s then return nil end
  s:setpeername("8.8.8.8", 53)
  local ip = s:getsockname()
  s:close()
  return ip
end

local function scan_subnet(prefix, exclude)
  local found, count = {}, 0
  local start = 1
  while start <= 254 do
    local batch = {}
    for h = start, math.min(start + SCAN_BATCH - 1, 254) do
      local ip = prefix .. h
      if not exclude[ip] then table.insert(batch, ip) end
    end
    local remaining = #batch
    for _, ip in ipairs(batch) do
      cosock.spawn(function()
        local alive = probe_port(ip, 62078, SCAN_TIMEOUT)
        if alive and not found[ip] then
          found[ip] = true
          count = count + 1
        end
        remaining = remaining - 1
      end, "scan " .. ip)
    end
    local waited = 0
    while remaining > 0 and waited < 15 do
      socket.sleep(0.2)
      waited = waited + 0.2
    end
    start = start + SCAN_BATCH
  end
  return found, count
end

local function check_presence(device)
  if not device:get_field("ips_shown") then
    device:set_field("ips_shown", emit_ips(device, effective_ips(device)))
  end
  if device:get_field("busy") or device:get_field("learning") then return end
  local ips = effective_ips(device)
  if #ips == 0 then
    log.warn(device.label .. ": no IP yet - use 'Learn phone'")
    return
  end
  device:set_field("busy", true)
  local alive, info, hit = false, "", nil
  for _, ip in ipairs(ips) do
    local a, i = is_online(ip)
    if a then
      alive, info, hit = true, i, ip
      break
    end
    info = info .. ip .. "=" .. i .. " "
  end
  device:set_field("busy", false)

  local now = os.time()
  local current = device:get_latest_state("main", capabilities.presenceSensor.ID,
    capabilities.presenceSensor.presence.NAME)

  if alive then
    device:set_field("last_seen", now)
    if current ~= "present" then
      log.info(string.format("%s (%s): online [%s] -> present", device.label, hit, info))
      device:emit_event(capabilities.presenceSensor.presence.present())
    end
  else
    local last_seen = device:get_field("last_seen") or 0
    local timeout = (device.preferences.awayTimeout or 10) * 60
    local gone = now - last_seen
    log.debug(string.format("%s: no answer [%s], offline %ds", device.label, info, gone))
    if current ~= "not present" and gone >= timeout then
      log.info(device.label .. ": offline too long -> not present")
      device:emit_event(capabilities.presenceSensor.presence.not_present())
    end
  end
end

local function start_learning(driver, device)
  local learn_comp = device.profile.components["learn"]
  if device:get_field("learning") then return end
  device:set_field("learning", true)
  device:set_field("learn_stop", false)
  device:emit_component_event(learn_comp, capabilities.switch.switch.on()); emit_status(device, "Scanning - keep WiFi OFF")

  cosock.spawn(function()
    local function finish(msg)
      device:set_field("learning", false)
      device:set_field("learn_stop", false)
      device:emit_component_event(learn_comp, capabilities.switch.switch.off())
      log.info(device.label .. ": LEARN ended - " .. msg); emit_status(device, "Done: " .. (msg:match("^(%d+)") or "0") .. " learned")
    end

    local hub_ip = get_hub_ip()
    local prefix = hub_ip and hub_ip:match("^(%d+%.%d+%.%d+%.)%d+$")
    if not prefix then
      log.error("Cannot determine hub subnet")
      finish("no subnet")
      return
    end

    local exclude = { [hub_ip] = true }
    for ign in tostring(device.preferences.ignoreIps or ""):gmatch("[^,%s]+") do exclude[ign] = true end
    for _, d in ipairs(driver:get_devices()) do
      if d.id ~= device.id then
        for _, other in ipairs(effective_ips(d)) do exclude[other] = true end
      end
    end

    log.info(device.label .. ": LEARN step 1 - scanning " .. prefix .. "0/24 (phone WiFi must be OFF)")
    local baseline, count = scan_subnet(prefix, exclude)
    local b2 = scan_subnet(prefix, exclude)
    for k in pairs(b2) do if not baseline[k] then baseline[k] = true; count = count + 1 end end
    for ip in pairs(baseline) do exclude[ip] = true end
    log.info(string.format("%s: baseline %d devices. Turn phone WiFi ON now (then switch networks one by one)", device.label, count)); emit_status(device, "Turn WiFi ON now")

    local learned = 0
    local deadline = os.time() + LEARN_IDLE
    while os.time() < deadline do
      if device:get_field("learn_stop") then
        finish(learned .. " IP(s) learned, stopped by user")
        return
      end
      socket.sleep(2)
      local found = scan_subnet(prefix, exclude)
      local new = {}
      for k in pairs(found) do table.insert(new, k) end
      if #new == 1 then
        local ip = new[1]
        exclude[ip] = true
        local all = save_learned_ip(device, ip)
        emit_ips(device, effective_ips(device))
        device:set_field("last_seen", os.time())
        device:emit_event(capabilities.presenceSensor.presence.present())
        learned = learned + 1
        log.info(device.label .. ": LEARNED " .. ip .. " (all: " .. table.concat(all, ", ") .. ") - switch to next network or turn Learn off"); emit_status(device, "Got ." .. ip:match("%d+$") .. " - next network or Learn OFF")
        deadline = os.time() + LEARN_IDLE
      elseif #new > 1 then
        log.warn(device.label .. ": several new devices (" .. table.concat(new, ", ") .. ") - waiting, add unknown ones to Ignore IPs"); emit_status(device, "Other device joined - wait")
      end
    end
    finish(learned .. " IP(s) learned, timeout")
  end, "learn " .. device.label)
end

local function start_polling(device)
  local old = device:get_field("poll_timer")
  if old then device.thread:cancel_timer(old) end
  local interval = device.preferences.pollInterval or 30
  local t = device.thread:call_on_schedule(interval, function() check_presence(device) end, "presence_poll")
  device:set_field("poll_timer", t)
  device.thread:call_with_delay(2, function() check_presence(device) end)
end

local function device_init(driver, device)
  device:set_field("learning", false)
  local current = device:get_latest_state("main", capabilities.presenceSensor.ID,
    capabilities.presenceSensor.presence.NAME)
  if current == "present" then device:set_field("last_seen", os.time()) end
  local learn_comp = device.profile.components["learn"]
  if learn_comp then device:emit_component_event(learn_comp, capabilities.switch.switch.off()) end
  log.info(device.label .. ": IPs = " .. table.concat(effective_ips(device), ", ")); emit_status(device, "WiFi OFF, then Learn ON")
  start_polling(device)
end

local function device_added(driver, device)
  device:emit_event(capabilities.presenceSensor.presence.not_present())
end

local function create_presence_device(driver)
  for _, d in ipairs(driver:get_devices()) do
    if #effective_ips(d) == 0 then
      log.info("'" .. d.label .. "' is not learned yet - learn it before adding another phone")
      return
    end
  end
  local n = #driver:get_devices() + 1
  driver:try_create_device({ type = "LAN", device_network_id = "wifipresence-" .. os.time(), label = "WiFi Presence " .. n, profile = "wifi-presence", manufacturer = "SD", model = "WiFi Presence", vendor_provided_label = "WiFi Presence" })
  log.info("Added WiFi Presence " .. n)
end

local function device_info_changed(driver, device, event, args)
  device:set_field("ips_shown", nil)
  local old = args and args.old_st_store and args.old_st_store.preferences; if device.preferences.addPhone and not (old and old.addPhone) then create_presence_device(driver) end
  if device.preferences.resetIps and not (old and old.resetIps) then
    device:set_field("learned_ips", nil, { persist = true })
    log.info(device.label .. ": learned IPs cleared")
  end
  device:set_field("last_seen", os.time())
  start_polling(device)
end

local function device_removed(driver, device)
  local t = device:get_field("poll_timer")
  if t then device.thread:cancel_timer(t) end
end

local function refresh_handler(driver, device, command)
  device:set_field("ips_shown", nil)
  check_presence(device)
end

local function switch_on_handler(driver, device, command)
  if command.component == "learn" then start_learning(driver, device) end
end

local function switch_off_handler(driver, device, command)
  if command.component ~= "learn" then return end
  if device:get_field("learning") then
    device:set_field("learn_stop", true)
  else
    device:emit_component_event(device.profile.components["learn"], capabilities.switch.switch.off())
  end
end

local function discovery_handler(driver, _, should_continue) if #driver:get_devices() > 0 then log.info("Scan ignored - use Add another phone in a presence device settings") return end
  local devices = driver:get_devices()
  for _, d in ipairs(devices) do
    if #effective_ips(d) == 0 then
      log.info("Learn the phone of '" .. d.label .. "' before adding another device")
      return
    end
  end
  local n = #devices + 1
  driver:try_create_device({
    type = "LAN",
    device_network_id = "wifipresence-" .. os.time(),
    label = "WiFi Presence " .. n,
    profile = "wifi-presence",
    manufacturer = "SD",
    model = "WiFi Presence",
    vendor_provided_label = "WiFi Presence",
  })
end

local driver = Driver("wifi-presence-sd", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = device_info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on_handler,
      [capabilities.switch.commands.off.NAME] = switch_off_handler,
    },
  },
})

driver:run()
