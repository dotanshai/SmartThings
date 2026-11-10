-- lumi_relay.lua : Aqara 0xFF01 (Basic cluster) combined report -> temperature / energy / voltage / current / power
local log = require "log"
local capabilities = require "st.capabilities"
local M = {}
local SIZES = { [0x10]=1,[0x18]=1,[0x20]=1,[0x21]=2,[0x22]=3,[0x23]=4,[0x24]=5,[0x25]=6,[0x26]=7,[0x27]=8,[0x28]=1,[0x29]=2,[0x2A]=3,[0x2B]=4,[0x39]=4,[0x3A]=8 }

local function read(s, pos, t)
  if t == 0x39 then return (string.unpack("<f", s, pos)) end
  if t == 0x3A then return (string.unpack("<d", s, pos)) end
  local n = SIZES[t]
  if t >= 0x28 and t <= 0x2F then return (string.unpack("<i" .. n, s, pos)) end
  return (string.unpack("<I" .. n, s, pos))
end

local function parse(s)
  local out, pos = {}, 1
  while pos + 1 <= #s do
    local tag, t = s:byte(pos), s:byte(pos + 1)
    local n = SIZES[t]
    if not n or pos + 1 + n > #s then break end
    out[tag] = read(s, pos + 2, t)
    pos = pos + 2 + n
  end
  return out
end

local function emit(device, cap, ev)
  if device:supports_capability(cap) then device:emit_event(ev) end
end

local function ff01(driver, device, value, zb_rx)
  local ok, err = pcall(function()
    local s = value and value.value
    if type(s) ~= "string" then return end
    local v = parse(s)
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = string.format("0x%02X=%s", k, tostring(x)) end
    log.info("[LUMI] " .. tostring(device.label) .. " FF01 " .. table.concat(parts, " "))
    if v[0x03] then emit(device, capabilities.temperatureMeasurement, capabilities.temperatureMeasurement.temperature({ value = v[0x03], unit = "C" })) end
    if v[0x95] then emit(device, capabilities.energyMeter, capabilities.energyMeter.energy({ value = math.floor(v[0x95] * 1000 + 0.5) / 1000, unit = "kWh" })) end
    if v[0x96] then device:set_field("lumi_v", v[0x96] / 10, { persist = true }) end
    if v[0x96] then emit(device, capabilities.voltageMeasurement, capabilities.voltageMeasurement.voltage({ value = math.floor(v[0x96] + 0.5) / 10, unit = "V" })) end
    if v[0x97] then emit(device, capabilities.currentMeasurement, capabilities.currentMeasurement.current({ value = math.floor(v[0x97] * 10000 + 0.5) / 10000, unit = "A" })) end
    if v[0x98] then emit(device, capabilities.powerMeter, capabilities.powerMeter.power({ value = math.floor(v[0x98] * 100 + 0.5) / 100, unit = "W" })) end
  end)
  if not ok then log.warn("[LUMI] FF01 parse error: " .. tostring(err)) end
end

-- live power: Analog Input cluster 0x000C, PresentValue 0x0055 (W); current derived from last voltage
local function analog(driver, device, value, zb_rx)
  local ok, err = pcall(function()
    local w = value and value.value
    if type(w) ~= "number" then return end
    w = math.floor(w * 100 + 0.5) / 100
    emit(device, capabilities.powerMeter, capabilities.powerMeter.power({ value = w, unit = "W" }))
    local v = device:get_field("lumi_v") or 230
    if v and v > 50 then
      emit(device, capabilities.currentMeasurement, capabilities.currentMeasurement.current({ value = math.floor(w / v * 10000 + 0.5) / 10000, unit = "A" }))
    end
    log.info(string.format("[LUMI] %s live power %.2f W", tostring(device.label), w))
  end)
  if not ok then log.warn("[LUMI] analog error: " .. tostring(err)) end
end

