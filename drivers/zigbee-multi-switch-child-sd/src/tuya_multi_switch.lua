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

local TUYA_CLUSTER_ID = 0xEF00
local TUYA_CMD_SEND   = 0x00
local TUYA_CMD_REPORT = 0x01
local TUYA_CMD_RESP   = 0x02
local SEQ = 0

-- DP numbers
local DP_SW1  = 1
local DP_SW2  = 2
local DP_SW3  = 3
local DP_SW4  = 4
local DP_SW5  = 5
local DP_SW6  = 6
local DP_MAST = 13
local DP_BL   = 16
local DP_CL   = 101

---------------------------------------------------------------------
-- PROFILE RESOLUTION
-- Strategy:
--   multiTile == "yes"  -> use smarthome4u-Ngang-switch-multi  (main01..N tiles in dashboard)
--   multiTile == "no"   -> use smarthome4u-Ngang-switch         (single tile in dashboard)
-- For 1-gang there is no multi variant; always use the standard profile.
---------------------------------------------------------------------

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

-- Returns true when the device is currently using a multi-tile profile
local function is_multi_tile(device)
  local pref = device.preferences and device.preferences.multiTile or "no"
  return pref == "yes"
end

local function get_profile_for_device(device)
  local mfr   = device:get_manufacturer()
  local count = mfr and MFR_TO_GANG_COUNT[mfr] or 2
  local multi = is_multi_tile(device)

  local base = "smarthome4u-" .. count .. "gang-switch"
  -- 1-gang has no multi variant
  local profile = (multi and count > 1) and (base .. "-multi") or base

  log.info("get_profile_for_device: mfr=" .. tostring(mfr)
    .. " gang=" .. count .. " multi=" .. tostring(multi)
    .. " -> " .. profile)
  return profile
end

---------------------------------------------------------------------
-- DP / COMPONENT MAPS  (mode-aware)
--
-- Single-tile mode (multiTile = no):
--   Components: main (dashboard, mirrors dashboardSwitch pref), sw1, switch2..N, master, backlight, childlock
--
-- Multi-tile mode (multiTile = yes):
--   Components: main (master DP), main01..N (individual gangs), backlight, childlock
---------------------------------------------------------------------

-- single-tile mode
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

