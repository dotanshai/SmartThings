-- pairing.proto message builders/parsers.
--
-- Field numbers below are taken directly from the compiled Go protobuf
-- descriptors for this protocol (github.com/drosocode/atvremote's
-- pairingmessage.pb.go), not guessed -- this is the same reverse-engineered
-- protocol used by Home Assistant's Android TV integration and the
-- louis49/androidtv-remote Node.js library.
local pb = require('protobuf')

local M = {}

M.STATUS = {
  UNKNOWN = 0,
  OK = 200,
  ERROR = 400,
  BAD_CONFIGURATION = 401,
  BAD_SECRET = 402,
}

M.ROLE = {
  UNKNOWN = 0,
  INPUT = 1,
  OUTPUT = 2,
}

M.ENCODING_TYPE = {
  UNKNOWN = 0,
  ALPHANUMERIC = 1,
  NUMERIC = 2,
  HEXADECIMAL = 3,
  QRCODE = 4,
}

-- PairingRequest { service_name = 1, client_name = 2 }
local function build_pairing_request(service_name, client_name)
  return pb.message(
    pb.field_bytes(1, service_name),
    pb.field_bytes(2, client_name)
  )
end

-- PairingOption { input_encodings = 1 (repeated), output_encodings = 2 (repeated), preferred_role = 3 }
-- We only ever need to *build* an option list with one encoding (we choose
-- it ourselves rather than negotiate), for symmetry with what we send back.
-- PairingEncoding { type = 1, symbol_length = 2 }
local function build_pairing_encoding(encoding_type, symbol_length)
  return pb.message(
    pb.field_varint(1, encoding_type),
    pb.field_varint(2, symbol_length)
  )
end

-- PairingConfiguration { encoding = 1, client_role = 2 }
local function build_pairing_configuration(encoding_type, symbol_length, client_role)
  local encoding = build_pairing_encoding(encoding_type, symbol_length)
  return pb.message(
    pb.field_bytes(1, encoding),
    pb.field_varint(2, client_role)
  )
end

-- PairingSecret { secret = 1 }
local function build_pairing_secret(secret_bytes)
  return pb.message(pb.field_bytes(1, secret_bytes))
end

-- Wraps any of the above sub-messages in the outer PairingMessage envelope.
-- `sub_field` is the outer field number (10/11/20/30/31/40/41), `sub_bytes`
-- is the already-encoded sub-message.
local function wrap(protocol_version, status, sub_field, sub_bytes)
  return pb.message(
    pb.field_varint(1, protocol_version),
    pb.field_varint(2, status),
    pb.field_bytes(sub_field, sub_bytes)
  )
end

function M.build_request(client_name)
  -- "atvremote" is the exact service_name the reference client uses --
  -- confirmed directly from its source, not guessed.
  return wrap(2, M.STATUS.OK, 10, build_pairing_request('atvremote', client_name))
end

-- PairingOption { input_encodings = 1 (repeated), preferred_role = 3 }
-- The CLIENT sends this proactively as soon as it receives PairingRequestAck
-- -- it does not wait for the server to send one first. (This was the bug:
-- the server was correctly waiting on us, and we never sent it.)
function M.build_option()
  local encoding = build_pairing_encoding(M.ENCODING_TYPE.HEXADECIMAL, 6)
  local option = pb.message(
    pb.field_bytes(1, encoding),
    pb.field_varint(3, M.ROLE.INPUT)
  )
  return wrap(2, M.STATUS.OK, 20, option)
end

function M.build_configuration()
  -- symbol_length=6 matches the total on-screen code length (a 1-byte
  -- checksum + 2-byte nonce, both hex-encoded = 6 hex characters), not
  -- just the nonce portion -- confirmed against the reference client's
  -- source and a real observed code ("97afa3", 6 characters).
  return wrap(2, M.STATUS.OK, 30,
    build_pairing_configuration(M.ENCODING_TYPE.HEXADECIMAL, 6, M.ROLE.INPUT))
end

function M.build_secret(secret_bytes)
  return wrap(2, M.STATUS.OK, 40, build_pairing_secret(secret_bytes))
end

-- Parses an outer PairingMessage and returns which inner message it
-- contains: 'request_ack' | 'option' | 'configuration_ack' | 'secret_ack' | 'unknown',
-- plus a decoded table for the fields we care about.
function M.parse(data)
  local outer = pb.parse(data)
  for _, entry in ipairs(outer) do
    if entry.field == 11 then
      return 'request_ack', {}
    elseif entry.field == 20 then
      -- PairingOption -- we don't need to inspect it; we always request
      -- HEXADECIMAL/4 ourselves in build_configuration().
      return 'option', {}
    elseif entry.field == 31 then
      return 'configuration_ack', {}
    elseif entry.field == 41 then
      return 'secret_ack', {}
    elseif entry.field == 2 then
      -- status field at the outer level, e.g. STATUS_BAD_SECRET with no
      -- sub-message attached
      if entry.value == M.STATUS.BAD_SECRET then
        return 'bad_secret', {}
      elseif entry.value == M.STATUS.BAD_CONFIGURATION then
        return 'bad_configuration', {}
      elseif entry.value == M.STATUS.ERROR then
        return 'error', {}
      end
    end
  end
  return 'unknown', {}
end

return M
