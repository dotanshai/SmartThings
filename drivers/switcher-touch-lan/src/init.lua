local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local protocol = require "switcher_protocol"

local TIMER_CAPABILITY_ID = "__ST_CAP_NAMESPACE__.timerMinutes"
local DELAY_CAPABILITY_ID = "__ST_CAP_NAMESPACE__.delay"
local RUNTIME_CAPABILITY_ID = "__ST_CAP_NAMESPACE__.timerRuntime"
local INFO_IP_CAPABILITY_ID = "__ST_CAP_NAMESPACE__.ip"
local INFO_DEVICE_ID_CAPABILITY_ID = "__ST_CAP_NAMESPACE__.deviceId"
local INFO_DEVICE_KEY_CAPABILITY_ID = "__ST_CAP_NAMESPACE__.deviceKey"
local INFO_DEVICE_TYPE_CAPABILITY_ID = "__ST_CAP_NAMESPACE__.deviceType"

local timer_capability = capabilities[TIMER_CAPABILITY_ID]
local delay_capability = capabilities[DELAY_CAPABILITY_ID]
local runtime_capability = capabilities[RUNTIME_CAPABILITY_ID]
local info_ip_capability = capabilities[INFO_IP_CAPABILITY_ID]
local info_device_id_capability = capabilities[INFO_DEVICE_ID_CAPABILITY_ID]
local info_device_key_capability = capabilities[INFO_DEVICE_KEY_CAPABILITY_ID]
local info_device_type_capability = capabilities[INFO_DEVICE_TYPE_CAPABILITY_ID]
local power_meter_capability = capabilities.powerMeter
local current_measurement_capability = capabilities.currentMeasurement

local MANUAL_SETUP_DNI = "sw-touch-lan-manual-setup"
local MANUAL_SETUP_LABEL = "Switcher Boiler"
local MANUAL_DISCOVERY_COOLDOWN_SECONDS = 60

local emit_current_ip

local function is_manual_setup_device(device)
  return tostring(device and device.device_network_id or "") == MANUAL_SETUP_DNI
end

local function static_model_value()
  -- Device identity is displayed by the Info capability. Keep SmartThings
  -- internal metadata static to avoid duplicate/stale information under the
  -- mobile app three-dot Information / Model Name screen.
  return "Switcher Water Heater LAN"
end

local function manual_setup_model_value()
  return static_model_value()
end

local function normalize_device_label(name)
  local label = tostring(name or "")

  if label == "" or label == "Boiler" then
    return "Switcher Boiler"
  end

  return label
end

local function value_or_none(value)
  value = tostring(value or "")
  if value == "" then
    return "None found"
  end
  return value
end

local function normalize_status_label(status)
  status = tostring(status or "")
  if status == "unreachable" or status == "Unreachable" then
    return "Unreachable"
  end
  if status == "searching" or status == "Searching" then
    return "Searching"
  end
  return ""
end

local function discovery_model_value(ip, device_id, device_type, status)
  return static_model_value()
end

local function discovery_metadata(ip, device_id, device_type, status)
  return {
    manufacturer = "Switcher",
    model = static_model_value(),
  }
end

local function normalize_device_id(device_id)
  device_id = tostring(device_id or "")
  if device_id == "" then
    return ""
  end
  return string.lower(device_id)
end

local function saved_field(device, name)
  local value = device:get_field(name)
  if value == nil or tostring(value) == "" then
    return nil
  end
  return tostring(value)
end

local function preference_value(device, name)
  local value = device.preferences and device.preferences[name]
  if value == nil or tostring(value) == "" then
    return nil
  end
  return tostring(value)
end

local function set_saved_network_info(device, info, reason)
  if not device or type(info) ~= "table" then
    return
  end

  local ip = tostring(info.ip or info.ip_address or "")
  local device_id = normalize_device_id(info.device_id)
  local device_key = tostring(info.device_key or "")
  local device_type = tostring(info.device_type or info.model or info.type_hex or "")

  if ip ~= "" then
    device:set_field("discovered_ip", ip, {persist = true})
  end

  if device_id ~= "" then
    device:set_field("discovered_device_id", device_id, {persist = true})
  end

  if device_key ~= "" then
    device:set_field("discovered_device_key", device_key, {persist = true})
  end

  if device_type ~= "" then
    device:set_field("discovered_device_type", device_type, {persist = true})
  end

  log.warn(
    "Switcher saved network info"
    .. ", reason=" .. tostring(reason or "unknown")
    .. ", ip=" .. tostring(ip)
    .. ", device_id=" .. tostring(device_id)
    .. ", type=" .. tostring(device_type)
  )

  if emit_current_ip then
    -- Stable/public DNIs may contain only device_id. In that case dni_backfill
    -- must not temporarily overwrite the footer with Unknown; keep the last
    -- saved/preference IP unless a new non-empty IP was provided.
    local footer_ip = ip
    if footer_ip == "" then
      footer_ip = saved_field(device, "discovered_ip") or preference_value(device, "deviceIp") or ""
    end
    emit_current_ip(device, footer_ip, "saved_network_info_" .. tostring(reason or "unknown"))
  end
end

local function update_discovery_metadata(device, discovered_info, reason, force)
  reason = tostring(reason or "unknown")
  force = force == true

  local discovered = protocol.parse_discovery_dni(device.device_network_id or "")

  if discovered and ((discovered.ip and tostring(discovered.ip) ~= "") or (discovered.device_key and tostring(discovered.device_key) ~= "") or (discovered.device_type and tostring(discovered.device_type) ~= "") or (discovered.model and tostring(discovered.model) ~= "")) then
    -- Backfill persistent fields for old private-build DNIs. New public DNIs
    -- often contain only device_id; in that case do not emit noisy blank
    -- backfill updates because the saved IP/key/type are maintained separately.
    set_saved_network_info(device, discovered, "dni_backfill")
  end

  if type(discovered_info) == "table" then
    set_saved_network_info(device, discovered_info, "metadata_update_" .. reason)
  end

  local ip = tostring(
    (type(discovered_info) == "table" and (discovered_info.ip or discovered_info.ip_address))
    or saved_field(device, "discovered_ip")
    or preference_value(device, "deviceIp")
    or (discovered and discovered.ip)
    or ""
  )

  local device_id = normalize_device_id(
    (type(discovered_info) == "table" and discovered_info.device_id)
    or saved_field(device, "discovered_device_id")
    or preference_value(device, "deviceId")
    or (discovered and discovered.device_id)
    or ""
  )

  local device_type = tostring(
    (type(discovered_info) == "table" and (discovered_info.device_type or discovered_info.model))
    or saved_field(device, "discovered_device_type")
    or ""
  )

  local manual_pending = is_manual_setup_device(device) and ip == "" and device_id == ""
  emit_current_ip(device, ip, "metadata_" .. tostring(reason or "unknown"))

  if not manual_pending and ip ~= "" and (device_type == "" or device_id == "") then
    local ok_identity, identity = pcall(function()
      return protocol.identify(ip, saved_field(device, "discovered_device_key") or preference_value(device, "deviceKey") or "")
    end)

    if ok_identity and type(identity) == "table" then
      set_saved_network_info(device, identity, "metadata_identity_read_" .. reason)
      device_id = normalize_device_id(identity.device_id or device_id)
      device_type = tostring(identity.device_type or device_type)
    else
      log.warn("Switcher discovery metadata identity read failed: " .. tostring(identity))
    end
  end

  -- No dynamic Model Name updates here. IP / Device ID / Device Key / Device Type
  -- are emitted through the Info capability only, so the SmartThings three-dot
  -- Information screen does not duplicate or show stale identity data.
  device:set_field("last_metadata_model", static_model_value(), {persist = true})
  log.debug("Switcher metadata update skipped by design, reason=" .. reason .. "; Info capability is source of truth")
