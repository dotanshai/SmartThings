local tuya = require "protocol.tuya"
local emit = require "capabilities.events.all"
local device_helpers = require "contracts.helpers.family"
local converter = tuya.converter

local device_definitions, register_device_definition = device_helpers.definition_registry()

-- HOBEIAN ZG-226Z: water leak + alarm siren
-- Volume/ring/duration/muffling are now Settings preferences (see app/driver.lua
-- infoChanged), not live capabilities - written directly via tuya.send_datapoint,
-- not through this declarative dp list.
local water_leak_alarm_zg226z = {
  profile = "safety-water-leak-alarm-battery-zg226z",
  tuya.dp_water_leak(1, { emit = emit.water(), converter = converter.true_false0() }),
  tuya.dp_on_off(101, { name = "alarm", emit = emit.alarm() }),
  tuya.dp_battery(4, { emit = emit.battery() }),
}

register_device_definition(water_leak_alarm_zg226z, {
  device_helpers.create_fingerprint("HOBEIAN", "ZG-226Z"),
})

-- HOBEIAN ZG-223Z: water leak + illuminance + battery
local water_illum_battery_model_zg_223z = {
  profile = "safety-water-leak-illuminance-battery-zg223z",
  tuya.dp_enum(1, {
    name = "rainwater",
    emit = emit.water(),
    converter = converter.from_only(converter.lookup_value({
      [0] = false,
      [1] = true,
    })),
  }),
  tuya.dp_numeric(2, {
    name = "sensitivity",
    emit = emit.leakSensitivity(),
  }),
  tuya.dp_numeric(101, { name = "illuminance_sampling", emit = emit.illuminanceSamplingMinutes() }),
  tuya.dp_illuminance(102, { emit = emit.illuminance() }),
  tuya.dp_battery(104, { emit = emit.battery() }),
}

register_device_definition(water_illum_battery_model_zg_223z, device_helpers.create_fingerprints("TS0601", {
  "_TZE200_jsaqgakf",
  "_TZE200_u6x1zyv2",
  "_TZE200_2pddnnrk",
}))

register_device_definition(water_illum_battery_model_zg_223z, {
  device_helpers.create_fingerprint("HOBEIAN", "ZG-223Z"),
})

return {
  id = "ef00.safety",
  registrations = device_definitions,
}
