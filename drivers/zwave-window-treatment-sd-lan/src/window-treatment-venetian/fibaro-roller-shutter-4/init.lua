-- Fibaro Roller Shutter 4 (FGR-224) - SD fork of Mariano's subdriver
-- Adds: command retries (for weak/one-way Z-Wave routes), optimistic state,
--       Window Covering reports, and an always-online "App" child device
--       (the hub marks this blind offline; the child keeps app control working).

local cc = (require "st.zwave.CommandClass")
local Configuration = (require "st.zwave.CommandClass.Configuration")({version=1})
local SwitchMultilevel = (require "st.zwave.CommandClass.SwitchMultilevel")({version=2})
local Basic = (require "st.zwave.CommandClass.Basic")({version=1})
local CentralScene = (require "st.zwave.CommandClass.CentralScene")({version=3})
local constants = require "st.zwave.constants"
local capabilities = require "st.capabilities"
local log = require "log"
local WindowShadeDefaults = require "st.zwave.defaults.windowShade"
local WindowShadeLevelDefaults = require "st.zwave.defaults.windowShadeLevel"
local window_Shade_Preset_Value = capabilities["legendabsolute60149.windowShadePresetValue"]
-- Window Covering CC (0x6A) - FGR-224 also reports position with it on Lifeline (manual, section 12)
local wc_ok, WindowCovering = pcall(function()
  return (require "st.zwave.CommandClass.WindowCovering")({version=1})
end)
if not wc_ok then WindowCovering = nil end
local OUT_BOTTOM_1 = 0x0C -- roller position, not calibrated
local OUT_BOTTOM_2 = 0x0D -- roller position, calibrated
local NOT_POSITION_AWARE = 0xFE -- manual: Basic/Multilevel report value when not calibrated

local FIBARO_ROLLER_SHUTTER_FINGERPRINTS = {
  {mfr = 0x010F, prod = 0x0304, model = 0x1000}, -- Fibaro Roller shutter_4 EU version
}

-- configuration parameters
local CALIBRATION_CONFIGURATION = 150
local OPERATING_MODE_CONFIGURATION = 151

-- fieldnames
local CALIBRATION = "calibration"
local CMD_TOKEN = "sd_cmd_token"
local LAST_REPORT = "sd_last_report"
local MOTION = "sd_motion" -- {from, to, t}: last movement, used to estimate the position
local PROGRESS_TIMER = "sd_progress_timer"
local LAST_SHOWN = "sd_last_shown"
local CHILD_KEY = "app"
local CHILD_PROFILE = "fgr224-app-control"

-- calibration statuses
local CLB_NOT_STARTED = "not_started"
local CLB_DONE = "done"
local CLB_MANUAL = "manual"
local CLB_PENDING = "pending"

-- retry settings (seconds after the first send)
local RETRY_DELAYS = {5, 10, 15}
local FINAL_GET_DELAY = 20
local OPTIMISTIC_DELAY = 25

local function can_handle_fibaro_roller_shutter_4(opts, driver, device, ...)
  if device.network_type ~= "DEVICE_ZWAVE" then return false end
  for _, fingerprint in ipairs(FIBARO_ROLLER_SHUTTER_FINGERPRINTS) do
    if device:id_match(fingerprint.mfr, fingerprint.prod, fingerprint.model) then
      return true
    end
  end
  return false
end

-- ---------- helpers ----------

-- ---------- App child device (always online, mirrors the blind) ----------

local DRIVER = nil -- set in device_init, used to find the LAN App device

local function app_dni(parent)
  return "fgr224-app-" .. parent.id
end

-- the always-online LAN "App" device that belongs to this blind
local function get_child(device)
  if DRIVER == nil then return nil end
  local id = device:get_field("sd_app_id")
  if id then
    local d = DRIVER:get_device_info(id)
    if d then return d end
  end
  local dni = app_dni(device)
  for _, d in ipairs(DRIVER:get_devices()) do
    if d.device_network_id == dni then
      device:set_field("sd_app_id", d.id, {persist = true})
      return d
    end
  end
  return nil
end

-- called by the App device (init + every command) so both sides know each other
local function bind(driver, parent, app)
  DRIVER = driver
  if parent:get_field("sd_app_id") ~= app.id then
    parent:set_field("sd_app_id", app.id, {persist = true})
  end
end

local function shade_state_for(level)
  if level >= 100 then
    return capabilities.windowShade.windowShade.open()
  elseif level <= 0 then
    return capabilities.windowShade.windowShade.closed()
  end
  return capabilities.windowShade.windowShade.partially_open()