end

local function find_manual_setup_device(driver)
  local ok, devices_or_err = pcall(function()
    return driver:get_devices()
  end)

  if not ok or type(devices_or_err) ~= "table" then
    return nil
  end

  for _, device in ipairs(devices_or_err) do
    if is_manual_setup_device(device) then
      return device
    end
  end

  return nil
end

local function find_existing_device(driver, info, opts)
  opts = type(opts) == "table" and opts or {}
  local allow_unbound_manual = opts.allow_unbound_manual ~= false

  if type(info) ~= "table" then
    return nil
  end

  local wanted_ip = tostring(info.ip or info.ip_address or "")
  local wanted_device_id = normalize_device_id(info.device_id)

  local ok, devices_or_err = pcall(function()
    return driver:get_devices()
  end)

  if not ok or type(devices_or_err) ~= "table" then
    log.warn("Switcher duplicate check skipped - unable to read existing devices: " .. tostring(devices_or_err))
    return nil
  end

  for _, device in ipairs(devices_or_err) do
    local discovered = protocol.parse_discovery_dni(device.device_network_id or "")
    local existing_device_id = normalize_device_id(
      saved_field(device, "discovered_device_id")
      or preference_value(device, "deviceId")
      or (discovered and discovered.device_id)
      or ""
    )

    local existing_ip = tostring(
      saved_field(device, "discovered_ip")
      or preference_value(device, "deviceIp")
      or (discovered and discovered.ip)
      or ""
    )

    if wanted_device_id ~= "" and existing_device_id ~= "" and wanted_device_id == existing_device_id then
      return device
    end

    if wanted_ip ~= "" and existing_ip ~= "" and wanted_ip == existing_ip then
      return device
    end
  end

  -- If a manual setup placeholder exists and has not yet been bound to a
  -- specific Switcher, adopt the first real Switcher discovered instead of
  -- creating a duplicate device. SmartThings device_network_id cannot be
  -- changed after creation, so the placeholder remains the same ST device,
  -- while all real control identity is saved in persistent fields.
  if allow_unbound_manual and (wanted_device_id ~= "" or wanted_ip ~= "") then
    for _, device in ipairs(devices_or_err) do
      if is_manual_setup_device(device) then
        local manual_device_id = normalize_device_id(saved_field(device, "discovered_device_id") or preference_value(device, "deviceId") or "")
        local manual_ip = tostring(saved_field(device, "discovered_ip") or preference_value(device, "deviceIp") or "")
        if manual_device_id == "" and manual_ip == "" then
          return device
        end
      end
    end
  end

  return nil
end

local DEFAULT_IP = ""
local DEFAULT_DEVICE_ID = ""
local DEFAULT_DEVICE_KEY = ""
local MAX_ON_MINUTES = 120
local DEFAULT_MONITOR_INTERVAL = 30

local pending_discovery_by_dni = {}

local refresh
local get_delay_pending
local set_delay_pending
local emit_event_for_component

local function clamp_minutes(minutes, allow_zero)
  minutes = tonumber(minutes or 0) or 0
  minutes = math.floor(minutes)

  if allow_zero and minutes <= 0 then
    return 0
  end

  if minutes < 1 then
    minutes = 1
  end

  if minutes > MAX_ON_MINUTES then
    minutes = MAX_ON_MINUTES
  end

  return minutes
end

local function clamp_interval(seconds)
  seconds = tonumber(seconds or DEFAULT_MONITOR_INTERVAL) or DEFAULT_MONITOR_INTERVAL
  seconds = math.floor(seconds)

  if seconds < 30 then
    seconds = 30
  end

  if seconds > 300 then
    seconds = 300
  end

  return seconds
end

local function seconds_to_remaining_minutes(seconds)
  seconds = tonumber(seconds or 0) or 0
  if seconds <= 0 then return 0 end
  return math.ceil(seconds / 60)
end

local function seconds_to_elapsed_minutes(seconds)
  seconds = tonumber(seconds or 0) or 0
  if seconds <= 0 then return 0 end
  return math.floor(seconds / 60)
end

local function seconds_to_total_minutes(seconds)
  seconds = tonumber(seconds or 0) or 0
  if seconds <= 0 then return 0 end
  -- Total timer should represent the selected timer length.
  -- Switcher sometimes reports total_seconds slightly above the nominal timer
  -- for external/app starts, e.g. 1830 seconds for a 30-minute run.
  -- Using floor keeps that displayed as 30 instead of 31.
  return math.floor((seconds + 1) / 60)
end

local function get_pref(device, name, default)
  local value = device.preferences and device.preferences[name]
  if value == nil or value == "" then
    return default
  end
  return value
end

local function get_config(device)
  local discovered = protocol.parse_discovery_dni(device.device_network_id or "")
  local discovered_ip = discovered and discovered.ip or DEFAULT_IP
  local discovered_device_id = discovered and discovered.device_id or DEFAULT_DEVICE_ID
  local discovered_device_key = discovered and discovered.device_key or DEFAULT_DEVICE_KEY

  local stored_ip = saved_field(device, "discovered_ip")
  local stored_device_id = saved_field(device, "discovered_device_id")
  local stored_device_key = saved_field(device, "discovered_device_key")

  return {
    -- Manual preferences override discovered values. Otherwise use the last
    -- saved IP/key from discovery/rediscovery. The stable DNI intentionally
    -- does not include IP.
    ip = get_pref(device, "deviceIp", stored_ip or discovered_ip),
    device_id = normalize_device_id(get_pref(device, "deviceId", stored_device_id or discovered_device_id)),
    device_key = get_pref(device, "deviceKey", stored_device_key or discovered_device_key),
    scan_prefix = get_pref(device, "scanPrefix", ""),
    default_minutes = clamp_minutes(get_pref(device, "defaultMinutes", MAX_ON_MINUTES), false),
    monitor_interval = clamp_interval(get_pref(device, "monitorInterval", DEFAULT_MONITOR_INTERVAL)),
  }
end

local REDISCOVERY_COOLDOWN_SECONDS = 120
local NETWORK_FAILURE_THRESHOLD = 3

local function should_force_rediscovery(reason)
  local label = tostring(reason or "")

  -- User-initiated changes/commands should not wait behind the background
  -- rediscovery cooldown. This is especially important after a manual IP
  -- override was corrected or cleared. Background monitor refreshes still use
  -- the cooldown to avoid repeated subnet scans.
  if label:find("infoChanged", 1, true) then
    return true
  end

  if label:find("manual_refresh", 1, true) then
    return true
  end

  if label:find("_command", 1, true) then
    return true
  end

  return false
end

local function rediscover_device(driver, device, cfg, reason, force)
  cfg = cfg or get_config(device)
  force = force == true or should_force_rediscovery(reason)

  local wanted_device_id = normalize_device_id(cfg.device_id)
  if wanted_device_id == "" or wanted_device_id == DEFAULT_DEVICE_ID then
    log.warn("Switcher rediscovery skipped - missing device_id")
    return nil
  end

  local now = os.time()
  local last = tonumber(device:get_field("last_rediscovery_time") or 0) or 0
  if not force and (now - last) < REDISCOVERY_COOLDOWN_SECONDS then
    log.warn("Switcher rediscovery skipped by cooldown, reason=" .. tostring(reason or "unknown"))
    return nil
  end

  if force then
    log.warn("Switcher rediscovery cooldown bypassed, reason=" .. tostring(reason or "unknown"))
  end

  device:set_field("last_rediscovery_time", now)

  local wanted_device_key = tostring(cfg.device_key or "")
  if wanted_device_key == "" then
    log.warn("Switcher rediscovery skipped - missing known device_key for device_id=" .. tostring(wanted_device_id))
    return nil
  end

  log.warn("Switcher rediscovery start, reason=" .. tostring(reason or "unknown") .. ", device_id=" .. tostring(wanted_device_id) .. ", using known key only")

  local ok, info_or_err = pcall(function()
    return protocol.rediscover_known_device(wanted_device_id, wanted_device_key, 30, cfg.scan_prefix)
  end)

  if not ok then
    log.error("Switcher rediscovery failed: " .. tostring(info_or_err))
    return nil
  end

  if type(info_or_err) == "table" and normalize_device_id(info_or_err.device_id) == wanted_device_id then
    set_saved_network_info(device, info_or_err, "rediscovery_" .. tostring(reason or "unknown"))
    update_discovery_metadata(device, info_or_err, "rediscovery", true)
    log.warn("Switcher rediscovery updated IP to " .. tostring(info_or_err.ip))
    return get_config(device)
  end

  log.warn("Switcher rediscovery did not find device_id=" .. tostring(wanted_device_id))
  return nil
