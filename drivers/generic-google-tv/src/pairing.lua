-- Pairing state machine for the Android TV Remote v2 protocol's pairing
-- port (6467 by default).
--
-- The secret-computation algorithm (M._compute_secret below) is Google's
-- original "Polo" pairing algorithm, ported directly from the official
-- Java reference implementation:
--   https://android.googlesource.com/platform/external/google-tv-pairing-protocol/+/7c99785/java/src/com/google/polo/pairing/PoloChallengeResponse.java
-- cross-checked against a working v2 JavaScript port. It is NOT a guess:
--   secret = SHA256(client_modulus || client_exponent ||
--                    server_modulus || server_exponent || nonce)
-- where modulus/exponent are the raw unsigned big-endian bytes of each
-- side's RSA public key (leading 0x00 sign byte stripped), and nonce is
-- the middle 2 bytes of the 6-character pairing code shown on the TV
-- (bytes 2-3, i.e. hex characters 3-6 of the code) -- the first byte of
-- the code is a checksum the client uses to sanity-check its own math
-- against, before it commits to sending the wrong secret.
-- Resolves a module by trying several possible require paths in order and
-- using whichever one loads. This driver got burned once already by
-- guessing a require path wrong (require("ssl") vs require("cosock.ssl"))
-- and having that crash the ENTIRE driver at load time -- which looks to
-- the user like "nothing happens, no devices, no logs" because the driver
-- process never starts. Guessing wrong here should never again be able to
-- take down device discovery for every other capability.
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
local der = require('der')
local base64 = require('base64')
local sha256 = require('sha256')
local frame = require('frame')
local pairingmessage = require('pairingmessage')

local M = {}

-- Our own certificate's RSA key material, computed once at load time from
-- the bundled cert (see cert.lua) so we don't need to re-derive it from
-- our own TLS socket at pairing time.
local OUR_MODULUS, OUR_EXPONENT
do
  local ok, der_bytes = pcall(base64.pem_to_der, cert.CERT_PEM)
  if ok then
    local ok2, m, e = pcall(der.rsa_pubkey_from_cert_der, der_bytes)
    if ok2 then
      OUR_MODULUS, OUR_EXPONENT = m, e
    end
  end
end

-- Converts a hex-digit-only code string like "123456" into raw bytes,
-- e.g. "123456" -> "\x12\x34\x56".
local function to_hex(s)
  local out = {}
  for i = 1, #s do out[#out + 1] = string.format('%02x', s:byte(i)) end
  return table.concat(out, ' ')
end

