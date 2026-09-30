local log = require "log"

local M = {}

-- Create child switch devices.
-- In single-tile mode, keys are "switch1".."switchN".
-- In multi-tile mode, keys are "main01".."mainNN".
function M.create_children(driver, device, gang_count, multi_tile)
  log.info("create_children: gang_count=" .. tostring(gang_count) .. " multi=" .. tostring(multi_tile))
  for i = 1, gang_count do
    local key
    if multi_tile then
      key = "main" .. string.format("%02d", i)
    else
      key = "switch" .. i
    end
    if not device:get_child_by_parent_assigned_key(key) then
      log.info("create_children: creating child " .. key)
      driver:try_create_device({
        type                      = "EDGE_CHILD",
        parent_device_id          = device.id,
        parent_assigned_child_key = key,
        label                     = device.label .. " - Switch " .. i,
        profile                   = "child-switch",
      })
    else
      log.info("create_children: child " .. key .. " already exists, skipping")
    end
  end
end

-- Delete child switch devices (tries both key formats so cleanup works
-- even if the user toggled multiTile before deleting children).
function M.delete_children(driver, device, gang_count)
  log.info("delete_children: gang_count=" .. tostring(gang_count))
  for i = 1, gang_count do
    for _, key in ipairs({ "switch" .. i, "main" .. string.format("%02d", i) }) do
      local child = device:get_child_by_parent_assigned_key(key)
      if child then
        driver:try_delete_device(child.device_network_id)
      end
    end
  end
end

return M
