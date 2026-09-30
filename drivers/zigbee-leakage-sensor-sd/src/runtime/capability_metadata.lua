local custom_capabilities = {}

custom_capabilities.enum = {
  {
    kind = "enum",
    emit_name = "battery_low",
    attribute_name = "batteryLow",
    argument_name = "batteryLow",
    command_name = "setBatteryLow",
    capability_id = "vehiclepatch55148.batteryLow",
    label = "Battery low",
    mapping_name = "battery_low",
    range_key = "battery_low",
    supported_values = { "normal", "low" },
    default_range = {},
  },
  {
    kind = "enum",
    emit_name = "mufflingWaterLeak",
    attribute_name = "mufflingWaterLeak",
    argument_name = "mufflingWaterLeak",
    command_name = "setMufflingWaterLeak",
    capability_id = "vehiclepatch55148.mufflingWaterLeak",
    label = "Muffling",
    mapping_name = "muffling",
    supported_values = { "off", "on" },
    default_range = {},
  },
  {
    kind = "enum",
    emit_name = "alarmVolumeHobeian",
    attribute_name = "alarmVolumeHobeian",
    argument_name = "alarmVolumeHobeian",
    command_name = "setAlarmVolumeHobeian",
    capability_id = "vehiclepatch55148.alarmVolumeHobeian",
    label = "Alarm Volume Hobeian",
    mapping_name = "alarm_volume",
    supported_values = { "low", "middle", "high", "mute" },
    default_range = {},
  },
  {
    kind = "enum",
    emit_name = "alarmRingHobeian",
    attribute_name = "alarmRingHobeian",
    argument_name = "alarmRingHobeian",
    command_name = "setAlarmRingHobeian",
    capability_id = "vehiclepatch55148.alarmRingHobeian",
    label = "Alarm Ring Hobeian",
    mapping_name = "alarm_ring",
    supported_values = { "mute", "beep", "music" },
    default_range = {},
  },
}

custom_capabilities.numeric = {
  {
    kind = "numeric",
    emit_name = "alarmDurationSiren",
    attribute_name = "alarmDurationSiren",
    argument_name = "alarmDurationSiren",
    command_name = "setAlarmDurationSiren",
    capability_id = "vehiclepatch55148.alarmDurationSiren",
    label = "Alarm Duration Siren",
    mapping_name = "duration",
    event_unit = "s",
    default_range = { minimum = 0, maximum = 1800, step = 1, unit = "s" },
  },
  {
    kind = "numeric",
    emit_name = "illuminanceSamplingMinutes",
    attribute_name = "illuminanceSamplingMinutes",
    argument_name = "illuminanceSamplingMinutes",
    command_name = "setIlluminanceSamplingMinutes",
    capability_id = "vehiclepatch55148.illuminanceSamplingMinutes",
    label = "Illuminance Sampling Minutes",
    mapping_name = "illuminance_sampling",
    event_unit = "min",
    default_range = { minimum = 1, maximum = 480, step = 1, unit = "min" },
  },
  {
    kind = "numeric",
    emit_name = "leakSensitivity",
    attribute_name = "leakSensitivity",
    argument_name = "leakSensitivity",
    command_name = "setLeakSensitivity",
    capability_id = "vehiclepatch55148.leakSensitivity",
    label = "Leak Sensitivity",
    mapping_name = "zg223z_sensitivity",
    default_range = { minimum = 0, maximum = 9, step = 1 },
  },
}

custom_capabilities.text = {}

custom_capabilities.driver_message = {
  attribute_name = "driverMessage",
  capability_id = "vehiclepatch55148.driverMessage",
  emit_name = "driver_message",
  label = "Driver message",
  maximum_length = 512,
}

custom_capabilities.by_range_key = {}
custom_capabilities.by_emit_name = {}
custom_capabilities.by_capability_id = {}

local function index_metadata(definitions)
  for _, metadata in ipairs(definitions) do
    custom_capabilities.by_emit_name[metadata.emit_name] = metadata
    if type(metadata.capability_id) == "string" and metadata.capability_id ~= "" then
      custom_capabilities.by_capability_id[metadata.capability_id] = metadata
    end
    if type(metadata.range_key) == "string" and metadata.range_key ~= "" then
      custom_capabilities.by_range_key[metadata.range_key] = metadata
    end
  end
end

index_metadata(custom_capabilities.numeric)
index_metadata(custom_capabilities.enum)
index_metadata(custom_capabilities.text)
custom_capabilities.by_emit_name[custom_capabilities.driver_message.emit_name] = custom_capabilities.driver_message
custom_capabilities.by_capability_id[custom_capabilities.driver_message.capability_id] = custom_capabilities.driver_message

local function clone_allowed_values(allowed_values)
  if type(allowed_values) ~= "table" then return nil end
  local copied = {}
  for index, value in ipairs(allowed_values) do
    copied[index] = value
  end
  return copied
end

function custom_capabilities.resolve_range(definition, metadata)
  if type(metadata) ~= "table" then return nil end
  local default_range = type(metadata.default_range) == "table" and metadata.default_range or nil
  local ranges = type(definition) == "table" and definition.presence_capability_ranges or nil
  local resolved = type(ranges) == "table" and ranges[metadata.range_key] or nil
  if type(resolved) ~= "table" then resolved = default_range end
  if type(resolved) ~= "table" then return nil end
  return {
    minimum = type(resolved.minimum) == "number" and resolved.minimum or (default_range and default_range.minimum or nil),
    maximum = type(resolved.maximum) == "number" and resolved.maximum or (default_range and default_range.maximum or nil),
    step = type(resolved.step) == "number" and resolved.step or (default_range and default_range.step or nil),
    unit = type(resolved.unit) == "string" and resolved.unit or (default_range and default_range.unit or nil),
    allowed_values = type(resolved.allowed_values) == "table" and clone_allowed_values(resolved.allowed_values)
      or clone_allowed_values(default_range and default_range.allowed_values or nil),
  }
end

return custom_capabilities
