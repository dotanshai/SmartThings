-- The Android TV Remote v2 protocol frames every protobuf message (on both
-- the pairing port and the remote port) with a single length byte: one byte
-- giving the message length (0-255), followed by that many bytes of
-- protobuf. This matches every reference implementation (Home Assistant's
-- androidtvremote2, louis49/androidtv-remote, etc).
--
-- This means a single message can never exceed 255 bytes. That's fine for
-- everything this driver sends/receives (pairing handshake messages, key
-- presses, volume state, ping/pong) -- it would only matter for very long
-- IME text input or app-link URLs, neither of which this driver does.
local M = {}

local cosock_socket = require('cosock.socket')

-- LuaSec's non-blocking TLS layer can return "wantread"/"wantwrite" from
-- send/receive when a TLS record needs another round trip before it has
-- enough data to produce (or send) plaintext -- this is normal and
-- distinct from a real timeout/error, and must be retried rather than
-- treated as failure. We retry with a brief yield (via cosock's sleep, so
-- the hub's other coroutines keep running) rather than busy-looping.
local function is_retryable(err)
  return err == 'wantread' or err == 'wantwrite'
end

local log = require('log')

local TIMEOUT_SECONDS = 30

function M.write(sock, payload)
  assert(#payload <= 255, 'frame payload too long for single-byte length prefix')
  local data = string.char(#payload) .. payload
  local total_sent = 0
  local deadline = os.time() + TIMEOUT_SECONDS
  while total_sent < #data do
    local sent_to, err, partial = sock:send(data, total_sent + 1)
    if sent_to then
      total_sent = sent_to
    elseif is_retryable(err) then
      if partial then total_sent = partial end
      if os.time() > deadline then return nil, 'timed out waiting to send (' .. err .. ')' end
      cosock_socket.sleep(0.05)
    else
      return nil, err
    end
  end
  return true
end

-- Reads exactly `n` bytes, retrying on wantread/wantwrite until a hard
-- wall-clock deadline (not just a retry count, so this can't be fooled by
-- individual retries taking longer than expected).
local function read_exact(sock, n)
  local deadline = os.time() + TIMEOUT_SECONDS
  local last_log = os.time()
  while true do
    local data, err = sock:receive(n)
    if data then return data end
    if is_retryable(err) then
      local now = os.time()
      if now > deadline then return nil, 'timed out waiting to receive (' .. err .. ')' end
      if now - last_log >= 5 then
        log.info('[googletv-diag] frame.read: still waiting (' .. err .. '), ' .. (deadline - now) .. 's left')
        last_log = now
      end
      cosock_socket.sleep(0.05)
    else
      return nil, err
    end
  end
end

-- Blocking-style read (cosock yields under the hood): reads exactly one
-- length-prefixed frame and returns its payload.
function M.read(sock)
  local header, err = read_exact(sock, 1)
  if not header then return nil, err end
  local len = header:byte(1)
  if len == 0 then return '' end
  return read_exact(sock, len)
end

return M
