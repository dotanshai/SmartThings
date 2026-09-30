-- init.lua — SmartThings Edge driver for Switcher Breeze (v2).
-- IR codes come from the packed all-remotes module, chosen by the device's
-- reported remote_id, so a single driver covers every AC in the DB (incl. swing).
local Driver = require "st.driver"
local caps = require "st.capabilities"
local log = require "log"
local protocol = require "breeze_protocol"

local DRIVER_VERSION = "v2-2026-07-04"
local DEFAULT_IP = "192.168.1.102"
local DEFAULT_ID = "c92fb7"

-- ST airConditionerMode uses "fanOnly"; our protocol uses "fan".
local AC_MODES = { "cool", "heat", "dry", "fanOnly", "auto" }
local AC_FANS  = { "auto", "low", "medium", "high" }
local AC_SWING = { "fixed", "all" }   -- fixed = swing off, all = swing on
local function mode_to_st(m) return m == "fan" and "fanOnly" or m end
local function mode_from_st(m) return m == "fanOnly" and "fan" or m end
local function swing_to_st(s) return s == "on" and "all" or "fixed" end
local function swing_from_st(s) return s == "fixed" and "off" or "on" end

-- ---- config + desired-state store -----------------------------------------
local function get_config(device)
  local p = device.preferences or {}
  return {
    ip = (p.deviceIp ~= nil and p.deviceIp ~= "") and p.deviceIp or DEFAULT_IP,
    device_id = (p.deviceId ~= nil and p.deviceId ~= "") and p.deviceId or DEFAULT_ID,
    poll = tonumber(p.pollInterval) or 60,
  }
end

local function get_desired(device)
  return {
    power  = device:get_field("d_power") or "on",
    mode   = device:get_field("d_mode") or "cool",
    target = tonumber(device:get_field("d_target")) or 24,
    fan    = device:get_field("d_fan") or "auto",
    swing  = device:get_field("d_swing") or "off",
  }
end

local function store_state(device, st)
  device:set_field("d_power", st.power, { persist = true })
  device:set_field("d_mode", st.mode, { persist = true })
  device:set_field("d_target", st.target, { persist = true })
  device:set_field("d_fan", st.fan, { persist = true })
  device:set_field("d_swing", st.swing or "off", { persist = true })
  if st.remote_id and st.remote_id ~= "" then
    device:set_field("remote_id", st.remote_id, { persist = true })
  end
end

-- ---- emit capability state -------------------------------------------------
local function emit_state(device, st)
  device:emit_event(st.power == "on" and caps.switch.switch.on() or caps.switch.switch.off())
  device:emit_event(caps.airConditionerMode.airConditionerMode(mode_to_st(st.mode)))
  device:emit_event(caps.airConditionerFanMode.fanMode(st.fan))
  device:emit_event(caps.fanOscillationMode.fanOscillationMode(swing_to_st(st.swing)))
  device:emit_event(caps.thermostatCoolingSetpoint.coolingSetpoint({ value = st.target, unit = "C" }))
  device:emit_event(caps.temperatureMeasurement.temperature({ value = st.room, unit = "C" }))
end

-- ---- core refresh + poll ---------------------------------------------------
local function refresh(driver, device)
  local cfg = get_config(device)
  log.debug("Breeze refresh: querying " .. cfg.ip .. " (device_id=" .. cfg.device_id .. ")")
  local ok, st = pcall(protocol.get_state, cfg.ip, cfg.device_id)
  if ok then
    store_state(device, st)
    emit_state(device, st)
    log.info(string.format("Breeze [%s] %s %s %s %d° room=%.1f",
      tostring(st.remote_id), st.power, st.mode, st.fan, st.target, st.room))
    -- Warm the IR-code cache once, off the click path, so the first command
    -- isn't stuck decompressing the code stream.
    if st.remote_id and st.remote_id ~= "" and not device:get_field("codes_warmed") then
      device:set_field("codes_warmed", true)   -- in-memory; re-warms after a driver restart
      device.thread:call_with_delay(1, function()
        local okc = protocol.ensure_codes(st.remote_id)
        log.info("Breeze codes warm for " .. st.remote_id .. ": " .. tostring(okc))
      end)
    end
  else
    log.error("Breeze refresh failed for " .. cfg.ip .. ": " .. tostring(st))
  end
end

local function schedule_poll(driver, device)
  if device:get_field("poll_scheduled") then return end
  device:set_field("poll_scheduled", true)
  local interval = get_config(device).poll
  device.thread:call_with_delay(interval, function()
    device:set_field("poll_scheduled", false)
    refresh(driver, device)
    schedule_poll(driver, device)
  end)
end

