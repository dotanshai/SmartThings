local capabilities  = require "st.capabilities"
local log           = require "log"
local zb_messages   = require "st.zigbee.messages"
local zcl_messages  = require "st.zigbee.zcl"
local zb_const      = require "st.zigbee.constants"
local data_types    = require "st.zigbee.data_types"
local generic_body  = require "st.zigbee.generic_body"

local dp_map        = require "tuya_dp_map"
local metrics       = require "metrics"
local child_utils   = require "tuya_child_devices"

local TUYA_CLUSTER_ID  = 0xEF00
local TUYA_CMD_SEND   = 0x00
local TUYA_CMD_REPORT = 0x01
local TUYA_CMD_RESP   = 0x02
local TUYA_CMD_QUERY  = 0x04   -- request device to report a specific DP
local TUYA_CMD_SCENE  = 0x03   -- scene/status request: triggers device to dump ALL current DP values
local SEQ = 0

-- DP numbers (kept local for readability; canonical source is dp_map)
local DP_SW1  = dp_map.DP_SWITCH_1
local DP_SW2  = dp_map.DP_SWITCH_2
local DP_SW3  = dp_map.DP_SWITCH_3
local DP_SW4  = dp_map.DP_SWITCH_4
local DP_SW5  = dp_map.DP_SWITCH_5
local DP_SW6  = dp_map.DP_SWITCH_6
local DP_MAST = dp_map.DP_MASTER
local DP_BL   = dp_map.DP_BACKLIGHT
local DP_CL   = dp_map.DP_CHILD_LOCK

local DP_DT1  = dp_map.DP_DEVICE_TYPE_1
local DP_DT2  = dp_map.DP_DEVICE_TYPE_2
local DP_DT3  = dp_map.DP_DEVICE_TYPE_3

local DP_CURTAIN_1 = dp_map.DP_CURTAIN_1
local DP_CURTAIN_2 = dp_map.DP_CURTAIN_2
local DP_CURTAIN_3 = dp_map.DP_CURTAIN_3

-- windowShade state from curtain DP value
local CURTAIN_VAL_TO_SHADE = {
  [dp_map.CURTAIN_CMD_STOP]        = "partially open",
  [dp_map.CURTAIN_CMD_OPEN]        = "opening",
  [dp_map.CURTAIN_CMD_CLOSE]       = "closing",
  [dp_map.CURTAIN_CMD_OPEN_TIMED]  = "opening",
  [dp_map.CURTAIN_CMD_CLOSE_TIMED] = "closing",
}

---------------------------------------------------------------------
-- DEVICE TYPE HELPERS
---------------------------------------------------------------------

local DT_FIELD = dp_map.DT_FIELD

local DT_COMP = {
  [DP_DT1] = "channeltype1",
  [DP_DT2] = "channeltype2",
  [DP_DT3] = "channeltype3",
}

local MFR_TO_GANG_COUNT = {
  ["_TZE200_b0ihkhxh"] = 1, ["_TZE284_b0ihkhxh"] = 1,
  ["_TZE200_htj3hcpl"] = 2, ["_TZE284_htj3hcpl"] = 2,
  ["_TZE200_7trei0di"] = 2, ["_TZE284_7trei0di"] = 2,
  ["_TZE200_5apf3k9b"] = 2, ["_TZE284_5apf3k9b"] = 2,
  ["_TZE200_pcg0rykt"] = 3, ["_TZE284_pcg0rykt"] = 3,
  ["_TZE200_7a5ob7xq"] = 4, ["_TZE284_7a5ob7xq"] = 4,
  ["_TZE200_xo3vpoah"] = 6, ["_TZE284_xo3vpoah"] = 6,
}

local function get_gang_count(device)
  local mfr   = device:get_manufacturer()
  local count = mfr and MFR_TO_GANG_COUNT[mfr] or 2
  log.info("get_gang_count: mfr=" .. tostring(mfr) .. " -> " .. count)
  return count
end

-- Quiet version (no log line) for hot paths like the zigbee handler
local function gang_count_of(device)
  local mfr = device:get_manufacturer()
  return mfr and MFR_TO_GANG_COUNT[mfr] or 2
end

---------------------------------------------------------------------
-- COLUMN HELPERS (4-gang: left/right, 6-gang: left/middle/right)
---------------------------------------------------------------------
local function get_columns(device)
  return dp_map.COLUMNS[gang_count_of(device)] or {}
end

local function col_is_curtain(device, col)
  return col ~= nil and device:get_field(DT_FIELD[col.dt]) == 1
end

-- Returns column, is_up for a switch DP (nil if DP not in a column)
local function col_for_dp(device, dp)
  for _, col in ipairs(get_columns(device)) do
    if dp == col.up then return col, true  end
    if dp == col.dn then return col, false end
  end
  return nil
end

-- Returns the column whose curtain component / child key is comp_id
local function col_by_comp(device, comp_id)
  for _, col in ipairs(get_columns(device)) do
    if col.comp == comp_id then return col end
  end
  return nil
end

local function any_curtain(device)
  for _, col in ipairs(get_columns(device)) do
    if col_is_curtain(device, col) then return true end
  end
  return false
end

-- True when a switch DP drives a curtain relay (must never be used as a light)
local function dp_is_curtain_relay(device, dp)
  local col = col_for_dp(device, dp)
  return col_is_curtain(device, col)
end

-- True once every deviceType DP of this panel has been received
local function all_dt_known(device, gang_count)
  local type_map = dp_map.GANG_TYPE_MAP[gang_count]
  if not type_map then return false end
  for _, entry in ipairs(type_map) do
    if device:get_field(DT_FIELD[entry.dp]) == nil then return false end
  end
  return true
end

-- Which curtain the "main" tile controls/mirrors (first present of 2,1,3)
local function resolve_curtain_comp(device, comp_id)
  if comp_id ~= "main" then return comp_id end
  for _, c in ipairs({ "curtain2", "curtain1", "curtain3" }) do
    if device.profile.components[c] then return c end
  end
  return comp_id
end

-- multiTileMode: "off" | "any_light" | "all_light"
-- Legacy "multiTile" yes/no preference is treated as "all_light" / "off"
local function get_multitile_mode(device)
  local prefs = device.preferences or {}
  local mode = prefs.multiTileMode
  if mode then
    -- Normalise legacy and new values to canonical set
    if mode == "on" or mode == "any_light" or mode == "all_light" then
      return "on"   -- all three mean "show all detected channels as tiles"
    end
    return "off"
  end
  -- Legacy boolean preference fallback
  if prefs.multiTile == "yes" then return "on" end
  return "off"
end

-- Returns true when multi-tile layout should be used.
-- mode "on"  → always true (show curtain + light tiles for all detected channels)
-- mode "off" → always false (single tile with dashboard button)
-- True when every column of the panel is a curtain (4/6-gang)
local function all_curtain(device)
  local cols = get_columns(device)
  if #cols == 0 then return false end
  if #cols * 2 < gang_count_of(device) then return false end  -- some gangs are lights
  for _, col in ipairs(cols) do
    if not col_is_curtain(device, col) then return false end
  end
  return true
end

-- Multi-tile is for lights only: an all-curtain panel is always single-tile
local function is_multi_tile(device)
  local gc = gang_count_of(device)
  if gc == 1 then return false end  -- no multi-tile layout for 1-gang
  if all_curtain(device) then return false end
  return get_multitile_mode(device) == "on"