-- multi-tile mode
local MT_COMP_TO_DP = {
  main01 = DP_SW1,
  main02 = DP_SW2,
  main03 = DP_SW3,
  main04 = DP_SW4,
  main05 = DP_SW5,
  main06 = DP_SW6,
  -- main is handled dynamically via get_dashboard_dp()
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

-- child key -> DP  (single-tile mode uses "switch1".."switchN" keys;
--                   multi-tile mode uses "main01".."mainNN" keys)
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

-- dashboardSwitch preference value -> DP  (single-tile mode only)
local PREF_TO_DP = {
  sw1    = DP_SW1,
  sw2    = DP_SW2,
  sw3    = DP_SW3,
  sw4    = DP_SW4,
  sw5    = DP_SW5,
  sw6    = DP_SW6,
  master = DP_MAST,
}

-- Return the DP that the single-tile dashboard tile (main) controls
local function get_dashboard_dp(device)
  local pref = device.preferences and device.preferences.dashboardSwitch or "master"
  return PREF_TO_DP[pref] or DP_MAST
end

---------------------------------------------------------------------
-- SEND A TUYA DP BOOL COMMAND
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
-- PARSE RAW TUYA DP FRAME
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
  -- Always use the dedicated "backlight" component (present in both single-tile and multi-tile profiles)
  local comp = device.profile.components["backlight"]
  if comp then
    local mode_val = (value == 1) and "on" or "off"
    device:emit_component_event(
      comp,
      capabilities["vehiclepatch55148.backlight"].backlightMode(mode_val)
    )
  end
end

local function emit_childlock(device, value)
  -- Always use the dedicated "childlock" component (present in both single-tile and multi-tile profiles)
  local comp = device.profile.components["childlock"]
  if comp then
    local mode_val = (value == 1) and "enabled" or "disabled"
    device:emit_component_event(
      comp,
      capabilities["vehiclepatch55148.childlock"].childLockMode(mode_val)
    )
  end
end

---------------------------------------------------------------------
-- EMIT INITIAL STATE
---------------------------------------------------------------------
local function emit_initial_state(device)
  if device.parent_assigned_child_key ~= nil then return end
  local gang_count = get_gang_count(device)

  if is_multi_tile(device) then
    -- Multi-tile mode: main + main01..N
    emit_switch(device, "main", "off")
    for i = 1, gang_count do
      emit_switch(device, "main" .. string.format("%02d", i), "off")
    end
  else
    -- Single-tile mode: main + sw1 + switch2..N + master
    emit_switch(device, "main", "off")
    emit_switch(device, "sw1", "off")
    for i = 2, gang_count do
      emit_switch(device, "switch" .. i, "off")
    end
    if gang_count > 1 then
      emit_switch(device, "master", "off")
    end
  end
end

---------------------------------------------------------------------
-- ZIGBEE HANDLER
---------------------------------------------------------------------
local function zigbee_handler(driver, device, zb_rx)
  metrics.emit_metrics(device, zb_rx)

  local dp, value = parse_tuya_dp(zb_rx)
  if not dp then return end

  log.info("zigbee_handler: dp=" .. tostring(dp) .. " value=" .. tostring(value))

  local sw_val = (value == 1) and "on" or "off"

  if dp == DP_BL then
    emit_backlight(device, value)
    return
  end

  if dp == DP_CL then
    emit_childlock(device, value)
    return
  end

  if is_multi_tile(device) then
    -- ── MULTI-TILE MODE ──────────────────────────────────────────
    local comp_id = MT_DP_TO_COMP[dp]
    -- Mirror to main tile if this DP matches the dashboardSwitch preference
    if dp == get_dashboard_dp(device) then
      emit_switch(device, "main", sw_val)
    end
    if comp_id and comp_id ~= "main" then
      emit_switch(device, comp_id, sw_val)
      -- Also update children (keyed as "main01".."mainNN")
      local child = device:get_child_by_parent_assigned_key(comp_id)
      if child then child:emit_event(capabilities.switch.switch(sw_val)) end
    elseif comp_id == nil then
      log.warn("zigbee_handler (multi): unhandled dp=" .. tostring(dp))
    end
  else
    -- ── SINGLE-TILE MODE ─────────────────────────────────────────
    local comp_id = ST_DP_TO_COMP[dp]

    -- Mirror to dashboard tile (main) if this DP is the selected one
    local dashboard_dp = get_dashboard_dp(device)
    if dp == dashboard_dp then
      emit_switch(device, "main", sw_val)
    end

    if comp_id == "sw1" then
      emit_switch(device, "sw1", sw_val)
      local child = device:get_child_by_parent_assigned_key("switch1")
      if child then child:emit_event(capabilities.switch.switch(sw_val)) end

    elseif comp_id and comp_id ~= "master" then
      emit_switch(device, comp_id, sw_val)
      local child = device:get_child_by_parent_assigned_key(comp_id)
      if child then child:emit_event(capabilities.switch.switch(sw_val)) end

    elseif comp_id == "master" then
      emit_switch(device, "master", sw_val)

    else
      log.warn("zigbee_handler (single): unhandled dp=" .. tostring(dp))
    end
  end
end

---------------------------------------------------------------------
-- CAPABILITY COMMAND HANDLERS
---------------------------------------------------------------------
local function switch_cmd(driver, device, cmd, turn_on)
  -- Child device: route to parent via child key
  if device.parent_assigned_child_key ~= nil then
    local parent = device:get_parent_device()
    if not parent then return end
    local key = device.parent_assigned_child_key
    -- Try multi-tile child key map first, then single-tile
    local dp = MT_CHILD_KEY_TO_DP[key] or ST_CHILD_KEY_TO_DP[key]
    if dp then send_dp(parent, dp, turn_on) end
    return
  end

  -- Parent device
  local comp = cmd.component

  if is_multi_tile(device) then
    -- Multi-tile: direct DP lookup; main uses dashboardSwitch pref (same as single-tile)
    local dp
    if comp == "main" then
      dp = get_dashboard_dp(device)
    else
      dp = MT_COMP_TO_DP[comp]
    end
    if dp then
      send_dp(device, dp, turn_on)
    else
      log.warn("switch_cmd (multi): unhandled component: " .. tostring(comp))
    end
  else
    -- Single-tile: "main" mirrors the selected dashboardSwitch DP
    if comp == "main" then
      send_dp(device, get_dashboard_dp(device), turn_on)
    else
      local dp = ST_COMP_TO_DP[comp]
      if dp then
        send_dp(device, dp, turn_on)
      else
        log.warn("switch_cmd (single): unhandled component: " .. tostring(comp))
      end
    end
  end
end

local function switch_on(driver, device, cmd)  switch_cmd(driver, device, cmd, true)  end
local function switch_off(driver, device, cmd) switch_cmd(driver, device, cmd, false) end

local function set_backlight_mode(driver, device, cmd)
  send_dp(device, DP_BL, (cmd.args.value == "on"))
end

local function set_childlock_mode(driver, device, cmd)
  send_dp(device, DP_CL, (cmd.args.value == "enabled"))
end

local function childlock_on(driver, device, cmd)  send_dp(device, DP_CL, true)  end
local function childlock_off(driver, device, cmd) send_dp(device, DP_CL, false) end

---------------------------------------------------------------------
-- LIFECYCLE HELPERS
---------------------------------------------------------------------
local function update_profile(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  local profile_name = get_profile_for_device(device)
  device:try_update_metadata({ profile = profile_name })
  log.info("Profile set to: " .. profile_name)
end

local function emit_custom_cap_defaults(device)
  log.info("emit_custom_cap_defaults: emitting initial state for custom capabilities")
  -- Always use dedicated backlight/childlock components (present in both single-tile and multi-tile profiles)
  local bl_comp = device.profile.components["backlight"]
  local cl_comp = device.profile.components["childlock"]
  if bl_comp then
    device:emit_component_event(
      bl_comp,
      capabilities["vehiclepatch55148.backlight"].backlightMode("off")
    )
  else
    log.warn("emit_custom_cap_defaults: backlight component not found in profile")
  end
  if cl_comp then
    device:emit_component_event(
      cl_comp,
      capabilities["vehiclepatch55148.childlock"].childLockMode("disabled")
    )
  else
    log.warn("emit_custom_cap_defaults: childlock component not found in profile")
  end
end

---------------------------------------------------------------------
-- LIFECYCLE HANDLERS
---------------------------------------------------------------------
local function device_added(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  update_profile(driver, device)
  local pref = device.preferences and device.preferences.createChildDevices
  if pref == "yes" then
    child_utils.create_children(driver, device, get_gang_count(device), is_multi_tile(device))
  end
  emit_initial_state(device)
end

local function device_init(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  update_profile(driver, device)
  emit_initial_state(device)
end

local function driver_switched(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  device:set_field("custom_caps_initialized", nil)
  update_profile(driver, device)
  log.info("driverSwitched: forced profile refresh")
  emit_initial_state(device)
end

local function do_configure(driver, device)
  if device.parent_assigned_child_key ~= nil then return end
  local already_done = device:get_field("custom_caps_initialized")
  if already_done then return end
  device:set_field("custom_caps_initialized", true)
  log.info("doConfigure: emitting initial state for custom capabilities")
  emit_custom_cap_defaults(device)
end

local function info_changed(driver, device)
  if device.parent_assigned_child_key ~= nil then return end

  -- ── multiTile preference changed ────────────────────────────────
  local multi_pref     = device.preferences and device.preferences.multiTile or "no"
  local old_multi_pref = device:get_field("last_multi_tile_pref")
  if multi_pref ~= old_multi_pref then
    device:set_field("last_multi_tile_pref", multi_pref)
    log.info("infoChanged: multiTile changed to " .. multi_pref)
    -- Switch profile. The profile object in RAM is still the OLD one at this
    -- point; SmartThings fires a second infoChanged ~600ms later once the new
    -- profile is fully loaded. Mark that we need cap defaults on that next call.
    update_profile(driver, device)
    device:set_field("custom_caps_initialized", nil)
    device:set_field("profile_switch_pending", true)
    -- emit_initial_state is deferred to the follow-up infoChanged as well,
    -- because emit_switch also reads the profile components map.
    return
  end

  -- ── Follow-up infoChanged after a profile switch ─────────────────
  -- This fires with the new profile fully loaded in RAM.
  if device:get_field("profile_switch_pending") then
    device:set_field("profile_switch_pending", nil)
    log.info("infoChanged: profile switch settled, emitting initial state")
    emit_initial_state(device)
    emit_custom_cap_defaults(device)
    device:set_field("custom_caps_initialized", true)
    return
  end

  -- ── createChildDevices preference changed ───────────────────────
  local pref     = device.preferences and device.preferences.createChildDevices
  local old_pref = device:get_field("last_create_children_pref")
  if pref ~= old_pref then
    device:set_field("last_create_children_pref", pref)
    if pref == "yes" then
      child_utils.create_children(driver, device, get_gang_count(device), is_multi_tile(device))
      log.info("Child devices created")
    elseif pref == "no" then
      child_utils.delete_children(driver, device, get_gang_count(device))
      log.info("Child devices deleted")
    end
  end

  -- ── dashboardSwitch preference changed (single-tile only) ───────
  local dash_pref     = device.preferences and device.preferences.dashboardSwitch
  local old_dash_pref = device:get_field("last_dashboard_switch_pref")
  if dash_pref ~= old_dash_pref then
    device:set_field("last_dashboard_switch_pref", dash_pref)
    log.info("infoChanged: dashboardSwitch changed to " .. tostring(dash_pref))
    emit_switch(device, "main", "off")
  end

  -- ── Emit custom capability defaults once (normal path) ──────────
  local already_done = device:get_field("custom_caps_initialized")
  if already_done then return end

  -- Verify the profile has the dedicated backlight component before emitting
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
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME]  = switch_on,
    [capabilities.switch.commands.off.NAME] = switch_off,
  },
  ["vehiclepatch55148.backlight"] = {
    ["setBacklightMode"] = set_backlight_mode,
  },
  ["vehiclepatch55148.childlock"] = {
    ["setChildLockMode"] = set_childlock_mode,
    ["on"]               = childlock_on,
    ["off"]              = childlock_off,
  },
}

M.zigbee_handlers = {
  cluster = {
    [TUYA_CLUSTER_ID] = {
      [TUYA_CMD_REPORT] = zigbee_handler,
      [TUYA_CMD_RESP]   = zigbee_handler,
    }
  }
}

return M