-- c2acn01: main = BOTH channels (dashboard / SharpTools tile), switch2 = channel 2 only
local SUB_MODEL = "lumi.relay.c2acn01"
local function lr_onoff_attr(driver, device, value, zb_rx)
  local ok, err = pcall(function()
    local ep = zb_rx.address_header.src_endpoint.value
    local comp = device:get_component_id_for_endpoint(ep)
    local on = value.value == true
    device:set_field("lr_" .. comp, on, { persist = true })
    local function ev(x) return x and capabilities.switch.switch.on() or capabilities.switch.switch.off() end
    if comp ~= "main" and device.profile.components[comp] then
      device:emit_component_event(device.profile.components[comp], ev(on))
      local ch = device:get_child_by_parent_assigned_key(comp)
      if ch then ch:emit_event(ev(on)) end
    end
    local a, b = device:get_field("lr_main") == true, device:get_field("lr_switch2") == true
    local tmr = device:get_field("lr_timer")
    if tmr then pcall(function() device.thread:cancel_timer(tmr) end) end
    device:set_field("lr_timer", device.thread:call_with_delay(1.5, function()
      local m = (device:get_field("lr_main") == true) or (device:get_field("lr_switch2") == true)
      device:emit_component_event(device.profile.components.main, ev(m))
      log.info("[LUMI] " .. tostring(device.label) .. " main settled " .. (m and "on" or "off"))
    end))
    local all = capabilities["legendabsolute60149.switchAllOnOff1"]
    if all and device:supports_capability(all) and a == b then device:emit_event(all.switchAllOnOff(a and "All On" or "All Off")) end
    local mc = device:get_child_by_parent_assigned_key("main")
    if mc then mc:emit_event(ev(a)) end
    log.info(string.format("[LUMI] %s ep%d %s -> ch1=%s ch2=%s main=%s", tostring(device.label), ep, on and "on" or "off", tostring(a), tostring(b), tostring(a or b)))
  end)
  if not ok then log.warn("[LUMI] onoff error: " .. tostring(err)) end
end
local function lr_switch(turn_on)
  return function(driver, device, cmd)
    local OnOff = (require "st.zigbee.zcl.clusters").OnOff
    local c = turn_on and OnOff.server.commands.On or OnOff.server.commands.Off
    local dev, comps = device, nil
    if device.network_type == "DEVICE_EDGE_CHILD" then dev = device:get_parent_device(); comps = { device.parent_assigned_child_key } else comps = cmd.component == "main" and { "main", "switch2" } or { cmd.component } end
    for _, comp in ipairs(comps) do
      dev:send(c(dev):to_endpoint(dev:get_endpoint_for_component_id(comp)))
    end
    log.info(string.format("[LUMI] %s %s %s", tostring(device.label), turn_on and "ON" or "OFF", table.concat(comps, "+")))
  end
end
local SUB = {
  NAME = "Aqara relay c2acn01 (main = all)",
  can_handle = function(opts, driver, device, ...)
    local ok, r = pcall(function() if device.network_type == "DEVICE_EDGE_CHILD" then local p = device:get_parent_device() return p ~= nil and p:get_model() == SUB_MODEL end return device:get_model() == SUB_MODEL end)
    return ok and r == true
  end,
  zigbee_handlers = { attr = { [0x0006] = { [0x0000] = lr_onoff_attr } } },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME]  = lr_switch(true),
      [capabilities.switch.commands.off.NAME] = lr_switch(false),
    },
  },
}

function M.add_handlers(template)
  template.sub_drivers = template.sub_drivers or {}
  table.insert(template.sub_drivers, 1, SUB)
  template.zigbee_handlers = template.zigbee_handlers or {}
  template.zigbee_handlers.attr = template.zigbee_handlers.attr or {}
  template.zigbee_handlers.attr[0x0000] = template.zigbee_handlers.attr[0x0000] or {}
  template.zigbee_handlers.attr[0x0000][0xFF01] = ff01
  template.zigbee_handlers.attr[0x000C] = template.zigbee_handlers.attr[0x000C] or {}
  template.zigbee_handlers.attr[0x000C][0x0055] = analog
end

return M