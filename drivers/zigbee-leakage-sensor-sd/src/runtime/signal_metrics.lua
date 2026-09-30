local capabilities = require "st.capabilities"
local signal_cap = capabilities["vehiclepatch55148.signalMetrics"]

local M = {}

function M.metrics(device, zb_rx)
  if not zb_rx or not zb_rx.lqi or not zb_rx.rssi then return end

  local lqi  = tonumber(zb_rx.lqi.value)
  local rssi = tonumber(zb_rx.rssi.value)

  if not lqi or not rssi then return end

  local text = string.format("LQI: %d | RSSI: %d dBm", lqi, rssi)
  device:emit_event(signal_cap.signalMetrics({ value = text }))
end

return M
