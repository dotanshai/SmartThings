-- =====================================================================
-- 8-gang DIN rail controller (TS0601 / _TZE2xx_9kz6bl6s, "CFDIN8-A")
--
-- Runs as a SUB-DRIVER with its own DP map (learned from logs, no docs).
--
-- Front panel:   OUT1 OUT2 OUT3 OUT4
--                OUT5 OUT6 OUT7 OUT8
-- Pair (column) c = OUTc + OUTc+4. Each pair is 2 lights or 1 curtain,
-- set by DIP switch c (C / L) and reported by the module.
--
-- DP map:
--   1-6 / 107 / 108   relay OUT1-6 / OUT7 / OUT8     (bool)
--   13                master (all relays)            (bool)
--   101               unknown (bool)                 - logged only
--   102               curtain jog mode (bool): 1 = Zigbee command = short jog,
--                                             0 = runs until stopped (driver sets 0)
--   111-114           pair 1-4 type (enum: 0 light, 1 curtain)
--
-- Curtain mode has NO curtain DP: the pair's two relays are the motor
-- directions (OUTc = open, OUTc+4 = close, interlocked by the module).
--   short press on the module = jog (relay on, then off ~0.5 s later)
--   long press               = runs until pressed again
--   Zigbee relay command     = jog while DP 102 = 1, continuous when 0
-- The driver switches both relays off after the curtain duration (safety).
--
-- One profile per layout: smarthome4u-8gang-din[-cXXXX]-v2
-- (X = pair 1..4, 1 = curtain; all-light = no suffix)
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
  ["_TZE200_9kz6bl6s"] = true,
  ["_TZE204_9kz6bl6s"] = true,
  ["_TZE284_9kz6bl6s"] = true,
}

local GANGS      = 8
local COLS       = 4
local SW_DPS     = { 1, 2, 3, 4, 5, 6, 107, 108 }
local DP_TO_GANG = {}
for i, dp in ipairs(SW_DPS) do DP_TO_GANG[dp] = i end

local DP_MASTER = 13
local DP_TYPE0  = 110            -- pair c type = 110 + c  (111..114)
local DP_UNKNOWN = { [101] = true }
-- DP 102: curtain "jog" mode. 1 (factory) = a Zigbee relay command is a short
-- jog (~0.5 s); 0 = runs until stopped. Found by test: set to 0 when the
-- layout has a curtain pair (a long press on the module runs either way).
local DP_JOG = 102

local DEFAULT_CURTAIN_SEC = 60
local STOP_SETTLE_SEC     = 1    -- wait before treating "both relays off" as a stop

local FORCE_HIDDEN = { state_change = true, visibility = { displayed = false } }
local CHANNEL_CAP  = "vehiclepatch55148.channelType"
local TAG = "8din"

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

-- This module only acts on the FIRST DP of a multi-DP frame, and may drop
-- back-to-back frames: send one DP per frame, FRAME_GAP seconds apart.
-- items = { {dp, bool}, ... } (sent in order)
local FRAME_GAP = 0.4
local function send_one(device, dp, on)
  log.info(string.format("%s send: %d=%s", TAG, dp, on and "1" or "0"))
  send_frame(device, CMD_SEND, string.char(0x00, next_seq(), dp, 0x01, 0x00, 0x01, on and 0x01 or 0x00))
end

local function send_dps(device, items)
  for i, it in ipairs(items) do
    if i == 1 then send_one(device, it[1], it[2])
    else device.thread:call_with_delay(FRAME_GAP * (i - 1), function() send_one(device, it[1], it[2]) end) end
  end
end