end

local function recover_device_key_at_current_ip(device, cfg, reason)
  cfg = cfg or get_config(device)
  local wanted_device_id = normalize_device_id(cfg.device_id)
  local ip = tostring(cfg.ip or "")

  if ip == "" or wanted_device_id == "" or wanted_device_id == DEFAULT_DEVICE_ID then
    return nil
  end

  local now = os.time()
  local last = tonumber(device:get_field("last_key_scan_time") or 0) or 0
  if (now - last) < REDISCOVERY_COOLDOWN_SECONDS then
    log.warn("Switcher key scan skipped by cooldown, reason=" .. tostring(reason or "unknown"))
    return nil
  end

  device:set_field("last_key_scan_time", now, {persist = true})
  log.warn("Switcher key recovery scan start on known IP only, ip=" .. ip .. ", device_id=" .. wanted_device_id .. ", reason=" .. tostring(reason or "unknown"))

  local ok, info_or_err = pcall(function()
    return protocol.find_key_for_device_at_ip(ip, wanted_device_id, 10)
  end)

  if ok and type(info_or_err) == "table" and normalize_device_id(info_or_err.device_id) == wanted_device_id then
    set_saved_network_info(device, info_or_err, "key_recovery_" .. tostring(reason or "unknown"))
    update_discovery_metadata(device, info_or_err, "key_recovery", true)
    log.warn("Switcher key recovery updated device_key=" .. tostring(info_or_err.device_key) .. ", ip=" .. tostring(ip))
    return get_config(device)
  end

  log.warn("Switcher key recovery did not find matching identity on current IP: " .. tostring(info_or_err))
  return nil
end

local function discover_for_manual_setup(driver, device, cfg, reason, force)
  if not is_manual_setup_device(device) then
    return nil
  end

  cfg = cfg or get_config(device)
  reason = tostring(reason or "manual_setup")
  force = force == true

  -- If the user filled manual preferences, use them immediately and stop
  -- requiring background discovery. Device key remains optional.
  if cfg.ip and cfg.ip ~= "" and cfg.device_id and cfg.device_id ~= "" and cfg.device_id ~= DEFAULT_DEVICE_ID then
    set_saved_network_info(device, {
      ip = cfg.ip,
      device_id = cfg.device_id,
      device_key = cfg.device_key or DEFAULT_DEVICE_KEY,
      device_type = saved_field(device, "discovered_device_type") or "Switcher Water Heater",
    }, "manual_preferences_" .. reason)
    update_discovery_metadata(device, {
      ip = cfg.ip,
      device_id = cfg.device_id,
      device_key = cfg.device_key or DEFAULT_DEVICE_KEY,
      device_type = saved_field(device, "discovered_device_type") or "Switcher Water Heater",
    }, "manual_preferences_" .. reason, true)
    return get_config(device)
  end

  local now = os.time()
  local last = tonumber(device:get_field("last_manual_discovery_time") or 0) or 0
  if not force and (now - last) < MANUAL_DISCOVERY_COOLDOWN_SECONDS then
    log.warn("Switcher manual setup discovery skipped by cooldown, reason=" .. reason)
    update_discovery_metadata(device, nil, "manual_setup_waiting_" .. reason, false)
    return nil
  end

  device:set_field("last_manual_discovery_time", now)
  log.warn("Switcher manual setup discovery start, reason=" .. reason)

  local ok, devices_or_err = pcall(function()
    return protocol.discover(30, cfg.scan_prefix, {
      workers = 16,
      key_scan_delay_ms = 10,
      probe_key = "00",
      on_candidate = function(candidate)
        local existing = find_existing_device(driver, candidate, { allow_unbound_manual = false })
        if existing and existing ~= device then
          set_saved_network_info(existing, candidate, "manual_setup_candidate_existing")
          update_discovery_metadata(existing, candidate, "manual_setup_candidate_existing", false)
          log.warn("Switcher manual setup auto discovery skipped existing candidate device_id=" .. tostring(candidate.device_id) .. ", ip=" .. tostring(candidate.ip))
          return "skip"
        end
        return "scan"
      end,
    })
  end)

  if not ok or type(devices_or_err) ~= "table" then
    log.warn("Switcher manual setup discovery failed: " .. tostring(devices_or_err))
    update_discovery_metadata(device, nil, "manual_setup_discovery_failed_" .. reason, false)
    return nil
  end

  if #devices_or_err == 0 then
    log.warn("Switcher manual setup discovery found no devices, reason=" .. reason)
    update_discovery_metadata(device, nil, "manual_setup_no_devices_" .. reason, false)
    return nil
  end

  local info = devices_or_err[1]
  if #devices_or_err > 1 then
    log.warn("Switcher manual setup discovery found multiple devices; adopting first device_id=" .. tostring(info.device_id) .. ", ip=" .. tostring(info.ip))
  else
    log.warn("Switcher manual setup discovery adopting device_id=" .. tostring(info.device_id) .. ", ip=" .. tostring(info.ip))
  end

  set_saved_network_info(device, info, "manual_setup_adopt_" .. reason)
  device:set_field("network_status", "reachable", {persist = true})
  device:set_field("network_fail_count", 0, {persist = true})
  update_discovery_metadata(device, info, "manual_setup_adopt_" .. reason, true)

  return get_config(device)
end

local function mark_network_success(device, cfg, info, reason)
  if not device then
    return
  end

  local previous_status = normalize_status_label(device:get_field("network_status"))

  device:set_field("network_fail_count", 0, {persist = true})
  device:set_field("last_success_time", os.time(), {persist = true})
  device:set_field("last_error", "", {persist = true})
  device:set_field("network_status", "reachable", {persist = true})

  if previous_status ~= "" then
    log.warn("Switcher network recovered, reason=" .. tostring(reason or "unknown"))
    update_discovery_metadata(device, {
      ip = cfg and cfg.ip or saved_field(device, "discovered_ip") or "",
      device_id = cfg and cfg.device_id or saved_field(device, "discovered_device_id") or "",
      device_key = cfg and cfg.device_key or saved_field(device, "discovered_device_key") or "",
      device_type = (type(info) == "table" and info.device_type) or saved_field(device, "discovered_device_type") or "Switcher Water Heater",
    }, "network_recovered_" .. tostring(reason or "unknown"), true)
  end
end

