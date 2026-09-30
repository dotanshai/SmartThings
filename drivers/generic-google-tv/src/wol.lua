-- Wake-on-LAN. Only works if the TV has WoL enabled in its network
-- settings (this varies by brand/model -- on most TCL Google TV sets it's
-- under Settings > Network & Internet > your Wi-Fi/Ethernet connection),
-- and only reliably wakes a TV connected over Ethernet; Wi-Fi WoL support
-- is inconsistent across TV hardware even when the OS-level toggle exists.
local cosock_socket = require('cosock.socket')
local log = require('log')

local M = {}

local function mac_to_bytes(mac)
  local hex = mac:gsub('[^0-9a-fA-F]', '')
  assert(#hex == 12, 'MAC address must have 12 hex digits, e.g. AA:BB:CC:DD:EE:FF')
  local out = {}
  for i = 1, 12, 2 do
    out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16))
  end
  return table.concat(out)
end

-- Given an IPv4 address like "192.168.1.137", returns the /24
-- subnet-directed broadcast address "192.168.1.255". This is a common-case
-- assumption (most home networks are /24) -- not universally correct, but
-- a reasonable best-effort guess when we don't know the actual subnet mask.
local function subnet_broadcast(ip)
  local a, b, c = ip:match('^(%d+)%.(%d+)%.(%d+)%.%d+$')
  if not a then return nil end
  return a .. '.' .. b .. '.' .. c .. '.255'
end

local function send_one(packet, ip, port)
  local udp = cosock_socket.udp()
  udp:setsockname('*', 0)
  udp:setoption('broadcast', true)
  local ok, err = udp:sendto(packet, ip, port)
  udp:close()
  return ok ~= nil, err
end

-- Sends a standard Wake-on-LAN magic packet (6 bytes of 0xFF followed by
-- the target MAC address repeated 16 times), to several destinations for
-- better real-world reliability over Wi-Fi:
--   - limited broadcast (255.255.255.255) on ports 9 and 7 (both are used
--     by different WoL implementations; 9 is the modern convention)
--   - the /24 subnet-directed broadcast (e.g. 192.168.1.255), since some
--     access points relay this differently than the limited broadcast
--   - a direct unicast copy to the TV's last-known IP, if provided --
--     some Wi-Fi radios in power-save mode filter broadcast/multicast
--     traffic aggressively but still respond to unicast frames addressed
--     to them specifically, which is a well-documented trick for exactly
--     this "broadcast WoL doesn't reach a sleeping Wi-Fi device" case.
--
-- Returns true if at least one send succeeded (this only confirms the hub
-- put the packet on the wire, never that the TV received or acted on it).
function M.send(mac_address, target_ip)
  local ok_bytes, mac_bytes = pcall(mac_to_bytes, mac_address)
  if not ok_bytes then
    log.warn('[googletv] wol.send: invalid MAC address: ' .. tostring(mac_bytes))
    return nil, tostring(mac_bytes)
  end
  local packet = ('\255'):rep(6) .. mac_bytes:rep(16)

  local targets = { { '255.255.255.255', 9 }, { '255.255.255.255', 7 } }
  if target_ip and target_ip ~= '' then
    local sb = subnet_broadcast(target_ip)
    if sb then targets[#targets + 1] = { sb, 9 } end
    targets[#targets + 1] = { target_ip, 9 }
  end

  local any_ok = false
  for _, t in ipairs(targets) do
    local ip, port = t[1], t[2]
    local ok, err = send_one(packet, ip, port)
    log.info('[googletv-diag] wol.send: -> ' .. ip .. ':' .. port .. ' = ' .. (ok and 'sent' or ('FAILED: ' .. tostring(err))))
    if ok then any_ok = true end
  end

  if not any_ok then
    return nil, 'all send attempts failed'
  end
  return true
end

return M
