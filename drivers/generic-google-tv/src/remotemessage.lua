-- remote.proto message builders/parsers.
--
-- Field numbers are taken directly from the compiled protobuf descriptors
-- (same source as pairingmessage.lua). Only the subset of RemoteKeyCode
-- needed for a normal SmartThings TV/media capability set is included --
-- the full enum has 300+ entries (see Google's android/keycodes.h) and
-- isn't needed for power/volume/dpad/media control.
local pb = require('protobuf')

local M = {}

M.KEYCODE = {
  UNKNOWN = 0,
  HOME = 3,
  BACK = 4,
  DPAD_UP = 19,
  DPAD_DOWN = 20,
  DPAD_LEFT = 21,
  DPAD_RIGHT = 22,
  DPAD_CENTER = 23,
  VOLUME_UP = 24,
  VOLUME_DOWN = 25,
  POWER = 26,
  ENTER = 66,
  MENU = 82,
  SEARCH = 84,
  MEDIA_PLAY_PAUSE = 85,
  MEDIA_STOP = 86,
  MEDIA_NEXT = 87,
  MEDIA_PREVIOUS = 88,
  MEDIA_REWIND = 89,
  MEDIA_FAST_FORWARD = 90,
  MUTE = 91,
  INFO = 165,
  CHANNEL_UP = 166,
  CHANNEL_DOWN = 167,
  GUIDE = 172,
  SETTINGS = 176,
  TV_INPUT = 178,
  TV = 170,
  TV_INPUT_HDMI_1 = 243,
  TV_INPUT_HDMI_2 = 244,
  TV_INPUT_HDMI_3 = 245,
  TV_INPUT_HDMI_4 = 246,
  ESCAPE = 111,
  NUMBER_0 = 7,
  NUMBER_1 = 8,
  NUMBER_2 = 9,
  NUMBER_3 = 10,
  NUMBER_4 = 11,
  NUMBER_5 = 12,
  NUMBER_6 = 13,
  NUMBER_7 = 14,
  NUMBER_8 = 15,
  NUMBER_9 = 16,
}

M.DIRECTION = {
  UNKNOWN = 0,
  START_LONG = 1,
  END_LONG = 2,
  SHORT = 3,
}

-- Feature bitflags (matches the reference client's Feature IntFlag enum).
-- Our default active set mirrors theirs minus IME/VOICE, which this driver
-- doesn't implement.
M.FEATURE = {
  PING = 1,      -- 2^0
  KEY = 2,       -- 2^1
  IME = 4,       -- 2^2
  VOICE = 8,     -- 2^3
  UNKNOWN_1 = 16, -- 2^4
  POWER = 32,    -- 2^5
  VOLUME = 64,   -- 2^6
  APP_LINK = 512, -- 2^9
}
M.OUR_DEFAULT_FEATURES = M.FEATURE.PING + M.FEATURE.KEY + M.FEATURE.POWER + M.FEATURE.VOLUME + M.FEATURE.APP_LINK

-- Outer RemoteMessage field numbers.
local FIELD = {
  remote_configure = 1,
  remote_set_active = 2,
  remote_error = 3,
  remote_ping_request = 8,
  remote_ping_response = 9,
  remote_key_inject = 10,
  remote_start = 40,
  remote_set_volume_level = 50,
  remote_app_link_launch_request = 90,
  remote_ime_key_inject = 20,
}
M.FIELD = FIELD

-- RemoteDeviceInfo { model=1, vendor=2, unknown1=3, unknown2=4, package_name=5, app_version=6 }
-- Matches the reference client's reply exactly: it leaves model/vendor unset
-- and uses these specific unknown1/unknown2/package_name/app_version values.
local function build_device_info()
  return pb.message(
    pb.field_varint(3, 1),
    pb.field_bytes(4, '1'),
    pb.field_bytes(5, 'atvremote'),
    pb.field_bytes(6, '1.0.0')
  )
end

-- RemoteConfigure { code1=1, device_info=2 }
function M.build_configure(code1)
  local msg = pb.message(
    pb.field_varint(1, code1),
    pb.field_bytes(2, build_device_info())
  )
  return pb.field_bytes(FIELD.remote_configure, msg)
end

-- RemoteSetActive { active=1 }
function M.build_set_active(active)
  local msg = pb.message(pb.field_varint(1, active))
  return pb.field_bytes(FIELD.remote_set_active, msg)
end

-- RemotePingResponse { val1=1 } -- echoes val1 from the RemotePingRequest we received.
function M.build_ping_response(val1)
  local msg = pb.message(pb.field_varint(1, val1))
  return pb.field_bytes(FIELD.remote_ping_response, msg)
end

-- RemoteKeyInject { key_code=1, direction=2 }
function M.build_key_inject(key_code, direction)
  local msg = pb.message(
    pb.field_varint(1, key_code),
    pb.field_varint(2, direction)
  )
  return pb.field_bytes(FIELD.remote_key_inject, msg)
end

-- RemoteAppLinkLaunchRequest { app_link=1 }
function M.build_app_link(url)
  local msg = pb.message(pb.field_bytes(1, url))
  return pb.field_bytes(FIELD.remote_app_link_launch_request, msg)
end

-- Parses an incoming RemoteMessage. Returns a kind string and a decoded
-- table with whatever fields we care about for that kind:
--   'configure'   -> { code1 = n }
--   'set_active'  -> {} (server telling us which features are active; we just echo ours back)
--   'remote_start'-> { started = bool }
--   'ping_request'-> { val1 = n }
--   'set_volume'  -> { volume_level = n, volume_max = n, volume_muted = bool }
--   'unknown'     -> {}
function M.parse(data)
  local outer = pb.parse(data)
  for _, entry in ipairs(outer) do
    if entry.field == FIELD.remote_configure then
      local inner = pb.parse_map(entry.value)
      return 'configure', { code1 = inner[1] }
    elseif entry.field == FIELD.remote_set_active then
      return 'set_active', {}
    elseif entry.field == 40 then -- remote_start { started = 1 }
      local inner = pb.parse_map(entry.value)
      return 'remote_start', { started = inner[1] == 1 }
    elseif entry.field == FIELD.remote_ping_request then
      local inner = pb.parse_map(entry.value)
      return 'ping_request', { val1 = inner[1] }
    elseif entry.field == FIELD.remote_set_volume_level then
      local inner = pb.parse_map(entry.value)
      return 'set_volume', {
        volume_level = inner[7],
        volume_max = inner[6],
        volume_muted = inner[8] == 1,
      }
    elseif entry.field == FIELD.remote_ime_key_inject then
      -- RemoteImeKeyInject { app_info=1, text_field_status=2 }
      -- RemoteAppInfo { ..., app_package=12 (string) }
      local ime_inner = pb.parse_map(entry.value)
      local app_info_bytes = ime_inner[1]
      if app_info_bytes then
        local app_info = pb.parse_map(app_info_bytes)
        return 'current_app', { app_package = app_info[12] }
      end
    end
  end
  return 'unknown', {}
end

return M