local function mark_network_failure(device, cfg, reason, err)
  if not device then
    return
  end

  local count = tonumber(device:get_field("network_fail_count") or 0) or 0
  count = count + 1

  device:set_field("network_fail_count", count, {persist = true})
  device:set_field("last_error", tostring(err or "unknown"), {persist = true})

  log.warn(
    "Switcher network failure"
    .. ", reason=" .. tostring(reason or "unknown")
    .. ", count=" .. tostring(count)
    .. ", error=" .. tostring(err or "unknown")
  )

  if count >= NETWORK_FAILURE_THRESHOLD then
    local previous_status = normalize_status_label(device:get_field("network_status"))
    device:set_field("network_status", "unreachable", {persist = true})

    update_discovery_metadata(device, {
      ip = cfg and cfg.ip or saved_field(device, "discovered_ip") or "",
      device_id = cfg and cfg.device_id or saved_field(device, "discovered_device_id") or "",
      device_key = cfg and cfg.device_key or saved_field(device, "discovered_device_key") or "",
      device_type = saved_field(device, "discovered_device_type") or "Switcher Water Heater",
    }, "network_unreachable_" .. tostring(reason or "unknown"), previous_status ~= "Unreachable")
  end
end


local function should_try_key_recovery(err)
  local msg = string.lower(tostring(err or ""))

  -- Key recovery is useful only when the current IP is reachable but the
  -- saved key is wrong/stale. When the old IP is unreachable, skip the key
  -- scan and go directly to known-device rediscovery by Device ID + known key.
  if msg:find("valid device_key", 1, true) then
    return true
  end

  if msg:find("login returned short response", 1, true) then
    return true
  end

  return false
end

local function get_state_with_recovery(driver, device, cfg, reason)
  local ok, info_or_err = pcall(function()
    return protocol.get_state(cfg.ip, cfg.device_id, cfg.device_key)
  end)

  if ok then
    return true, info_or_err, cfg
  end

  log.error("Switcher state read failed before rediscovery: " .. tostring(info_or_err))

  if should_try_key_recovery(info_or_err) then
    local key_cfg = recover_device_key_at_current_ip(device, cfg, reason or "state_read_failed")
    if key_cfg and key_cfg.ip and key_cfg.ip ~= "" then
      local ok_key_retry, key_retry_or_err = pcall(function()
        return protocol.get_state(key_cfg.ip, key_cfg.device_id, key_cfg.device_key)
      end)

      if ok_key_retry then
        return true, key_retry_or_err, key_cfg
      end

      log.error("Switcher state read failed after key recovery: " .. tostring(key_retry_or_err))
      cfg = key_cfg
    end
  else
    log.warn("Switcher key recovery skipped because current IP is unreachable or error is not key-related; going to known-device rediscovery")
  end

  local new_cfg = rediscover_device(driver, device, cfg, reason or "state_read_failed")
  if not new_cfg or not new_cfg.ip or new_cfg.ip == "" then
    return false, info_or_err, cfg
  end

  local ok_retry, retry_or_err = pcall(function()
    return protocol.get_state(new_cfg.ip, new_cfg.device_id, new_cfg.device_key)
  end)

  if ok_retry then
    return true, retry_or_err, new_cfg
  end

  log.error("Switcher state read failed after rediscovery: " .. tostring(retry_or_err))
  return false, retry_or_err, new_cfg
end

local function set_power_with_recovery(driver, device, cfg, power, minutes, reason)
  local ok, err = pcall(function()
    protocol.set_power(cfg.ip, cfg.device_id, cfg.device_key, power, minutes)
  end)

  if ok then
    return true, cfg, nil
  end

  log.error("Switcher " .. tostring(power) .. " failed before rediscovery: " .. tostring(err))

  if should_try_key_recovery(err) then
    local key_cfg = recover_device_key_at_current_ip(device, cfg, reason or ("set_power_" .. tostring(power)))
    if key_cfg and key_cfg.ip and key_cfg.ip ~= "" then
      local ok_key_retry, key_retry_err = pcall(function()
        protocol.set_power(key_cfg.ip, key_cfg.device_id, key_cfg.device_key, power, minutes)
      end)

      if ok_key_retry then
        return true, key_cfg, nil
      end

      log.error("Switcher " .. tostring(power) .. " failed after key recovery: " .. tostring(key_retry_err))
      cfg = key_cfg
    end
  else
    log.warn("Switcher key recovery skipped for " .. tostring(power) .. " because current IP is unreachable or error is not key-related; going to known-device rediscovery")
  end

  local new_cfg = rediscover_device(driver, device, cfg, reason or ("set_power_" .. tostring(power)))
  if not new_cfg or not new_cfg.ip or new_cfg.ip == "" then
    return false, cfg, err
  end

  local ok_retry, retry_err = pcall(function()
    protocol.set_power(new_cfg.ip, new_cfg.device_id, new_cfg.device_key, power, minutes)
  end)

  if ok_retry then
    return true, new_cfg, nil
  end

  log.error("Switcher " .. tostring(power) .. " failed after rediscovery: " .. tostring(retry_err))
  return false, new_cfg, retry_err
end

local function get_selected_minutes(device, cfg)
  local latest = device:get_latest_state("main", TIMER_CAPABILITY_ID, "timerMinutes")
  local selected = tonumber(latest or 0) or 0

  if selected <= 0 then
    selected = cfg.default_minutes
  end

  return clamp_minutes(selected, false)
end

local function emit_timer(device, minutes)
  minutes = clamp_minutes(minutes, true)
  device:emit_event(timer_capability.timerMinutes(minutes))
end

local function round_number(value, decimals)
  value = tonumber(value or 0) or 0
  decimals = tonumber(decimals or 0) or 0
  local scale = 10 ^ decimals
  return math.floor((value * scale) + 0.5) / scale
end

local function watts_to_amps(power_watts)
  power_watts = tonumber(power_watts or 0) or 0
  if power_watts <= 0 then return 0 end

  -- Switcher state packets expose current power in watts. The official app-style
  -- current value matches an estimate using about 220V mains.
  return power_watts / 220
end

-- Keep SmartThings standard measurement capabilities archivable so the app can
-- show normal power/current history.

local function current_ip_display_value(device, ip)
  ip = tostring(ip or "")
  if ip ~= "" then
    return ip
  end

  if device and is_manual_setup_device(device) then
    return "Searching"
  end

  return "Unknown"
end

local function info_field_display_value(device, value)
  value = tostring(value or "")
  if value ~= "" then
    return value
  end

  if device and is_manual_setup_device(device) then
    return "Searching"
  end

  return "Unknown"
end

local function get_info_display_values(device, ip)
  local discovered = protocol.parse_discovery_dni(device and device.device_network_id or "")

  -- Display order is intentional:
  -- 1. Manual preferences explicitly entered by the user.
  -- 2. Persisted values discovered from the physical device.
  -- 3. Legacy DNI fallback from older/private builds.
  --
  -- The IP is the only value that should normally change automatically after
  -- rediscovery. Device ID / Device Key / Device Type stay stable unless the
  -- user manually overrides them or a full identity read discovers them first.
  local display_ip = tostring(
    ip
    or preference_value(device, "deviceIp")
    or saved_field(device, "discovered_ip")
    or (discovered and discovered.ip)
    or ""
  )

  local device_id = normalize_device_id(
    preference_value(device, "deviceId")
    or saved_field(device, "discovered_device_id")
    or (discovered and discovered.device_id)
    or ""
  )

  local device_key = tostring(
    preference_value(device, "deviceKey")
    or saved_field(device, "discovered_device_key")
    or (discovered and discovered.device_key)
    or ""
  )

  local device_type = tostring(
    saved_field(device, "discovered_device_type")
    or (discovered and (discovered.device_type or discovered.model))
    or ""
  )

  return {
    current_ip = current_ip_display_value(device, display_ip),
    device_id = info_field_display_value(device, device_id),
    device_key = info_field_display_value(device, device_key),
    device_type = info_field_display_value(device, device_type),
  }
end

local function build_info_signature(values)
  return tostring(values.current_ip or "Unknown")
    .. "|" .. tostring(values.device_id or "Unknown")
    .. "|" .. tostring(values.device_key or "Unknown")
    .. "|" .. tostring(values.device_type or "Unknown")
end