local function hex_to_bytes(hexstr)
  local out = {}
  for i = 1, #hexstr, 2 do
    out[#out + 1] = string.char(tonumber(hexstr:sub(i, i + 1), 16))
  end
  return table.concat(out)
end

-- Computes the full SHA-256 "alpha" hash used both for the client's own
-- checksum verification and as the PairingSecret payload.
function M._compute_alpha(server_modulus, server_exponent, nonce_bytes)
  local msg = OUR_MODULUS .. OUR_EXPONENT .. server_modulus .. server_exponent .. nonce_bytes
  return sha256.digest(msg)
end

-- Starts a pairing session: opens a TLS connection to ip:pairing_port using
-- our bundled client certificate, exchanges PairingRequest/Option/
-- Configuration, and returns a handle once the TV is ready to show a
-- pairing code (i.e. once PairingConfigurationAck has been received).
--
-- This is meant to be called from inside a cosock coroutine (e.g. one
-- spawned by the driver's settings-changed handler) since it blocks on
-- network I/O the cosock way.
--
-- Returns handle, nil on success, or nil, err_message on failure.
function M.start(ip, pairing_port, client_name)
  if not OUR_MODULUS then
    return nil, 'bundled client certificate could not be parsed at load time'
  end
  if not ssl then
    return nil, 'could not load a TLS module (tried cosock.ssl, ssl) -- check the driver logs for the exact require error'
  end
  if not cosock_socket then
    return nil, 'could not load cosock.socket -- check the driver logs for the exact require error'
  end

  log.info('[googletv-diag] pairing.start: creating tcp socket')
  local tcp = cosock_socket.tcp()
  tcp:settimeout(10)
  log.info('[googletv-diag] pairing.start: connecting to ' .. tostring(ip) .. ':' .. tostring(pairing_port))
  local ok, err = tcp:connect(ip, pairing_port)
  log.info('[googletv-diag] pairing.start: connect returned ok=' .. tostring(ok) .. ' err=' .. tostring(err))
  if not ok then
    return nil, 'TCP connect failed: ' .. tostring(err)
  end

  log.info('[googletv-diag] pairing.start: wrapping with TLS')
  local tls, tls_err = ssl.wrap(tcp, {
    mode = 'client',
    protocol = 'any', -- this platform's ssl module only supports 'any' -- can't exclude TLS 1.3 via API here
    verify = 'none', -- the TV's cert is self-signed and unknown ahead of time; that's expected
    certificates = { { certificate = cert.CERT_PEM, key = cert.KEY_PEM } },
    options = { 'all' },
  })
  log.info('[googletv-diag] pairing.start: wrap returned tls=' .. tostring(tls ~= nil) .. ' err=' .. tostring(tls_err))
  if not tls then
    return nil, 'TLS wrap failed: ' .. tostring(tls_err)
  end

  tls:settimeout(10) -- wrapping for TLS can reset/detach the timeout the raw tcp socket had

  log.info('[googletv-diag] pairing.start: starting TLS handshake')
  local handshake_ok, handshake_err
  local retries = 0
  repeat
    handshake_ok, handshake_err = tls:dohandshake()
    if not handshake_ok then
      if handshake_err == 'wantread' or handshake_err == 'wantwrite' then
        retries = retries + 1
        if retries == 1 or retries % 20 == 0 then
          log.info('[googletv-diag] pairing.start: handshake retry ' .. retries .. ' (' .. handshake_err .. ')')
        end
        if retries > 200 then
          tls:close()
          return nil, 'TLS handshake timed out waiting on ' .. handshake_err
        end
        cosock_socket.sleep(0.05)
      else
        tls:close()
        return nil, 'TLS handshake failed: ' .. tostring(handshake_err)
      end
    end
  until handshake_ok
  log.info('[googletv-diag] pairing.start: TLS handshake succeeded, reading peer certificate')

  -- Best-effort: log whatever the platform's ssl module can tell us about
  -- the negotiated connection (protocol version, cipher), trying a few
  -- possible method names since none of this is documented. Failures here
  -- are silently ignored -- purely diagnostic, never fatal.
  for _, method_name in ipairs({ 'info', 'getpeerverification', 'getpeercertificate' }) do
    local m = tls[method_name]
    if type(m) == 'function' then
      local ok_m, result = pcall(m, tls)
      if ok_m and result then
        if type(result) == 'table' then
          local parts = {}
          for k, v in pairs(result) do
            parts[#parts + 1] = tostring(k) .. '=' .. tostring(v)
          end
          log.info('[googletv-diag] pairing.start: tls:' .. method_name .. '() = {' .. table.concat(parts, ', ') .. '}')
        else
          log.info('[googletv-diag] pairing.start: tls:' .. method_name .. '() = ' .. tostring(result))
        end
      end
    end
  end

  -- Pull the TV's certificate to get its RSA public key. LuaSec's x509
  -- object exposes :pem() on essentially every version, so we go via that
  -- (full certificate PEM) rather than relying on the less-universally-
  -- present :pubkey() convenience method.
  local peer_cert = tls:getpeercertificate()
  if not peer_cert then
    tls:close()
    return nil, 'could not read the TV certificate from the TLS handshake'
  end
  local peer_pem = peer_cert:pem()
  local peer_der = base64.pem_to_der(peer_pem)
  local ok3, server_modulus, server_exponent = pcall(der.rsa_pubkey_from_cert_der, peer_der)
  if not ok3 then
    tls:close()
    return nil, 'could not parse the TV certificate public key: ' .. tostring(server_modulus)
  end
  log.info('[googletv-diag] pairing.start: got peer cert, sending PairingRequest')

  -- Step 1: PairingRequest -> expect PairingRequestAck
  local sent = frame.write(tls, pairingmessage.build_request(client_name or 'SmartThings'))
  if not sent then
    tls:close()
    return nil, 'failed to send PairingRequest'
  end
  local resp, rerr = frame.read(tls)
  if not resp then
    tls:close()
    return nil, 'no response to PairingRequest: ' .. tostring(rerr)
  end
  local kind = pairingmessage.parse(resp)
  log.info('[googletv-diag] pairing.start: raw ack bytes (' .. #resp .. '): ' .. to_hex(resp) .. ' parsed_as=' .. kind)
  if kind ~= 'request_ack' then
    tls:close()
    return nil, 'unexpected response to PairingRequest (got ' .. kind .. ')'
  end
  log.info('[googletv-diag] pairing.start: got PairingRequestAck, sending our PairingOption')

  -- Step 2: send OUR PairingOption -- this is the step that was missing.
  -- The client speaks first here; the TV was correctly waiting on us the
  -- whole time, not the other way around.
  local sent_opt = frame.write(tls, pairingmessage.build_option())
  if not sent_opt then
    tls:close()
    return nil, 'failed to send PairingOption'
  end

  -- Step 3: now wait for the TV's own PairingOption in response.
  local resp2, rerr2 = frame.read(tls)
  if not resp2 then
    tls:close()
    return nil, 'no PairingOption received: ' .. tostring(rerr2)
  end
  local kind2 = pairingmessage.parse(resp2)
  if kind2 ~= 'option' then
    tls:close()
    return nil, 'unexpected message waiting for PairingOption (got ' .. kind2 .. ')'
  end

  -- Step 4: send PairingConfiguration -> expect PairingConfigurationAck.
  -- This is the step that makes the TV display the on-screen code.
  local sent2 = frame.write(tls, pairingmessage.build_configuration())
  if not sent2 then
    tls:close()
    return nil, 'failed to send PairingConfiguration'
  end
  local resp3, rerr3 = frame.read(tls)
  if not resp3 then
    tls:close()
    return nil, 'no PairingConfigurationAck received: ' .. tostring(rerr3)
  end
  local kind3 = pairingmessage.parse(resp3)
  if kind3 ~= 'configuration_ack' then
    tls:close()
    return nil, 'TV rejected pairing configuration (got ' .. kind3 .. ') -- the TV should now be showing a code on screen; if it never appeared, check that ports 6466/6467 are reachable'
  end

  return {
    tls = tls,
    server_modulus = server_modulus,
    server_exponent = server_exponent,
  }
end

-- Given a handle from M.start() and the code the user read off the TV
-- screen (a 6-character hex string -- Google TV pairing codes only ever
-- use digits 0-9, which are also valid hex digits, so this works whether
-- or not a given TV's code generator would ever produce A-F), completes
-- pairing. Returns true on success, or nil, err_message on failure.
--
-- IMPORTANT: the caller is responsible for closing handle.tls when done
-- with it (on both success and failure) unless it intends to reuse the
-- same connection, which it should NOT -- open a fresh connection on
-- port 6466 (the remote port) for actual remote-control traffic; this
-- pairing connection is single-purpose.
function M.submit_code(handle, code)
  code = code:gsub('%s', '')
  if #code ~= 6 then
    return nil, 'pairing code must be exactly 6 characters (as shown on the TV)'
  end

  local checksum_byte = hex_to_bytes(code:sub(1, 2))
  local nonce = hex_to_bytes(code:sub(3, 6))

  local alpha = M._compute_alpha(handle.server_modulus, handle.server_exponent, nonce)
  if alpha:sub(1, 1) ~= checksum_byte then
    return nil, 'code does not match (typo, or paired with the wrong TV?) -- please re-check the code shown on screen'
  end

  local sent = frame.write(handle.tls, pairingmessage.build_secret(alpha))
  if not sent then
    return nil, 'failed to send PairingSecret'
  end

  local resp, rerr = frame.read(handle.tls)
  if not resp then
    return nil, 'no response to PairingSecret: ' .. tostring(rerr)
  end
  local kind = pairingmessage.parse(resp)
  if kind ~= 'secret_ack' then
    return nil, 'TV rejected the pairing secret (got ' .. kind .. ')'
  end

  return true
end

return M
