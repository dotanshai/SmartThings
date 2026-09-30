-- prefs.lua
-- Reads driver preferences from the device.

local M = {}

function M.get(device)
  local p = device.preferences or {}
  return {
    email      = p.dolphinEmail    or "",
    password   = p.dolphinPassword or "",
    deviceName = p.deviceName      or "",
    pollInterval = tonumber(p.pollInterval) or 30,
  }
end

return M
