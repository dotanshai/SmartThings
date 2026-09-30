-- Driver-level diagnostics, triggered via the "refresh" capability (tap
-- the refresh/sync icon on the device in the app). Runs the same category
-- of checks as the standalone diagnose_googletv.py tool, but from the
-- hub's own network vantage point -- which is what actually matters for
-- whether the driver itself can reach the TV, as opposed to whether some
-- other PC on the LAN can.
--
-- Everything is logged via log.info/log.warn so it shows up in
-- `smartthings edge:drivers:logcat` -- ask whoever's having trouble to
-- run this (tap refresh, or ask them to) and send the log output.
local log = require('log')

local function try_require(...)
  local candidates = { ... }
  for _, name in ipairs(candidates) do
    local ok, mod = pcall(require, name)
    if ok then return mod end
  end
  return nil
end

local ssl = try_require('cosock.ssl', 'ssl')
local cosock_socket = try_require('cosock.socket')
local cert = require('cert')

local M = {}

local function check_tcp_port(ip, port, timeout)
  local sock = cosock_socket.tcp()
  sock:settimeout(timeout or 5)
  local ok, err = sock:connect(ip, port)
  sock:close()
  if ok then
    return true, 'reachable'
  end
  return false, tostring(err)
end

local function check_tls_handshake(ip, port, timeout)
  local sock = cosock_socket.tcp()
  sock:settimeout(timeout or 5)
  local ok, err = sock:connect(ip, port)
  if not ok then
    return false, 'TCP connect failed: ' .. tostring(err)
  end

  if not ssl then
    sock:close()
    return false, 'no TLS module available on this driver'
  end

  local tls, tls_err = ssl.wrap(sock, {
    mode = 'client',
    protocol = 'any',
    verify = 'none',
    certificates = { { certificate = cert.CERT_PEM, key = cert.KEY_PEM } },
    options = { 'all' },
  })
  if not tls then
    return false, 'TLS wrap failed: ' .. tostring(tls_err)
  end
  tls:settimeout(timeout or 5)

  local retries = 0
  local deadline = os.time() + (timeout or 5)
  local hs_ok, hs_err
  repeat
    hs_ok, hs_err = tls:dohandshake()
    if not hs_ok and (hs_err == 'wantread' or hs_err == 'wantwrite') then
      if os.time() > deadline then
        tls:close()
        return false, 'handshake timed out'
      end
      cosock_socket.sleep(0.05)
    end
  until hs_ok or (hs_err ~= 'wantread' and hs_err ~= 'wantwrite')

  if not hs_ok then
    tls:close()
    return false, 'TLS handshake failed: ' .. tostring(hs_err)
  end

  local peer_cert = tls:getpeercertificate()
  tls:close()
  if peer_cert then
    return true, 'TLS handshake succeeded, TV presented a certificate'
  end
  return true, 'TLS handshake succeeded'
end

-- Runs the full diagnostic and logs a clean, copy-paste-able report.
function M.run(device)
  local ip = device.preferences.ipAddress
  log.info('[googletv-report] ===== Google TV diagnostic report =====')
  log.info('[googletv-report] IP address: ' .. tostring(ip))

  if not ip or ip == '' then
    log.info('[googletv-report] No IP address set in device Settings -- nothing to test. Set it and run this again.')
    return
  end

  local pairing_ok, pairing_detail = check_tcp_port(ip, 6467)
  log.info('[googletv-report] Pairing port (6467): ' .. (pairing_ok and 'REACHABLE' or 'UNREACHABLE') .. ' -- ' .. pairing_detail)

  local remote_ok, remote_detail = check_tcp_port(ip, 6466)
  log.info('[googletv-report] Remote port (6466): ' .. (remote_ok and 'REACHABLE' or 'UNREACHABLE') .. ' -- ' .. remote_detail)

  local tls_ok, tls_detail
  if pairing_ok then
    tls_ok, tls_detail = check_tls_handshake(ip, 6467)
    log.info('[googletv-report] TLS handshake on 6467: ' .. (tls_ok and 'OK' or 'FAILED') .. ' -- ' .. tls_detail)
  else
    log.info('[googletv-report] TLS handshake: SKIPPED (pairing port unreachable)')
  end

  local handle = device:get_field('remote_handle')
  local tv_is_on = device:get_field('tv_is_on')
  log.info('[googletv-report] Current remote connection: ' .. (handle and handle.connected and 'CONNECTED' or 'not connected'))
  log.info('[googletv-report] Last known TV power state: ' .. tostring(tv_is_on))

  log.info('[googletv-report] ----- Verdict -----')
  if tls_ok then
    log.info('[googletv-report] The hub CAN reach and TLS-handshake with this TV. If pairing/commands still fail, the problem is in the driver logic -- send this whole report plus a fresh pairing attempt log.')
  elseif pairing_ok then
    log.info('[googletv-report] The hub can reach the port but TLS failed -- this usually means the device isn\'t running the Android TV Remote service at all (may not be genuine Android TV OS/Google TV).')
  else
    log.info('[googletv-report] The hub cannot reach this IP/port at all. Check: IP address is correct and static, TV is powered on, and the hub and TV are on networks that can reach each other (no VLAN/AP isolation blocking it).')
  end
  log.info('[googletv-report] ===== end of report =====')
end

return M
