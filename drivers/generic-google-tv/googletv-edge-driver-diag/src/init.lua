local Driver = require('st.driver')
local capabilities = require('st.capabilities')
local log = require('log')

local function discovery_handler(driver, opts, cons)
  log.info('[googletv-diag] discovery_handler called')
  local existing = driver:get_devices()
  log.info('[googletv-diag] existing device count: ' .. tostring(#existing))
  if #existing > 0 then
    return
  end
  local id = 'googletv-diag-' .. tostring(math.random(100000, 999999))
  local metadata = {
    type = 'LAN',
    device_network_id = id,
    label = 'Google TV (diag)',
    profile = 'googletv.v1',
    manufacturer = 'Generic',
    model = 'Google TV',
    vendor_provided_label = 'Google TV',
  }
  local ok, err = driver:try_create_device(metadata)
  log.info('[googletv-diag] try_create_device returned ok=' .. tostring(ok) .. ' err=' .. tostring(err))
end

local function device_added(driver, device)
  log.info('[googletv-diag] device_added called')
  device:emit_event(capabilities.switch.switch.off())
end

log.info('[googletv-diag] driver file loaded, constructing Driver object')

local driver = Driver('googletv', {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = device_added,
  },
  capability_handlers = {},
})

log.info('[googletv-diag] Driver object constructed, calling run()')

driver:run()
