-- signal_sd.lua : publish LQI / RSSI of every incoming Zigbee message as signalStrength (throttled)
local log = require "log"
local capabilities = require "st.capabilities"
local M = {}

local function record(device, rx)
  if not (device and rx and rx.lqi and rx.rssi) then return end
  if not device:supports_capability_by_id("signalStrength") then return end
  local lqi, rssi = rx.lqi.value, rx.rssi.value
  if type(lqi) ~= "number" or type(rssi) ~= "number" then return end
  local now = os.time()
  if lqi == device:get_field("sig_lqi") and rssi == device:get_field("sig_rssi") and now - (device:get_field("sig_last") or 0) < 300 then return end
  device:set_field("sig_last", now); device:set_field("sig_lqi", lqi); device:set_field("sig_rssi", rssi)
  device:emit_event(capabilities.signalStrength.lqi({ value = lqi }, { visibility = { displayed = false } }))
  device:emit_event(capabilities.signalStrength.rssi({ value = rssi, unit = "dBm" }, { visibility = { displayed = false } }))
end

function M.wrap(driver)
  local disp = driver.zigbee_message_dispatcher
  if disp and type(disp.dispatch) == "function" then
    local orig = disp.dispatch
    disp.dispatch = function(self, drv, device, rx, ...)
      pcall(record, device, rx)
      return orig(self, drv, device, rx, ...)
    end
    log.info("[SIG] signal hook installed (dispatcher)")
  elseif type(driver.zigbee_message_handler) == "function" then
    local orig = driver.zigbee_message_handler
    driver.zigbee_message_handler = function(drv, device, rx, ...)
      pcall(record, device, rx)
      return orig(drv, device, rx, ...)
    end
    log.info("[SIG] signal hook installed (handler)")
  else
    log.warn("[SIG] could not install signal hook")
  end
end

return M