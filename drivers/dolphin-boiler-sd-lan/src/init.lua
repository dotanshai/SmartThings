-- Dolphin Boiler SD - SmartThings Edge Driver
-- Polls Dolphin Cloud API to control and monitor a smart water boiler.
-- All modes: manual on/off, fixed temperature, Shabbat on/off.

local Driver     = require("st.driver")
local caps       = require("st.capabilities")
local log        = require("log")

local api        = require("dolphin_api")
local prefs      = require("prefs")
local timers     = require("timers")

-- Custom capabilities
local boilerMode      = caps["perfectworld33337.boilerMode"]
local shabbatMode     = caps["perfectworld33337.shabbatMode"]
local fixedTempCtrl   = caps["perfectworld33337.fixedTemperatureControl"]

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function emit_state(device, data)
  if data.currentTemperature then
    device:emit_event(caps.temperatureMeasurement.temperature({
      value = data.currentTemperature, unit = "C"
    }))
  end

  local sw_on = (data.isHeating == true) or
                (data.mode == "manual") or
                (data.mode == "fixed")
  device:emit_event(sw_on and caps.switch.switch.on() or caps.switch.switch.off())

  if data.targetTemperature then
    device:emit_event(caps.thermostatHeatingSetpoint.heatingSetpoint({
      value = data.targetTemperature, unit = "C"
    }))
  end

  if data.mode then
    device:emit_event(boilerMode.mode({ value = data.mode }))
  end

  if data.shabbatEnabled ~= nil then
    device:emit_event(shabbatMode.shabbat({
      value = data.shabbatEnabled and "enabled" or "disabled"
    }))
  end

  if data.fixedTempEnabled ~= nil then
    device:emit_event(fixedTempCtrl.fixedTemp({
      value = data.fixedTempEnabled and "enabled" or "disabled"
    }))
  end
end

local function poll_device(driver, device)
  local p = prefs.get(device)
  if not p.email or p.email == "" or not p.password or p.password == "" or not p.deviceName or p.deviceName == "" then
    log.warn("[Dolphin] Prefs not set, skipping poll")
    return
  end

  local api_key, err = api.ensure_key(device, p.email, p.password)
  if not api_key then
    log.error("[Dolphin] Auth failed: " .. tostring(err))
    device:offline()
    return
  end

  local data, err2 = api.get_status(p.deviceName, p.email, api_key)
  if not data then
    log.error("[Dolphin] Status poll failed: " .. tostring(err2))
    device:offline()
    return
  end

  device:online()
  emit_state(device, data)
end

-----------------------------------------------------------------------
-- Capability command handlers
-----------------------------------------------------------------------

local function handle_switch_on(driver, device, cmd)
  local p = prefs.get(device)
  local api_key = api.get_cached_key(device)
  if not api_key then return end
  local ok, err = api.send_command(p.deviceName, p.email, api_key, "turnOnManually")
  if ok then
    device:emit_event(caps.switch.switch.on())
    device:emit_event(boilerMode.mode({ value = "manual" }))
  else
    log.error("[Dolphin] turnOnManually failed: " .. tostring(err))
  end
end

local function handle_switch_off(driver, device, cmd)
  local p = prefs.get(device)
  local api_key = api.get_cached_key(device)
  if not api_key then return end
  local ok, err = api.send_command(p.deviceName, p.email, api_key, "turnOffManually")
  if ok then
    device:emit_event(caps.switch.switch.off())
    device:emit_event(boilerMode.mode({ value = "off" }))
  else
    log.error("[Dolphin] turnOffManually failed: " .. tostring(err))
  end
end

local function handle_set_setpoint(driver, device, cmd)
  local temp = cmd.args.setpoint
  local p = prefs.get(device)
  local api_key = api.get_cached_key(device)
  if not api_key then return end
  local ok, err = api.send_command(
    p.deviceName, p.email, api_key, "setFixedTemperature", { temperature = temp }
  )
  if ok then
    device:emit_event(caps.thermostatHeatingSetpoint.heatingSetpoint({
      value = temp, unit = "C"
    }))
    device:emit_event(fixedTempCtrl.fixedTemp({ value = "enabled" }))
    device:emit_event(boilerMode.mode({ value = "fixed" }))
    device:emit_event(caps.switch.switch.on())
  else
    log.error("[Dolphin] setFixedTemperature failed: " .. tostring(err))
  end
end

local function handle_fixed_temp_off(driver, device, cmd)
  local p = prefs.get(device)
  local api_key = api.get_cached_key(device)
  if not api_key then return end
  local ok, err = api.send_command(p.deviceName, p.email, api_key, "turnOffFixedTemperature")
  if ok then
    device:emit_event(fixedTempCtrl.fixedTemp({ value = "disabled" }))
    device:emit_event(boilerMode.mode({ value = "off" }))
    device:emit_event(caps.switch.switch.off())
  else
    log.error("[Dolphin] turnOffFixedTemperature failed: " .. tostring(err))
  end
end

local function handle_shabbat_on(driver, device, cmd)
  local p = prefs.get(device)
  local api_key = api.get_cached_key(device)
  if not api_key then return end
  local ok, err = api.send_command(p.deviceName, p.email, api_key, "enableShabbat")
  if ok then
    device:emit_event(shabbatMode.shabbat({ value = "enabled" }))
    device:emit_event(boilerMode.mode({ value = "shabbat" }))
    device:emit_event(caps.switch.switch.on())
  else
    log.error("[Dolphin] enableShabbat failed: " .. tostring(err))
  end