end

local function emit_child_level(device, level)
  local child = get_child(device)
  if child == nil then return end
  child:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
  child:emit_event(shade_state_for(level))
  child:online()
end

-- copy the parent's current level to the child
local function mirror_to_child(device)
  local level = device:get_latest_state("main", capabilities.windowShadeLevel.ID,
    capabilities.windowShadeLevel.shadeLevel.NAME)
  if level ~= nil then emit_child_level(device, level) end
end

local function emit_optimistic(device, component, level)
  local shown = level >= 99 and 100 or level
  device:set_field(LAST_SHOWN, shown)
  local comp = device.profile.components[component] or device.profile.components.main
  device:emit_component_event(comp, capabilities.windowShadeLevel.shadeLevel(shown))
  device:emit_component_event(comp, shade_state_for(shown))
  emit_child_level(device, shown)
end

-- send a command, then re-send it until a report arrives or retries run out
local function send_with_retry(device, component, cmd, target_level)
  local token = tostring(os.time()) .. "-" .. tostring(math.random(100000))
  local sent_at = os.time()
  device:set_field(CMD_TOKEN, token)

  device:send_to_component(cmd, component)
  log.info(string.format("[SD] sent %s (target=%s)", cmd.cmd_name or "cmd", tostring(target_level)))

  local function still_pending()
    if device:get_field(CMD_TOKEN) ~= token then return false end -- newer command superseded this one
    local last = device:get_field(LAST_REPORT) or 0
    return last < sent_at
  end

  for i, delay in ipairs(RETRY_DELAYS) do
    device.thread:call_with_delay(delay, function()
      if still_pending() then
        log.warn(string.format("[SD] no report yet - resend #%d", i))
        device:send_to_component(cmd, component)
      end
    end)
  end

  if target_level ~= nil then
    device.thread:call_with_delay(FINAL_GET_DELAY, function()
      if device:get_field(CMD_TOKEN) == token then
        device:send_to_component(SwitchMultilevel:Get({}), component)
      end
    end)
    device.thread:call_with_delay(OPTIMISTIC_DELAY, function()
      if still_pending() and device:get_field(PROGRESS_TIMER) == nil then
        log.warn("[SD] still no report - showing target level " .. tostring(target_level))
        emit_optimistic(device, component, target_level)
      end
    end)
  end
end

-- ---------- position estimate (blind never reports its position) ----------

local function current_level(device)
  return device:get_latest_state("main", capabilities.windowShadeLevel.ID,
    capabilities.windowShadeLevel.shadeLevel.NAME) or 0
end

-- SD settings live on the App device (always online); fall back to the blind, then default
local function sd_pref(device, name, default)
  local child = get_child(device)
  local v = child and child.preferences and child.preferences[name]
  if v == nil then v = device.preferences[name] end
  if v == nil then v = default end
  return v
end

-- estimated level now, from the last movement and the full-travel times in Settings
local function estimate_level(device)
  local m = device:get_field(MOTION)
  if m == nil then return nil end
  local up = m.to > m.from
  local travel = up and sd_pref(device, "travelUpSec", 30) or sd_pref(device, "travelDownSec", 30)
  if travel < 1 then travel = 1 end
  local moved = (os.time() - m.t) * 100 / travel
  local pos
  if up then pos = math.min(m.from + moved, m.to) else pos = math.max(m.from - moved, m.to) end
  return math.floor(pos + 0.5), up, travel, os.time() - m.t
end

-- ---------- live progress display while moving ----------

local function stop_progress(device)
  local t = device:get_field(PROGRESS_TIMER)
  if t then device.thread:cancel_timer(t) end
  device:set_field(PROGRESS_TIMER, nil)
end

-- level only (state is sent once at start / end), on the blind and the App device
local function show_level(device, level)
  if device:get_field(LAST_SHOWN) == level then return end
  device:set_field(LAST_SHOWN, level)
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
  local child = get_child(device)
  if child then child:emit_event(capabilities.windowShadeLevel.shadeLevel(level)) end
end

local function show_state(device, state_event_fn)
  device:emit_event(state_event_fn())
  local child = get_child(device)
  if child then child:emit_event(state_event_fn()) end
end