end
local function get_devtype_profile_suffix(device, gang_count)
  local type_map = dp_map.GANG_TYPE_MAP[gang_count]
  if not type_map then return nil end  -- 1-gang, 3-gang: light-only, no suffix

  -- Collect per-group types; bail if any are unknown yet
  local types = {}
  for _, entry in ipairs(type_map) do
    local raw = device:get_field(DT_FIELD[entry.dp])
    if raw == nil then return nil end
    types[#types + 1] = raw
  end

  -- All-light = base profile (no suffix)
  local all_light = true
  for _, v in ipairs(types) do if v ~= 0 then all_light = false; break end end
  if all_light then return nil end

  if gang_count == 2 then return (types[1] == 1) and "curtain" or nil end
  if gang_count == 3 then return (types[1] == 1) and "mixed-13" or nil end
  if gang_count == 4 then
    local dt1, dt2 = types[1], types[2]
    if dt1 == 1 and dt2 == 1 then return "curtain" end
    if dt1 == 1 and dt2 == 0 then return "mixed"   end
    if dt1 == 0 and dt2 == 1 then return "mixed-r"  end
    return nil
  end

  if gang_count == 6 then
    local dt1, dt2, dt3 = types[1], types[2], types[3]
    -- All curtain
    if dt1==1 and dt2==1 and dt3==1 then return "curtain" end
    -- Two curtain columns
    if dt1==1 and dt2==1 and dt3==0 then return "mixed-lm" end
    if dt1==1 and dt2==0 and dt3==1 then return "mixed-lr" end
    if dt1==0 and dt2==1 and dt3==1 then return "mixed-mr" end
    -- One curtain column
    if dt1==1 and dt2==0 and dt3==0 then return "mixed-l" end
    if dt1==0 and dt2==1 and dt3==0 then return "mixed-m" end
    if dt1==0 and dt2==0 and dt3==1 then return "mixed-r" end
    return nil
  end

  -- 2-gang: no mixed profiles
  return nil
end

local function get_profile_for_device(device)
  local mfr   = device:get_manufacturer()
  local count = mfr and MFR_TO_GANG_COUNT[mfr] or 2
  local multi = is_multi_tile(device)

  local base      = "smarthome4u-" .. count .. "gang-switch"
  local dt_suffix = get_devtype_profile_suffix(device, count)

  local profile
  if multi and count > 1 then
    if dt_suffix == "mixed" then
      profile = base .. "-mixed-multi-v3"
    elseif dt_suffix == "curtain" then
      profile = base .. "-curtain-multi-v2"
    elseif dt_suffix == "mixed-r" and count == 4 then
      profile = base .. "-mixed-r-multi-v2"
    elseif dt_suffix then
      -- covers mixed-l, mixed-m, mixed-r(6g), mixed-lm, mixed-lr, mixed-mr
      profile = base .. "-" .. dt_suffix .. "-multi-v2"
    else
      profile = base .. "-multi-v2"
    end
  elseif dt_suffix then
    profile = base .. "-" .. dt_suffix .. "-v2"
  else
    profile = base .. "-v2"
  end

  log.info("get_profile_for_device: mfr=" .. tostring(mfr)
    .. " gang=" .. count .. " multi=" .. tostring(multi)
    .. " dt_suffix=" .. tostring(dt_suffix)
    .. " -> " .. profile)
  return profile
end

---------------------------------------------------------------------
-- DP / COMPONENT MAPS
---------------------------------------------------------------------

local ST_COMP_TO_DP = {
  sw1     = DP_SW1,
  switch2 = DP_SW2,
  switch3 = DP_SW3,
  switch4 = DP_SW4,
  switch5 = DP_SW5,
  switch6 = DP_SW6,
  master  = DP_MAST,
}

local ST_DP_TO_COMP = {
  [DP_SW1]  = "sw1",
  [DP_SW2]  = "switch2",
  [DP_SW3]  = "switch3",
  [DP_SW4]  = "switch4",
  [DP_SW5]  = "switch5",
  [DP_SW6]  = "switch6",
  [DP_MAST] = "master",
}

local MT_COMP_TO_DP = {
  main01 = DP_SW1,
  main02 = DP_SW2,
  main03 = DP_SW3,
  main04 = DP_SW4,
  main05 = DP_SW5,
  main06 = DP_SW6,
}

local MT_DP_TO_COMP = {
  [DP_SW1]  = "main01",
  [DP_SW2]  = "main02",
  [DP_SW3]  = "main03",
  [DP_SW4]  = "main04",
  [DP_SW5]  = "main05",
  [DP_SW6]  = "main06",
  [DP_MAST] = "main",
}

local ST_CHILD_KEY_TO_DP = {
  switch1 = DP_SW1,
  switch2 = DP_SW2,
  switch3 = DP_SW3,
  switch4 = DP_SW4,
  switch5 = DP_SW5,
  switch6 = DP_SW6,
}

local MT_CHILD_KEY_TO_DP = {
  main01 = DP_SW1,
  main02 = DP_SW2,
  main03 = DP_SW3,
  main04 = DP_SW4,
  main05 = DP_SW5,
  main06 = DP_SW6,
}

---------------------------------------------------------------------
-- SEND A TUYA DP BOOL COMMAND
---------------------------------------------------------------------
local function parse_tuya_dp(zb_rx)
  local body = zb_rx.body.zcl_body
  if not body then return nil, nil end
  local raw = body.body_bytes
  if not raw or type(raw) ~= "string" or #raw < 7 then return nil, nil end
  return raw:byte(3), raw:byte(7)
end

---------------------------------------------------------------------
-- EMIT HELPERS
---------------------------------------------------------------------
local function emit_switch(device, component_id, sw_val)
  local comp = device.profile.components[component_id]
  if comp then
    device:emit_component_event(comp, capabilities.switch.switch(sw_val))
  end
end

local function emit_backlight(device, value)
  local comp = device.profile.components["backlight"]
  if comp then
    local mode_val = (value == 1) and "on" or "off"
    device:emit_component_event(
      comp,
      capabilities["perfectworld33337.backlightMode"].backlightMode(mode_val, { state_change = true })
    )
  end
end

local function emit_childlock(device, value)
  local comp = device.profile.components["childlock"]
  if comp then
    local mode_val = (value == 1) and "enabled" or "disabled"
    device:emit_component_event(
      comp,
      capabilities["vehiclepatch55148.childlock"].childLockMode(mode_val, { state_change = true })
    )
  end
end


-- Returns true if the given gang number is configured as a curtain on this device
local function is_curtain_gang(device, gang_num)
  local dt_dp_map = {
    [1] = dp_map.DP_DEVICE_TYPE_1,
    [2] = dp_map.DP_DEVICE_TYPE_2,
    [3] = dp_map.DP_DEVICE_TYPE_3,
  }
  local dt_dp = dt_dp_map[gang_num]
  if not dt_dp then return false end
  local field = DT_FIELD[dt_dp]
  local raw = field and device:get_field(field)
  return raw == 1
end

local function emit_curtain(device, component_id, shade_val)
  local comp = device.profile.components[component_id]
  if comp then
    -- Track last known state per curtain column for pause/stop logic
    local col = col_by_comp(device, component_id)
    if col then device:set_field("curtain_state_" .. col.key, shade_val) end
    device:emit_component_event(comp, capabilities.windowShade.windowShade(shade_val))
  end
  -- Mirror to "main" only for the curtain that main controls
  -- (panels with 2-3 curtains would otherwise show whichever moved last)
  local main_comp = device.profile.components["main"]
  if main_comp and main_comp.capabilities and main_comp.capabilities["windowShade"] then
    if all_curtain(device) then
      -- All-curtain panel: main shows the combined state of all curtains
      local all_open, all_closed = true, true
      for _, col in ipairs(get_columns(device)) do
        local st = device:get_field("curtain_state_" .. col.key)
        if st ~= "open" then all_open = false end
        if st ~= "closed" then all_closed = false end
      end
      local agg = all_closed and "closed" or (all_open and "open" or "partially open")
      device:emit_component_event(main_comp, capabilities.windowShade.windowShade(agg))
    elseif resolve_curtain_comp(device, "main") == component_id then
      device:emit_component_event(main_comp, capabilities.windowShade.windowShade(shade_val))
    end
  end  -- Propagate to curtain child device (key = component_id: curtain1/2/3)
  local child = device:get_child_by_parent_assigned_key(component_id)
  if child then
    local child_comp = child.profile.components["main"]
    if child_comp then
      child:emit_component_event(child_comp, capabilities.windowShade.windowShade(shade_val))
    end
  end
end

-- emit_main: emit switch state to "main" component (light profiles only)
local function emit_main(device, val)
  local comp = device.profile.components["main"]
  if not comp then return end
  -- When main has windowShade it IS the curtain dashboard tile.
  -- Its state is driven by emit_curtain via windowShade, not by switch.
  -- Emitting switch here would override the curtain display, so skip it.
  if comp.capabilities and comp.capabilities["windowShade"] then return end
  if comp.capabilities and comp.capabilities["switch"] then
    emit_switch(device, "main", val)
  end
end

-- emit_main_shade: emit windowShade state to "main" when it has windowShade capability
local function emit_main_shade(device, shade_val)
  local comp = device.profile.components["main"]
  if not comp then return end
  if comp.capabilities and comp.capabilities["windowShade"] then
    device:emit_component_event(comp, capabilities.windowShade.windowShade(shade_val))
  end
end

-- main_has_shade: returns true if "main" component has windowShade capability
local function main_has_shade(device)
  local comp = device.profile.components["main"]
  return comp and comp.capabilities and comp.capabilities["windowShade"]
end

-- emit_master: emit switch state to "master" component (DP 0x0D)
local function emit_master(device, val)
  local comp = device.profile.components["master"]
  if not comp then return end
  emit_switch(device, "master", val)
end

---------------------------------------------------------------------
-- DASHBOARD BUTTON ("main" switch) TARGETS
-- dashboardSwitch values: "sw1","switch2".."switch6","main01".."main06",
-- "both" (legacy 4-gang), "all". Everything is resolved to switch DPs so
-- single-tile (swN) and multi-tile (main0N) names behave the same.
-- Curtain relay DPs are ALWAYS filtered out, so a stale preference can
-- never move a curtain from the dashboard light button.
---------------------------------------------------------------------
local function light_comp_for_dp(device, dp)
  for _, c in ipairs({ ST_DP_TO_COMP[dp], MT_DP_TO_COMP[dp] }) do
    if c and device.profile.components[c] then return c end
  end
  return nil
end

local function dashboard_target_dps(device)
  local prefs = device.preferences or {}
  local db_sw = prefs.dashboardSwitch
  local dps = {}
  local function add(dp)
    if dp and not dp_is_curtain_relay(device, dp) and light_comp_for_dp(device, dp) then
      dps[#dps + 1] = dp
    end
  end
  if db_sw == "all" or (db_sw == nil and not any_curtain(device)) then
    for dp = DP_SW1, DP_SW6 do add(dp) end
  elseif db_sw == "both" then
    if device.profile.components["main01"] or device.profile.components["sw1"] then
      add(DP_SW1); add(DP_SW3)
    else
      add(DP_SW2); add(DP_SW4)
    end
  elseif db_sw then
    add(ST_COMP_TO_DP[db_sw] or MT_COMP_TO_DP[db_sw])
  end
  -- Fallback: first light present on the panel
  if #dps == 0 then
    for dp = DP_SW1, DP_SW6 do
      add(dp)
      if #dps > 0 then break end
    end
  end
  return dps
end

local function main_has_switch(device)
  local c = device.profile.components["main"]
  return c and c.capabilities and c.capabilities["switch"]
end

-- Read a component's current switch value ("on"/"off"/nil)
local function latest_switch(device, comp)
  local v = device:get_latest_state(comp, "switch", "switch")
  if type(v) == "table" then v = v.value end
  return v
end

-- Keep the "main" dashboard button in sync with the light(s) it controls.
-- Button = ON if ANY targeted light is on, OFF only when all are off
-- (so the tile background dims correctly with "all" / "both").
local function emit_dashboard_mirror(device, comp_id, sw_val)
  if not main_has_switch(device) then return end
  local dp = ST_COMP_TO_DP[comp_id] or MT_COMP_TO_DP[comp_id]
  if not dp then return end
  local targets, hit = dashboard_target_dps(device), false
  for _, t in ipairs(targets) do if t == dp then hit = true end end
  if not hit then return end
  local any_on = false
  for _, t in ipairs(targets) do
    local v
    if t == dp then v = sw_val
    else
      local c = light_comp_for_dp(device, t)
      v = c and latest_switch(device, c)
    end
    if v == "on" then any_on = true end
  end
  emit_switch(device, "main", any_on and "on" or "off")
end

local function dp_to_gangs(dp, gang_count)
  local map = dp_map.GANG_TYPE_MAP[gang_count]
  if not map then return nil end
  for _, entry in ipairs(map) do
    if entry.dp == dp then return entry.gangs, entry.label end
  end
  return nil
end

local function emit_channeltype(device, dp, raw_value)
  local comp_id = DT_COMP[dp]
  if not comp_id then return end
  local comp = device.profile.components[comp_id]
  if not comp then
    log.debug(string.format("emit_channeltype: component %s not in profile, skipping", comp_id))
    return
  end
  local type_val   = dp_map.DEVICE_TYPE_NAME[raw_value]  or "light"    -- schema enum
  local type_label = dp_map.DEVICE_TYPE_LABEL[raw_value] or "💡 Light"  -- display only
  log.info(string.format("emit_channeltype: %s -> %s", comp_id, type_label))
  local cap = capabilities["vehiclepatch55148.channelType"]
  if not cap then
    log.warn("emit_channeltype: capability vehiclepatch55148.channelType not found, skipping")
    return
  end
  device:emit_component_event(comp, cap.channelType(type_val, { state_change = true, visibility = { displayed = false } }))
end

local function update_devtype_summary(device, gang_count)
  if not dp_map.GANG_TYPE_MAP[gang_count] then return end

  local parts = {}
  local gang_types = {}

  local type_map = dp_map.GANG_TYPE_MAP[gang_count] or {}
  for _, entry in ipairs(type_map) do
    local raw = device:get_field(DT_FIELD[entry.dp])
    local type_name = (raw ~= nil) and (dp_map.DEVICE_TYPE_LABEL[raw] or "unknown") or "unknown"
    for _, g in ipairs(entry.gangs) do
      gang_types[g] = type_name
    end
  end

  for i = 1, gang_count do
    local t = gang_types[i] or "unknown"
    parts[#parts + 1] = string.format("Gang%d=%s", i, t)
  end

  local summary = table.concat(parts, "  ")
  device:set_field("devtype_summary", summary)

  log.info("╔══ DEVICE TYPE DETECTION ══════════════════════════════════╗")
  log.info("║  " .. tostring(gang_count) .. "-gang panel · " .. summary)
  for _, entry in ipairs(type_map) do
    local raw = device:get_field(DT_FIELD[entry.dp])
    local type_name = (raw ~= nil) and (dp_map.DEVICE_TYPE_LABEL[raw] or "unknown") or "unknown"
    local dp_hex = string.format("0x%02X", entry.dp)
    local gangs_str = entry.label or table.concat(entry.gangs, "+")
    log.info(string.format("║  DP %s  →  gangs {%s}  →  %s",
      dp_hex, gangs_str, string.upper(type_name)))
  end
  log.info("╚═══════════════════════════════════════════════════════════╝")
end

---------------------------------------------------------------------
-- HANDLE DEVICE TYPE DP
---------------------------------------------------------------------
-- Emit channel type for every column the panel reports (safe: skips missing components)
local function emit_all_channeltypes(device)
  for dp, _ in pairs(DT_COMP) do
    local raw = device:get_field(DT_FIELD[dp])
    if raw ~= nil then emit_channeltype(device, dp, raw) end
  end
  -- Tell the app which curtain buttons exist (otherwise "hasn't updated all its status")
  local sup = { "open", "close", "pause" }
  local opt = { state_change = true, visibility = { displayed = false } }
  for _, comp in pairs(device.profile.components) do
    if comp.capabilities and comp.capabilities["windowShade"] then
      device:emit_component_event(comp, capabilities.windowShade.supportedWindowShadeCommands(sup, opt))
    end
  end
  for _, key in ipairs({ "curtain1", "curtain2", "curtain3" }) do
    local child = device:get_child_by_parent_assigned_key(key)
    if child then child:emit_event(capabilities.windowShade.supportedWindowShadeCommands(sup, opt)) end
  end
end
local function handle_device_type_dp(driver, device, dp, raw_value, gang_count)
  local field = DT_FIELD[dp]
  if not field then return end

  if not dp_map.GANG_TYPE_MAP[gang_count] then
    log.debug(string.format(
      "handle_device_type_dp: dp=0x%02X gang_count=%d – not applicable, ignoring",
      dp, gang_count))
    return
  end

  local type_name = dp_map.DEVICE_TYPE_LABEL[raw_value] or ("unknown(" .. tostring(raw_value) .. ")")
  local gangs, gangs_label = dp_to_gangs(dp, gang_count)
  local gangs_str = gangs_label or (gangs and table.concat(gangs, "+")) or "?"

  log.info(string.format(
    "DeviceType DP 0x%02X received: value=%d (%s) · affects gangs {%s}",
    dp, raw_value, type_name, gangs_str))

  device:set_field(field, raw_value, { persist = true })

  local profile_just_switched = false
  -- Only decide once ALL deviceType DPs are known (they arrive one by one).
  -- This also allows switching back to the all-light base profile.
  if all_dt_known(device, gang_count) then
    local new_profile = get_profile_for_device(device)
    local applied_profile = device:get_field("applied_profile_name")
    if new_profile ~= applied_profile then
      log.info(string.format(
        "handle_device_type_dp: switching profile %s -> %s", tostring(applied_profile), new_profile))
      device:try_update_metadata({ profile = new_profile })
      device:set_field("applied_profile_name", new_profile)
      profile_just_switched = true
    end
  end

  if profile_just_switched then
    device:set_field("custom_caps_initialized", nil)
    device:set_field("profile_switch_pending", true)
    log.info("handle_device_type_dp: profile switched, deferring channeltype emit to infoChanged")
  else
    emit_channeltype(device, dp, raw_value)
  end

  device.thread:call_with_delay(3, function() emit_all_channeltypes(device) end)
  update_devtype_summary(device, gang_count)
end

---------------------------------------------------------------------
-- QUERY DEVICE TYPES
---------------------------------------------------------------------
local function send_tuya_cmd(device, cmd_id)
  SEQ = (SEQ + 1) % 256
  local tuya_payload = string.char(0x00, SEQ)

  local zclh = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(cmd_id),
  })
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_disable_default_response()

  local addrh = zb_messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(TUYA_CLUSTER_ID) or 0x01,
    zb_const.HA_PROFILE_ID,
    TUYA_CLUSTER_ID
  )

  log.info(string.format("send_tuya_cmd: sending cmd=0x%02X to device", cmd_id))

  device:send(zb_messages.ZigbeeMessageTx({
    address_header = addrh,
    body = zcl_messages.ZclMessageBody({
      zcl_header = zclh,
      zcl_body   = generic_body.GenericBody(tuya_payload),
    }),
  }))
