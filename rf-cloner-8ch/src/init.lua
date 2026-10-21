-- Tuya RF Cloner 8CH (TS0601 / _TZE284_tdg4ckyh) Edge Driver
--
-- This device speaks Tuya's proprietary DP protocol over the custom
-- Zigbee cluster 0xEF00 (TuyaEF00) instead of standard ZCL clusters.
-- There is no "official" zigbee-clusters support for this, so we build
-- and parse the 0xEF00 frames by hand, matching the DP map from the
-- zigbee-herdsman-converters definition for this device.
--
-- >>> NOTE ON COMMAND IDS <<<
-- Tuya EF00 command IDs are not fully standardized across devices. This
-- driver assumes the common convention:
--   0x00 = SET_DATA        (hub -> device, write a DP)
--   0x02 = SET_DATA_REPORT (device -> hub, DP value report)
-- If the device never reports state changes back, or never reacts to
-- writes, the first thing to try is swapping these two IDs (search this
-- file for TUYA_CMD_SET_DATA / TUYA_CMD_DATA_REPORT).
--
-- >>> DEBUG LOGGING <<<
-- This build logs heavily on purpose so a test session can be captured
-- from `smartthings.exe edge:drivers:logcat`. Every inbound zigbee
-- message on the EF00 cluster (regardless of command id, not just the
-- one we expect), every outbound DP write, and every capability command
-- received from the app is logged. Once we have a real capture from
-- Effi's testing we can trim this down.

local log = require "log"
local capabilities = require "st.capabilities"
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local zb_const = require "st.zigbee.constants"
local data_types = require "st.zigbee.data_types"
local generic_body = require "st.zigbee.generic_body"

local rfSlot = capabilities["vehiclepatch55148.rfSlot"]
-- NOTE: packetMode is no longer surfaced as a capability on the main
-- card -- it's driven entirely by the "packetMode" Settings preference
-- now (see device_info_changed below). The capability still exists on
-- the platform (harmless, just unused) in case it's ever needed again.

local TUYA_CLUSTER_ID = 0xEF00
local TUYA_CMD_SET_DATA = 0x00
local TUYA_CMD_DATA_REPORT = 0x02

-- Tuya DP type bytes
local DP_TYPE_RAW = 0x00
local DP_TYPE_BOOL = 0x01
local DP_TYPE_VALUE = 0x02
local DP_TYPE_STRING = 0x03
local DP_TYPE_ENUM = 0x04
local DP_TYPE_BITMAP = 0x05

local DP_TYPE_NAME = {
  [DP_TYPE_RAW] = "raw",
  [DP_TYPE_BOOL] = "bool",
  [DP_TYPE_VALUE] = "value",
  [DP_TYPE_STRING] = "string",
  [DP_TYPE_ENUM] = "enum",
  [DP_TYPE_BITMAP] = "bitmap",
}

-- DP ids, taken directly from the Z2M converter's tuyaDatapoints table
local DP_STATE = 117        -- bool, RF learn mode enabled
local DP_PACK = 118         -- bool, false = Short Packet, true = Long Packet
local DP_ILLUMINANCE = 119  -- raw
local DP_BUTTON_BASE = 100  -- button{n} status is on DP 100+n (101..108)
local DP_START_BASE = 108   -- button{n} transmit trigger is on DP 108+n (109..116)

local BUTTON_STATUS = { [0] = "Learn", [1] = "Saved", [2] = "Delete" }
local BUTTON_STATUS_TO_VALUE = { Learn = 0, Saved = 1, Delete = 2 }

local seq_no = 0
local function next_seq()
  seq_no = (seq_no + 1) % 0xFFFF
  return seq_no
end

local function to_hex(bytes)
  if not bytes or #bytes == 0 then return "<empty>" end
  local out = {}
  for i = 1, #bytes do
    out[i] = string.format("%02X", string.byte(bytes, i))
  end
  return table.concat(out, " ")
end

