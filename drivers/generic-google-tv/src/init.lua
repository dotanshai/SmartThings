local Driver = require('st.driver')
local capabilities = require('st.capabilities')
local cosock = require('cosock')
local log = require('log')

local pairing = require('pairing')
local remote = require('remote')
local commands = require('commands')

local PAIRING_PORT = 6467
local REMOTE_PORT = 6466

-- Bump this whenever the pairing/remote protocol code changes meaningfully.
-- Logged at startup so a bug report (a logcat capture from someone in the
-- Facebook group) can be matched to the exact build that produced it.
local DRIVER_VERSION = '2026-07-31.1'
log.info('[googletv] driver version ' .. DRIVER_VERSION)

-- Creates one placeholder device when the user taps "Scan nearby" /
-- "Add device" for this driver. There's no network-discoverable
-- fingerprint for "any Google TV on the LAN" (unlike Zigbee/Z-Wave), so
-- the user fills in the IP address (and MAC, for Wake-on-LAN) from the
-- device's Settings screen afterwards -- the same manual-IP pattern used
-- by most other community LAN Edge drivers.
local CREATOR_DEVICE_NETWORK_ID = 'googletv-creator-device'

-- Creates ONE permanent "Add new Google TV" placeholder/button device the
-- first time the user taps "Scan nearby" / "Add device" for this driver --
-- never more than one, and never on subsequent scans. This intentionally
-- does NOT create an actual pairable TV device from discovery: since
-- SmartThings broadcasts every "Scan nearby" to all installed drivers
-- (not just the one the user intended), doing that meant scanning for an
-- unrelated Zigbee/LAN device would also spawn an unwanted Google TV
-- device every time. Instead, the user presses the creator device's own
-- button whenever they actually want to add a new TV (see
-- commands.momentary_press's CREATOR_DEVICE_NETWORK_ID branch) -- explicit
-- user intent, not an accidental side effect of scanning for something
-- else entirely.
local function discovery_handler(driver, opts, cons)
  for _, d in ipairs(driver:get_devices()) do
    if d.device_network_id == CREATOR_DEVICE_NETWORK_ID then
      return
    end
  end
  local metadata = {
    type = 'LAN',
    device_network_id = CREATOR_DEVICE_NETWORK_ID,
    label = 'Google TV - Add New',
    profile = 'googletv-creator.v1',
    manufacturer = 'Generic',
    model = 'Google TV Creator',
    vendor_provided_label = 'Google TV Creator',
  }
  local ok, err = driver:try_create_device(metadata)
  if not ok then
    log.error('[googletv] failed to create the "add new device" creator device: ' .. tostring(err))
  end
end

-- connect_remote lives in commands.lua now (see commands.connect_remote) so
-- switch_on can reuse the exact same connection logic after Wake-on-LAN.

-- Kicks off pairing when the user sets/changes the IP address: opens the
-- pairing connection and waits (the TV will now show a code on screen)
-- for the user to come back and fill in the pairing code preference.
local function start_pairing(driver, device)
  local ip = device.preferences.ipAddress
  if not ip or ip == '' then return end

  cosock.spawn(function()
    local call_ok, handle, err = pcall(pairing.start, ip, PAIRING_PORT, 'SmartThings')
    if not call_ok then
      log.error('[googletv] ' .. device.label .. ': pairing crashed unexpectedly: ' .. tostring(handle))
      device:offline()
      return
    end
    if not handle then
      log.error('[googletv] ' .. device.label .. ': pairing failed: ' .. tostring(err))
      device:offline()
      return
    end
    device:set_field('pairing_handle', handle, { persist = false })
    log.info('[googletv] ' .. device.label .. ': the TV should now be showing a 6-character code -- enter it in the "Pairing code" setting')
  end, 'googletv-pair-' .. device.id)
end

-- Completes pairing when the user fills in the pairing code preference.
local function submit_pairing_code(driver, device, code)
  local handle = device:get_field('pairing_handle')
  if not handle then
    log.warn('[googletv] ' .. device.label .. ': got a pairing code but no pairing session is open -- change the IP address setting to restart pairing')
    return
  end

  cosock.spawn(function()
    local ok, err = pairing.submit_code(handle, code)
    pcall(function() handle.tls:close() end)
    device:set_field('pairing_handle', nil, { persist = false })
    if ok then
      log.info('[googletv] ' .. device.label .. ': paired successfully')
      commands.connect_remote(driver, device)
    else
      log.error('[googletv] ' .. device.label .. ': ' .. tostring(err))
      device:offline()
    end
  end, 'googletv-submit-code-' .. device.id)
end

local function emit_presets(device)
  local attribute_value = {}
  for _, p in ipairs(commands.all_presets_for(device)) do
    attribute_value[#attribute_value + 1] = { id = p.id, name = p.name }
  end
  device:emit_event(capabilities.mediaPresets.presets(attribute_value))
end

local function device_init(driver, device)
  if device.device_network_id == CREATOR_DEVICE_NETWORK_ID then
    return
  end
  device:emit_event(capabilities.keypadInput.supportedKeyCodes(commands.SUPPORTED_KEYPAD_CODES))
  device:emit_event(capabilities.mediaPlayback.playbackStatus.stopped())
  device:emit_event(capabilities.mediaTrackControl.supportedTrackControlCommands({'previousTrack', 'nextTrack'}))
  emit_presets(device)

  local ip = device.preferences.ipAddress
  local code = device.preferences.pairingCode
  if ip and ip ~= '' and code and code ~= '' then
    -- Driver restarted (e.g. hub reboot) with a device that was already
    -- paired; just reconnect, no need to re-pair.
    commands.connect_remote(driver, device)
  end
end

local function device_added(driver, device)
  if device.device_network_id == CREATOR_DEVICE_NETWORK_ID then
    return
  end
  device:emit_event(capabilities.switch.switch.off())
  device:emit_event(capabilities.keypadInput.supportedKeyCodes(commands.SUPPORTED_KEYPAD_CODES))
  device:emit_event(capabilities.mediaPlayback.playbackStatus.stopped())
  device:emit_event(capabilities.mediaTrackControl.supportedTrackControlCommands({'previousTrack', 'nextTrack'}))
  emit_presets(device)
end

local function info_changed(driver, device, event, args)
  local old = args.old_st_store and args.old_st_store.preferences or {}
  local new = device.preferences
  local already_connected = device:get_field('remote_handle') ~= nil
  log.info('[googletv] ' .. device.label .. ': infoChanged fired -- ipAddress=' .. tostring(new.ipAddress) ..
    ' pairingCode_set=' .. tostring(new.pairingCode ~= nil and new.pairingCode ~= '') ..
    ' already_connected=' .. tostring(already_connected))

  if new.customApps ~= old.customApps then
    emit_presets(device)
  end

  if new.pairingCode and new.pairingCode ~= '' and new.pairingCode ~= old.pairingCode then
    -- A fresh code was entered: complete whichever pairing session is open.
    submit_pairing_code(driver, device, new.pairingCode)
  elseif new.ipAddress and new.ipAddress ~= '' and not already_connected then
    -- Any settings save while not yet connected (re)starts pairing --
    -- covers both "IP changed" and "just retrying after a failure/re-
    -- opening Settings with the same IP still in the box", since relying
    -- on exact old-vs-new comparison here turned out to silently no-op
    -- on the latter.
    local existing_pairing = device:get_field('pairing_handle')
    if existing_pairing then
      pcall(function() existing_pairing.tls:close() end)
      device:set_field('pairing_handle', nil, { persist = false })
    end
    start_pairing(driver, device)
  end
end

local driver = Driver('googletv', {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    infoChanged = info_changed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = commands.switch_on,
      [capabilities.switch.commands.off.NAME] = commands.switch_off,
    },
    [capabilities.audioMute.ID] = {
      [capabilities.audioMute.commands.mute.NAME] = commands.mute,
      [capabilities.audioMute.commands.unmute.NAME] = commands.unmute,
    },
    [capabilities.audioVolume.ID] = {
      [capabilities.audioVolume.commands.volumeUp.NAME] = commands.volume_up,
      [capabilities.audioVolume.commands.volumeDown.NAME] = commands.volume_down,
      [capabilities.audioVolume.commands.setVolume.NAME] = commands.set_volume,
    },
    [capabilities.mediaPlayback.ID] = {
      [capabilities.mediaPlayback.commands.play.NAME] = commands.media_play,
      [capabilities.mediaPlayback.commands.pause.NAME] = commands.media_pause,
      [capabilities.mediaPlayback.commands.stop.NAME] = commands.media_stop,
      [capabilities.mediaPlayback.commands.fastForward.NAME] = commands.media_fast_forward,
      [capabilities.mediaPlayback.commands.rewind.NAME] = commands.media_rewind,
    },
    [capabilities.mediaTrackControl.ID] = {
      [capabilities.mediaTrackControl.commands.nextTrack.NAME] = commands.next_track,
      [capabilities.mediaTrackControl.commands.previousTrack.NAME] = commands.previous_track,
    },
    [capabilities.tvChannel.ID] = {
      [capabilities.tvChannel.commands.channelUp.NAME] = commands.channel_up,
      [capabilities.tvChannel.commands.channelDown.NAME] = commands.channel_down,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = commands.refresh,
    },
    [capabilities.keypadInput.ID] = {
      [capabilities.keypadInput.commands.sendKey.NAME] = commands.send_keypad_key,
    },
    [capabilities.mediaPresets.ID] = {
      [capabilities.mediaPresets.commands.playPreset.NAME] = commands.play_preset,
    },
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = commands.momentary_press,
    },
  },
})

driver:run()
