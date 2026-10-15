-- App device for the Fibaro FGR-224 (SD).
-- A driver-owned LAN device (dni "fgr224-app-<blind id>"): always online,
-- full slider + open/close/pause, forwards every command to the real blind (with the SD retries).

local capabilities = require "st.capabilities"
local st_device = require "st.device"
local log = require "log"

local function can_handle_app_child(opts, driver, device, ...)
  return device.network_type == st_device.NETWORK_TYPE_CHILD or device.network_type == "DEVICE_LAN"
end

local DNI_PREFIX = "fgr224-app-"

-- LAN App device -> its blind (id is in the network id); old EDGE_CHILD -> its parent
local function get_blind(driver, device)
  local dni = device.device_network_id or ""
  if dni:sub(1, #DNI_PREFIX) == DNI_PREFIX then
    return driver:get_device_info(dni:sub(#DNI_PREFIX + 1))
  end
  if device.get_parent_device then return device:get_parent_device() end
  return nil
end

local function frs4()
  return require("window-treatment-venetian/fibaro-roller-shutter-4").sd
end

local function forward(driver, device, fn_name, args)
  device:online()
  local parent = get_blind(driver, device)
  if parent == nil then
    log.error("[SD-App] parent blind not found")
    return
  end
  frs4().bind(driver, parent, device)
  log.info("[SD-App] forwarding " .. fn_name .. " to " .. tostring(parent.label))
  frs4()[fn_name](driver, parent, {component = "main", args = args or {}})
end

local function open_handler(driver, device, command)
  forward(driver, device, "open")
end

local function close_handler(driver, device, command)
  forward(driver, device, "close")
end

local function pause_handler(driver, device, command)
  forward(driver, device, "pause")
end

local function set_level_handler(driver, device, command)
  local level = math.max(math.min(command.args.shadeLevel, 100), 0)
  forward(driver, device, "set_level", {shadeLevel = level})
end

local function child_init(driver, device)
  device:emit_event(capabilities.windowShade.supportedWindowShadeCommands({"open", "close", "pause"}))
  device:online()
  local parent = get_blind(driver, device)
  local level = 0
  if parent then
    frs4().bind(driver, parent, device)
    level = parent:get_latest_state("main", capabilities.windowShadeLevel.ID,
      capabilities.windowShadeLevel.shadeLevel.NAME) or 0
  end
  -- always give the App device a level, so the app shows the slider
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
  if level >= 100 then
    device:emit_event(capabilities.windowShade.windowShade.open())
  elseif level <= 0 then
    device:emit_event(capabilities.windowShade.windowShade.closed())
  else
    device:emit_event(capabilities.windowShade.windowShade.partially_open())
  end
  log.info("[SD-App] child init - online")
end

local function noop() end

local app_child = {
  NAME = "FGR-224 App child (SD)",
  can_handle = can_handle_app_child,
  capability_handlers = {
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = open_handler,
      [capabilities.windowShade.commands.close.NAME] = close_handler,
      [capabilities.windowShade.commands.pause.NAME] = pause_handler
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = set_level_handler
    }
  },
  lifecycle_handlers = {
    init = child_init,
    added = child_init,
    infoChanged = noop,
    doConfigure = noop
  }
}

return app_child
