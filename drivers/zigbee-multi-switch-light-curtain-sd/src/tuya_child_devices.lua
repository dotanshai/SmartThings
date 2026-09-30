local log    = require "log"
local dp_map = require "tuya_dp_map"

local M = {}

local function col_is_curtain(device, col)
  return device:get_field(dp_map.DT_FIELD[col.dt]) == 1
end

local function light_key(gang, multi_tile)
  return multi_tile and ("main" .. string.format("%02d", gang)) or ("switch" .. gang)
end

local function create_one(driver, device, key, label, profile)
  if device:get_child_by_parent_assigned_key(key) then
    log.info("create_children: child " .. key .. " already exists, skipping")
    return
  end
  log.info("create_children: creating child " .. key .. " (" .. profile .. ")")
  driver:try_create_device({
    type                      = "EDGE_CHILD",
    parent_device_id          = device.id,
    parent_assigned_child_key = key,
    label                     = device.label .. " - " .. label,
    profile                   = profile,
  })
end

-- Create child devices, column-aware (4-gang and 6-gang via dp_map.COLUMNS).
--   curtain column -> one child-curtain, key = curtain1/2/3
--   light column   -> one child-switch per gang, key = switchN or mainNN
-- Gangs not covered by a column table (1/2/3-gang) are all lights.
function M.create_children(driver, device, gang_count, multi_tile)
  log.info("create_children: gang_count=" .. tostring(gang_count) .. " multi=" .. tostring(multi_tile))
  local covered = {}
  for _, col in ipairs(dp_map.COLUMNS[gang_count] or {}) do
    covered[col.up], covered[col.dn] = true, true
    if col_is_curtain(device, col) then
      create_one(driver, device, col.comp, "Curtain (" .. col.label .. ")", "child-curtain")
    else
      for _, g in ipairs({ col.up, col.dn }) do
        create_one(driver, device, light_key(g, multi_tile), "Switch " .. g, "child-switch")
      end
    end
  end
  for g = 1, gang_count do
    if not covered[g] then
      create_one(driver, device, light_key(g, multi_tile), "Switch " .. g, "child-switch")
    end
  end
end

-- Delete all children (every key format, so cleanup works after mode changes)
function M.delete_children(driver, device, gang_count)
  log.info("delete_children: gang_count=" .. tostring(gang_count))
  local keys = { "curtain1", "curtain2", "curtain3" }
  for i = 1, gang_count do
    keys[#keys + 1] = "switch" .. i
    keys[#keys + 1] = "main" .. string.format("%02d", i)
  end
  for _, key in ipairs(keys) do
    local child = device:get_child_by_parent_assigned_key(key)
    if child then driver:try_delete_device(child.id) end
  end
end

return M