end

local function send_dp_query(device, dp)
  SEQ = (SEQ + 1) % 256
  local tuya_payload = string.char(0x00, SEQ, dp, 0x01, 0x00, 0x01, 0x00)

  local zclh = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(TUYA_CMD_QUERY),
  })
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_disable_default_response()

  local addrh = zb_messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(TUYA_CLUSTER_ID) or 0x01,
    zb_const.HA_PROFILE_ID,
    TUYA_CLUSTER_ID
  )

  log.info(string.format("send_dp_query: querying DP 0x%02X from device", dp))

  device:send(zb_messages.ZigbeeMessageTx({
    address_header = addrh,
    body = zcl_messages.ZclMessageBody({
      zcl_header = zclh,
      zcl_body   = generic_body.GenericBody(tuya_payload),
    }),
  }))
end

local function query_device_types(device, gang_count)
  if not dp_map.GANG_TYPE_MAP[gang_count] then return end

  local type_map = dp_map.GANG_TYPE_MAP[gang_count] or {}
  log.info(string.format(
    "query_device_types: %d-gang panel, expecting DPs: %s",
    gang_count,
    (function()
      local dps = {}
      for _, e in ipairs(type_map) do
        dps[#dps+1] = string.format("0x%02X(%s)", e.dp, e.label or "?")
      end
      return table.concat(dps, ", ")
    end)()
  ))

  log.info("query_device_types: sending CMD_SCENE (0x03) to trigger full DP dump")
  send_tuya_cmd(device, TUYA_CMD_SCENE)

  for _, entry in ipairs(type_map) do
    log.info(string.format(
      "query_device_types: sending CMD_QUERY (0x04) for DP 0x%02X (%s)",
      entry.dp, entry.label or table.concat(entry.gangs, "+")))
    send_dp_query(device, entry.dp)
  end

  local have_any = false
  for _, entry in ipairs(type_map) do
    if device:get_field(DT_FIELD[entry.dp]) ~= nil then
      have_any = true
    end
  end
  if have_any then
    log.info("query_device_types: cached device-type data found, rebuilding summary")
    local profile_just_switched_cached = false
    if all_dt_known(device, gang_count) then
      local new_profile = get_profile_for_device(device)
      local applied_profile = device:get_field("applied_profile_name")
      if new_profile ~= applied_profile then
        log.info(string.format(
          "query_device_types: switching profile (cached) %s -> %s",
          tostring(applied_profile), new_profile))
        device:try_update_metadata({ profile = new_profile })
        device:set_field("applied_profile_name", new_profile)
        profile_just_switched_cached = true
      end
    end
    if profile_just_switched_cached then
      device:set_field("custom_caps_initialized", nil)
      device:set_field("profile_switch_pending", true)
      log.info("query_device_types: profile switched (cached), deferring channeltype emit to infoChanged")
    else
      for _, entry in ipairs(type_map) do
        local raw = device:get_field(DT_FIELD[entry.dp])
        if raw ~= nil then
          emit_channeltype(device, entry.dp, raw)
        end
      end
    end
    update_devtype_summary(device, gang_count)
  end
end

---------------------------------------------------------------------
-- EMIT INITIAL STATE
---------------------------------------------------------------------
local function emit_initial_state(device)
  if device.parent_assigned_child_key ~= nil then return end
  local gang_count = get_gang_count(device)

  local multi   = is_multi_tile(device)
  local dp2comp = multi and MT_DP_TO_COMP or ST_DP_TO_COMP
  local columns = dp_map.COLUMNS[gang_count] or {}

  if not multi then
    emit_main(device, "off")   -- no-op if main has no switch / is a curtain tile
    emit_master(device, "off")
    -- Mixed profiles: main has switch + windowShade, emit_main() skips it.
    -- Seed the dashboard button's switch so the tile has a state.
    if main_has_switch(device) then emit_switch(device, "main", "off") end
  end

  -- Column panels (4/6-gang): curtain columns -> windowShade, light columns -> 2 switches
  local covered, first_light = {}, nil
  for _, col in ipairs(columns) do
    covered[col.up], covered[col.dn] = true, true
    if col_is_curtain(device, col) then
      emit_curtain(device, col.comp, "partially open")
    else
      for _, g in ipairs({ col.up, col.dn }) do
        emit_switch(device, dp2comp[g], "off")
        first_light = first_light or dp2comp[g]
      end
    end
  end
  -- Gangs outside any column (1/2/3-gang panels): plain lights
  for g = 1, gang_count do
    if not covered[g] then
      emit_switch(device, dp2comp[g], "off")
      first_light = first_light or dp2comp[g]
    end
  end

  if multi then
    if any_curtain(device) then
      if first_light then emit_dashboard_mirror(device, first_light, "off") end
    else
      emit_main(device, "off")
    end
  end

  for dp, comp_id in pairs(DT_COMP) do
    local comp = device.profile.components[comp_id]
    if comp then
      local field   = DT_FIELD[dp]
      local raw     = field and device:get_field(field)
      local type_val   = (raw ~= nil) and (dp_map.DEVICE_TYPE_NAME[raw]  or "light")    or "light"
      local type_label = (raw ~= nil) and (dp_map.DEVICE_TYPE_LABEL[raw] or "💡 Light") or "💡 Light"
      log.info(string.format("emit_initial_state: %s -> %s (raw=%s)", comp_id, type_label, tostring(raw)))
      local cap2 = capabilities["vehiclepatch55148.channelType"]
      if not cap2 then
        log.warn("emit_initial_state: capability vehiclepatch55148.channelType not found, skipping")
      else
        device:emit_component_event(comp, cap2.channelType(type_val, { state_change = true, visibility = { displayed = false } }))
      end
    end
  end
end

---------------------------------------------------------------------
-- FIX: emit_custom_cap_defaults now uses cached values when available
-- instead of always defaulting to "off"/"disabled".
---------------------------------------------------------------------
local function emit_custom_cap_defaults(device)
  log.info("emit_custom_cap_defaults: emitting initial state for custom capabilities")

  local bl_comp = device.profile.components["backlight"]
  local cl_comp = device.profile.components["childlock"]

  if bl_comp then
    -- Use cached backlight value if the device has already reported it;
    -- only fall back to "off" if we have no data yet.
    local cached_bl = device:get_field("cached_backlight_value")
    local bl_val = (cached_bl ~= nil) and ((cached_bl == 1) and "on" or "off") or "off"
    log.info("emit_custom_cap_defaults: backlight -> " .. bl_val
      .. " (cached_raw=" .. tostring(cached_bl) .. ")")
    device:emit_component_event(
      bl_comp,
      capabilities["perfectworld33337.backlightMode"].backlightMode(bl_val, { state_change = true, visibility = { displayed = false } })
    )
  else
    log.warn("emit_custom_cap_defaults: backlight component not found in profile")
  end

  if cl_comp then
    -- Use cached child lock value if the device has already reported it.
    local cached_cl = device:get_field("cached_childlock_value")
    local cl_val = (cached_cl ~= nil) and ((cached_cl == 1) and "enabled" or "disabled") or "disabled"
    log.info("emit_custom_cap_defaults: childlock -> " .. cl_val
      .. " (cached_raw=" .. tostring(cached_cl) .. ")")
    device:emit_component_event(
      cl_comp,
      capabilities["vehiclepatch55148.childlock"].childLockMode(cl_val, { state_change = true, visibility = { displayed = false } })
    )
  else
    log.warn("emit_custom_cap_defaults: childlock component not found in profile")
  end
end

---------------------------------------------------------------------
-- ZIGBEE HANDLER
---------------------------------------------------------------------
local function parse_dp(zb_rx)
  local body = zb_rx.body.zcl_body
  if not body then return nil, nil end
  local raw = body.body_bytes
  if not raw or type(raw) ~= "string" or #raw < 7 then return nil, nil end
  return raw:byte(3), raw:byte(7)
end

---------------------------------------------------------------------
-- CURTAIN DURATION HELPER (defined here so zigbee_handler can use it)
---------------------------------------------------------------------
local DEFAULT_CURTAIN_SEC = 90  -- 1.5 minutes

-- col: a column entry from dp_map.COLUMNS (nil -> curtainDuration1)
local function get_curtain_duration(device, col)
  local pref_name = (col and col.dur) or "curtainDuration1"
  local pref = device.preferences and device.preferences[pref_name]
  local secs = tonumber(pref)
  if secs and secs >= 10 and secs <= 600 then return secs end
  return DEFAULT_CURTAIN_SEC
end

-- Safe emit to "main": uses windowShade if main has it, switch otherwise
local function zigbee_handler(driver, device, zb_rx)
  metrics.emit_metrics(device, zb_rx)

  local dp, value = parse_dp(zb_rx)
  if not dp then return end

  -- Alt switch DPs (0x66/0x67) exist on the 4-gang mixed panel only.
  -- The 6-gang reports 0x66 with a different meaning, so never remap there.
  local canonical_dp = gang_count_of(device) == 4
    and dp_map.DP_ALT_SWITCH_MAP and dp_map.DP_ALT_SWITCH_MAP[dp]
  if canonical_dp then
    log.info(string.format("zigbee_handler: remapping alt dp=0x%02X -> canonical dp=0x%02X", dp, canonical_dp))
    dp = canonical_dp
  end

  if dp == 0x66 then return end  -- tt_switch: not used
  log.debug(string.format("zigbee_handler: dp=0x%02X (%d)  value=%d", dp, dp, value))

  if dp == DP_DT1 or dp == DP_DT2 or dp == DP_DT3 then
    local gang_count = get_gang_count(device)
    handle_device_type_dp(driver, device, dp, value, gang_count)
    return
  end

  local sw_val = (value == 1) and "on" or "off"

  if dp == DP_BL then
    log.info(string.format("zigbee_handler: backlight dp=0x%02X value=%d (%s)", dp, value, sw_val))
    -- FIX: cache the raw value so emit_custom_cap_defaults can restore it correctly
    device:set_field("cached_backlight_value", value)
    emit_backlight(device, value)
    return
  end

  if dp == DP_CL then
    log.info(string.format("zigbee_handler: childlock dp=0x%02X value=%d (%s)", dp, value, sw_val))
    -- FIX: cache the raw value so emit_custom_cap_defaults can restore it correctly
    device:set_field("cached_childlock_value", value)
    emit_childlock(device, value)
    return
  end

  -- Curtain command DPs (0x79/0x7A/0x7B) are write-only commands.
  -- The device echoes them back after we send; ignore these echoes since
  -- actual motor state is tracked via switch DPs 0x01-0x06.
  local CURTAIN_CMD_DPS = { [DP_CURTAIN_1]=true, [DP_CURTAIN_2]=true, [DP_CURTAIN_3]=true }
  if CURTAIN_CMD_DPS[dp] then
    local shade_val = CURTAIN_VAL_TO_SHADE[value] or "partially open"
    log.info(string.format("zigbee_handler: curtain cmd echo dp=0x%02X value=%d (%s) -> ignored (status via switch DPs)", dp, value, shade_val))
    return
  end

  log.info(string.format("zigbee_handler: switch dp=0x%02X (%d) value=%d (%s)", dp, dp, value, sw_val))

  -- Map switch DPs to gang numbers so we can check if a gang is a curtain
  local DP_TO_GANG_NUM = {
    [DP_SW1] = 1, [DP_SW2] = 2, [DP_SW3] = 3,
    [DP_SW4] = 4, [DP_SW5] = 5, [DP_SW6] = 6,
  }

  -- For each switch DP, check if its column is a curtain.
  -- DPs 0x01-0x06 are state feedback: ON=open/moving, OFF=stopped/closed
  -- Route to the curtain component (curtain1/curtain2), not to the switch component.
  -- For curtain columns, use elapsed time to determine final state when DP turns OFF.
  local function emit_for_comp(comp_id, gang_num)
    local colent, is_up_dp = col_for_dp(device, dp)
    if colent and col_is_curtain(device, colent) then
      local curtain_comp = colent.comp
      if device.profile.components[curtain_comp] then
        local shade_val
        local col         = colent.key
        local duration    = get_curtain_duration(device, colent)
        local ts_field    = "curtain_start_ts_" .. col
        local dir_field   = "curtain_dir_" .. col  -- "up" or "down" — last active direction

        if sw_val == "on" then
          -- Motor started: record direction, timestamp, and state
          local start_ts = os.time()
          device:set_field(ts_field, start_ts)
          device:set_field(dir_field, is_up_dp and "up" or "down")
          shade_val = is_up_dp and "opening" or "closing"
          log.info(string.format(
            "zigbee_handler: curtain %s ON dir=%s ts=%d",
            col, device:get_field(dir_field), start_ts))

          -- Completion timer: if relay hasn't reported OFF after duration+2s,
          -- the motor finished its full run — emit the resolved state directly.
          local final_state = is_up_dp and "open" or "closed"
          driver:call_with_delay(duration + 2, function()
            local stored_ts  = device:get_field(ts_field)
            local stored_dir = device:get_field(dir_field)
            -- Only resolve if this is still the same run (ts unchanged, still active)
            if stored_ts == start_ts and stored_dir ~= nil then
              log.info(string.format(
                "zigbee_handler: curtain %s completion timer fired -> %s",
                col, final_state))
              device:set_field(ts_field, nil)
              device:set_field(dir_field, nil)
              emit_curtain(device, curtain_comp, final_state)
            end
          end)
        else
          -- Motor OFF: only process if this DP matches the active direction
          -- (ignore the opposite relay turning off as a side-effect of the command)
          local active_dir = device:get_field(dir_field)
          local this_dir   = is_up_dp and "up" or "down"

          if active_dir ~= nil and active_dir ~= this_dir then
            -- This is the opposite relay confirming it's off — ignore completely
            log.info(string.format(
              "zigbee_handler: curtain %s %s-relay OFF ignored (active=%s)",
              col, this_dir, active_dir))
            return
          end

          -- Process the stop of the active relay
          local start_ts = device:get_field(ts_field)

          if not start_ts then
            -- No active run tracked: relay-OFF echo from a stop/pause command
            -- sent while curtain was already at rest. Keep the current state.
            local cur_state = col and device:get_field("curtain_state_" .. col)
            log.info(string.format(
              "zigbee_handler: curtain %s OFF no start_ts -> ignoring (state=%s)",
              tostring(col), tostring(cur_state)))
            return
          end

          local elapsed = os.time() - start_ts
          if elapsed < 1 then
            -- Relay-OFF arrived within 1s of run start: this is the stop-echo
            -- of the PREVIOUS command (device clears relays before starting new
            -- direction). Ignore it — the real stop will arrive after the motor runs.
            log.info(string.format(
              "zigbee_handler: curtain %s OFF elapsed=%ds < 1s -> ignoring stop-echo",
              col, elapsed))
            return
          end

          device:set_field(ts_field, nil)
          device:set_field(dir_field, nil)

          if is_up_dp then
            shade_val = (elapsed >= duration) and "open" or "partially open"
          else
            shade_val = (elapsed >= duration) and "closed" or "partially open"
          end
          log.info(string.format(
            "zigbee_handler: curtain %s OFF elapsed=%ds duration=%ds -> %s",
            col, elapsed, duration, shade_val))
        end  -- if sw_val == "on" / else

        emit_curtain(device, curtain_comp, shade_val)
        return
      end  -- if device.profile.components[curtain_comp]
    end  -- if col and col_is_curtain
    emit_switch(device, comp_id, sw_val)
  end

  if is_multi_tile(device) then
    local comp_id = MT_DP_TO_COMP[dp]
    if dp == DP_MAST then
      -- On a mixed panel DP_MAST fires for curtain relay changes too.
      -- Only update "main" (dashboard button) for pure-light multi profiles.
      -- Mixed profiles have curtain1 + main02/main04; dashboard mirror is
      -- handled by emit_dashboard_mirror when light DPs 0x02/0x04 arrive.
      if not any_curtain(device) and ((device.preferences or {}).dashboardSwitch or "all") == "all" then
        -- Pure-light multi profile: DP_MAST mirrors to main
        emit_main(device, sw_val)
      end
      emit_master(device, sw_val) -- always update master component
      return  -- fully handled
    end
    if comp_id and comp_id ~= "main" then
      emit_for_comp(comp_id, DP_TO_GANG_NUM[dp])
      -- Mirror to dashboard button for light components only (skip curtain relay DPs)
      if not dp_is_curtain_relay(device, dp) then
        emit_dashboard_mirror(device, comp_id, sw_val)
      end
      local child = device:get_child_by_parent_assigned_key(comp_id)
      if child then child:emit_event(capabilities.switch.switch(sw_val)) end
    elseif comp_id == nil then
      log.warn(string.format("zigbee_handler (multi): unhandled dp=0x%02X", dp))
    end
  else
    local comp_id = ST_DP_TO_COMP[dp]
    local gang_num = DP_TO_GANG_NUM[dp]

    local dashboard_dp = DP_MAST
    if dp == dashboard_dp then
      -- On mixed panels, DP_MAST fires for curtain relays too — don't update
      -- the dashboard button from it. The button is kept in sync by
      -- emit_dashboard_mirror when light DPs 0x02/0x04 actually change.
      if not any_curtain(device) and ((device.preferences or {}).dashboardSwitch or "all") == "all" then
        emit_main(device, sw_val)   -- pure-light profiles only
      end
      emit_master(device, sw_val) -- always update master component
      return  -- DP_MAST is fully handled; don't fall into comp_id dispatch
    end

    if comp_id == "sw1" then
      emit_for_comp("sw1", gang_num)
      -- Mirror to dashboard button (DP1 is a curtain relay on some layouts)
      if not dp_is_curtain_relay(device, dp) then
        emit_dashboard_mirror(device, "sw1", sw_val)
      end
      local child = device:get_child_by_parent_assigned_key("switch1")
      if child then child:emit_event(capabilities.switch.switch(sw_val)) end

    elseif comp_id and comp_id ~= "master" then
      emit_for_comp(comp_id, gang_num)
      -- Mirror to dashboard button for light components only (skip curtain relay DPs)
      if not dp_is_curtain_relay(device, dp) then
        emit_dashboard_mirror(device, comp_id, sw_val)
      end
      local child = device:get_child_by_parent_assigned_key(comp_id)
      if child then child:emit_event(capabilities.switch.switch(sw_val)) end

    elseif comp_id == "master" then
      emit_switch(device, "master", sw_val)

    else
      log.warn(string.format("zigbee_handler (single): unhandled dp=0x%02X", dp))
    end
  end
end

---------------------------------------------------------------------
-- SEND HELPERS
---------------------------------------------------------------------
local function send_dp(device, dp, value)
  SEQ = (SEQ + 1) % 256

  local tuya_payload = string.char(
    0x00, SEQ, dp, 0x01, 0x00, 0x01,
    value and 0x01 or 0x00
  )

  local zclh = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(TUYA_CMD_SEND),
  })
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_disable_default_response()

  local addrh = zb_messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(TUYA_CLUSTER_ID) or 0x01,
    zb_const.HA_PROFILE_ID,
    TUYA_CLUSTER_ID
  )

  device:send(zb_messages.ZigbeeMessageTx({
    address_header = addrh,
    body = zcl_messages.ZclMessageBody({
      zcl_header = zclh,
      zcl_body   = generic_body.GenericBody(tuya_payload),
    }),
  }))