--- Build and send a raw Tuya EF00 "set data" frame for one DP.
local function send_tuya_dp(device, dp_id, dp_type, value_bytes)
  local seq = next_seq()
  local body_bytes = string.char(
    math.floor(seq / 256) % 256, seq % 256,
    dp_id,
    dp_type,
    math.floor(#value_bytes / 256) % 256, #value_bytes % 256
  ) .. value_bytes

  log.info(string.format(
    "[rf-cloner][TX] seq=%d dp=%d type=%s(0x%02X) len=%d value=[%s] full_body=[%s]",
    seq, dp_id, DP_TYPE_NAME[dp_type] or "?", dp_type, #value_bytes,
    to_hex(value_bytes), to_hex(body_bytes)
  ))

  local addr_header = messages.AddressHeader(
    zb_const.HUB.ADDR, zb_const.HUB.ENDPOINT,
    device:get_short_address(), device:get_endpoint(TUYA_CLUSTER_ID) or 1,
    zb_const.HA_PROFILE_ID, TUYA_CLUSTER_ID
  )
  local zcl_header = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(TUYA_CMD_SET_DATA)
  })
  zcl_header.frame_ctrl:set_cluster_specific()
  local zcl_body = generic_body.GenericBody(body_bytes)
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zcl_header,
    zcl_body = zcl_body
  })
  local tx = messages.ZigbeeMessageTx({
    address_header = addr_header,
    body = message_body
  })

  local ok, err = pcall(function() device:send(tx) end)
  if not ok then
    log.error(string.format("[rf-cloner][TX] send failed for dp=%d: %s", dp_id, tostring(err)))
  else
    log.debug(string.format("[rf-cloner][TX] send() call completed for dp=%d, seq=%d", dp_id, seq))
  end
end

local function send_bool_dp(device, dp_id, bool_value)
  send_tuya_dp(device, dp_id, DP_TYPE_BOOL, string.char(bool_value and 1 or 0))
end

local function send_enum_dp(device, dp_id, enum_value)
  send_tuya_dp(device, dp_id, DP_TYPE_ENUM, string.char(enum_value))
end

--- Ask the device to report all its DPs (Tuya dataQuery, cmd 0x03).
local function send_data_query(device)
  local ok, err = pcall(function()
    local addr_header = messages.AddressHeader(
      zb_const.HUB.ADDR, zb_const.HUB.ENDPOINT,
      device:get_short_address(), device:get_endpoint(TUYA_CLUSTER_ID) or 1,
      zb_const.HA_PROFILE_ID, TUYA_CLUSTER_ID
    )
    local zcl_header = zcl_messages.ZclHeader({ cmd = data_types.ZCLCommandId(0x03) })
    zcl_header.frame_ctrl:set_cluster_specific()
    local message_body = zcl_messages.ZclMessageBody({
      zcl_header = zcl_header,
      zcl_body = generic_body.GenericBody("")
    })
    device:send(messages.ZigbeeMessageTx({ address_header = addr_header, body = message_body }))
  end)
  if not ok then log.error("[rf-cloner] dataQuery failed: " .. tostring(err)) end
end

local function query_later(device)
  for _, secs in ipairs({ 4, 15 }) do
    pcall(function() device.thread:call_with_delay(secs, function() send_data_query(device) end) end)
  end
end

--- Extract the trailing number from a component id like "button3" -> 3
local function button_index(component_id)
  local n = tonumber(component_id:match("button(%d+)"))
  if not n then
    log.warn(string.format("[rf-cloner] could not parse button index from component '%s'", tostring(component_id)))
  end
  return n
end

-------------------------------------------------------------------
-- Incoming DP report handling
-------------------------------------------------------------------

local function bytes_to_uint(bytes)
  local n = 0
  for i = 1, #bytes do
    n = n * 256 + string.byte(bytes, i)
  end
  return n
end