local function send_bools(device, dps, on)
  local items = {}
  for _, dp in ipairs(dps) do items[#items + 1] = { dp, on } end
  send_dps(device, items)
end

local function request_dump(device)
  log.info(TAG .. ": requesting full DP dump")
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
-- LAYOUT
---------------------------------------------------------------------
local function col_type(device, c) return device:get_field("coltype_" .. c) end
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
  if code == nil or code == "0000" then return "smarthome4u-8gang-din-v2" end
  return "smarthome4u-8gang-din-c" .. code .. "-v2"
end

local function light_gangs(device)
  local t = {}
  for g = 1, GANGS do if gang_is_light(device, g) then t[#t + 1] = g end end
  return t
end

---------------------------------------------------------------------
-- DASHBOARD BUTTON + MASTER
---------------------------------------------------------------------
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
-- CURTAINS (driven by the pair's two relays)
---------------------------------------------------------------------
local function curtain_duration(device, c)
  local secs = tonumber((device.preferences or {})["curtainDuration" .. c])
  if secs and secs >= 5 and secs <= 600 then return secs end
  return DEFAULT_CURTAIN_SEC
end

-- relay DPs of pair c: open, close (after the reverse preference)
local function curtain_dps(device, c)
  local top, bottom = SW_DPS[c], SW_DPS[c + COLS]
  return top, bottom
end

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

local function relay_on(device, dp) return device:get_field("relay_" .. dp) == 1 end

-- Called after every relay report of a curtain pair
local function evaluate_curtain(device, c)
  local dp_open, dp_close = curtain_dps(device, c)
  local ts_key, dir_key = "curtain_ts_" .. c, "curtain_dir_" .. c
  local dir = relay_on(device, dp_open) and "up" or (relay_on(device, dp_close) and "down" or nil)

  if dir then
    if device:get_field(dir_key) == dir then return end   -- already running this way
    local start = os.time()
    device:set_field(ts_key, start)
    device:set_field(dir_key, dir)
    device:set_field("curtain_prev_" .. c, device:get_field("curtain_state_" .. c))
    log.info(string.format("%s: curtain %d %s", TAG, c, dir == "up" and "opening" or "closing"))
    emit_curtain(device, c, dir == "up" and "opening" or "closing")
    -- safety: switch the relays off when the run time is over
    device.thread:call_with_delay(curtain_duration(device, c) + 1, function()
      if device:get_field(ts_key) == start then
        log.info(string.format("%s: curtain %d run time over -> relays off", TAG, c))
        send_dps(device, { { dp_open, false }, { dp_close, false } })
      end
    end)
    return
  end

  -- both relays off: wait a moment (reversal reports "off" before "on")
  local start = device:get_field(ts_key)
  if not start then return end
  device.thread:call_with_delay(STOP_SETTLE_SEC, function()
    if device:get_field(ts_key) ~= start then return end
    if relay_on(device, dp_open) or relay_on(device, dp_close) then return end
    local run_dir = device:get_field(dir_key)
    device:set_field(ts_key, nil)
    device:set_field(dir_key, nil)
    local elapsed = os.time() - start
    -- full run, or it was already at that end -> open/closed; short move from elsewhere -> partially open
    local final = (run_dir == "up") and "open" or "closed"
    local state = "partially open"
    if elapsed >= curtain_duration(device, c) or device:get_field("curtain_prev_" .. c) == final then state = final end
    log.info(string.format("%s: curtain %d stopped after %ds -> %s", TAG, c, elapsed, state))
    emit_curtain(device, c, state)
  end)
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
        label = device.label .. " - OUT" .. g, profile = "child-switch",
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
-- "Channel Type - Pair c" text: what the module reports for DIP c
local function emit_channeltypes(device)
  local cap = capabilities[CHANNEL_CAP]
  if not cap then return end
  for c = 1, COLS do
    local t = col_type(device, c)
    if t ~= nil then
      emit(device, "channeltype" .. c, cap.channelType(t == 1 and "curtain" or "light", FORCE_HIDDEN))
    end
  end
end

local function emit_static(device)
  emit_channeltypes(device)
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

-- Curtain pairs need DP 102 = 0 (continuous run from Zigbee)
local function ensure_continuous(device)
  local any = false
  for c = 1, COLS do if col_is_curtain(device, c) then any = true end end
  if any and device:get_field("jog_value") ~= 0 then
    log.info(TAG .. ": curtain layout -> setting dp 102 = 0 (continuous run)")
    send_one(device, DP_JOG, false)
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
    log.info(TAG .. ": layout " .. code .. " -> profile " .. want)
    device:set_field("applied_profile_name", want)
    device:set_field("layout_pending", true)
    device:try_update_metadata({ profile = want })
  end
end

local function handle_type(device, c, value)
  local old = col_type(device, c)
  device:set_field("coltype_" .. c, value, { persist = true })
  local cap = capabilities[CHANNEL_CAP]
  if cap then emit(device, "channeltype" .. c, cap.channelType(value == 1 and "curtain" or "light", FORCE_HIDDEN)) end
  if old ~= value then
    log.info(string.format("%s: pair %d (OUT%d+OUT%d) is %s", TAG, c, c, c + COLS, value == 1 and "CURTAIN" or "light"))
  end
  apply_layout(device)
  if c == COLS then
    device.thread:call_with_delay(2, function() ensure_continuous(device) end)
  end
end

---------------------------------------------------------------------
-- INCOMING DPs
---------------------------------------------------------------------
local function handle_dp(device, dp, dtype, value)
  local gang = DP_TO_GANG[dp]
  if gang then
    device:set_field("relay_" .. dp, value)
    if not gang_is_light(device, gang) then
      evaluate_curtain(device, col_of_gang(gang))
      return
    end
    local val = (value == 1) and "on" or "off"
    log.info(string.format("%s: OUT%d (dp %d) -> %s", TAG, gang, dp, val))
    emit(device, comp_for_gang(gang), capabilities.switch.switch(val))
    local child = device:get_child_by_parent_assigned_key(comp_for_gang(gang))
    if child then child:emit_event(capabilities.switch.switch(val)) end
    refresh_aggregates(device, gang, val)
    return
  end

  if dp > DP_TYPE0 and dp <= DP_TYPE0 + COLS then
    handle_type(device, dp - DP_TYPE0, value)
    return
  end

  if dp == DP_MASTER then return end   -- state derived from the lights

  if dp == DP_JOG then
    device:set_field("jog_value", value)
    log.info(string.format("%s: jog mode (dp 102) = %d", TAG, value))
    return
  end

  if DP_UNKNOWN[dp] then
    log.debug(string.format("%s: dp %d = %d (unknown)", TAG, dp, value))
    return
  end

  log.warn(string.format("%s: unhandled dp=%d type=0x%02X value=%d", TAG, dp, dtype, value))
end

local METRICS_INTERVAL = 60

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
    local gangs = dashboard_gangs(target)
    if #gangs == GANGS then
      send_bools(target, { DP_MASTER }, on)          -- all 8 are lights: master = one frame
    else
      local dps = {}
      for _, g in ipairs(gangs) do dps[#dps + 1] = SW_DPS[g] end
      send_bools(target, dps, on)                    -- one frame per relay
    end
  elseif comp == "master" then
    send_bools(target, { DP_MASTER }, on)
  else
    local n = gang_for_comp(comp)
    if n and gang_is_light(target, n) then send_bools(target, { SW_DPS[n] }, on)
    else log.warn(TAG .. ": switch command ignored for " .. tostring(comp)) end
  end
end

local function switch_on(driver, device, cmd)  switch_cmd(driver, device, cmd, true)  end
local function switch_off(driver, device, cmd) switch_cmd(driver, device, cmd, false) end

-- action: "open" | "close" | "pause". The opposite relay is always switched
-- off first (its own frame, 0.4 s earlier), so both directions are never on together.
local function shade_cmd(device, cmd, action)
  local target, comp = parent_and_key(device, cmd)
  if not target then return end
  local cols = {}
  if comp == "main" then
    for c = 1, COLS do if col_is_curtain(target, c) then cols[#cols + 1] = c end end
  else
    local c = col_for_comp(comp)
    if c and col_is_curtain(target, c) then cols[1] = c end
  end
  if #cols == 0 then log.warn(TAG .. ": curtain command ignored for " .. tostring(comp)) return end
  local items = {}
  for _, c in ipairs(cols) do
    local dp_open, dp_close = curtain_dps(target, c)
    if action == "open" then
      items[#items + 1] = { dp_close, false }; items[#items + 1] = { dp_open, true }
    elseif action == "close" then
      items[#items + 1] = { dp_open, false };  items[#items + 1] = { dp_close, true }
    else
      items[#items + 1] = { dp_open, false };  items[#items + 1] = { dp_close, false }
    end
  end
  send_dps(target, items)
end

local function shade_open(driver, device, cmd)  shade_cmd(device, cmd, "open")  end
local function shade_close(driver, device, cmd) shade_cmd(device, cmd, "close") end
local function shade_pause(driver, device, cmd) shade_cmd(device, cmd, "pause") end

-- Channel type is set by the DIP switches: app changes are ignored
local function set_channel_type_noop(driver, device, cmd)
  log.warn(TAG .. ": channel type is set by the DIP switch on the module - ignored")
  local target = is_child(device) and device:get_parent_device() or device
  if target then emit_channeltypes(target) end
end

local function do_refresh(driver, device, cmd)
  local target = is_child(device) and device:get_parent_device() or device
  if target then request_dump(target) end
end

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

  if device:get_field("layout_pending") then
    device:set_field("layout_pending", nil)
    log.info(TAG .. ": layout settled, re-seeding state")
    emit_initial(device)
    ensure_continuous(device)
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
    log.info(TAG .. ": dashboardSwitch -> " .. tostring(new.dashboardSwitch))
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
  NAME = "tuya_8gang_din_9kz6bl6s",
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
    [CHANNEL_CAP] = {
      ["setChannelType"] = set_channel_type_noop,
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