end

---------------------------------------------------------------------
-- REFRESH
---------------------------------------------------------------------
local function do_refresh(driver, device, cmd)
  if device.parent_assigned_child_key ~= nil then return end
  local gang_count = get_gang_count(device)
  log.info("do_refresh: triggered by user — querying device types for " .. gang_count .. "-gang panel")

  query_device_types(device, gang_count)

  if dp_map.GANG_TYPE_MAP[gang_count] then
    device.thread:call_with_delay(2, function()
      log.info("do_refresh: second attempt (delayed)")
      send_tuya_cmd(device, TUYA_CMD_SCENE)
    end)
  end
end

---------------------------------------------------------------------
-- CAPABILITY COMMAND HANDLERS
---------------------------------------------------------------------
-- Send several switch DPs in ONE Tuya frame (the MCU drops back-to-back frames)
local function send_dps(device, dps, value)
  if #dps == 1 then return send_dp(device, dps[1], value) end
  SEQ = (SEQ + 1) % 256
  local parts = { string.char(0x00, SEQ) }
  for _, dp in ipairs(dps) do
    parts[#parts + 1] = string.char(dp, 0x01, 0x00, 0x01, value and 0x01 or 0x00)
  end
  local zclh = zcl_messages.ZclHeader({ cmd = data_types.ZCLCommandId(TUYA_CMD_SEND) })
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_disable_default_response()
  local addrh = zb_messages.AddressHeader(
    zb_const.HUB.ADDR, zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(TUYA_CLUSTER_ID) or 0x01,
    zb_const.HA_PROFILE_ID, TUYA_CLUSTER_ID
  )
  device:send(zb_messages.ZigbeeMessageTx({
    address_header = addrh,
    body = zcl_messages.ZclMessageBody({
      zcl_header = zclh,
      zcl_body   = generic_body.GenericBody(table.concat(parts)),
    }),
  }))
end
local function switch_cmd(driver, device, cmd, turn_on)
  if device.parent_assigned_child_key ~= nil then
    local parent = device:get_parent_device()
    if not parent then return end
    local key = device.parent_assigned_child_key
    local dp = MT_CHILD_KEY_TO_DP[key] or ST_CHILD_KEY_TO_DP[key]
    if dp and not dp_is_curtain_relay(parent, dp) then send_dp(parent, dp, turn_on) end
    return
  end

  local comp = cmd.component

  if comp == "main" then
    -- Dashboard button: fire the light(s) chosen by dashboardSwitch.
    -- Curtain relay DPs are filtered out inside dashboard_target_dps().
    local dps = dashboard_target_dps(device)
    if #dps == 0 then
      log.warn("switch_cmd: dashboard button has no light target on this panel")
    end
    send_dps(device, dps, turn_on)
    return
  end

  local dp = (is_multi_tile(device) and MT_COMP_TO_DP[comp]) or ST_COMP_TO_DP[comp] or MT_COMP_TO_DP[comp]
  if not dp then
    log.warn("switch_cmd: unhandled component: " .. tostring(comp))
    return
  end
  if dp_is_curtain_relay(device, dp) then
    log.warn(string.format("switch_cmd: component %s is a curtain relay (dp=0x%02X) — ignoring", comp, dp))
    return
  end
  send_dp(device, dp, turn_on)
end

local function switch_on(driver, device, cmd)  switch_cmd(driver, device, cmd, true)  end
local function switch_off(driver, device, cmd) switch_cmd(driver, device, cmd, false) end

-- setChannelType is read-only — hardware dip-switch controls it; ignore app commands.
local function set_channel_type_noop(driver, device, cmd)
  log.warn(string.format("set_channel_type_noop: ignoring setChannelType (read-only), component=%s value=%s",
    tostring(cmd.component), tostring(cmd.args and cmd.args.value)))
end

local function set_backlight_mode(driver, device, cmd)
  send_dp(device, DP_BL, (cmd.args.value == "on"))
end

local function set_childlock_mode(driver, device, cmd)
  send_dp(device, DP_CL, (cmd.args.value == "enabled"))
end

local function childlock_on(driver, device, cmd)  send_dp(device, DP_CL, true)  end
local function childlock_off(driver, device, cmd) send_dp(device, DP_CL, false) end

---------------------------------------------------------------------
-- CURTAIN COMMAND HELPERS
-- Uses dedicated curtain DPs (0x79/0x7A):
--   cmd=0  stop
--   cmd=1  open 5 min (device's built-in timer)
--   cmd=2  close 5 min (device's built-in timer)
-- The curtainDuration preference is used only for state interpretation
---------------------------------------------------------------------
local function send_curtain_cmd(device, comp_id, cmd_val)
  local col = col_by_comp(device, comp_id)
  local curtain_dp = col and col.cdp
  if not curtain_dp then
    log.warn("send_curtain_cmd: no curtain DP for component " .. tostring(comp_id))
    return
  end
  SEQ = (SEQ + 1) % 256
  local tuya_payload = string.char(
    0x00, SEQ, curtain_dp, 0x04, 0x00, 0x01, cmd_val
  )
  local zclh = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(TUYA_CMD_SEND),
  })
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_disable_default_response()
  local addrh = zb_messages.AddressHeader(
    zb_const.HUB.ADDR, zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(TUYA_CLUSTER_ID) or 0x01,
    zb_const.HA_PROFILE_ID, TUYA_CLUSTER_ID
  )
  log.info(string.format("send_curtain_cmd: comp=%s col=%s dp=0x%02X cmd=%d",
    comp_id, col.key, curtain_dp, cmd_val))
  device:send(zb_messages.ZigbeeMessageTx({
    address_header = addrh,
    body = zcl_messages.ZclMessageBody({
      zcl_header = zclh,
      zcl_body   = generic_body.GenericBody(tuya_payload),
    }),
  }))
end

-- Shared open/close/pause logic.
-- Works for the parent (component curtain1/2/3 or "main") and for curtain
-- child devices (key curtain1/2/3 -> routed through the parent).
local function curtain_action(device, cmd, action)
  local target, comp_id
  local key = device.parent_assigned_child_key
  if key ~= nil then
    target = device:get_parent_device()
    if not target then return end
    comp_id = key
  else
    target  = device
    comp_id = resolve_curtain_comp(device, cmd.component)
  end

  local col = col_by_comp(target, comp_id)
  if not col then
    log.warn(string.format("curtain_%s: %s is not a curtain column on this panel", action, tostring(comp_id)))
    return
  end

  local ts_field, dir_field = "curtain_start_ts_" .. col.key, "curtain_dir_" .. col.key

  if action == "pause" then
    send_curtain_cmd(target, comp_id, dp_map.CURTAIN_CMD_STOP)
    local was_moving = target:get_field(dir_field) ~= nil
    target:set_field(ts_field, nil)
    target:set_field(dir_field, nil)
    if was_moving then
      emit_curtain(target, comp_id, "partially open")
    else
      log.info(string.format("curtain_pause: %s was not moving, keeping state=%s",
        col.key, tostring(target:get_field("curtain_state_" .. col.key))))
    end
    return
  end

  local is_open = (action == "open")
  send_curtain_cmd(target, comp_id, is_open and dp_map.CURTAIN_CMD_OPEN or dp_map.CURTAIN_CMD_CLOSE)
  target:set_field(ts_field, os.time())
  target:set_field(dir_field, is_open and "up" or "down")
  log.info(string.format("curtain_%s: comp=%s col=%s duration=%ds",
    action, comp_id, col.key, get_curtain_duration(target, col)))
  -- No optimistic emit: state update driven by DP 1-6 relay feedback
end

local function curtain_open(driver, device, cmd)  curtain_action(device, cmd, "open")  end
local function curtain_close(driver, device, cmd) curtain_action(device, cmd, "close") end
local function curtain_pause(driver, device, cmd) curtain_action(device, cmd, "pause") end
---------------------------------------------------------------------
local function update_profile(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  local profile_name = get_profile_for_device(device)
  local applied = device:get_field("applied_profile_name")
  if applied and applied ~= profile_name then
    log.info("update_profile: keeping existing applied profile " .. applied
      .. " (would downgrade to " .. profile_name .. ")")
    return
  end
  device:try_update_metadata({ profile = profile_name })
  device:set_field("applied_profile_name", profile_name)
  log.info("Profile set to: " .. profile_name)
end

---------------------------------------------------------------------
-- LIFECYCLE HANDLERS
---------------------------------------------------------------------
local function device_added(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  device:set_field("applied_profile_name", nil)
  update_profile(driver, device)
  local gang_count = get_gang_count(device)
  local pref = device.preferences and device.preferences.createChildDevices
  if pref == "yes" then
    child_utils.create_children(driver, device, gang_count, is_multi_tile(device))
  end
  emit_initial_state(device)
  query_device_types(device, gang_count)
end

local function device_init(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  emit_all_channeltypes(device)
  update_profile(driver, device)
  emit_initial_state(device)
  query_device_types(device, get_gang_count(device))
end

local function driver_switched(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  device:set_field("custom_caps_initialized", nil)
  -- FIX: do NOT clear applied_profile_name here — doing so caused the profile
  -- to downgrade back to the base (non-mixed) profile on every driver switch,
  -- losing the mixed-v2 profile until device type DPs were re-received.
  -- update_profile already guards against unwanted downgrades via the
  -- "applied ~= profile_name" check, so clearing is both unnecessary and harmful.
  update_profile(driver, device)
  log.info("driverSwitched: forced profile refresh")
  emit_initial_state(device)
  query_device_types(device, get_gang_count(device))
end

local function do_configure(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  local already_done = device:get_field("custom_caps_initialized")
  if already_done then return end
  device:set_field("custom_caps_initialized", true)
  log.info("doConfigure: emitting initial state for custom capabilities")
  emit_custom_cap_defaults(device)
end

local function info_changed(driver, device, event, args)
  if device.parent_assigned_child_key ~= nil then return end
  emit_all_channeltypes(device)

  local multi_pref     = get_multitile_mode(device)
  local old_multi_pref = device:get_field("last_multi_tile_pref")
  local old_prefs = args and args.old_st_store and args.old_st_store.preferences
  local multi_changed
  if old_prefs then multi_changed = (old_prefs.multiTileMode ~= (device.preferences or {}).multiTileMode)
  else multi_changed = (multi_pref ~= old_multi_pref) end
  if multi_changed then    device:set_field("last_multi_tile_pref", multi_pref)
    log.info("infoChanged: multiTileMode changed to " .. multi_pref)
    local prev_profile = device:get_field("applied_profile_name")
    device:set_field("applied_profile_name", nil)
    update_profile(driver, device)
    local new_profile = device:get_field("applied_profile_name")
    device:set_field("custom_caps_initialized", nil)
    if new_profile and new_profile == prev_profile then
      log.info("infoChanged: profile unchanged (" .. tostring(new_profile) .. "), emitting state now")
      emit_initial_state(device)
      emit_custom_cap_defaults(device)
      local gang_count = get_gang_count(device)
      local type_map = dp_map.GANG_TYPE_MAP[gang_count] or {}
      for _, entry in ipairs(type_map) do
        local f   = DT_FIELD[entry.dp]
        local raw = f and device:get_field(f)
        if raw ~= nil then emit_channeltype(device, entry.dp, raw) end
      end
      device:set_field("custom_caps_initialized", true)
    else
      device:set_field("profile_switch_pending", true)
    end
    return
  end

  if device:get_field("profile_switch_pending") then
    device:set_field("profile_switch_pending", nil)
    log.info("infoChanged: profile switch settled, emitting initial state")
    emit_initial_state(device)
    emit_custom_cap_defaults(device)
    local gang_count = get_gang_count(device)
    local type_map = dp_map.GANG_TYPE_MAP[gang_count] or {}
    for _, entry in ipairs(type_map) do
      local f   = DT_FIELD[entry.dp]
      local raw = f and device:get_field(f)
      if raw ~= nil then
        emit_channeltype(device, entry.dp, raw)
      end
    end
    device:set_field("custom_caps_initialized", true)
    -- Recreate children to match the settled profile (the initial children may have
    -- been created before device-type DPs arrived, so they used the wrong profile,
    -- e.g. 4x light instead of 1x curtain + 2x light for a mixed panel).
    local pref = device.preferences and device.preferences.createChildDevices
    if pref == "yes" then
      log.info("infoChanged: profile switch settled, recreating children for new profile")
      child_utils.delete_children(driver, device, gang_count)
      child_utils.create_children(driver, device, gang_count, is_multi_tile(device))
    else
      child_utils.delete_children(driver, device, gang_count)  -- new profile has no children
    end
    return
  end

  local pref     = device.preferences and device.preferences.createChildDevices
  local old_pref = device:get_field("last_create_children_pref")
  local children_changed
  if old_prefs then children_changed = (old_prefs.createChildDevices ~= pref)
  else children_changed = (pref ~= old_pref) end
  if children_changed then    device:set_field("last_create_children_pref", pref)
    if pref == "yes" then
      child_utils.create_children(driver, device, get_gang_count(device), is_multi_tile(device))
      log.info("Child devices created")
    elseif pref == "no" then
      child_utils.delete_children(driver, device, get_gang_count(device))
      log.info("Child devices deleted")
    end
  end

  -- Log curtainDuration changes (used at runtime for state interpretation only)
  for _, col in ipairs(get_columns(device)) do
    local new_dur = device.preferences and device.preferences[col.dur]
    local f = "last_" .. col.dur .. "_pref"
    if new_dur ~= device:get_field(f) then
      device:set_field(f, new_dur)
      log.info(string.format("infoChanged: %s (%s col) changed to %s (%ds)",
        col.dur, col.key, tostring(new_dur), get_curtain_duration(device, col)))
    end
  end

  -- dashboardSwitch changed: mirror the newly selected light onto "main"
  local new_db_sw = (device.preferences and device.preferences.dashboardSwitch) or "default"
  if new_db_sw ~= device:get_field("last_dashboard_switch_pref") then
    device:set_field("last_dashboard_switch_pref", new_db_sw)
    log.info("infoChanged: dashboardSwitch changed to " .. new_db_sw)
    if main_has_switch(device) then
      local dp  = dashboard_target_dps(device)[1]
      local src = dp and light_comp_for_dp(device, dp)
      if src then
        local sv  = latest_switch(device, src) or "off"
        emit_switch(device, "main", sv)
        log.info("infoChanged: mirrored " .. src .. " (" .. sv .. ") -> main dashboard")
      end
    end
  end

  local already_done = device:get_field("custom_caps_initialized")
  if already_done then return end

  if not device.profile.components["backlight"] then return end

  device:set_field("custom_caps_initialized", true)
  log.info("infoChanged: emitting initial state for custom capabilities")
  emit_custom_cap_defaults(device)
end

---------------------------------------------------------------------
-- EXPORT
---------------------------------------------------------------------
local M = {}

M.lifecycle_handlers = {
  added          = device_added,
  init           = device_init,
  driverSwitched = driver_switched,
  doConfigure    = do_configure,
  infoChanged    = info_changed,
}

M.capability_handlers = {
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = do_refresh,
  },
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME]  = switch_on,
    [capabilities.switch.commands.off.NAME] = switch_off,
  },
  ["vehiclepatch55148.channelType"] = {
    ["setChannelType"] = set_channel_type_noop,
  },
  ["perfectworld33337.backlightMode"] = {
    ["setBacklightMode"] = set_backlight_mode,
  },
  ["vehiclepatch55148.childlock"] = {
    ["setChildLockMode"] = set_childlock_mode,
    ["on"]               = childlock_on,
    ["off"]              = childlock_off,
  },
  [capabilities.windowShade.ID] = {
    [capabilities.windowShade.commands.open.NAME]  = curtain_open,
    [capabilities.windowShade.commands.close.NAME] = curtain_close,
    [capabilities.windowShade.commands.pause.NAME] = curtain_pause,
  },
}

M.zigbee_handlers = {
  cluster = {
    [TUYA_CLUSTER_ID] = {
      [TUYA_CMD_REPORT] = zigbee_handler,
      [TUYA_CMD_RESP]   = zigbee_handler,
      [TUYA_CMD_QUERY]  = zigbee_handler,
      [TUYA_CMD_SCENE]  = zigbee_handler,
    },
  }
}

return M
