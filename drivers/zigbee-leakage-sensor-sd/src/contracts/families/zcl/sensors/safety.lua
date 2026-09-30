local zcl = require "protocol.zcl"
local device_helpers = require "contracts.helpers.family"

local device_definitions, register_device_definition = device_helpers.definition_registry()

local water_battery_low_battery_sensor = {
  profile = "safety-water-leak-battery-low-battery",
  zcl_clusters = {
    zcl.water(),
    zcl.battery_low(),
    zcl.battery(),
  },
}

local water_tamper_battery_low_battery_sensor = {
  profile = "safety-water-leak-tamper-battery-low-battery",
  zcl_clusters = {
    zcl.water(),
    zcl.tamper(),
    zcl.battery_low(),
    zcl.battery(),
  },
}

local water_temp_battery_low_battery_sensor = {
  profile = "safety-water-leak-temp-battery-low-battery",
  zcl_clusters = {
    zcl.water(),
    zcl.temperature(),
    zcl.battery_low(),
    zcl.battery(),
  },
}

-- TS0207 family (tamper-capable variants)
register_device_definition(water_tamper_battery_low_battery_sensor, device_helpers.create_fingerprints("TS0207", {
  "_TZ3000_kyb656no",
  "_TZ3000_abaplimj",
  "_TZ3000_mqiev3jk",
  "_TZ3000_ocjlo4ea",
  "_TYZB01_sqmd19i1",
  "_TZ3000_t6jriawg",
  "_TZ3000_awvmkayh",
  "_TZ3000_0s9gukzt",
  "_TZ3000_c8bqthpo",
  "_TZ3000_eit7p838",
}))

-- TS0207 family (no tamper sensor)
register_device_definition(water_battery_low_battery_sensor, device_helpers.create_fingerprints("TS0207", {
  "_TZ3000_kstbkt6a",
  "_TZ3000_k4ej3ww2",
  "_TZ3000_upgcbody",
  "_TYZB01_ttvdudvx",
  "_TZ3000_mugyhz0q",
}))

-- AOYAN AY222Z
register_device_definition(water_tamper_battery_low_battery_sensor, {
  device_helpers.create_fingerprint("AOYAN", "AY222Z"),
  { manufacturer = "AOYAN  ", model = "AY222Z" },
})

-- HEIMAN water sensors
register_device_definition(water_tamper_battery_low_battery_sensor, {
  device_helpers.create_fingerprint("HEIMAN", "WaterSensor-N"),
  device_helpers.create_fingerprint("HEIMAN", "WaterSensor-EM"),
  device_helpers.create_fingerprint("HEIMAN", "WaterSensor-N-3.0"),
  device_helpers.create_fingerprint("HEIMAN", "WaterSensor-EF-3.0"),
  device_helpers.create_fingerprint("HEIMAN", "WATER_TPV13"),
  device_helpers.create_fingerprint("HEIMAN", "TY0207"),
})

register_device_definition(water_temp_battery_low_battery_sensor, {
  device_helpers.create_fingerprint("HEIMAN", "WaterSensor2-EF-3.0"),
})

-- HOBEIAN ZG-222Z (added by Shai D. - not yet in upstream wonjj6768 repo as of 2026-09)
register_device_definition(water_tamper_battery_low_battery_sensor, {
  device_helpers.create_fingerprint("HOBEIAN", "ZG-222Z"),
})

return {
  id = "zcl.sensors",
  registrations = device_definitions,
}