local function emit_info_state(device, capability_obj, attribute_name, value)
  if not capability_obj then
    log.warn("Switcher info capability helper is unavailable: " .. tostring(attribute_name))
    return
  end

  if not capability_obj[attribute_name] then
    log.warn("Switcher info capability attribute helper is unavailable: " .. tostring(attribute_name))
    return
  end

  emit_event_for_component(device, "info", capability_obj[attribute_name](tostring(value or "Unknown")))
end

emit_current_ip = function(device, ip, reason)
  if not device then
    return
  end

  local values = get_info_display_values(device, ip)
  local signature = build_info_signature(values)
  local previous_signature = tostring(device:get_field("last_emitted_info_signature") or "")

  if previous_signature == signature then
    return
  end

  local ok, err = pcall(function()
    -- Four separate single-state capabilities are used intentionally.
    -- SmartThings does not preserve newline formatting in a single state label;
    -- separate capabilities render as separate Info rows/tiles with small labels.
    emit_info_state(device, info_ip_capability, "ip", values.current_ip)
    emit_info_state(device, info_device_id_capability, "deviceId", values.device_id)
    emit_info_state(device, info_device_key_capability, "deviceKey", values.device_key)
    emit_info_state(device, info_device_type_capability, "deviceType", values.device_type)

    device:set_field("last_emitted_info_signature", signature, {persist = true})
    device:set_field("last_emitted_current_ip", values.current_ip, {persist = true})
    log.warn(
      "Switcher info capabilities updated"
      .. ", reason=" .. tostring(reason or "unknown")
      .. ", current_ip=" .. values.current_ip
      .. ", device_id=" .. values.device_id
      .. ", device_key=" .. values.device_key
      .. ", device_type=" .. values.device_type
    )
  end)

  if not ok then
    log.warn("Switcher info capability emit failed: " .. tostring(err))
  end
end

local function emit_measurements(device, power_watts)
  power_watts = tonumber(power_watts or 0) or 0
  if power_watts < 0 or power_watts > 10000 then
    power_watts = 0
  end

  local watts = round_number(power_watts, 0)
  local amps = round_number(watts_to_amps(power_watts), 1)

  local ok_power, err_power = pcall(function()
    if power_meter_capability and power_meter_capability.power then
      device:emit_event(power_meter_capability.power({ value = watts, unit = "W" }))
    else
      log.warn("Switcher powerMeter capability helper is unavailable")
    end
  end)
  if not ok_power then
    log.warn("Switcher powerMeter emit failed: " .. tostring(err_power))
  end

  local ok_current, err_current = pcall(function()
    if current_measurement_capability and current_measurement_capability.current then
      device:emit_event(current_measurement_capability.current({ value = amps, unit = "A" }))
    else
      log.warn("Switcher currentMeasurement capability helper is unavailable")
    end
  end)
  if not ok_current then
    log.warn("Switcher currentMeasurement emit failed: " .. tostring(err_current))
  end
end

local function emit_runtime(device, elapsed_minutes, remaining_minutes, total_minutes, power_watts)
  elapsed_minutes = clamp_minutes(elapsed_minutes, true)
  remaining_minutes = clamp_minutes(remaining_minutes, true)
  total_minutes = clamp_minutes(total_minutes, true)

  power_watts = tonumber(power_watts or 0) or 0
  if power_watts < 0 or power_watts > 10000 then
    power_watts = 0
  end

  device:emit_event(runtime_capability.elapsedMinutes(elapsed_minutes))
  device:emit_event(runtime_capability.remainingMinutes(remaining_minutes))
  device:emit_event(runtime_capability.totalMinutes(total_minutes))
  emit_measurements(device, power_watts)
end


emit_event_for_component = function(device, component_id, event)
  component_id = component_id or "main"

  if component_id == "main" then
    device:emit_event(event)
    return
  end

  if device.profile and device.profile.components and device.profile.components[component_id] then
    device:emit_component_event(device.profile.components[component_id], event)
  else
    log.warn("Switcher missing component " .. tostring(component_id) .. ", falling back to main event")
    device:emit_event(event)
  end
end

local function emit_switch_state(device, state, component_id)
  local event
  if state == "on" then
    event = capabilities.switch.switch.on()
  else
    event = capabilities.switch.switch.off()
  end

  emit_event_for_component(device, component_id or "main", event)
end

local function get_command_component(command)
  return tostring((command and (command.component or command.component_id)) or "main")
end

local function command_source_name(source)
  if type(source) == "table" then
    return tostring(source.command or source.command_name or "manual_refresh")
  end
  return tostring(source or "manual")
end

local function is_manual_refresh_command(source)
  if type(source) ~= "table" then
    return false
  end
  return tostring(source.command or source.command_name or "") == "refresh"
end

local function schedule_monitor(driver, device)
  if device:get_field("monitor_scheduled") then
    return
  end

  local cfg = get_config(device)
  local interval = cfg.monitor_interval

  device:set_field("monitor_scheduled", true)

  log.warn("Switcher local monitor scheduled every " .. tostring(interval) .. " seconds")

  device.thread:call_with_delay(interval, function()
    device:set_field("monitor_scheduled", false)

    log.warn("Switcher local monitor tick")
    refresh(driver, device, "local_monitor")

    schedule_monitor(driver, device)
  end)
end

refresh = function(driver, device, source)
  local cfg = get_config(device)
  local source_label = command_source_name(source)
  log.warn("Switcher refresh start, source=" .. source_label)

  if not cfg.device_id or cfg.device_id == "" or cfg.device_id == DEFAULT_DEVICE_ID then
    if is_manual_setup_device(device) then
      log.warn("Switcher refresh has no Device ID yet - manual setup device will keep searching")
      local discovered_cfg = discover_for_manual_setup(driver, device, cfg, "refresh_" .. source_label, is_manual_refresh_command(source))
      if discovered_cfg then
        cfg = discovered_cfg
      end
    end

    if not cfg.device_id or cfg.device_id == "" or cfg.device_id == DEFAULT_DEVICE_ID then
      log.warn("Switcher refresh skipped - missing discovered/manual Device ID")
      return
    end
  end

  -- A normal Refresh first uses the saved/current IP. Rediscovery is performed
  -- only by get_state_with_recovery() after the saved IP actually fails, or
  -- below when no IP is known. This keeps manual Refresh fast and separates
  -- existing-device IP recovery from new-device discovery/key scanning.

  if not cfg.ip or cfg.ip == "" then
    if is_manual_setup_device(device) then
      log.warn("Switcher refresh missing IP - manual setup device will keep searching")
      local discovered_cfg = discover_for_manual_setup(driver, device, cfg, "missing_ip_refresh", is_manual_refresh_command(source))
      if discovered_cfg then
        cfg = discovered_cfg
      end
    else
      log.warn("Switcher refresh missing IP - trying rediscovery")
      local discovered_cfg = rediscover_device(driver, device, cfg, "missing_ip_refresh")
      if discovered_cfg then
        cfg = discovered_cfg
      end
    end
  end

  if not cfg.ip or cfg.ip == "" then
    log.warn("Switcher refresh skipped - missing discovered/manual IP")
    return
  end

  local ok, info_or_err, active_cfg = get_state_with_recovery(driver, device, cfg, "refresh_" .. source_label)
  cfg = active_cfg or cfg

  if ok then
    local info = info_or_err

    mark_network_success(device, cfg, info, "refresh_success_" .. source_label)

    update_discovery_metadata(device, {
      ip = cfg.ip,
      device_id = cfg.device_id,
      device_key = cfg.device_key,
      device_type = info.device_type or saved_field(device, "discovered_device_type") or "Switcher Water Heater",
    }, "refresh_success_" .. source_label, false)

    local latest_switch = device:get_latest_state("main", capabilities.switch.ID, "switch") or "unknown"
    local actual_switch = info.state == "on" and "on" or "off"

    log.warn(
      "Switcher refresh state="
      .. tostring(actual_switch)
      .. ", previous_state="
      .. tostring(latest_switch)
      .. ", remaining_seconds="
      .. tostring(info.remaining_seconds or 0)
      .. ", elapsed_seconds="
      .. tostring(info.elapsed_seconds or 0)
      .. ", total_seconds="
      .. tostring(info.total_seconds or 0)
      .. ", power_watts="
      .. tostring(info.power_watts or 0)
      .. ", current_amps="
      .. tostring(round_number(watts_to_amps(info.power_watts or 0), 1))
    )

    if latest_switch ~= actual_switch then
      log.warn("Switcher external/manual state change detected: " .. tostring(latest_switch) .. " -> " .. tostring(actual_switch))
    end


    -- Always show the real physical Switcher state on the Boiler/main switch.
    -- If Delay countdown is pending and the physical boiler is still off, main stays OFF.
    -- If someone turns the boiler on manually or through the official app during the delay,
    -- main shows ON and runtime is displayed; the scheduled delay still remains active.
    emit_switch_state(device, actual_switch)

    if actual_switch == "on" then
      local remaining = seconds_to_remaining_minutes(info.remaining_seconds)
      local elapsed = seconds_to_elapsed_minutes(info.elapsed_seconds)
      local total = seconds_to_total_minutes(info.total_seconds)

      -- If the packet gives remaining+elapsed but total is missing, calculate it.
      if total == 0 and ((info.remaining_seconds or 0) > 0 or (info.elapsed_seconds or 0) > 0) then
        total = seconds_to_total_minutes((info.remaining_seconds or 0) + (info.elapsed_seconds or 0))
      end

      -- If Switcher returns no runtime progress, use selected/default duration as fallback.
      if remaining == 0 and elapsed == 0 and total == 0 then
        total = get_selected_minutes(device, cfg)
        remaining = total
        elapsed = 0
      end

      -- Keep total at least remaining+elapsed rounded to minutes.
      local total_from_parts = clamp_minutes(remaining + elapsed, true)
      if total < total_from_parts then
        total = total_from_parts
      end

      emit_runtime(device, elapsed, remaining, total, info.power_watts or 0)
    else
      emit_runtime(device, 0, 0, 0)
    end

    -- Timer Minutes is selected duration for next ON; do not overwrite it on Refresh.
  else
    log.error("Switcher refresh failed: " .. tostring(info_or_err))
    mark_network_failure(device, cfg, "refresh_" .. source_label, info_or_err)
  end
