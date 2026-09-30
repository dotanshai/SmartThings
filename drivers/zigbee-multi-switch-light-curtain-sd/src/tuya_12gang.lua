-- =====================================================================
-- 12-gang + 2-scene Tuya panel (TS0601 / _TZE2xx_xbaltyob, "14key smart switch")
--
-- Runs as a SUB-DRIVER so the 1/2/3/4/6-gang code is not affected.
-- This panel uses its own DP map (DP 101-107 mean something else here).
--
-- Layout (2 rows x 7):   [Scene1]  1  2  3  4  5  6
--                        [Scene2]  7  8  9 10 11 12
-- Column c (1-6) = top button c + bottom button c+6.
-- A column is either 2 lights or 1 curtain (hardware DIP, reported by the panel).
--
-- DP map (manufacturer sheet + logs):
--   1-6 / 101-106  switch 1-6 / 7-12          (bool)  - light columns only
--   13             master (switch_all)          (bool, issue only)
--   16             backlight                    (bool)
--   107            child lock                   (bool)
--   108            tt_switch                    (not used)
--   109-114        curtain 1-6 control          (enum: 0 open, 1 stop, 2 close,
--                                                        3 l_open, 4 l_close)
--   115-120        device_type column 1-6       (enum: 0 light, 1 curtain)
--   121 / 122      scene 1 / 2 button press     (enum)
--   123            switch all (report)          (bool)
--
-- One profile per layout: smarthome4u-12gang-switch[-cXXXXXX]-v2
-- (X = column 1..6, 1 = curtain; all-light = no suffix)
-- =====================================================================
local capabilities = require "st.capabilities"
local log          = require "log"
local zb_messages  = require "st.zigbee.messages"
local zcl_messages = require "st.zigbee.zcl"
local zb_const     = require "st.zigbee.constants"
local data_types   = require "st.zigbee.data_types"
local generic_body = require "st.zigbee.generic_body"
local metrics      = require "metrics"

local TUYA_CLUSTER = 0xEF00
local CMD_SEND     = 0x00
local CMD_DUMP     = 0x03

local MFRS = {
  ["_TZE200_xbaltyob"] = true,
  ["_TZE204_xbaltyob"] = true,
  ["_TZE284_xbaltyob"] = true,
}

local GANGS       = 12
local COLS        = 6
local SW_DPS      = { 1, 2, 3, 4, 5, 6, 101, 102, 103, 104, 105, 106 }
local DP_TO_GANG  = {}
for i, dp in ipairs(SW_DPS) do DP_TO_GANG[dp] = i end

local DP_MASTER    = 13
local DP_BACKLIGHT = 16
local DP_CHILDLOCK = 107
local DP_TT        = 108
local DP_CURTAIN0  = 108   -- curtain c control = 108 + c   (109..114)
local DP_TYPE0     = 114   -- column c type     = 114 + c   (115..120)
local DP_ALL       = 123
local DP_SCENE     = { [121] = "scene1", [122] = "scene2" }

local CUR_OPEN, CUR_STOP, CUR_CLOSE = 0, 1, 2
local DEFAULT_CURTAIN_SEC = 90

local BACKLIGHT_CAP = "perfectworld33337.backlightMode"
local CHILDLOCK_CAP = "vehiclepatch55148.childlock"
local FORCE         = { state_change = true }
local FORCE_HIDDEN  = { state_change = true, visibility = { displayed = false } }

local SEQ = 0

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------
local function is_child(device) return device.parent_assigned_child_key ~= nil end

local function comp_for_gang(i) return "switch" .. i end
local function comp_for_col(c)  return "curtain" .. c end
local function col_of_gang(g)   return ((g - 1) % COLS) + 1 end

local function gang_for_comp(comp_id)
  local n = comp_id and tonumber(comp_id:match("^switch(%d+)$"))
  if n and n >= 1 and n <= GANGS then return n end
  return nil
end

local function col_for_comp(comp_id)
  local n = comp_id and tonumber(comp_id:match("^curtain(%d+)$"))
  if n and n >= 1 and n <= COLS then return n end
  return nil
end

