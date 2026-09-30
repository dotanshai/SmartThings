local zigbee_driver = require "st.zigbee"
local capabilities  = require "st.capabilities"
local tuya_multi    = require "tuya_multi_switch"

local driver_template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.refresh,
    capabilities.healthCheck,
    capabilities.signalStrength,
  },

  health_check = false,  -- opt out of deprecated monitored-attributes health check

  lifecycle_handlers = tuya_multi.lifecycle_handlers,
  capability_handlers = tuya_multi.capability_handlers,
  zigbee_handlers = tuya_multi.zigbee_handlers,
}

local driver = zigbee_driver("zigbee_multi_switch_child_sd", driver_template)
driver:run()