-- timers.lua
-- Manages per-device recurring poll timers.

local log   = require("log")
local timer = require("st.utils") -- cosock timer via driver

local M = {}

-- timer handle storage: device_id -> timer handle
local _timers = {}

function M.start_poll(driver, device, poll_fn)
  M.stop_poll(device)

  local prefs = require("prefs")
  local p = prefs.get(device)
  local interval = p.pollInterval

  log.info(string.format("[Dolphin Timers] Starting poll every %ds for %s", interval, device.label))

  _timers[device.id] = driver:call_on_schedule(interval, function()
    poll_fn(driver, device)
  end, "dolphin_poll_" .. device.id)
end

function M.stop_poll(device)
  if _timers[device.id] then
    _timers[device.id]:cancel()
    _timers[device.id] = nil
    log.info("[Dolphin Timers] Stopped poll for " .. device.label)
  end
end

return M
