local capabilities = require "st.capabilities"
local log          = require "log"

local M = {}

-- Emit signal strength metrics once per Zigbee message, always on "sw1"
-- (the component that has signalStrength capability). Falls back to "main".
function M.emit_metrics(device, zb_rx)
  local comp = device.profile.components["sw1"]
              or device.profile.components["main"]
  if not comp then return end

  if zb_rx.lqi and zb_rx.lqi.value then
    device:emit_component_event(comp, capabilities.signalStrength.lqi(zb_rx.lqi.value))
  end
  if zb_rx.rssi and zb_rx.rssi.value then
    device:emit_component_event(comp, capabilities.signalStrength.rssi(zb_rx.rssi.value))
  end
end

return M
