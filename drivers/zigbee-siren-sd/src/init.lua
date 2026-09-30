local ZigbeeDriver = require "st.zigbee"
local capabilities = require "st.capabilities"
local data_types = require "st.zigbee.data_types"
local clusters = require "st.zigbee.zcl.clusters"

local IASWD = clusters.IASWD
local OnOff = clusters.OnOff
local IASZone = clusters.IASZone
local Basic = clusters.Basic
local ColorControl = clusters.ColorControl

local SirenConfiguration = IASWD.types.SirenConfiguration
local WarningMode = IASWD.types.WarningMode
local Strobe = IASWD.types.Strobe
local IaswdLevel = IASWD.types.IaswdLevel

local signal = require "signal-metrics"
local signal_cap = capabilities["vehiclepatch55148.signalMetrics"]

---------------------------------------------------------
-- Duration helper
---------------------------------------------------------
local function get_duration(device)
  local prefs = device.preferences or {}
  local d = prefs.sirenDuration or 300
  if d < 1 then d = 1 end
  if d > 600 then d = 600 end
  return d
end

---------------------------------------------------------
-- IASWD siren control
---------------------------------------------------------
local function send_iaswd(device, mode)
  local duration = get_duration(device)
  local duty_cycle = 40
  local strobe_level = IaswdLevel.LOW_LEVEL
  local cfg = SirenConfiguration(0x00)

  if mode == "off" then
    cfg:set_warning_mode(WarningMode.STOP)
    cfg:set_strobe(Strobe.NO_STROBE)
    cfg:set_siren_level(IaswdLevel.LOW_LEVEL)
  elseif mode == "siren" then
    cfg:set_warning_mode(WarningMode.BURGLAR)
    cfg:set_strobe(Strobe.NO_STROBE)
    cfg:set_siren_level(IaswdLevel.LOW_LEVEL)
  elseif mode == "both" then
    cfg:set_warning_mode(WarningMode.BURGLAR)
    cfg:set_strobe(Strobe.NO_STROBE)
    cfg:set_siren_level(IaswdLevel.LOW_LEVEL)
  end

  device:send(
    IASWD.server.commands.StartWarning(
      device,
      cfg,
      data_types.Uint16(duration),
      data_types.Uint8(duty_cycle),
      data_types.Enum8(strobe_level)
    )
  )
end

---------------------------------------------------------
-- Capability handlers
---------------------------------------------------------
local function alarm_off(driver, device, cmd)
  send_iaswd(device, "off")
  device:send(OnOff.server.commands.Off(device))
  device:emit_event(capabilities.alarm.alarm.off())
  device:emit_event(capabilities.switch.switch.off())
end

local function alarm_siren(driver, device, cmd)
  send_iaswd(device, "siren")
  device:send(OnOff.server.commands.On(device))
  device:emit_event(capabilities.alarm.alarm.siren())
  device:emit_event(capabilities.switch.switch.on())
end

local function alarm_strobe(driver, device, cmd)
  device:send(OnOff.server.commands.On(device))
  send_iaswd(device, "off")
  device:emit_event(capabilities.alarm.alarm.strobe())
  device:emit_event(capabilities.switch.switch.on())
end

local function alarm_both(driver, device, cmd)
  device:send(OnOff.server.commands.On(device))
  send_iaswd(device, "both")
  device:emit_event(capabilities.alarm.alarm.both())
  device:emit_event(capabilities.switch.switch.on())
end

local function switch_on(driver, device, cmd)
  alarm_siren(driver, device, cmd)
end

local function switch_off(driver, device, cmd)
  alarm_off(driver, device, cmd)
end

---------------------------------------------------------
-- Metrics handler
---------------------------------------------------------
local function metrics_any(driver, device, zb_rx)
  signal.metrics(device, zb_rx)
end

---------------------------------------------------------
-- Duration preference handler
---------------------------------------------------------
local function info_changed(driver, device, event, args)
  local old = (args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}

  if old.sirenDuration ~= new.sirenDuration then
    local new_dur = get_duration(device)
    device.log.info(string.format(
      "Duration changed: old=%s new=%s (writing %d)",
      tostring(old.sirenDuration), tostring(new.sirenDuration), new_dur
    ))
    device:send(IASWD.attributes.MaxDuration:write(device, data_types.Uint16(new_dur)))
  end
end

---------------------------------------------------------
-- Driver template
---------------------------------------------------------
local driver_template = {
  health_check = false,

  supported_capabilities = {
    capabilities.alarm,
    capabilities.switch,
    capabilities.refresh,
    signal_cap,
  },

  lifecycle_handlers = {
    added = function(driver, device)
      device:emit_event(capabilities.switch.switch.off())
      device:emit_event(capabilities.alarm.alarm.off())
      device:emit_event(signal_cap.signalMetrics({ value = "Waiting for data..." }))
    end,

    infoChanged = info_changed,
  },

  capability_handlers = {
    [capabilities.alarm.ID] = {
      [capabilities.alarm.commands.off.NAME]    = alarm_off,
      [capabilities.alarm.commands.siren.NAME]  = alarm_siren,
      [capabilities.alarm.commands.strobe.NAME] = alarm_strobe,
      [capabilities.alarm.commands.both.NAME]   = alarm_both,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME]  = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = function(driver, device, cmd)
        device:send(OnOff.attributes.OnOff:read(device))
        device:send(IASWD.attributes.MaxDuration:read(device))
        device:send(Basic.attributes.ApplicationVersion:read(device))

        device:send(OnOff.server.commands.Off(device))
        device:send(OnOff.server.commands.On(device))
      end,
    },
  },

  zigbee_handlers = {
    attr = {
      [ColorControl.ID] = {
        [0xF000] = metrics_any,
        [0xE100] = metrics_any,
      },
      [IASWD.ID] = {
        [0x0000] = metrics_any,
        [0x0001] = metrics_any,
        [0x0002] = metrics_any,
        [0x0004] = metrics_any,
        [0x0005] = metrics_any,
        [0x0006] = metrics_any,
        [0xE000] = metrics_any,
      },
      [Basic.ID] = {
        [0x0007] = metrics_any,
      },
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = metrics_any,
      },
      [IASZone.ID] = {
        [IASZone.attributes.ZoneStatus.ID] = metrics_any,
      },
    },

    cluster = {
      [IASWD.ID] = { default = metrics_any, [0x0B] = metrics_any },
      [OnOff.ID] = { default = metrics_any, [0x0B] = metrics_any },
      [IASZone.ID] = { default = metrics_any, [0x00] = metrics_any },
      [ColorControl.ID] = { default = metrics_any },
      [Basic.ID] = { default = metrics_any },
    },
  },
}

local driver = ZigbeeDriver("zigbee_siren_sd_metrics_v2", driver_template)
driver:run()