-- tuya_curtain_motor.lua : Tuya EF00 curtain motor (_TZE200_cxu0jkjk)
-- DP1 enum: 2=open 0=close 1=stop | DP2 value: set position (100-level) | DP3 value: position (0=open,100=closed)
local capabilities = require "st.capabilities"
local log          = require "log"
local messages     = require "st.zigbee.messages"
local zcl_messages = require "st.zigbee.zcl"
local data_types   = require "st.zigbee.data_types"
local generic_body = require "st.zigbee.generic_body"
local zb_const     = require "st.zigbee.constants"

local MODELS = { ["_TZE200_cxu0jkjk"] = true }
local CL = 0xEF00

local function send_dp(device, dp, dtype, val)
  local seq = ((device:get_field("tuya_seq") or 0) + 1) % 65536
  device:set_field("tuya_seq", seq)
  local v = (dtype == 0x04) and string.char(val) or string.pack(">I4", val)
  local payload = string.pack(">I2", seq) .. string.char(dp, dtype) .. string.pack(">I2", #v) .. v
  local header = zcl_messages.ZclHeader({ cmd = data_types.ZCLCommandId(0x00) })
  header.frame_ctrl:set_cluster_specific()
  header.frame_ctrl:set_disable_default_response()
  local addr = messages.AddressHeader(zb_const.HUB.ADDR, zb_const.HUB.ENDPOINT, device:get_short_address(), 0x01, zb_const.HA_PROFILE_ID, CL)
  local body = zcl_messages.ZclMessageBody({ zcl_header = header, zcl_body = generic_body.GenericBody(payload) })
  device:send(messages.ZigbeeMessageTx({ address_header = addr, body = body }))
  log.info(string.format("[CURTAIN] %s -> dp %d = %d", tostring(device.label), dp, val))
end

local function emit_level(device, lvl)
  lvl = math.max(0, math.min(100, lvl))
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(lvl))
  device:emit_event(capabilities.windowShade.windowShade(lvl >= 100 and "open" or (lvl <= 0 and "closed" or "partially open")))
end

local function rx(driver, device, zb_rx)
  local ok, err = pcall(function()
    local b = zb_rx.body and zb_rx.body.zcl_body and zb_rx.body.zcl_body.body_bytes
    if type(b) ~= "string" then return end
    local pos = 3
    while pos + 3 <= #b do
      local dp, t = b:byte(pos), b:byte(pos + 1)
      local len = b:byte(pos + 2) * 256 + b:byte(pos + 3)
      local raw = b:sub(pos + 4, pos + 3 + len)
      local val = 0
      for i = 1, #raw do val = val * 256 + raw:byte(i) end
      log.info(string.format("[CURTAIN] %s <- dp %d type %d = %d", tostring(device.label), dp, t, val))
      if dp == 3 then emit_level(device, 100 - val)
      elseif dp == 1 then
        if val == 2 then device:emit_event(capabilities.windowShade.windowShade("opening"))
        elseif val == 0 then device:emit_event(capabilities.windowShade.windowShade("closing")) end
      end
      pos = pos + 4 + len
    end
  end)
  if not ok then log.warn("[CURTAIN] rx error: " .. tostring(err)) end
end

local function init(driver, device)
  if not device:supports_capability_by_id("windowShade") then
    log.info("[CURTAIN] switching profile to tuya-curtain-motor-sd")
    device:try_update_metadata({ profile = "tuya-curtain-motor-sd" })
    return
  end
  device:emit_event(capabilities.windowShade.supportedWindowShadeCommands({ "open", "close", "pause" }, { visibility = { displayed = false } }))
end

local sub = {
  NAME = "Tuya curtain motor",
  can_handle = function(opts, driver, device, ...) return MODELS[device:get_manufacturer()] == true end,
  lifecycle_handlers = { init = init, added = init, driverSwitched = init, doConfigure = function() end, infoChanged = init },
  zigbee_handlers = { cluster = { [CL] = { [0x01] = rx, [0x02] = rx, [0x06] = rx } } },
  capability_handlers = {
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME]  = function(_, d) send_dp(d, 1, 0x04, 2) end,
      [capabilities.windowShade.commands.close.NAME] = function(_, d) send_dp(d, 1, 0x04, 0) end,
      [capabilities.windowShade.commands.pause.NAME] = function(_, d) send_dp(d, 1, 0x04, 1) end,
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = function(_, d, cmd) send_dp(d, 2, 0x02, 100 - math.floor(cmd.args.shadeLevel)) end,
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = function(_, d) send_dp(d, 2, 0x02, 50) end,
    },
    [capabilities.refresh.ID] = { [capabilities.refresh.commands.refresh.NAME] = function() end },
  },
}
return sub