-- neighbors.lua : Zigbee neighbor tables (ZDO Mgmt_Lqi_req) + ghost removal (ZDO Mgmt_Leave_req)
local log           = require "log"
local messages      = require "st.zigbee.messages"
local zdo           = require "st.zigbee.zdo"
local constants     = require "st.zigbee.constants"
local mgmt_bind_req = require "st.zigbee.zdo.mgmt_bind_request"

local M = {}
local CAP_ID          = "perfectworld33337.zigbeeNeighbors"
local MGMT_LQI_REQ    = 0x0031
local MGMT_LQI_RESP   = 0x8031
local MGMT_LEAVE_REQ  = 0x0034
local MGMT_LEAVE_RESP = 0x8034
local INTERVAL        = 900
local REL       = { [0] = "parent", "child", "sibling", "none", "prev_child" }
local TYPE      = { [0] = "coordinator", "router", "end_device", "unknown" }
local REL_CODE  = { parent = "P", child = "C", sibling = "S", none = "N", prev_child = "X" }
local TYPE_CODE = { coordinator = "Z", router = "R", end_device = "E", unknown = "U" }

local okg, GHOSTS = pcall(require, "ghosts")
if not okg or type(GHOSTS) ~= "table" then GHOSTS = {} end
local GHOST = {}
for _, e in ipairs(GHOSTS) do GHOST[string.upper(e)] = true end

local function hexdump(s)
  local t = {}
  for i = 1, #s do t[#t + 1] = string.format("%02X", s:byte(i)) end
  return table.concat(t, " ")
end