local function send_frame(device, cmd, payload)
  local zclh = zcl_messages.ZclHeader({ cmd = data_types.ZCLCommandId(cmd) })
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_disable_default_response()
  local addrh = zb_messages.AddressHeader(
    zb_const.HUB.ADDR, zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(TUYA_CLUSTER) or 0x01,
    zb_const.HA_PROFILE_ID, TUYA_CLUSTER)
  device:send(zb_messages.ZigbeeMessageTx({
    address_header = addrh,
    body = zcl_messages.ZclMessageBody({
      zcl_header = zclh,
      zcl_body   = generic_body.GenericBody(payload),
    }),
  }))
end

local function next_seq()
  SEQ = (SEQ + 1) % 256
  return SEQ
end

-- One or more bool DPs in ONE Tuya frame (the MCU drops back-to-back frames)
local function send_bools(device, dps, on)
  if #dps == 0 then return end
  local parts = { string.char(0x00, next_seq()) }
  for _, dp in ipairs(dps) do
    parts[#parts + 1] = string.char(dp, 0x01, 0x00, 0x01, on and 0x01 or 0x00)
  end
  log.info(string.format("12g send: dps=%s value=%s", table.concat(dps, ","), tostring(on)))
  send_frame(device, CMD_SEND, table.concat(parts))
end

local function send_enum(device, dp, value)
  log.info(string.format("12g send: dp=%d enum=%d", dp, value))
  send_frame(device, CMD_SEND, string.char(0x00, next_seq(), dp, 0x04, 0x00, 0x01, value))
end

local function request_dump(device)
  log.info("12g: requesting full DP dump")
  send_frame(device, CMD_DUMP, string.char(0x00, next_seq()))
end

local function has_comp(device, comp_id) return device.profile.components[comp_id] ~= nil end

local function emit(device, comp_id, event)
  local comp = device.profile.components[comp_id]
  if comp then device:emit_component_event(comp, event) end
end

local function latest_switch(device, comp_id)
  local v = device:get_latest_state(comp_id, "switch", "switch")
  if type(v) == "table" then v = v.value end
  return v
end

---------------------------------------------------------------------
-- LAYOUT (which columns are curtains)
---------------------------------------------------------------------
local function col_type(device, c) return device:get_field("coltype_" .. c) end   -- 0 / 1 / nil

local function col_is_curtain(device, c) return col_type(device, c) == 1 end

local function gang_is_light(device, g) return not col_is_curtain(device, col_of_gang(g)) end

local function layout_code(device)
  local s = ""
  for c = 1, COLS do
    local t = col_type(device, c)
    if t == nil then return nil end
    s = s .. (t == 1 and "1" or "0")
  end
  return s
end

local function profile_for(code)
  if code == nil or code == "000000" then return "smarthome4u-12gang-switch-v2" end
  return "smarthome4u-12gang-switch-c" .. code .. "-v2"
end

local function light_gangs(device)
  local t = {}
  for g = 1, GANGS do if gang_is_light(device, g) then t[#t + 1] = g end end
  return t
end

---------------------------------------------------------------------
-- DASHBOARD BUTTON + MASTER
---------------------------------------------------------------------
-- dashboardSwitch: "all" (default) or "switch1".."switch12" (light gangs only)
local function dashboard_gangs(device)
  local pref = (device.preferences or {}).dashboardSwitch or "all"
  local n = gang_for_comp(pref)
  if n and gang_is_light(device, n) then return { n } end
  return light_gangs(device)
end

local function any_on(device, gangs, changed_gang, changed_val)
  for _, g in ipairs(gangs) do
    local v = (g == changed_gang) and changed_val or latest_switch(device, comp_for_gang(g))
    if v == "on" then return true end
  end
  return false
end

-- Emit only when the value changes (a master on/off reports 12 DPs in ~1 s;
-- re-emitting main/master every time floods the cloud and events get dropped)
local function emit_if_changed(device, comp_id, val, force)
  local key = "last_" .. comp_id
  if not force and device:get_field(key) == val then return end
  device:set_field(key, val)
  emit(device, comp_id, capabilities.switch.switch(val))
end

local function refresh_aggregates(device, changed_gang, changed_val, force)
  local main = device.profile.components["main"]
  if main and main.capabilities and main.capabilities["switch"] then
    local on_dash = any_on(device, dashboard_gangs(device), changed_gang, changed_val)
    emit_if_changed(device, "main", on_dash and "on" or "off", force)
  end
  if has_comp(device, "master") then
    local on_all = any_on(device, light_gangs(device), changed_gang, changed_val)
    emit_if_changed(device, "master", on_all and "on" or "off", force)
  end
end

---------------------------------------------------------------------
-- CURTAINS
---------------------------------------------------------------------
local function curtain_duration(device, c)
  local secs = tonumber((device.preferences or {})["curtainDuration" .. c])
  if secs and secs >= 10 and secs <= 600 then return secs end
  return DEFAULT_CURTAIN_SEC
end

-- Card of an all-curtain panel: closed only if all closed, open only if all open
local function emit_main_shade(device)
  local main = device.profile.components["main"]
  if not (main and main.capabilities and main.capabilities["windowShade"]) then return end
  local all_open, all_closed = true, true
  for c = 1, COLS do
    local st = device:get_field("curtain_state_" .. c)
    if st ~= "open" then all_open = false end
    if st ~= "closed" then all_closed = false end
  end
  local agg = all_closed and "closed" or (all_open and "open" or "partially open")
  device:emit_component_event(main, capabilities.windowShade.windowShade(agg))
end

local function emit_curtain(device, c, state)
  device:set_field("curtain_state_" .. c, state, { persist = true })
  emit(device, comp_for_col(c), capabilities.windowShade.windowShade(state))
  local child = device:get_child_by_parent_assigned_key(comp_for_col(c))
  if child then child:emit_event(capabilities.windowShade.windowShade(state)) end
  emit_main_shade(device)
end

-- Curtain control DP report (panel press or echo of our command)
local function handle_curtain(device, c, value)
  if not col_is_curtain(device, c) then
    log.info(string.format("12g: curtain %d report %d but column is light -- ignored", c, value))
    return
  end
  local ts_key, dir_key = "curtain_ts_" .. c, "curtain_dir_" .. c
  if value == CUR_OPEN or value == 3 or value == CUR_CLOSE or value == 4 then
    local up = (value == CUR_OPEN or value == 3)
    local start = os.time()
    device:set_field(ts_key, start)
    device:set_field(dir_key, up and "up" or "down")
    log.info(string.format("12g: curtain %d %s", c, up and "opening" or "closing"))
    emit_curtain(device, c, up and "opening" or "closing")
    local final = up and "open" or "closed"
    device.thread:call_with_delay(curtain_duration(device, c) + 2, function()
      if device:get_field(ts_key) == start then
        device:set_field(ts_key, nil)
        device:set_field(dir_key, nil)
        log.info(string.format("12g: curtain %d run complete -> %s", c, final))
        emit_curtain(device, c, final)
      end
    end)
  elseif value == CUR_STOP then
    local start, dir = device:get_field(ts_key), device:get_field(dir_key)
    device:set_field(ts_key, nil)
    device:set_field(dir_key, nil)
    if start and dir then
      local elapsed = os.time() - start
      local state = "partially open"
      if elapsed >= curtain_duration(device, c) then state = (dir == "up") and "open" or "closed" end
      log.info(string.format("12g: curtain %d stop after %ds -> %s", c, elapsed, state))
      emit_curtain(device, c, state)
    else
      log.info(string.format("12g: curtain %d stop (was idle)", c))
    end
  end
end

---------------------------------------------------------------------
-- CHILD DEVICES
---------------------------------------------------------------------
local function create_children(driver, device)
  for g = 1, GANGS do
    local key = comp_for_gang(g)
    if gang_is_light(device, g) and not device:get_child_by_parent_assigned_key(key) then
      driver:try_create_device({
        type = "EDGE_CHILD", parent_device_id = device.id, parent_assigned_child_key = key,
        label = device.label .. " - Switch " .. g, profile = "child-switch",
      })
    end
  end
  for c = 1, COLS do
    local key = comp_for_col(c)
    if col_is_curtain(device, c) and not device:get_child_by_parent_assigned_key(key) then
      driver:try_create_device({
        type = "EDGE_CHILD", parent_device_id = device.id, parent_assigned_child_key = key,
        label = device.label .. " - Curtain " .. c, profile = "child-curtain",
      })
    end
  end
end

local function delete_children(driver, device)
  for g = 1, GANGS do
    local child = device:get_child_by_parent_assigned_key(comp_for_gang(g))
    if child then driver:try_delete_device(child.id) end
  end
  for c = 1, COLS do
    local child = device:get_child_by_parent_assigned_key(comp_for_col(c))
    if child then driver:try_delete_device(child.id) end
  end
end

---------------------------------------------------------------------
-- STATE SEEDING
---------------------------------------------------------------------
local function emit_static(device)
  local hidden = { visibility = { displayed = false } }
  for _, s in ipairs({ "scene1", "scene2" }) do
    emit(device, s, capabilities.button.supportedButtonValues({ "pushed" }, hidden))
    emit(device, s, capabilities.button.numberOfButtons({ value = 1 }, hidden))
  end
  local bl = device:get_field("cached_backlight_value")
  emit(device, "backlight", capabilities[BACKLIGHT_CAP].backlightMode(bl == 1 and "on" or "off", FORCE_HIDDEN))
  local cl = device:get_field("cached_childlock_value")
  emit(device, "childlock", capabilities[CHILDLOCK_CAP].childLockMode(cl == 1 and "enabled" or "disabled", FORCE_HIDDEN))
  -- curtains: supported buttons + last known state
  local sup = { "open", "close", "pause" }
  for c = 1, COLS do
    if col_is_curtain(device, c) then
      emit(device, comp_for_col(c), capabilities.windowShade.supportedWindowShadeCommands(sup, FORCE_HIDDEN))
      emit(device, comp_for_col(c), capabilities.windowShade.windowShade(device:get_field("curtain_state_" .. c) or "partially open", FORCE_HIDDEN))
      local child = device:get_child_by_parent_assigned_key(comp_for_col(c))
      if child then child:emit_event(capabilities.windowShade.supportedWindowShadeCommands(sup, FORCE_HIDDEN)) end
    end
  end
  local main = device.profile.components["main"]
  if main and main.capabilities and main.capabilities["windowShade"] then
    device:emit_component_event(main, capabilities.windowShade.supportedWindowShadeCommands(sup, FORCE_HIDDEN))
    emit_main_shade(device)
  end
end

local function emit_initial(device)
  for g = 1, GANGS do
    if gang_is_light(device, g) and latest_switch(device, comp_for_gang(g)) == nil then
      emit(device, comp_for_gang(g), capabilities.switch.switch("off"))
    end
  end
  refresh_aggregates(device, nil, nil, true)
  emit_static(device)
end

---------------------------------------------------------------------
-- LAYOUT SWITCHING
---------------------------------------------------------------------
local function apply_layout(device)
  local code = layout_code(device)
  if not code then return end
  local want = profile_for(code)
  if device:get_field("applied_profile_name") ~= want then
    log.info("12g: layout " .. code .. " -> profile " .. want)
    device:set_field("applied_profile_name", want)
    device:set_field("layout_pending", true)
    device:try_update_metadata({ profile = want })
  end
end

local function handle_type(device, c, value)
  local old = col_type(device, c)
  device:set_field("coltype_" .. c, value, { persist = true })
  if old ~= value then
    log.info(string.format("12g: column %d is %s", c, value == 1 and "CURTAIN" or "light"))
  end
  apply_layout(device)
end

---------------------------------------------------------------------
-- INCOMING DPs
---------------------------------------------------------------------
local function handle_dp(device, dp, dtype, value)
  local gang = DP_TO_GANG[dp]
  if gang then
    if not gang_is_light(device, gang) then
      log.info(string.format("12g: relay dp %d belongs to curtain column %d -- ignored", dp, col_of_gang(gang)))
      return
    end
    local val = (value == 1) and "on" or "off"
    log.info(string.format("12g: switch %d (dp %d) -> %s", gang, dp, val))
    emit(device, comp_for_gang(gang), capabilities.switch.switch(val))
    local child = device:get_child_by_parent_assigned_key(comp_for_gang(gang))
    if child then child:emit_event(capabilities.switch.switch(val)) end
    refresh_aggregates(device, gang, val)
    return
  end

  if dp > DP_CURTAIN0 and dp <= DP_CURTAIN0 + COLS then
    handle_curtain(device, dp - DP_CURTAIN0, value)
    return
  end

  if dp > DP_TYPE0 and dp <= DP_TYPE0 + COLS then
    handle_type(device, dp - DP_TYPE0, value)
    return
  end

  if dp == DP_MASTER or dp == DP_ALL then
    log.debug(string.format("12g: master/all dp %d -> %d (state derived from lights)", dp, value))
    return
  end

  if dp == DP_BACKLIGHT then
    device:set_field("cached_backlight_value", value, { persist = true })
    emit(device, "backlight", capabilities[BACKLIGHT_CAP].backlightMode(value == 1 and "on" or "off", FORCE))
    return
  end

  if dp == DP_CHILDLOCK then
    device:set_field("cached_childlock_value", value, { persist = true })
    emit(device, "childlock", capabilities[CHILDLOCK_CAP].childLockMode(value == 1 and "enabled" or "disabled", FORCE))
    return
  end

  local scene = DP_SCENE[dp]
  if scene then
    log.info("12g: " .. scene .. " pressed")
    emit(device, scene, capabilities.button.button.pushed({ state_change = true }))
    return
  end

  if dp == DP_TT then return end

  log.warn(string.format("12g: unhandled dp=%d type=0x%02X value=%d", dp, dtype, value))
end

local METRICS_INTERVAL = 60  -- seconds between signal-quality updates

-- A Tuya frame may carry several DPs: [status][seq] then {dp,type,lenHi,lenLo,data...}*
local function zigbee_handler(driver, device, zb_rx)
  local now = os.time()
  if now - (device:get_field("last_metrics_ts") or 0) >= METRICS_INTERVAL then
    device:set_field("last_metrics_ts", now)
    metrics.emit_metrics(device, zb_rx)
  end
  local body = zb_rx.body and zb_rx.body.zcl_body
  local raw  = body and body.body_bytes
  if type(raw) ~= "string" or #raw < 7 then return end
  local pos = 3
  while pos + 3 <= #raw do
    local dp    = raw:byte(pos)
    local dtype = raw:byte(pos + 1)
    local len   = raw:byte(pos + 2) * 256 + raw:byte(pos + 3)
    if pos + 3 + len > #raw then break end
    local value = 0
    for k = 1, len do value = value * 256 + raw:byte(pos + 3 + k) end
    handle_dp(device, dp, dtype, value)
    pos = pos + 4 + len
  end
end

---------------------------------------------------------------------
-- CAPABILITY HANDLERS
---------------------------------------------------------------------
local function parent_and_key(device, cmd)
  if is_child(device) then return device:get_parent_device(), device.parent_assigned_child_key end
  return device, cmd.component
end

local function switch_cmd(driver, device, cmd, on)
  local target, comp = parent_and_key(device, cmd)
  if not target then return end
  if comp == "main" then
    local dps = {}
    for _, g in ipairs(dashboard_gangs(target)) do dps[#dps + 1] = SW_DPS[g] end
    send_bools(target, dps, on)
  elseif comp == "master" then
    send_bools(target, { DP_MASTER }, on)
  else
    local n = gang_for_comp(comp)
    if n and gang_is_light(target, n) then send_bools(target, { SW_DPS[n] }, on)
    else log.warn("12g: switch command ignored for " .. tostring(comp)) end
  end
end

local function switch_on(driver, device, cmd)  switch_cmd(driver, device, cmd, true)  end
local function switch_off(driver, device, cmd) switch_cmd(driver, device, cmd, false) end

local function shade_cmd(device, cmd, value)
  local target, comp = parent_and_key(device, cmd)
  if not target then return end
  local cols = {}
  if comp == "main" then
    for c = 1, COLS do if col_is_curtain(target, c) then cols[#cols + 1] = c end end
  else
    local c = col_for_comp(comp)
    if c and col_is_curtain(target, c) then cols[1] = c end
  end
  for _, c in ipairs(cols) do send_enum(target, DP_CURTAIN0 + c, value) end
  if #cols == 0 then log.warn("12g: curtain command ignored for " .. tostring(comp)) end
end

local function shade_open(driver, device, cmd)  shade_cmd(device, cmd, 3)  end
local function shade_close(driver, device, cmd) shade_cmd(device, cmd, 4) end
local function shade_pause(driver, device, cmd) shade_cmd(device, cmd, CUR_STOP)  end

local function do_refresh(driver, device, cmd)
  local target = is_child(device) and device:get_parent_device() or device
  if target then request_dump(target) end
end

local function set_backlight(driver, device, cmd)
  send_bools(device, { DP_BACKLIGHT }, cmd.args.value == "on")
end

local function set_childlock(driver, device, cmd)
  send_bools(device, { DP_CHILDLOCK }, cmd.args.value == "enabled")
end
local function childlock_on(driver, device, cmd)  send_bools(device, { DP_CHILDLOCK }, true)  end
local function childlock_off(driver, device, cmd) send_bools(device, { DP_CHILDLOCK }, false) end

---------------------------------------------------------------------
-- LIFECYCLE
---------------------------------------------------------------------
local function device_added(driver, device)
  if is_child(device) then return end
  emit_initial(device)
  if (device.preferences or {}).createChildDevices == "yes" then create_children(driver, device) end
  request_dump(device)
end

local function device_init(driver, device)
  if is_child(device) then return end
  emit_static(device)
  device.thread:call_with_delay(2, function() request_dump(device) end)
end

local function driver_switched(driver, device)
  if is_child(device) then return end
  device:try_update_metadata({ profile = profile_for(layout_code(device)) })
  device.thread:call_with_delay(3, function()
    emit_initial(device)
    request_dump(device)
  end)
end

local function info_changed(driver, device, event, args)
  if is_child(device) then return end
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}

  -- Layout (profile) just changed: re-seed state and rebuild children
  if device:get_field("layout_pending") then
    device:set_field("layout_pending", nil)
    log.info("12g: layout settled, re-seeding state")
    emit_initial(device)
    delete_children(driver, device)
    if new.createChildDevices == "yes" then create_children(driver, device) end
    request_dump(device)
    return
  end

  if new.createChildDevices ~= old.createChildDevices then
    if new.createChildDevices == "yes" then create_children(driver, device)
    else delete_children(driver, device) end
  end
  if new.dashboardSwitch ~= old.dashboardSwitch then
    log.info("12g: dashboardSwitch -> " .. tostring(new.dashboardSwitch))
    refresh_aggregates(device, nil, nil, true)
  end
  emit_static(device)
end

local function do_configure(driver, device)
  if is_child(device) then return end
  request_dump(device)
end

---------------------------------------------------------------------
-- SUB-DRIVER
---------------------------------------------------------------------
local function can_handle(opts, driver, device, ...)
  local d = device
  if device.parent_assigned_child_key ~= nil then
    d = device:get_parent_device()
    if not d then return false end
  end
  local mfr = d:get_manufacturer()
  return mfr ~= nil and MFRS[mfr] == true
end

local sub_driver = {
  NAME = "tuya_12gang_xbaltyob",
  can_handle = can_handle,
  lifecycle_handlers = {
    added          = device_added,
    init           = device_init,
    driverSwitched = driver_switched,
    infoChanged    = info_changed,
    doConfigure    = do_configure,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME]  = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off,
    },
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME]  = shade_open,
      [capabilities.windowShade.commands.close.NAME] = shade_close,
      [capabilities.windowShade.commands.pause.NAME] = shade_pause,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    },
    [BACKLIGHT_CAP] = {
      ["setBacklightMode"] = set_backlight,
    },
    [CHILDLOCK_CAP] = {
      ["setChildLockMode"] = set_childlock,
      ["on"]               = childlock_on,
      ["off"]              = childlock_off,
    },
  },
  zigbee_handlers = {
    cluster = {
      [TUYA_CLUSTER] = {
        [0x01] = zigbee_handler,
        [0x02] = zigbee_handler,
        [0x05] = zigbee_handler,
        [0x06] = zigbee_handler,
      },
    },
  },
}

return sub_driver