end

local function turn_on_for_minutes(driver, device, minutes, source)
  local cfg = get_config(device)
  minutes = clamp_minutes(minutes, false)

  log.warn("Switcher ON requested from " .. tostring(source or "unknown") .. ", using selected minutes=" .. tostring(minutes))

  if is_manual_setup_device(device) and (not cfg.ip or cfg.ip == "" or not cfg.device_id or cfg.device_id == "" or cfg.device_id == DEFAULT_DEVICE_ID) then
    local discovered_cfg = discover_for_manual_setup(driver, device, cfg, "on_command", true)
    if discovered_cfg then
      cfg = discovered_cfg
    end
  end

  if not cfg.ip or cfg.ip == "" or not cfg.device_id or cfg.device_id == "" or cfg.device_id == DEFAULT_DEVICE_ID then
    local err = "missing IP or Device ID; waiting for discovery or manual preferences"
    log.warn("Switcher ON skipped: " .. err)
    mark_network_failure(device, cfg, "on_command_missing_identity", err)
    return
  end

  local ok, active_cfg, err = set_power_with_recovery(driver, device, cfg, "on", minutes, "on_command")
  cfg = active_cfg or cfg

  if ok then
    mark_network_success(device, cfg, nil, "on_command")

    -- Remember a recent successful ON.
    -- SmartThings Routines can send switch.on first and setTimerMinutes right after it.
    -- If that happens, set_timer_minutes will re-send ON with the new minutes so the
    -- physical Switcher timer matches the routine-selected duration.
    device:set_field("last_successful_on_epoch", os.time(), {persist = false})
    device:set_field("last_successful_on_minutes", minutes, {persist = false})
    device:set_field("last_successful_on_source", tostring(source or "unknown"), {persist = false})

    emit_switch_state(device, "on")
    emit_timer(device, minutes)
    emit_runtime(device, 0, minutes, minutes)
    refresh(driver, device, "after_on")
  else
    log.error("Switcher ON failed: " .. tostring(err))
    mark_network_failure(device, cfg, "on_command", err)
  end
end

local function get_delay_enabled(device)
  local field_value = device:get_field("delay_enabled")
  if field_value ~= nil then
    return field_value == true
  end

  local state = device:get_latest_state("delay", capabilities.switch.ID, "switch")
  return state == "on"
end

local function set_delay_enabled(device, enabled)
  enabled = enabled == true
  device:set_field("delay_enabled", enabled, {persist = true})
  emit_switch_state(device, enabled and "on" or "off", "delay")
end

local function clamp_delay_hours(hours)
  hours = tonumber(hours or 0) or 0
  hours = math.floor(hours)
  if hours < 0 then hours = 0 end
  if hours > 24 then hours = 24 end
  return hours
end

local function clamp_delay_minutes(minutes)
  minutes = tonumber(minutes or 0) or 0
  minutes = math.floor(minutes)
  if minutes < 0 then minutes = 0 end
  if minutes > 59 then minutes = 59 end
  return minutes
end

local function get_delay_total_minutes(device)
  local hours = clamp_delay_hours(device:get_latest_state("delay", DELAY_CAPABILITY_ID, "delayHours") or 0)
  local minutes = clamp_delay_minutes(device:get_latest_state("delay", DELAY_CAPABILITY_ID, "delayMinutes") or 0)
  return hours * 60 + minutes, hours, minutes
end

local function emit_delay_values(device, hours, minutes, selected_total, status)
  hours = clamp_delay_hours(hours)
  minutes = clamp_delay_minutes(minutes)
  selected_total = tonumber(selected_total or 0) or 0
  selected_total = math.floor(selected_total)
  if selected_total < 0 then selected_total = 0 end
  if selected_total > 1440 then selected_total = 1440 end

  status = tostring(status or "idle")
  if status ~= "scheduled" then status = "idle" end

  emit_event_for_component(device, "delay", delay_capability.delayHours(hours))
  emit_event_for_component(device, "delay", delay_capability.delayMinutes(minutes))
  emit_event_for_component(device, "delay", delay_capability.selectedDelayMinutes(selected_total))
  emit_event_for_component(device, "delay", delay_capability.delayStatus(status))
end

local function next_delay_token(device)
  local token = tonumber(device:get_field("delay_token") or 0) or 0
  token = token + 1
  device:set_field("delay_token", token)
  return token
end

get_delay_pending = function(device)
  return device:get_field("delay_pending") == true
end

set_delay_pending = function(device, pending)
  device:set_field("delay_pending", pending == true, {persist = true})
end

local function cancel_pending_delay(device)
  next_delay_token(device)
  set_delay_pending(device, false)
  local total, hours, minutes = get_delay_total_minutes(device)
  emit_delay_values(device, hours, minutes, 0, "idle")
end