local function start_motion(device, target)
  stop_progress(device)
  local from = current_level(device)
  if target == from then
    device:set_field(MOTION, nil)
    return
  end
  device:set_field(MOTION, {from = from, to = target, t = os.time()})
  device:set_field(LAST_SHOWN, from)
  local up = target > from
  show_state(device, up and capabilities.windowShade.windowShade.opening or capabilities.windowShade.windowShade.closing)

  local interval = sd_pref(device, "progressSec", 2)
  if interval <= 0 then return end
  local timer = device.thread:call_on_schedule(interval, function()
    local pos = estimate_level(device)
    if pos == nil then stop_progress(device) return end
    show_level(device, pos)
    if pos == target then
      stop_progress(device)
      local shown = target >= 99 and 100 or target
      show_level(device, shown)
      show_state(device, function() return shade_state_for(shown) end)
    end
  end, "sd_progress")
  device:set_field(PROGRESS_TIMER, timer)
end

local function to_device_level(device, level)
  level = math.max(math.min(level, 99), 0)
  if device.preferences.reverse then level = 99 - level end
  return level
end

-- ---------- capability handlers ----------

local function open_handler(driver, device, command)
  start_motion(device, 100)
  local value = device.preferences.reverse and 0 or 99
  send_with_retry(device, command.component,
    SwitchMultilevel:Set({value = value, duration = constants.DEFAULT_DIMMING_DURATION}), 99)
end

local function close_handler(driver, device, command)
  start_motion(device, 0)
  local value = device.preferences.reverse and 99 or 0
  send_with_retry(device, command.component,
    SwitchMultilevel:Set({value = value, duration = constants.DEFAULT_DIMMING_DURATION}), 0)
end

local function pause_handler(driver, device, command)
  stop_progress(device)
  local pos, up, travel, elapsed = estimate_level(device)
  device:set_field(MOTION, nil)
  send_with_retry(device, command.component, SwitchMultilevel:StopLevelChange({}), nil)
  if pos ~= nil then
    log.info(string.format("[SD] stopped after %ds moving %s (full travel %ds) - estimated level %d%%",
      elapsed, up and "up" or "down", travel, pos))
    emit_optimistic(device, command.component, pos)
  end
  device.thread:call_with_delay(3, function()
    device:send_to_component(SwitchMultilevel:Get({}), command.component)
  end)
end

local function set_level_handler(driver, device, command)
  local requested = math.max(math.min(command.args.shadeLevel, 100), 0)
  start_motion(device, requested)
  local value = to_device_level(device, requested)
  send_with_retry(device, command.component,
    SwitchMultilevel:Set({value = value, duration = constants.DEFAULT_DIMMING_DURATION}), requested)
end

local function preset_handler(driver, device, command)
  local preset = device:get_field("windowShadePreset_Value") or "50%"
  local level
  if preset == "Random" then
    level = math.random(device.preferences.randomPresetMin or 40, device.preferences.randomPresetMax or 90)
  else
    level = tonumber((preset:gsub("%%", ""))) or 50
  end
  start_motion(device, level)
  send_with_retry(device, command.component,
    SwitchMultilevel:Set({value = to_device_level(device, level), duration = constants.DEFAULT_DIMMING_DURATION}), level)
end

-- ---------- Z-Wave handlers ----------

local function level_report_handler(driver, device, cmd)
  device:set_field(LAST_REPORT, os.time())
  stop_progress(device) -- real position arrived: stop the estimate
  device:set_field(MOTION, nil)
  if cmd.args.value == NOT_POSITION_AWARE then
    log.warn("[SD] blind reports 'position unknown' (0xFE) - run calibration (parameter 150 = 3)")
    return
  end
  WindowShadeDefaults.zwave_handlers[cc.SWITCH_MULTILEVEL][SwitchMultilevel.REPORT](driver, device, cmd)
  WindowShadeLevelDefaults.zwave_handlers[cc.SWITCH_MULTILEVEL][SwitchMultilevel.REPORT](driver, device, cmd)
  mirror_to_child(device)
end

local function window_covering_report_handler(driver, device, cmd)
  local pid = cmd.args.parameter_id
  if pid ~= OUT_BOTTOM_1 and pid ~= OUT_BOTTOM_2 then return end -- slats (0x16/0x17) ignored
  device:set_field(LAST_REPORT, os.time())
  stop_progress(device) -- real position arrived: stop the estimate
  device:set_field(MOTION, nil)
  local value = cmd.args.current_value
  if value == nil or value == NOT_POSITION_AWARE then return end
  if device.preferences.reverse then value = 99 - value end
  emit_optimistic(device, "main", value)
end

local function central_scene_handler(driver, device, cmd)
  log.info(string.format("[SD] wall switch scene %s (%s)",
    tostring(cmd.args.scene_number), tostring(cmd.args.key_attributes)))
  -- the blind is moving because of the wall switch: ask for the position when it stops
  device.thread:call_with_delay(30, function()
    device:send(SwitchMultilevel:Get({}))
  end)