end

local function handle_shabbat_off(driver, device, cmd)
  local p = prefs.get(device)
  local api_key = api.get_cached_key(device)
  if not api_key then return end
  local ok, err = api.send_command(p.deviceName, p.email, api_key, "disableShabbat")
  if ok then
    device:emit_event(shabbatMode.shabbat({ value = "disabled" }))
    device:emit_event(boilerMode.mode({ value = "off" }))
    device:emit_event(caps.switch.switch.off())
  else
    log.error("[Dolphin] disableShabbat failed: " .. tostring(err))
  end
end

-----------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------

local function device_added(driver, device)
  log.info("[Dolphin] Device added: " .. device.label)
  device:emit_event(caps.switch.switch.off())
  device:emit_event(boilerMode.mode({ value = "off" }))
  device:emit_event(shabbatMode.shabbat({ value = "disabled" }))
  device:emit_event(fixedTempCtrl.fixedTemp({ value = "disabled" }))
end

local function device_init(driver, device)
  log.info("[Dolphin] Device init: " .. device.label)
  timers.start_poll(driver, device, poll_device)
end

local function device_removed(driver, device)
  log.info("[Dolphin] Device removed: " .. device.label)
  timers.stop_poll(device)
end

local function driver_switched(driver, device, event, args)
  log.info("[Dolphin] Driver switched - updating profile to dolphin-boiler-main")
  device:try_update_metadata({
    profile = "dolphin-boiler-main",
    manufacturer = "Dolphin",
    model = "Smart Boiler",
    vendor_provided_label = "Dolphin Boiler",
  })

  -- Schedule deletion of this vSwitch device and creation of a proper
  -- Dolphin device. We do it after a short delay so the profile update
  -- settles first, then the new device gets created before this one dies.
  local cosock = require "cosock"
  cosock.spawn(function()
    cosock.socket.sleep(3)
    log.info("[Dolphin] Creating proper Dolphin device to replace vSwitch...")
    local metadata = {
      type = "LAN",
      device_network_id = "dolphin-boiler-001",
      label = "Dolphin Boiler",
      profile = "dolphin-boiler-main",
      manufacturer = "Dolphin",
      model = "Smart Boiler",
      vendor_provided_label = "Dolphin Boiler",
    }
    driver:try_create_device(metadata)
    -- Give ST time to create the new device, then delete the vSwitch
    cosock.socket.sleep(5)
    log.info("[Dolphin] Deleting vSwitch placeholder: " .. device.id)
    device:emit_event(caps.switch.switch.off())  -- ensure clean state
    driver:try_delete_device(device.id)
  end, "dolphin-replace-vswitch")
end

local function info_changed(driver, device, event, args)
  log.info("[Dolphin] Preferences changed, restarting poll timer")
  api.clear_key(device)
  timers.stop_poll(device)
  timers.start_poll(driver, device, poll_device)
  poll_device(driver, device)
end

-----------------------------------------------------------------------
-- Discovery — called when user taps "Scan for nearby devices"
-----------------------------------------------------------------------

local function create_dolphin_device(driver)
  local device_list = driver:get_devices()
  if #device_list > 0 then
    log.info("[Dolphin] Device already exists, skipping creation")
    return
  end

  local metadata = {
    type = "LAN",
    device_network_id = "dolphin-boiler-001",
    label = "Dolphin Boiler",
    profile = "dolphin-boiler-main",
    manufacturer = "Dolphin",
    model = "Smart Boiler",
    vendor_provided_label = "Dolphin Boiler",
  }

  log.info("[Dolphin] Creating device...")
  driver:try_create_device(metadata)
  log.info("[Dolphin] Device creation requested")
end

local function discovery_handler(driver, _, should_continue)
  log.info("[Dolphin] Discovery triggered")
  create_dolphin_device(driver)
end

-----------------------------------------------------------------------
-- Driver definition
-----------------------------------------------------------------------

local dolphin_driver = Driver("dolphin-boiler-sd", {
  discovery = discovery_handler,

  lifecycle_handlers = {
    added       = device_added,
    init        = device_init,
    removed     = device_removed,
    infoChanged = info_changed,
    driverSwitched = driver_switched,
  },

  capability_handlers = {
    [caps.switch.ID] = {
      [caps.switch.commands.on.NAME]  = handle_switch_on,
      [caps.switch.commands.off.NAME] = handle_switch_off,
    },
    [caps.thermostatHeatingSetpoint.ID] = {
      [caps.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = handle_set_setpoint,
    },
    [fixedTempCtrl.ID] = {
      ["disable"] = handle_fixed_temp_off,
    },
    [shabbatMode.ID] = {
      ["enable"]  = handle_shabbat_on,
      ["disable"] = handle_shabbat_off,
    },
  },
})

-- Auto-create device on driver startup (2 second delay to allow init to complete)
local cosock = require "cosock"
cosock.spawn(function()
  cosock.socket.sleep(2)
  create_dolphin_device(dolphin_driver)
end, "dolphin-auto-create")

dolphin_driver:run()