-- ---- command application ---------------------------------------------------
-- mutate the desired state, send one full-state IR command, emit the result.
local function apply(device, mutate)
  local cfg = get_config(device)
  local d = get_desired(device)
  mutate(d)
  local remote_id = device:get_field("remote_id")
  log.debug(string.format("Breeze cmd->apply ip=%s id=%s remote=%s want power=%s mode=%s target=%s fan=%s swing=%s",
    cfg.ip, cfg.device_id, tostring(remote_id),
    d.power, d.mode, tostring(d.target), d.fan, d.swing))
  local ok, st = pcall(protocol.apply, cfg.ip, cfg.device_id, remote_id, d)
  if ok then
    store_state(device, st)
    emit_state(device, st)
    log.info("Breeze command OK, sent key=" .. tostring(st.sent_key))
  else
    log.error("Breeze command FAILED: " .. tostring(st))
  end
end

-- ---- capability handlers ---------------------------------------------------
local function cmd_on(driver, device)
  log.info("Breeze cmd: switch on"); apply(device, function(d) d.power = "on" end)
end
local function cmd_off(driver, device)
  log.info("Breeze cmd: switch off"); apply(device, function(d) d.power = "off" end)
end
local function cmd_set_mode(driver, device, command)
  log.info("Breeze cmd: setAirConditionerMode=" .. tostring(command.args.mode))
  apply(device, function(d) d.power = "on"; d.mode = mode_from_st(command.args.mode) end)
end
local function cmd_set_setpoint(driver, device, command)
  log.info("Breeze cmd: setCoolingSetpoint=" .. tostring(command.args.setpoint))
  apply(device, function(d) d.power = "on"; d.target = math.floor(tonumber(command.args.setpoint) or d.target) end)
end
local function cmd_set_fan(driver, device, command)
  log.info("Breeze cmd: setFanMode=" .. tostring(command.args.fanMode))
  apply(device, function(d) d.power = "on"; d.fan = command.args.fanMode end)
end
local function cmd_set_swing(driver, device, command)
  log.info("Breeze cmd: setFanOscillationMode=" .. tostring(command.args.fanOscillationMode))
  apply(device, function(d) d.power = "on"; d.swing = swing_from_st(command.args.fanOscillationMode) end)
end
local function cmd_refresh(driver, device)
  log.info("Breeze cmd: refresh"); refresh(driver, device)
end

-- ---- lifecycle -------------------------------------------------------------
local function device_init(driver, device)
  local cfg = get_config(device)
  log.info(string.format("Breeze init (%s): dni=%s ip=%s device_id=%s poll=%ds",
    DRIVER_VERSION, tostring(device.device_network_id), cfg.ip, cfg.device_id, cfg.poll))
  device:emit_event(caps.airConditionerMode.supportedAcModes(AC_MODES))
  device:emit_event(caps.airConditionerFanMode.supportedAcFanModes(AC_FANS))
  device:emit_event(caps.fanOscillationMode.supportedFanOscillationModes(AC_SWING))
  refresh(driver, device)
  schedule_poll(driver, device)
end

local function device_added(driver, device)
  log.info("Breeze device added: dni=" .. tostring(device.device_network_id))
  refresh(driver, device)
end

local function device_info_changed(driver, device)
  local cfg = get_config(device)
  log.info("Breeze infoChanged: ip=" .. cfg.ip .. " device_id=" .. cfg.device_id .. " poll=" .. cfg.poll)
  refresh(driver, device)
end

-- ---- discovery: create the device (IP/device_id come from preferences) -----
local function discovery_handler(driver, opts, should_continue)
  if next(driver:get_devices() or {}) ~= nil then return end
  driver:try_create_device({
    type = "LAN",
    device_network_id = "switcher-breeze-" .. DEFAULT_ID,
    label = "Switcher Breeze",
    profile = "switcher-breeze",
    manufacturer = "Switcher",
    model = "Breeze",
  })
end

local breeze_driver = Driver("switcher-breeze", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = device_info_changed,
  },
  capability_handlers = {
    [caps.switch.ID] = {
      [caps.switch.commands.on.NAME] = cmd_on,
      [caps.switch.commands.off.NAME] = cmd_off,
    },
    [caps.airConditionerMode.ID] = {
      [caps.airConditionerMode.commands.setAirConditionerMode.NAME] = cmd_set_mode,
    },
    [caps.thermostatCoolingSetpoint.ID] = {
      [caps.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME] = cmd_set_setpoint,
    },
    [caps.airConditionerFanMode.ID] = {
      [caps.airConditionerFanMode.commands.setFanMode.NAME] = cmd_set_fan,
    },
    [caps.fanOscillationMode.ID] = {
      [caps.fanOscillationMode.commands.setFanOscillationMode.NAME] = cmd_set_swing,
    },
    [caps.refresh.ID] = {
      [caps.refresh.commands.refresh.NAME] = cmd_refresh,
    },
  },
})

log.info("Switcher Breeze driver starting (" .. DRIVER_VERSION .. ")")
breeze_driver:run()