local function hex_rev(s, i, n)
  local t = {}
  for k = i + n - 1, i, -1 do t[#t + 1] = string.format("%02X", s:byte(k)) end
  return table.concat(t)
end

-- Mgmt_Lqi_req payload = 1 byte start index, identical to Mgmt_Bind_req, so reuse that body with cluster 0x0031
function M.request(device, start_index)
  start_index = start_index or 0
  local ok, err = pcall(function()
    local hdr = messages.AddressHeader(constants.HUB.ADDR, 0x00, device:get_short_address(), 0x00,
                                       constants.ZDO_PROFILE_ID, MGMT_LQI_REQ)
    local body = zdo.ZdoMessageBody({ zdo_body = mgmt_bind_req.MgmtBindRequest(start_index) })
    device:send(messages.ZigbeeMessageTx({ address_header = hdr, body = body }))
  end)
  if not ok then log.warn("[NEIGH] request failed: " .. tostring(err)) end
end

local function raw_bytes(zb_rx)
  local cands = {}
  if zb_rx.body then
    cands[#cands + 1] = zb_rx.body.zdo_body
    cands[#cands + 1] = zb_rx.body
  end
  for _, b in ipairs(cands) do
    if type(b) == "table" then
      if type(b.body_bytes) == "string" then return b.body_bytes end
      if type(b.body_bytes) == "table" and type(b.body_bytes.value) == "string" then return b.body_bytes.value end
      for _, f in ipairs({ "_serialize", "serialize" }) do
        if type(b[f]) == "function" then
          local ok, s = pcall(b[f], b)
          if ok and type(s) == "string" and #s > 0 then return s end
        end
      end
    end
  end
  return nil
end

local function parse(p)
  local len = #p
  if (len - 4) % 22 ~= 0 and (len - 5) % 22 == 0 then p = p:sub(2); len = len - 1 end
  if len < 4 then return nil end
  local status, total, start, count = p:byte(1, 4)
  local out = { status = status, total = total, start = start, entries = {} }
  local pos = 5
  for _ = 1, count do
    if pos + 21 > len then break end
    local flags = p:byte(pos + 18)
    out.entries[#out.entries + 1] = {
      eui   = hex_rev(p, pos + 8, 8),
      nwk   = string.format("%04X", p:byte(pos + 16) + p:byte(pos + 17) * 256),
      type  = TYPE[flags & 0x03],
      rel   = REL[(flags >> 4) & 0x07] or "?",
      depth = p:byte(pos + 20),
      lqi   = p:byte(pos + 21),
    }
    pos = pos + 22
  end
  return out
end

local function find_comp(device)
  local cap = require("st.capabilities")[CAP_ID]
  for id, c in pairs(device.profile.components) do
    if device:supports_capability_by_id(CAP_ID, id) then return c, cap end
  end
  return nil, cap
end

function M.status(device, text)
  local ok, err = pcall(function()
    local comp, cap = find_comp(device)
    if comp and cap and cap.lastAction then
      device:emit_component_event(comp, cap.lastAction(text, { visibility = { displayed = false }, state_change = true }))
    end
  end)
  if not ok then log.warn("[NEIGH] status error: " .. tostring(err)) end
end

function M.publish(device, acc)
  local ok, err = pcall(function()
    local comp, cap = find_comp(device)
    if comp == nil then log.warn("[NEIGH] zigbeeNeighbors not in device profile"); return end
    local parts = {}
    for _, e in ipairs(acc) do
      parts[#parts + 1] = string.format("%s,%d,%s,%s", e.eui, e.lqi, REL_CODE[e.rel] or "N", TYPE_CODE[e.type] or "U")
    end
    device:emit_component_event(comp, cap.neighbors(table.concat(parts, ";"), { visibility = { displayed = false }, state_change = true }))
    device:emit_component_event(comp, cap.count(#acc, { visibility = { displayed = false } }))
    log.info(string.format("[NEIGH] published %d neighbors to component %s", #acc, comp.id))
  end)
  if not ok then log.warn("[NEIGH] publish error: " .. tostring(err)) end
end

-- Mgmt_Leave_req: DeviceAddress (IEEE, little endian) + flags (0 = no rejoin, keep children)
function M.leave(device, eui, nwk)
  local ok, err = pcall(function()
    local generic_body = require "st.zigbee.generic_body"
    local b = {}
    for i = 15, 1, -2 do b[#b + 1] = string.char(tonumber(eui:sub(i, i + 1), 16)) end
    local payload = table.concat(b) .. string.char(0x00)
    local function send(dst)
      local hdr = messages.AddressHeader(constants.HUB.ADDR, 0x00, dst, 0x00, constants.ZDO_PROFILE_ID, MGMT_LEAVE_REQ)
      device:send(messages.ZigbeeMessageTx({ address_header = hdr, body = zdo.ZdoMessageBody({ zdo_body = generic_body.GenericBody(payload) }) }))
    end
    device:set_field("last_leave_eui", eui)
    send(device:get_short_address())
    if nwk then send(tonumber(nwk, 16)) end
  end)
  log.info(string.format("[NEIGH] Mgmt_Leave_req for %s via %s: %s", eui, tostring(device.label), ok and "sent" or tostring(err)))
  return ok
end

local function kick_ghosts(device, acc)
  for _, e in ipairs(acc) do
    if GHOST[e.eui] then M.leave(device, e.eui, e.nwk) end
  end
end

function M.handler(driver, device, zb_rx)
  local ok, err = pcall(function()
    local p = raw_bytes(zb_rx)
    if not p then log.warn("[NEIGH] no raw bytes: " .. tostring(zb_rx:pretty_print())); return end
    local r = parse(p)
    if not r then log.warn("[NEIGH] parse failed: " .. hexdump(p)); return end
    local acc = (r.start == 0) and {} or (device:get_field("neigh_acc") or {})
    for _, e in ipairs(r.entries) do acc[#acc + 1] = e end
    device:set_field("neigh_acc", acc)
    if r.status == 0 and #r.entries > 0 and r.start + #r.entries < r.total then
      M.request(device, r.start + #r.entries)
    else
      device:set_field("neighbors", acc)
      log.info(string.format("[NEIGH] %s done: %d neighbors", tostring(device.label), #acc))
      M.publish(device, acc)
      kick_ghosts(device, acc)
    end
  end)
  if not ok then log.warn("[NEIGH] handler error: " .. tostring(err)) end
end

local function leave_rsp(_, device, zb_rx)
  local p = raw_bytes(zb_rx)
  local st = (p and #p > 0) and p:byte(1) or nil
  local eui = device:get_field("last_leave_eui") or "?"
  local txt
  if st == 0 then txt = "Router accepted removal of " .. eui
  elseif st then txt = string.format("Router refused removal of %s (0x%02X) - power-cycle the router to clear it", eui, st)
  else txt = "Could not read the router answer for " .. eui end
  log.info("[NEIGH] Mgmt_Leave_rsp from " .. tostring(device.label) .. ": " .. txt)
  M.status(device, txt)
  device.thread:call_with_delay(10, function() M.request(device, 0) end)
end

local function cmd_leave(driver, device, command)
  local eui = string.upper(tostring((command.args and command.args.eui) or ""))
  if #eui ~= 16 or not eui:match("^%x+$") then M.status(device, "Invalid address: " .. eui); return end
  local nwk = nil
  for _, e in ipairs(device:get_field("neighbors") or {}) do
    if e.eui == eui then nwk = e.nwk end
  end
  if M.leave(device, eui, nwk) then M.status(device, "Removal request sent for " .. eui .. " - waiting for router answer") end
end

function M.add_handlers(template)
  template.zigbee_handlers = template.zigbee_handlers or {}
  template.zigbee_handlers.zdo = template.zigbee_handlers.zdo or {}
  template.zigbee_handlers.zdo[MGMT_LQI_RESP] = M.handler
  template.zigbee_handlers.zdo[MGMT_LEAVE_RESP] = leave_rsp
  template.capability_handlers = template.capability_handlers or {}
  template.capability_handlers[CAP_ID] = template.capability_handlers[CAP_ID] or {}
  template.capability_handlers[CAP_ID]["leaveNeighbor"] = cmd_leave
end

local function poll(driver)
  local delay = 1
  for _, dev in ipairs(driver:get_devices()) do
    if dev.network_type == "DEVICE_ZIGBEE" and not dev:supports_capability_by_id("battery") then
      driver:call_with_delay(delay, function() M.request(dev, 0) end)
      delay = delay + 3
    end
  end
end

function M.start(driver)
  driver:call_with_delay(30, function() pcall(poll, driver) end)
  driver:call_on_schedule(INTERVAL, function() pcall(poll, driver) end, "neighbors_poll")
end

return M