end

local function configuration_report(driver, device, cmd)
  local parameter_number = cmd.args.parameter_number
  local configuration_value = cmd.args.configuration_value

  if parameter_number == CALIBRATION_CONFIGURATION then
    local calibration_status
    if configuration_value == 0 then
      calibration_status = CLB_NOT_STARTED
    elseif configuration_value == 1 then
      calibration_status = CLB_DONE
    elseif configuration_value == 2 then -- Calibration failed
      calibration_status = CLB_NOT_STARTED
    elseif configuration_value == 3 then
      if device:get_field(CALIBRATION) == CLB_NOT_STARTED then
        calibration_status = CLB_PENDING
      end
    elseif configuration_value == 4 then
      calibration_status = CLB_MANUAL
    end
    device:set_field(CALIBRATION, calibration_status, {persist = true})
  elseif parameter_number == OPERATING_MODE_CONFIGURATION then
    if configuration_value > 0 then -- 1= venetian 90, 2= venetian 180
      device:try_update_metadata({profile = "fibaro-roller-shutter-4-venetian"})
    else
      device:try_update_metadata({profile = "fibaro-roller-shutter-4"})
    end
  end
end

-- ---------- lifecycle ----------

local function endpoint_to_component(device, endpoint)
  if endpoint == 2 then return "venetianBlind" else return "main" end
end

local function component_to_endpoint(device, component)
  if component == "venetianBlind" then return {2} else return {} end
end

local function device_init(driver, device)
  if device.network_type ~= "DEVICE_ZWAVE" then return end -- never run for App child devices
  -- same component mapping as the parent venetian subdriver
  device:set_endpoint_to_component_fn(endpoint_to_component)
  device:set_component_to_endpoint_fn(component_to_endpoint)

  DRIVER = driver
  local child = get_child(device)
  if child == nil then
    if not device:get_field("sd_lan_requested") then
      device:set_field("sd_lan_requested", true)
      log.info("[SD] creating LAN App device " .. app_dni(device))
      driver:try_create_device({
        type = "LAN",
        device_network_id = app_dni(device),
        label = (device.label or "Blind") .. " (App)",
        profile = CHILD_PROFILE,
        manufacturer = "SD",
        model = "FGR-224 App Control",
        vendor_provided_label = "FGR-224 App Control"
      })
    end
  else
    mirror_to_child(device)
  end
  log.info("[SD] FGR-224 init - LAN App device=" .. tostring(child ~= nil))
end

local function device_added(driver, device)
  if device:get_field("windowShadePreset_Value") == nil then
    device:set_field("windowShadePreset_Value", "50%", {persist = true})
  end
  device:emit_event(window_Shade_Preset_Value.windowShadePresetValue(device:get_field("windowShadePreset_Value")))
  device:set_field(CALIBRATION, CLB_NOT_STARTED)
  device:do_refresh()
end

local zwave_handlers = {
  [cc.CONFIGURATION] = {
    [Configuration.REPORT] = configuration_report
  },
  [cc.SWITCH_MULTILEVEL] = {
    [SwitchMultilevel.REPORT] = level_report_handler
  },
  [cc.BASIC] = {
    [Basic.REPORT] = level_report_handler
  },
  [cc.CENTRAL_SCENE] = {
    [CentralScene.NOTIFICATION] = central_scene_handler
  }
}
if WindowCovering and cc.WINDOW_COVERING then
  zwave_handlers[cc.WINDOW_COVERING] = {
    [WindowCovering.REPORT] = window_covering_report_handler
  }
end

local fibaro_roller_shutter_4 = {
  NAME = "fibaro roller shutter 4 SD",
  can_handle = can_handle_fibaro_roller_shutter_4,
  zwave_handlers = zwave_handlers,
  capability_handlers = {
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = open_handler,
      [capabilities.windowShade.commands.close.NAME] = close_handler,
      [capabilities.windowShade.commands.pause.NAME] = pause_handler
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = set_level_handler
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = preset_handler
    }
  },
  lifecycle_handlers = {
    init = device_init,
    add = device_added -- kept as in Mariano's original
  }
}

-- used by the App child device subdriver
fibaro_roller_shutter_4.sd = {
  open = open_handler,
  close = close_handler,
  pause = pause_handler,
  set_level = set_level_handler,
  emit_child_level = emit_child_level,
  bind = bind
}

return fibaro_roller_shutter_4
