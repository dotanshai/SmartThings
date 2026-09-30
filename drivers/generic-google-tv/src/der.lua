-- Minimal DER/ASN.1 reader.
--
-- We only need to do two things with it:
--   1. Walk an X.509 certificate far enough to find the subjectPublicKeyInfo
--      BIT STRING (we don't care about anything else in the certificate).
--   2. Parse that BIT STRING's contents as an RSAPublicKey SEQUENCE
--      { INTEGER modulus, INTEGER publicExponent } and return the two
--      integers as raw big-endian byte strings with any leading 0x00
--      sign byte stripped (matching Java's BigInteger.toByteArray() minus
--      the leading null byte, which is what the pairing hash is defined
--      over).
--
-- This is intentionally NOT a general-purpose ASN.1 library -- just enough
-- reading to get from "start of certificate" to "two integers".
local M = {}

-- Reads one TLV (tag/length/value) starting at 1-based position `pos` in
-- byte-string `data`. Returns tag byte, the value's start position, the
-- value's length, and the position right after the value (i.e. the start
-- of the next TLV).
local function read_tlv(data, pos)
  local tag = data:byte(pos)
  if not tag then return nil end
  local len_byte = data:byte(pos + 1)
  local len, header_len
  if len_byte < 0x80 then
    len = len_byte
    header_len = 2
  else
    local n_bytes = len_byte - 0x80
    len = 0
    for i = 1, n_bytes do
      len = (len * 256) + data:byte(pos + 1 + i)
    end
    header_len = 2 + n_bytes
  end
  local value_start = pos + header_len
  local next_pos = value_start + len
  return tag, value_start, len, next_pos
end

-- Strips leading 0x00 bytes (the DER "this is a positive integer" sign
-- byte), matching the reference pairing implementation exactly.
local function strip_leading_zero(bytes)
  local i = 1
  while i < #bytes and bytes:byte(i) == 0 do
    i = i + 1
  end
  return bytes:sub(i)
end

-- Parses an RSAPublicKey SEQUENCE { INTEGER modulus, INTEGER exponent }
-- and returns modulus, exponent as raw byte strings (leading zero stripped).
local function parse_rsa_public_key(data)
  local tag, seq_start = read_tlv(data, 1)
  assert(tag == 0x30, 'expected SEQUENCE for RSAPublicKey')
  local itag, mod_start, mod_len, next1 = read_tlv(data, seq_start)
  assert(itag == 0x02, 'expected INTEGER for modulus')
  local modulus = strip_leading_zero(data:sub(mod_start, mod_start + mod_len - 1))
  local itag2, exp_start, exp_len = read_tlv(data, next1)
  assert(itag2 == 0x02, 'expected INTEGER for exponent')
  local exponent = strip_leading_zero(data:sub(exp_start, exp_start + exp_len - 1))
  return modulus, exponent
end

-- Given the raw DER bytes of a full X.509 certificate, returns the RSA
-- modulus and exponent (as raw big-endian byte strings) from its
-- subjectPublicKeyInfo.
function M.rsa_pubkey_from_cert_der(der)
  -- Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
  local tag, cert_val_start = read_tlv(der, 1)
  assert(tag == 0x30, 'expected SEQUENCE for Certificate')

  -- TBSCertificate ::= SEQUENCE { ... , subjectPublicKeyInfo, ... }
  local ttag, tbs_val_start = read_tlv(der, cert_val_start)
  assert(ttag == 0x30, 'expected SEQUENCE for TBSCertificate')

  -- Walk the TBSCertificate's children in order, skipping everything
  -- until we hit the subjectPublicKeyInfo (the 7th element if version
  -- and issuerUniqueID/extensions are present, but easiest/most robust
  -- is to just walk and identify by shape: it's the first SEQUENCE
  -- whose first child is itself a SEQUENCE -- i.e. AlgorithmIdentifier --
  -- immediately followed by a BIT STRING).
  local pos = tbs_val_start
  while true do
    local field_tag, field_val_start, field_len, next_pos = read_tlv(der, pos)
    if not field_tag then
      error('subjectPublicKeyInfo not found in certificate')
    end
    if field_tag == 0x30 then
      -- Peek: does this SEQUENCE's content look like
      -- SEQUENCE { AlgorithmIdentifier } BIT STRING ?
      local inner_tag, inner_val_start, inner_len, inner_next =
        read_tlv(der, field_val_start)
      if inner_tag == 0x30 then
        local bs_tag = der:byte(inner_next)
        if bs_tag == 0x03 then
          -- Found subjectPublicKeyInfo. Read the BIT STRING.
          local bstag, bs_val_start, bs_len = read_tlv(der, inner_next)
          assert(bstag == 0x03, 'expected BIT STRING for subjectPublicKey')
          -- First content byte of a BIT STRING is the "unused bits" count,
          -- which is 0 for a DER-encoded key; the RSAPublicKey SEQUENCE
          -- follows immediately after it.
          local key_der = der:sub(bs_val_start + 1, bs_val_start + bs_len - 1)
          return parse_rsa_public_key(key_der)
        end
      end
    end
    pos = next_pos
  end
end

return M
