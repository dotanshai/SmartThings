local zigbee_driver = require "st.zigbee"
local capabilities  = require "st.capabilities"
local tuya_multi    = require "tuya_multi_switch"
local tuya_12gang   = require "tuya_12gang"
local tuya_8gang_din = require "tuya_8gang_din"

local driver_template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.windowShade,
    capabilities.button,
    capabilities.refresh,
    capabilities.healthCheck,
    capabilities.signalStrength,
    capabilities["perfectworld33337.signalMetrics"],
  },

  health_check = false,  -- opt out of deprecated monitored-attributes health check

  lifecycle_handlers = tuya_multi.lifecycle_handlers,
  capability_handlers = tuya_multi.capability_handlers,
  zigbee_handlers = tuya_multi.zigbee_handlers,

  sub_drivers = { tuya_12gang, tuya_8gang_din },  -- 12-gang panel + 8-gang DIN (own DP maps)
}

local driver = zigbee_driver("zigbee_multi_switch_child_sd", driver_template)
driver:run()