local function schedule_main_on_after_delay(driver, device, delay_total, source)
  if get_delay_pending(device) then
    log.warn("Switcher Delay received while already scheduled - keeping existing internal timer")
    -- Do not fake main ON here. Main must reflect the real physical boiler state only.
    emit_switch_state(device, "on", "delay")
    return
  end

  local token = next_delay_token(device)
  local _, hours, minutes = get_delay_total_minutes(device)
  local selected_now = get_selected_minutes(device, get_config(device))

  log.warn("Switcher Delay scheduling requested by " .. tostring(source) .. ". Internal timer set for " .. tostring(delay_total) .. " minutes. Boiler/main remains physical-state only. Current selected run minutes=" .. tostring(selected_now))

  -- No communication to the physical Switcher happens here.
  -- This only starts an internal driver timer.
  -- Boiler/main is NOT changed here: it must reflect the real physical Switcher state only.
  set_delay_pending(device, true)
  emit_delay_values(device, hours, minutes, delay_total, "scheduled")

  device.thread:call_with_delay(delay_total * 60, function()
    local current_token = tonumber(device:get_field("delay_token") or 0) or 0
    if current_token ~= token then
      log.warn("Switcher delayed ON ignored because it was cancelled/replaced/cancelled")
      return
    end

    -- Read Timer Minutes at execution time, not when scheduling.
    -- This prevents falling back to 120 if the user changes Timer Minutes after enabling Delay.
    local run_minutes = get_selected_minutes(device, get_config(device))

    log.warn("Switcher internal delay elapsed - sending physical ON now, run for " .. tostring(run_minutes) .. " minutes")
    set_delay_pending(device, false)
    set_delay_enabled(device, false)
    emit_delay_values(device, hours, minutes, 0, "idle")
    turn_on_for_minutes(driver, device, run_minutes, "delay_elapsed_internal_on")
  end)
end

local function switch_on(driver, device, command)
  local component_id = get_command_component(command)
  local cfg = get_config(device)
  local minutes = get_selected_minutes(device, cfg)

  if component_id == "delay" then
    log.warn("Switcher Delay enabled - starting countdown immediately")
    cancel_pending_delay(device)
    set_delay_enabled(device, true)
    local total, hours, extra_minutes = get_delay_total_minutes(device)
    emit_delay_values(device, hours, extra_minutes, total, "idle")

    if total <= 0 then
      log.warn("Switcher Delay is ON but time is 0, starting immediately")
      set_delay_enabled(device, false)
      turn_on_for_minutes(driver, device, minutes, "delay_on_zero_delay")
      return
    end

    schedule_main_on_after_delay(driver, device, total, "delay_switch_on")
    return
  end

  if get_delay_pending(device) then
    log.warn("Switcher main ON received while Delay countdown is already running - turning ON now and keeping Delay scheduled")
    -- Manual ON is allowed while Delay remains active:
    -- 1. Turn the physical Switcher on immediately using the current Timer Minutes.
    -- 2. Keep the internal Delay countdown alive.
    -- 3. When Delay elapses, it will send ON again using the then-current Timer Minutes,
    --    effectively restarting/extending the physical Switcher timer at that time.
    turn_on_for_minutes(driver, device, minutes, "main_on_during_delay_keep_delay")
    return
  end

  turn_on_for_minutes(driver, device, minutes, "regular_on_selected_timer")
end

local function switch_off(driver, device, command)
  local component_id = get_command_component(command)

  if component_id == "delay" then
    log.warn("Switcher Delay disabled/cancelled")
    set_delay_enabled(device, false)
    -- Do not force main OFF here. Main is the real physical boiler state.
    cancel_pending_delay(device)
    refresh(driver, device, "after_delay_cancel")
    return
  end

  -- Parallel behavior:
  -- Boiler/main OFF turns the physical Switcher off only.
  -- It must NOT cancel a pending Delay, and must NOT turn the Delay component off.
  -- The Delay component can be cancelled only from Delay OFF/cancelDelay.
  local cfg = get_config(device)
  log.warn("Switcher OFF requested")

  if is_manual_setup_device(device) and (not cfg.ip or cfg.ip == "" or not cfg.device_id or cfg.device_id == "" or cfg.device_id == DEFAULT_DEVICE_ID) then
    local discovered_cfg = discover_for_manual_setup(driver, device, cfg, "off_command", true)
    if discovered_cfg then
      cfg = discovered_cfg
    end
  end

  if not cfg.ip or cfg.ip == "" or not cfg.device_id or cfg.device_id == "" or cfg.device_id == DEFAULT_DEVICE_ID then
    local err = "missing IP or Device ID; waiting for discovery or manual preferences"
    log.warn("Switcher OFF skipped: " .. err)
    mark_network_failure(device, cfg, "off_command_missing_identity", err)
    return
  end

  local ok, active_cfg, err = set_power_with_recovery(driver, device, cfg, "off", 0, "off_command")
  cfg = active_cfg or cfg

  if ok then
    mark_network_success(device, cfg, nil, "off_command")
    emit_switch_state(device, "off")
    emit_runtime(device, 0, 0, 0)
    -- Do not reset Timer Minutes on OFF. It remains next selected duration.
    refresh(driver, device, "after_off")
  else
    log.error("Switcher OFF failed: " .. tostring(err))
    mark_network_failure(device, cfg, "off_command", err)
  end
end

local function set_timer_minutes(driver, device, command)
  local minutes = tonumber(command.args and command.args.timerMinutes) or 0
  minutes = clamp_minutes(minutes, true)

  local latest_switch = device:get_latest_state("main", capabilities.switch.ID, "switch") or "unknown"
  local last_on_epoch = tonumber(device:get_field("last_successful_on_epoch") or 0) or 0
  local last_on_minutes = tonumber(device:get_field("last_successful_on_minutes") or 0) or 0
  local last_on_source = tostring(device:get_field("last_successful_on_source") or "")
  local age = os.time() - last_on_epoch

  emit_timer(device, minutes)

  -- Routine-order fix:
  -- In SmartThings Routines, commands may arrive as switch.on first and only then
  -- setTimerMinutes. Without this, the physical Switcher starts using the old selected
  -- duration. If the timer changes shortly after a successful ON, re-issue the ON
  -- command with the new minutes.
  if latest_switch == "on" and last_on_epoch > 0 and age >= 0 and age <= 2 and minutes > 0 and minutes ~= last_on_minutes then
    log.warn(
      "Switcher timerMinutes changed shortly after ON; assuming Routine command order and updating physical timer: old="
      .. tostring(last_on_minutes)
      .. ", new="
      .. tostring(minutes)
      .. ", age="
      .. tostring(age)
      .. "s, last_on_source="
      .. last_on_source
    )

    -- Clear the marker before re-sending ON so this correction cannot cascade.
    device:set_field("last_successful_on_epoch", 0, {persist = false})
    device:set_field("last_successful_on_minutes", 0, {persist = false})
    device:set_field("last_successful_on_source", "routine_timer_correction", {persist = false})

    turn_on_for_minutes(driver, device, minutes, "routine_timer_order_fix")
    return
  end

  log.warn("Switcher timerMinutes selected only, no power command: " .. tostring(minutes))
end

local function get_first_arg(command, named_key)
  if command and command.args then
    if named_key and command.args[named_key] ~= nil then return command.args[named_key] end
    if command.args[1] ~= nil then return command.args[1] end
    if command.args.value ~= nil then return command.args.value end
    if command.args.argument ~= nil then return command.args.argument end
    if command.args.delayHours ~= nil then return command.args.delayHours end
    if command.args.delayMinutes ~= nil then return command.args.delayMinutes end
  end
  if command and command.positional_args and command.positional_args[1] ~= nil then
    return command.positional_args[1]
  end
  if command and command.named_args and named_key and command.named_args[named_key] ~= nil then
    return command.named_args[named_key]
  end
  return nil
end

local function set_delay_hours(driver, device, command)
  local hours = clamp_delay_hours(get_first_arg(command, "delayHours"))
  local minutes = clamp_delay_minutes(device:get_latest_state("delay", DELAY_CAPABILITY_ID, "delayMinutes") or 0)
  local selected = hours * 60 + minutes
  local status = device:get_latest_state("delay", DELAY_CAPABILITY_ID, "delayStatus") or "idle"
  log.warn("Switcher Delay hours set: " .. tostring(hours))
  emit_delay_values(device, hours, minutes, selected, status)