local function handle_dp_report(driver, device, dp_id, dp_type, value_bytes)
  log.info(string.format(
    "[rf-cloner][DP] dp=%d type=%s(0x%02X) len=%d value_hex=[%s] value_uint=%d",
    dp_id, DP_TYPE_NAME[dp_type] or "?", dp_type, #value_bytes,
    to_hex(value_bytes), bytes_to_uint(value_bytes)
  ))

  if dp_id == DP_STATE then
    local on = (string.byte(value_bytes, 1) or 0) ~= 0
    log.info(string.format("[rf-cloner][DP] DP_STATE -> switch.%s", on and "on" or "off"))
    device.profile.components["main"]:emit_event(on and capabilities.switch.switch.on() or capabilities.switch.switch.off())

  elseif dp_id == DP_PACK then
    local long_mode = (string.byte(value_bytes, 1) or 0) ~= 0
    -- no attribute to emit here anymore (packet mode is a write-only
    -- Settings preference now) -- just log it for visibility
    log.info(string.format("[rf-cloner][DP] DP_PACK report: device now reports %s", long_mode and "Long Packet" or "Short Packet"))

  elseif dp_id == DP_ILLUMINANCE then
    -- device sends this as a raw DP rather than a typed "value" DP;
    -- best-effort big-endian integer interpretation, verify against
    -- real readings and adjust if the scale looks wrong.
    local lux = bytes_to_uint(value_bytes)
    log.info(string.format("[rf-cloner][DP] DP_ILLUMINANCE raw_hex=[%s] -> illuminance=%d (VERIFY against a known light level)", to_hex(value_bytes), lux))
    device.profile.components["main"]:emit_event(capabilities.illuminanceMeasurement.illuminance(lux))

  elseif dp_id > DP_BUTTON_BASE and dp_id <= DP_BUTTON_BASE + 8 then
    local n = dp_id - DP_BUTTON_BASE
    local raw_status = string.byte(value_bytes, 1) or -1
    local status = BUTTON_STATUS[raw_status]
    log.info(string.format("[rf-cloner][DP] button%d status raw=%d -> %s", n, raw_status, status or "UNKNOWN"))
    if status then
      local comp = device.profile.components["button" .. n]
      if comp then
        comp:emit_event(rfSlot.status(status))
      else
        log.error(string.format("[rf-cloner][DP] no component found for button%d", n))
      end
    else
      log.warn(string.format("[rf-cloner][DP] unrecognized button status value %d on dp=%d", raw_status, dp_id))
    end

  elseif dp_id > DP_START_BASE and dp_id <= DP_START_BASE + 8 then
    -- DPs 109-116 (start1..start8) are write-only triggers; device is
    -- not expected to report them back, but log it if it ever does.
    log.info(string.format("[rf-cloner][DP] unexpected report on transmit-trigger dp=%d (button%d)", dp_id, dp_id - DP_START_BASE))

  else
    log.warn(string.format("[rf-cloner][DP] unmapped dp=%d type=%s len=%d value_hex=[%s] -- new/unknown datapoint, capture this and tell Shai", dp_id, DP_TYPE_NAME[dp_type] or "?", #value_bytes, to_hex(value_bytes)))
  end
end

--- Parses one or more back-to-back DP records out of a EF00 body.
-- Some Tuya devices batch multiple DPs in a single frame; we loop
-- until the body is consumed instead of assuming exactly one DP.
local function parse_and_handle_dps(driver, device, body)
  local offset = 3 -- skip 2-byte seq, DP record starts at byte 3
  local dp_count = 0
  while offset + 4 <= #body do
    local dp_id = string.byte(body, offset)
    local dp_type = string.byte(body, offset + 1)
    local len = string.byte(body, offset + 2) * 256 + string.byte(body, offset + 3)
    local value_start = offset + 4
    local value_end = value_start + len - 1
    if value_end > #body then
      log.error(string.format(
        "[rf-cloner][RX] declared dp len=%d overruns body (offset=%d, body_len=%d) -- stopping parse, raw body=[%s]",
        len, offset, #body, to_hex(body)
      ))
      break
    end
    local value_bytes = body:sub(value_start, value_end)
    dp_count = dp_count + 1
    handle_dp_report(driver, device, dp_id, dp_type, value_bytes)
    offset = value_end + 1
  end
  if dp_count == 0 then
    log.warn(string.format("[rf-cloner][RX] parsed zero DPs out of body -- unexpected frame shape, raw body=[%s]", to_hex(body)))
  elseif offset <= #body then
    log.warn(string.format("[rf-cloner][RX] %d trailing unparsed byte(s) after %d dp(s): [%s]", #body - offset + 1, dp_count, to_hex(body:sub(offset))))
  end
end

--- Registered against TUYA_CMD_DATA_REPORT specifically.
local signal_cap = capabilities["vehiclepatch55148.signalMetrics"]
local function emit_signal(device, zb_rx)
  pcall(function() device:online() end)
  pcall(function()
    if zb_rx and zb_rx.lqi and zb_rx.rssi then
      local lqi = tonumber(zb_rx.lqi.value)
      local rssi = tonumber(zb_rx.rssi.value)
      if lqi and rssi then
        device:emit_event(signal_cap.signalMetrics({ value = string.format("LQI: %d | RSSI: %d dBm", lqi, rssi) }))
      end
    end
  end)
end
local function tuya_data_report_handler(driver, device, zb_rx)
  emit_signal(device, zb_rx)
  local body = zb_rx.body.zcl_body.body_bytes
  log.info(string.format("[rf-cloner][RX] EF00 cmd=0x%02X (expected data-report) body=[%s]", TUYA_CMD_DATA_REPORT, to_hex(body)))
  if not body or #body < 6 then
    log.warn(string.format("[rf-cloner][RX] body too short (%d bytes) to contain a DP record", body and #body or 0))
    return
  end
  parse_and_handle_dps(driver, device, body)
end

--- Catch-all for ANY EF00 cluster command, so if the device is using a
-- different command id than we assumed, we still see and log the raw
-- frame instead of silently dropping it. This is the most useful log
-- line if buttons don't seem to do anything during testing.
local function tuya_time_sync_handler(driver, device, zb_rx)
  emit_signal(device, zb_rx)
  local ok, err = pcall(function()
    local req = zb_rx.body.zcl_body.body_bytes or ""
    local s1, s2 = 0, 0
    if #req >= 2 then s1 = string.byte(req, 1); s2 = string.byte(req, 2) end
    local utc = os.time()
    local loc = utc + (os.time(os.date("*t", utc)) - os.time(os.date("!*t", utc)))
    local function be32(n)
      return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    end
    local payload = string.char(s1, s2) .. be32(utc) .. be32(loc)
    local addr_header = messages.AddressHeader(
      zb_const.HUB.ADDR, zb_const.HUB.ENDPOINT,
      device:get_short_address(), device:get_endpoint(TUYA_CLUSTER_ID) or 1,
      zb_const.HA_PROFILE_ID, TUYA_CLUSTER_ID
    )
    local zcl_header = zcl_messages.ZclHeader({ cmd = data_types.ZCLCommandId(0x24) })
    zcl_header.frame_ctrl:set_cluster_specific()
    local message_body = zcl_messages.ZclMessageBody({
      zcl_header = zcl_header,
      zcl_body = generic_body.GenericBody(payload)
    })
    device:send(messages.ZigbeeMessageTx({ address_header = addr_header, body = message_body }))
    log.info("[rf-cloner][TX] time sync reply sent")
  end)
  if not ok then log.error("[rf-cloner] time sync failed: " .. tostring(err)) end
end
local function tuya_cluster_catchall_handler(driver, device, zb_rx)
  emit_signal(device, zb_rx)
  local cmd_id = zb_rx.body.zcl_header.cmd.value
  local body = zb_rx.body.zcl_body.body_bytes
  log.info(string.format(
    "[rf-cloner][RX][catchall] EF00 frame received, cmd=0x%02X, body=[%s]",
    cmd_id, to_hex(body)
  ))
  if cmd_id == TUYA_CMD_DATA_REPORT then
    return -- already handled by the dedicated handler above
  end
  -- Try parsing it anyway in case this device reports on a different
  -- command id than 0x02 -- if this logs sensible-looking DPs, update
  -- TUYA_CMD_DATA_REPORT to match cmd_id above.
  if body and #body >= 6 then
    log.info(string.format("[rf-cloner][RX][catchall] attempting best-effort DP parse of cmd=0x%02X body anyway", cmd_id))
    parse_and_handle_dps(driver, device, body)
  end
end

-------------------------------------------------------------------
-- Outgoing capability command handlers
-------------------------------------------------------------------

local function switch_on_handler(driver, device, command)
  log.info(string.format("[rf-cloner][CMD] switch.on received on component=%s", command.component))
  send_bool_dp(device, DP_STATE, true)
end

local function switch_off_handler(driver, device, command)
  log.info(string.format("[rf-cloner][CMD] switch.off received on component=%s", command.component))
  send_bool_dp(device, DP_STATE, false)
end

local function rf_slot_learn_handler(driver, device, command)
  log.info(string.format("[rf-cloner][CMD] rfSlot.learn received on component=%s", command.component))
  local n = button_index(command.component)
  if not n then return end
  send_bool_dp(device, DP_STATE, true)
  device.profile.components["main"]:emit_event(capabilities.switch.switch.on())
  send_enum_dp(device, DP_BUTTON_BASE + n, BUTTON_STATUS_TO_VALUE.Learn)
  query_later(device)
end

local function rf_slot_delete_handler(driver, device, command)
  log.info(string.format("[rf-cloner][CMD] rfSlot.delete received on component=%s", command.component))
  local n = button_index(command.component)
  if not n then return end
  send_enum_dp(device, DP_BUTTON_BASE + n, BUTTON_STATUS_TO_VALUE.Delete)
  query_later(device)
end

local function rf_slot_transmit_handler(driver, device, command)
  log.info(string.format("[rf-cloner][CMD] rfSlot.transmit received on component=%s", command.component))
  local n = button_index(command.component)
  if not n then return end
  send_enum_dp(device, DP_START_BASE + n, 0) -- 0 = Transmit
  query_later(device)
end

-------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------

-------------------------------------------------------------------
-- Slot button child devices (momentary Push -> Transmit)
-------------------------------------------------------------------

local function is_child_device(device)
  return device.parent_assigned_child_key ~= nil and device.parent_assigned_child_key ~= ""
end

local function delete_slot_children(driver, device)
  for n = 1, 8 do
    local key = "slot" .. n
    local child = device:get_child_by_parent_assigned_key(key)
    if child then
      local ok, err = pcall(function() driver:try_delete_device(child.id) end)
      if ok then
        log.info(string.format("[rf-cloner][CHILD] deleted %s", key))
      else
        log.error(string.format("[rf-cloner][CHILD] delete %s failed: %s", key, tostring(err)))
      end
    end
  end
end

local function create_slot_children(driver, device)  for n = 1, 8 do
    local key = "slot" .. n
    if not device:get_child_by_parent_assigned_key(key) then
      local ok, err = pcall(function()
        driver:try_create_device({
          type = "EDGE_CHILD",
          label = string.format("RF Slot %d", n),
          profile = "rf-slot-switch",
          parent_device_id = device.id,
          parent_assigned_child_key = key,
        })
      end)
      if ok then
        log.info(string.format("[rf-cloner][CHILD] created %s", key))
      else
        log.error(string.format("[rf-cloner][CHILD] create %s failed: %s", key, tostring(err)))
      end
    end
  end
end

local function child_switch_on(driver, device, command)
  local parent = device:get_parent_device()
  local key = device.parent_assigned_child_key
  local n = key and tonumber(key:match("^slot(%d)$"))
  if not parent or not n then
    log.warn("[rf-cloner][CHILD] press on a device with no parent/slot, ignoring")
    device:emit_event(capabilities.switch.switch.off())
    return
  end
  log.info(string.format("[rf-cloner][CHILD] slot %d pressed -> transmit", n))
  send_enum_dp(parent, DP_START_BASE + n, 0)
  query_later(parent)
  device:emit_event(capabilities.switch.switch.on())
  local ok = pcall(function()
    device.thread:call_with_delay(1.5, function()
      device:emit_event(capabilities.switch.switch.off())
    end)
  end)
  if not ok then device:emit_event(capabilities.switch.switch.off()) end
end

local function child_switch_off(driver, device, command)
  device:emit_event(capabilities.switch.switch.off())
end
local function device_added(driver, device)
  if is_child_device(device) then
    device:emit_event(capabilities.switch.switch.off())
    return
  end
  log.info(string.format("[rf-cloner][LIFECYCLE] added: id=%s network_id=%s", device.id, tostring(device:get_short_address())))
  device.profile.components["main"]:emit_event(capabilities.switch.switch.off())
  send_data_query(device)
end

local function rf_send_basic_reads(device)
  pcall(function()
    local clusters = require "st.zigbee.zcl.clusters"
    local B = clusters.Basic.attributes
    device:send(B.ZCLVersion:read(device))
    device:send(B.ApplicationVersion:read(device))
    device:send(B.ManufacturerName:read(device))
    device:send(B.ModelIdentifier:read(device))
    device:send(B.PowerSource:read(device))
    log.info("[rf-cloner][TX] basic attribute reads sent")
    device.thread:call_with_delay(5, function() pcall(send_data_query, device) end)
  end)
end
local keepalive_started = {}
local function rf_start_keepalive(device)
  if keepalive_started[device.id] then return end
  keepalive_started[device.id] = true
  pcall(function()
    device.thread:call_on_schedule(300, function() pcall(send_data_query, device) end, "rf_keepalive")
  end)
end
local function device_init(driver, device)
  if is_child_device(device) then return end
  rf_start_keepalive(device)
  rf_send_basic_reads(device)
  if false and not device:get_field("rf_profile_v2") then
    log.info("[PROFILE] migrating device to rf-cloner-8ch-v2")
    local okp = pcall(function() device:try_update_metadata({ profile = "rf-cloner-8ch-v2" }) end)
    if okp then device:set_field("rf_profile_v2", true, { persist = true }) end
  end
  log.info(string.format("[rf-cloner][LIFECYCLE] init: id=%s", device.id))
  send_data_query(device)
end

local PREF_ACTION_TO_DP_VALUE = { learn = BUTTON_STATUS_TO_VALUE.Learn, delete = BUTTON_STATUS_TO_VALUE.Delete }

local function device_info_changed(driver, device, event, args)
  if is_child_device(device) then return end
  log.debug(string.format("[rf-cloner][LIFECYCLE] infoChanged: id=%s", device.id))

  if not (args and args.old_st_store and args.old_st_store.preferences) then
    log.debug("[rf-cloner][PREF] infoChanged fired with no old preferences to diff against, skipping")
    return
  end

  local old_prefs = args.old_st_store.preferences
  local new_prefs = device.preferences

  if new_prefs.createSlotButtons and not old_prefs.createSlotButtons then
    log.info("[rf-cloner][PREF] createSlotButtons turned on")
    create_slot_children(driver, device)
  elseif old_prefs.createSlotButtons and not new_prefs.createSlotButtons then
    log.info("[rf-cloner][PREF] createSlotButtons turned off")
    delete_slot_children(driver, device)
  end

  if old_prefs.packetMode ~= new_prefs.packetMode then
    log.info(string.format("[rf-cloner][PREF] packetMode changed: %s -> %s", tostring(old_prefs.packetMode), tostring(new_prefs.packetMode)))
    send_bool_dp(device, DP_PACK, new_prefs.packetMode == "long")
  end

  for n = 1, 8 do
    local pref_name = "button" .. n .. "Action"
    local old_val = old_prefs[pref_name]
    local new_val = new_prefs[pref_name]
    if old_val ~= new_val then
      log.info(string.format("[rf-cloner][PREF] %s changed: %s -> %s", pref_name, tostring(old_val), tostring(new_val)))
      local dp_value = PREF_ACTION_TO_DP_VALUE[new_val]
      if dp_value then
        if new_val == "learn" then
          send_bool_dp(device, DP_STATE, true)
          device.profile.components["main"]:emit_event(capabilities.switch.switch.on())
        end
        send_enum_dp(device, DP_BUTTON_BASE + n, dp_value)
      elseif new_val ~= "none" then
        log.warn(string.format("[rf-cloner][PREF] unrecognized value '%s' for %s, ignoring", tostring(new_val), pref_name))
      end
    end
  end
end

local function device_doConfigure(driver, device)
  if is_child_device(device) then return end
  log.info(string.format("[rf-cloner][LIFECYCLE] doConfigure: id=%s", device.id))
  device:configure()
  send_data_query(device)
end

local rf_cloner_driver_template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.illuminanceMeasurement,
    rfSlot,
    signal_cap,
  },
  zigbee_handlers = {
    cluster = {
      [TUYA_CLUSTER_ID] = {
        [TUYA_CMD_DATA_REPORT] = tuya_data_report_handler,
        [TUYA_CMD_SET_DATA] = tuya_cluster_catchall_handler,
        [0x01] = tuya_cluster_catchall_handler,
        [0x03] = tuya_cluster_catchall_handler,
        [0x04] = tuya_cluster_catchall_handler,
        [0x05] = tuya_cluster_catchall_handler,
        [0x06] = tuya_cluster_catchall_handler,
        [0x24] = tuya_time_sync_handler,
      }
    }
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = function(driver, device, command)
        if is_child_device(device) then return child_switch_on(driver, device, command) end
        return switch_on_handler(driver, device, command)
      end,
      [capabilities.switch.commands.off.NAME] = function(driver, device, command)
        if is_child_device(device) then return child_switch_off(driver, device, command) end
        return switch_off_handler(driver, device, command)
      end,
    },
    [rfSlot.ID] = {
      -- learn/delete are no longer exposed as on-card buttons (moved to
      -- Settings preferences below to prevent accidental taps), but the
      -- handlers stay registered in case they're ever invoked directly
      -- via the API or an automation.
      [rfSlot.commands.learn.NAME] = rf_slot_learn_handler,
      [rfSlot.commands.delete.NAME] = rf_slot_delete_handler,
      [rfSlot.commands.transmit.NAME] = rf_slot_transmit_handler,
    },
  },
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    infoChanged = device_info_changed,
    doConfigure = device_doConfigure,
  },
}

local ZigbeeDriver = require "st.zigbee"
local rf_cloner_driver = ZigbeeDriver("rf-cloner-8ch", rf_cloner_driver_template)
log.info("[rf-cloner] driver starting (v3)")
rf_cloner_driver:run()
