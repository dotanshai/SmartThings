-- Persistent connection to the TV's remote-control port (6466 by default),
-- used once pairing (port 6467) has already succeeded -- the TV recognizes
-- our certificate from here on, no code needed.
--
-- Handshake order below (TV sends RemoteConfigure first, client echoes it
-- back and then announces itself active) matches the documented behavior
-- of the existing open-source clients for this protocol; unlike the
-- pairing secret algorithm (verified against Google's original reference
-- source + a real generated certificate earlier), this handshake sequence
-- is taken from community documentation rather than official source, so
-- it's the most likely place to need a small tweak once tested against a
-- real TV.
local function try_require(...)
  local candidates = { ... }
  local last_err
  for _, name in ipairs(candidates) do
    local ok, mod = pcall(require, name)
    if ok then return mod, name end
    last_err = mod
  end
  return nil, last_err
end

local ssl = try_require('cosock.ssl', 'ssl')
local cosock = require('cosock')
local cosock_socket = try_require('cosock.socket')
local log = require('log')

local cert = require('cert')
local frame = require('frame')
local remotemessage = require('remotemessage')

local M = {}

-- Opens the remote-control TLS connection and completes the handshake.
-- Returns a handle (a table with the tls socket plus a background reader
-- thread) on success, or nil, err_message on failure.
--
-- `on_event(kind, data)` is called from the background reader thread
-- whenever an unsolicited message arrives (kind is 'set_volume' or
-- 'power', currently) so the caller can update SmartThings capability
-- state.
function M.connect(ip, remote_port, on_event)
  if not ssl then
    return nil, 'could not load a TLS module (tried cosock.ssl, ssl) -- check the driver logs for the exact require error'
  end
  if not cosock_socket then
    return nil, 'could not load cosock.socket -- check the driver logs for the exact require error'
  end

  local tcp = cosock_socket.tcp()
  tcp:settimeout(10)
  local ok, err = tcp:connect(ip, remote_port)
  if not ok then
    return nil, 'TCP connect failed: ' .. tostring(err)
  end

  local tls, tls_err = ssl.wrap(tcp, {
    mode = 'client',
    protocol = 'any',
    verify = 'none',
    certificates = { { certificate = cert.CERT_PEM, key = cert.KEY_PEM } },
    options = { 'all' },
  })
  if not tls then
    return nil, 'TLS wrap failed: ' .. tostring(tls_err)
  end

  tls:settimeout(10) -- wrapping for TLS can reset/detach the timeout the raw tcp socket had

  local handshake_ok, handshake_err
  local retries = 0
  repeat
    handshake_ok, handshake_err = tls:dohandshake()
    if not handshake_ok then
      if handshake_err == 'wantread' or handshake_err == 'wantwrite' then
        retries = retries + 1
        if retries > 200 then
          tls:close()
          return nil, 'TLS handshake timed out waiting on ' .. handshake_err
        end
        cosock_socket.sleep(0.05)
      else
        tls:close()
        return nil, 'TLS handshake failed: ' .. tostring(handshake_err) ..
          ' (if this TV was previously paired against a different certificate, delete and re-pair the device)'
      end
    end
  until handshake_ok

  local handle = { tls = tls, connected = true }

  -- Background reader: handles the initial RemoteConfigure handshake, then
  -- keeps answering ping requests and forwarding state updates for as
  -- long as the connection lives.
  local negotiated_features = remotemessage.OUR_DEFAULT_FEATURES

  cosock.spawn(function()
    while handle.connected do
      local payload, rerr = frame.read(tls)
      if not payload then
        log.info('[googletv] remote connection closed: ' .. tostring(rerr))
        handle.connected = false
        break
      end
      local kind, data = remotemessage.parse(payload)
      if kind == 'configure' then
        -- Our reply advertises the intersection of what we support and what
        -- the TV says it supports -- not an echo of whatever it sent, and
        -- NOT followed by an unprompted RemoteSetActive (the server sends
        -- that separately when it's ready; replying to it unprompted was
        -- the earlier bug that caused an immediate disconnect).
        negotiated_features = remotemessage.OUR_DEFAULT_FEATURES & (data.code1 or 0)
        frame.write(tls, remotemessage.build_configure(negotiated_features))
      elseif kind == 'set_active' then
        frame.write(tls, remotemessage.build_set_active(negotiated_features))
      elseif kind == 'ping_request' then
        frame.write(tls, remotemessage.build_ping_response(data.val1 or 0))
      elseif kind == 'set_volume' then
        if on_event then on_event('set_volume', data) end
      elseif kind == 'remote_start' then
        -- The TV proactively sends this whenever its actual power state
        -- changes (including from the physical remote, not just us) --
        -- this is the real signal to track, since the TCP connection
        -- itself can stay alive across power off/on when the TV's Wi-Fi
        -- doesn't fully drop in standby.
        if on_event then on_event('remote_start', data) end
      elseif kind == 'current_app' then
        if on_event then on_event('current_app', data) end
      end
    end
  end, 'googletv-remote-reader')

  return handle
end

-- Sends a single key press (short tap) for `keycode` (see remotemessage.KEYCODE).
function M.send_key(handle, keycode)
  if not handle or not handle.connected then
    return nil, 'not connected'
  end
  local ok = frame.write(handle.tls, remotemessage.build_key_inject(keycode, remotemessage.DIRECTION.SHORT))
  if not ok then
    handle.connected = false
    return nil, 'send failed'
  end
  return true
end

-- Sends a URL as an app-link launch request (used for opening specific apps
-- that register a deep link, e.g. https://www.youtube.com/).
function M.send_app_link(handle, url)
  if not handle or not handle.connected then
    return nil, 'not connected'
  end
  local ok = frame.write(handle.tls, remotemessage.build_app_link(url))
  if not ok then
    handle.connected = false
    return nil, 'send failed'
  end
  return true
end

function M.close(handle)
  if handle then
    handle.connected = false
    if handle.tls then
      pcall(function() handle.tls:close() end)
    end
  end
end

return M