end

local function set_delay_minutes(driver, device, command)
  local minutes = clamp_delay_minutes(get_first_arg(command, "delayMinutes"))
  local hours = clamp_delay_hours(device:get_latest_state("delay", DELAY_CAPABILITY_ID, "delayHours") or 0)
  local selected = hours * 60 + minutes
  local status = device:get_latest_state("delay", DELAY_CAPABILITY_ID, "delayStatus") or "idle"
  log.warn("Switcher Delay minutes set: " .. tostring(minutes))
  emit_delay_values(device, hours, minutes, selected, status)
end

local function delay_unused_start(driver, device, command)
  -- Not exposed in the v35 UI. Kept only because this capability already contains these commands.
  log.warn("Switcher unused Delay command received; ignoring")
end

local function discovery_handler(driver, opts, should_continue)
  log.warn("Switcher discovery handler started - scanning TCP 9957")

  local found_any = false
  local devices = {}

  local ok, result_or_err = pcall(function()
    return protocol.discover(45, nil, {
      workers = 16,
      key_scan_delay_ms = 10,
      probe_key = "00",
      on_candidate = function(candidate)
        -- Candidate probe already gives IP + device_id. If that device already
        -- exists, update the current IP and skip the expensive key scan.
        local existing = find_existing_device(driver, candidate, { allow_unbound_manual = false })
        if existing then
          found_any = true
          set_saved_network_info(existing, candidate, "discovery_probe_existing_device")
          update_discovery_metadata(existing, candidate, "discovery_probe_existing_device", false)
          log.warn(
            "Switcher discovery probe matched existing device"
            .. ", device_id=" .. tostring(candidate.device_id)
            .. ", ip=" .. tostring(candidate.ip)
            .. "; skipped key scan and create"
          )
          return "skip"
        end
        return "scan"
      end,
    })
  end)

  if ok and type(result_or_err) == "table" then
    devices = result_or_err
  else
    log.error("Switcher discovery failed: " .. tostring(result_or_err))
  end

  for _, info in ipairs(devices) do
    if should_continue then
      local ok_continue, keep_going = pcall(function() return should_continue() end)
      if ok_continue and keep_going == false then
        log.warn("Switcher discovery stopped by SmartThings")
        break
      end
    end

    local dni = protocol.discovery_dni(info)
    local label = normalize_device_label(info.name)
    pending_discovery_by_dni[dni] = info

    local existing_device = find_existing_device(driver, info)

    if existing_device then
      found_any = true
      set_saved_network_info(existing_device, info, "discovery_existing_device")
      mark_network_success(existing_device, {
        ip = info.ip,
        device_id = info.device_id,
        device_key = info.device_key or "",
      }, info, "discovery_existing_device")
      update_discovery_metadata(existing_device, info, "discovery_existing_device", true)
      log.warn(
        "Switcher discovery matched existing device"
        .. ", device_id=" .. tostring(info.device_id)
        .. ", ip=" .. tostring(info.ip)
        .. "; updated saved IP and metadata"
      )
    else
      local metadata_info = discovery_metadata(info.ip, info.device_id, info.device_type or info.model)
      local metadata = {
        type = "LAN",
        device_network_id = dni,
        label = label,
        profile = "switcher-touch-lan",
        manufacturer = metadata_info.manufacturer,
        model = metadata_info.model
      }
      log.warn("Switcher creating supported water-heater device from discovery: label=" .. tostring(label) .. ", dni=" .. tostring(dni))

      local created, err = pcall(function()
        driver:try_create_device(metadata)
      end)

      if created then
        found_any = true
        log.warn("Switcher try_create_device called for discovered device " .. tostring(label))
      else
        log.error("Switcher try_create_device failed: " .. tostring(err))
      end
    end
  end

  if found_any then
    return
  end

  -- Manual setup fallback: create one placeholder device only. It remains
  -- usable for manual IP/Device ID entry and also keeps running the same TCP
  -- discovery protocol in the background until it can adopt a real Switcher.
  local manual_device = find_manual_setup_device(driver)
  if manual_device then
    log.warn("Switcher discovery found no devices - manual setup device already exists; it will keep searching")
    update_discovery_metadata(manual_device, nil, "discovery_no_devices_existing_manual", true)
    return
  end

  local metadata = {
    type = "LAN",
    device_network_id = MANUAL_SETUP_DNI,
    label = MANUAL_SETUP_LABEL,
    profile = "switcher-touch-lan",
    manufacturer = "Switcher",
    model = manual_setup_model_value(),
  }

  log.warn("Switcher discovery found no devices - creating manual setup placeholder")
  local created, err = pcall(function()
    driver:try_create_device(metadata)
  end)

  if created then
    log.warn("Switcher manual setup placeholder create requested")
  else
    log.error("Switcher manual setup placeholder create failed: " .. tostring(err))
  end
end

local function device_added(driver, device)
  log.warn("Switcher device added")

  local pending_info = pending_discovery_by_dni[device.device_network_id or ""]
  if pending_info then
    set_saved_network_info(device, pending_info, "device_added_pending_discovery")
    pending_discovery_by_dni[device.device_network_id or ""] = nil
  end

  if is_manual_setup_device(device) then
    device:set_field("manual_setup_device", true, {persist = true})
    device:set_field("network_status", "searching", {persist = true})
  end

  update_discovery_metadata(device, pending_info, "device_added", true)
  emit_switch_state(device, "off")
  emit_switch_state(device, "off", "delay")
  device:set_field("delay_enabled", false, {persist = true})
  device:set_field("delay_pending", false, {persist = true})
  device:set_field("network_fail_count", 0, {persist = true})
  if is_manual_setup_device(device) and not pending_info then
    device:set_field("network_status", "searching", {persist = true})
  else
    device:set_field("network_status", "reachable", {persist = true})
  end
  device:set_field("last_error", "", {persist = true})
  emit_timer(device, 0)
  emit_delay_values(device, 0, 0, 0, "idle")
  emit_runtime(device, 0, 0, 0)
end

local function device_init(driver, device)
  log.warn("Switcher device init")
  update_discovery_metadata(device, nil, "init", false)
  refresh(driver, device, "init")
  schedule_monitor(driver, device)
end

local function device_info_changed(driver, device, event, args)
  log.warn("Switcher device infoChanged")
  update_discovery_metadata(device, nil, "infoChanged", true)
  refresh(driver, device, "infoChanged")
  schedule_monitor(driver, device)
end

local switcher_driver = Driver("switcher-touch-lan", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    infoChanged = device_info_changed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off,
    },
    [TIMER_CAPABILITY_ID] = {
      [timer_capability.commands.setTimerMinutes.NAME] = set_timer_minutes,
    },
    [DELAY_CAPABILITY_ID] = {
      [delay_capability.commands.setDelayHours.NAME] = set_delay_hours,
      [delay_capability.commands.setDelayMinutes.NAME] = set_delay_minutes,
      [delay_capability.commands.startDelay30.NAME] = delay_unused_start,
      [delay_capability.commands.startDelay60.NAME] = delay_unused_start,
      [delay_capability.commands.startDelay120.NAME] = delay_unused_start,
      [delay_capability.commands.startDelayCustom.NAME] = delay_unused_start,
      [delay_capability.commands.cancelDelay.NAME] = delay_unused_start,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh,
    },
  },
})

log.warn("Switcher Water Heater LAN release driver loaded v1.2.0-public-final, timer capability=" .. TIMER_CAPABILITY_ID .. ", delay capability=" .. DELAY_CAPABILITY_ID .. ", runtime capability=" .. RUNTIME_CAPABILITY_ID)
switcher_driver:run()
