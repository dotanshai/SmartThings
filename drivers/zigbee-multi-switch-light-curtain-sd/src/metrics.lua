local capabilities = require "st.capabilities"
local log          = require "log"

-- Custom capability for curtain profiles (signal component, Blind category)
local signalMetrics = capabilities["perfectworld33337.signalMetrics"]

local M = {}

-- Find the component that should receive signal strength events.
-- Priority: "signal" component (custom cap) > "main" > "sw1" > any other
function M.emit_metrics(device, zb_rx)
  local comp = nil

  -- First try: "signal" component with our custom capability
  local sig = device.profile.components["signal"]
  if sig and sig.capabilities and sig.capabilities["perfectworld33337.signalMetrics"] then
    comp = sig
    if zb_rx.lqi and zb_rx.lqi.value then
      device:emit_component_event(comp, signalMetrics.lqi(zb_rx.lqi.value))
    end
    if zb_rx.rssi and zb_rx.rssi.value then
      device:emit_component_event(comp, signalMetrics.rssi(zb_rx.rssi.value))
    end
    return
  end

  -- Fallback: standard signalStrength on "main" or "sw1"
  for _, id in ipairs({"main", "sw1"}) do
    local c = device.profile.components[id]
    if c and c.capabilities and c.capabilities["signalStrength"] then
      comp = c
      break
    end
  end
  -- Last resort: any component with signalStrength, skip Blind category
  if not comp then
    for _, c in pairs(device.profile.components) do
      if c.capabilities and c.capabilities["signalStrength"] then
        local cat = c.categories and c.categories[1] and c.categories[1].name
        if cat ~= "Blind" then
          comp = c
          break
        end
      end
    end
  end
  if not comp then return end

  if zb_rx.lqi and zb_rx.lqi.value then
    device:emit_component_event(comp, capabilities.signalStrength.lqi(zb_rx.lqi.value))
  end
  if zb_rx.rssi and zb_rx.rssi.value then
    device:emit_component_event(comp, capabilities.signalStrength.rssi(zb_rx.rssi.value))
  end
end

return M
