-- Maps SmartThings capability commands onto Android TV Remote key presses.
-- Kept separate from init.lua so the capability-handler wiring in init.lua
-- stays readable.
local log = require('log')
local capabilities = require('st.capabilities')
local cosock = require('cosock')
local cosock_socket = require('cosock.socket')

local remote = require('remote')
local remotemessage = require('remotemessage')
local wol = require('wol')
local diagnostics = require('diagnostics')

local REMOTE_PORT = 6466

local M = {}

-- Ensures a persistent, self-healing remote-control connection for a
-- device that's already paired. Idempotent: calling this while the loop
-- is already running just waits for the next successful (re)connect and
-- fires `on_connected` then, rather than starting a duplicate loop.
--
-- The loop itself never gives up -- on any disconnect (Wi-Fi drop, TV
-- reboot, whatever) it retries with exponential backoff (5s, 10s, 20s...
-- capped at 5 minutes) forever, so a dropped connection gets noticed and
-- repaired within seconds to low minutes rather than needing a manual
-- refresh or waiting for a scheduled check.
function M.connect_remote(driver, device, on_connected)
  local ip = device.preferences.ipAddress
  if not ip or ip == '' then return end

  if device:get_field('reconnect_loop_active') then
    if on_connected then
      cosock.spawn(function()
        local waited = 0
        local handle = device:get_field('remote_handle')
        while (not handle or not handle.connected) and waited < 30 do
          cosock_socket.sleep(1)
          waited = waited + 1
          handle = device:get_field('remote_handle')
        end
        if handle and handle.connected then on_connected(handle) end
      end, 'googletv-wait-connect-' .. device.id)
    end
    return
  end
  device:set_field('reconnect_loop_active', true, { persist = false })

  cosock.spawn(function()
    local backoff = 5
    while true do
      -- Re-read the IP on every attempt, not just once at loop start --
      -- if it changes (e.g. the router reassigns it via DHCP), this picks
      -- up the new value on the very next retry instead of retrying a
      -- stale, now-wrong IP forever with no way to recover short of a
      -- driver restart.
      local current_ip = device.preferences.ipAddress
      if not current_ip or current_ip == '' then
        cosock_socket.sleep(backoff)
        backoff = math.min(backoff * 2, 300)
        goto continue
      end
      local handle, err = remote.connect(current_ip, REMOTE_PORT, function(kind, data)
        if kind == 'set_volume' and data.volume_level then
          device:set_field('last_volume_level', data.volume_level, { persist = false })
          device:emit_event(capabilities.audioVolume.volume(data.volume_level))
          if data.volume_muted then
            device:emit_event(capabilities.audioMute.mute.muted())
          else
            device:emit_event(capabilities.audioMute.mute.unmuted())
          end
        elseif kind == 'remote_start' then
          -- This is the real on/off signal -- reflects the TV's actual power
          -- state regardless of what caused the change (our own commands,
          -- the physical remote, a phone app, etc), and the TCP connection
          -- can stay alive across power off/on (e.g. with "high consumption"
          -- energy mode keeping Wi-Fi up), so this is NOT the same thing as
          -- "connected".
          device:set_field('tv_is_on', data.started, { persist = false })
          if data.started then
            device:emit_event(capabilities.switch.switch.on())
          else
            device:emit_event(capabilities.switch.switch.off())
          end
        elseif kind == 'current_app' then
          -- Best-effort: the TV only sends this on some transitions (e.g.
          -- launching an app, going Home), not on every screen change --
          -- HDMI input switches, for example, did NOT trigger this during
          -- testing. So its absence doesn't mean nothing happened, but
          -- when it does show up, this is a genuine, real report from the
          -- TV of what's currently in the foreground.
          log.info('[googletv-report] current app: ' .. tostring(data.app_package))
        end
      end)

      if handle then
        device:set_field('remote_handle', handle, { persist = false })
        device:online()
        log.info('[googletv] ' .. device.label .. ': connected')
        backoff = 5 -- reset backoff after a successful connect
        if on_connected then
          on_connected(handle)
          on_connected = nil -- only the caller that triggered this attempt gets the callback
        end
        -- Block here for as long as this connection stays alive; the
        -- background reader thread inside remote.connect() flips
        -- handle.connected to false once it detects the connection is gone.
        while handle.connected do
          cosock_socket.sleep(2)
        end
        log.warn('[googletv] ' .. device.label .. ': connection lost, will retry reconnecting')
        device:set_field('remote_handle', nil, { persist = false })
        -- Deliberately NOT calling device:offline() here -- a dropped
        -- connection is the EXPECTED, normal result of the TV going to
        -- standby (or a routine reconnect cycle), not a genuine problem.
        -- Marking it offline here risked the app disabling interaction
        -- with the device at exactly the moment someone would want to tap
        -- "On" to wake it via WoL -- the opposite of what should happen.
        -- Real problems (e.g. pairing failure) still mark offline
        -- separately in init.lua.
      else
        log.warn('[googletv] ' .. device.label .. ': connect attempt failed: ' .. tostring(err))
      end

      cosock_socket.sleep(backoff)
      backoff = math.min(backoff * 2, 300)
      ::continue::
    end
  end, 'googletv-connect-' .. device.id)
end

-- Looks up (or lazily connects) the live remote-control connection for a
-- device. Returns the handle, or nil if the device isn't paired/connected
-- yet.
local function get_handle(device)
  return device:get_field('remote_handle')
end

local function send_key(device, keycode)
  local handle = get_handle(device)
  if not handle or not handle.connected then
    log.warn('[googletv] ' .. device.label .. ': not connected, ignoring command')
    return
  end
  remote.send_key(handle, keycode)
end

-- Ensures the remote-control connection is alive (waking the TV via
-- Wake-on-LAN and waiting for it to boot if necessary) before running
-- action_fn(handle). Used by switch_on's wake-nudge, and by any other
-- action (Home, Back, Screensaver, D-pad) that should also work even when
-- starting from the TV being fully off -- previously these silently did
-- nothing if the TV was off, which a tester reported for Screensaver
-- specifically ("doesn't work... starting when the TV is off").
local function wake_nudge(remote_handle)
  -- This only runs when tv_is_on is confirmed false (genuinely off), so
  -- sending POWER here is safe -- it's a toggle, and we know which way
  -- it'll go. Added after confirming the volume-only nudge doesn't wake
  -- Sony's picture at all, even though tv_is_on tracking itself is
  -- reliable there. Keeping the volume nudge too since it's confirmed
  -- necessary on TCL (Wake-on-LAN/an alive connection brings the system
  -- back but not the display by itself there).
  log.info('[googletv-diag] wake_nudge: sending POWER')
  remote.send_key(remote_handle, remotemessage.KEYCODE.POWER)
  cosock_socket.sleep(0.5)
  log.info('[googletv-diag] wake_nudge: sending VOLUME_UP')
  remote.send_key(remote_handle, remotemessage.KEYCODE.VOLUME_UP)
  cosock_socket.sleep(0.3)
  log.info('[googletv-diag] wake_nudge: sending VOLUME_DOWN')
  remote.send_key(remote_handle, remotemessage.KEYCODE.VOLUME_DOWN)
end

-- Ensures the TV is actually awake (not just "connected") before running
-- action_fn(handle). Checks the real tv_is_on state, not connection status
-- -- the TCP connection can stay alive across power off/on (e.g. with
-- "high consumption" energy mode keeping Wi-Fi up in standby), so being
-- connected does NOT mean the picture is actually on. If it's off, sends
-- the picture-wake nudge first (waking the network via Wake-on-LAN and
-- waiting for boot first, if not even connected), THEN runs action_fn.
-- This covers every action (Home, Back, Screensaver, D-pad, app launches),
-- not just switch_on -- previously only switch_on got this treatment, so
-- e.g. launching a favorite app while connected-but-off silently did
-- nothing.
local function ensure_awake_then(driver, device, action_fn)
  local tv_is_on = device:get_field('tv_is_on')
  local handle = get_handle(device)
  log.info('[googletv-diag] ensure_awake_then: tv_is_on=' .. tostring(tv_is_on) ..
    ' connected=' .. tostring(handle and handle.connected or false))

  if handle and handle.connected then
    if tv_is_on then
      log.info('[googletv-diag] ensure_awake_then: already on and connected, running action directly')
      action_fn(handle)
    else
      log.info('[googletv-diag] ensure_awake_then: connected but off -- sending wake nudge')
      wake_nudge(handle)
      cosock_socket.sleep(1.0) -- give the picture a moment to actually come on
      log.info('[googletv-diag] ensure_awake_then: nudge done, running action')
      action_fn(handle)
    end
    return
  end

  log.info('[googletv-diag] ensure_awake_then: not connected -- attempting Wake-on-LAN')
  local mac = device.preferences.macAddress
  if mac and mac ~= '' then
    local ok, err = wol.send(mac, device.preferences.ipAddress)
    if not ok then
      log.warn('[googletv] Wake-on-LAN failed: ' .. tostring(err))
      return
    end
    cosock.spawn(function()
      cosock_socket.sleep(8) -- give the TV time to finish booting
      log.info('[googletv-diag] ensure_awake_then: post-WoL wait done, reconnecting')
      M.connect_remote(driver, device, function(fresh_handle)
        -- Re-check tv_is_on NOW, not the stale value from 8+ seconds ago --
        -- the TV may have already come back on through an entirely
        -- separate reconnect in the meantime (confirmed via a real bug
        -- report: a delayed nudge fired after the TV was already
        -- naturally back on, and its POWER keypress toggled it back off,
        -- since POWER is a toggle). Only nudge if it's still genuinely off.
        if device:get_field('tv_is_on') then
          log.info('[googletv-diag] ensure_awake_then: already on by the time we reconnected -- skipping nudge, running action')
          action_fn(fresh_handle)
        else
          log.info('[googletv-diag] ensure_awake_then: reconnected after WoL -- sending wake nudge')
          wake_nudge(fresh_handle)
          cosock_socket.sleep(1.0)
          log.info('[googletv-diag] ensure_awake_then: nudge done, running action')
          action_fn(fresh_handle)
        end
      end)
    end, 'googletv-wake-then-' .. device.id)
  else
    log.warn('[googletv] ' .. device.label .. ': not connected and no MAC address set, cannot wake')
  end
end

function M.switch_on(driver, device, command)
  local tv_is_on = device:get_field('tv_is_on')

  if tv_is_on then
    -- The TV itself already told us it's on (via a remote_start message) --
    -- nothing to do. Note this is NOT the same check as "connected": the
    -- TCP connection can stay alive across power off/on (e.g. with "high
    -- consumption" energy mode keeping Wi-Fi up in standby), so connection
    -- status alone can't tell us whether the display is actually on.
    device:emit_event(capabilities.switch.switch.on())
    return
  end

  -- ensure_awake_then applies the picture-wake nudge automatically
  -- whenever tv_is_on is false -- that's exactly all switch_on needs.
  ensure_awake_then(driver, device, function() end)
  device:emit_event(capabilities.switch.switch.on())
end

function M.switch_off(driver, device, command)
  local tv_is_on = device:get_field('tv_is_on')
  log.info('[googletv-diag] switch_off: tv_is_on=' .. tostring(tv_is_on))
  if tv_is_on == false then
    -- We already know the TV is off (via a real remote_start report) --
    -- the POWER key is a TOGGLE on this protocol, not a discrete "off",
    -- so sending it here would actually turn the TV back ON. Confirmed
    -- via a Sony Android TV test: pressing "off" while already off
    -- toggled it back on. Nothing to send, but we DO still need to sync
    -- the app's UI to "off" here -- confirmed via a second Sony test that
    -- skipping this emit left the switch stuck showing stale "on" even
    -- though our own tv_is_on tracking was already correctly false.
    log.info('[googletv-diag] switch_off: already off, skipping POWER to avoid re-toggling on')
    device:emit_event(capabilities.switch.switch.off())
    return
  end
  log.info('[googletv-diag] switch_off: sending POWER')
  send_key(device, remotemessage.KEYCODE.POWER)
  -- Don't optimistically emit "off" here -- the TV will tell us via a real
  -- remote_start event once it actually changes state, which is also what
  -- keeps the app's displayed state correct when power is toggled from the
  -- physical remote instead of from here.
end

function M.media_play(driver, device, command)
  send_key(device, remotemessage.KEYCODE.MEDIA_PLAY_PAUSE)
  device:emit_event(capabilities.mediaPlayback.playbackStatus.playing())
end

function M.media_pause(driver, device, command)
  send_key(device, remotemessage.KEYCODE.MEDIA_PLAY_PAUSE)
  device:emit_event(capabilities.mediaPlayback.playbackStatus.paused())
end

function M.media_stop(driver, device, command)
  send_key(device, remotemessage.KEYCODE.MEDIA_STOP)
  device:emit_event(capabilities.mediaPlayback.playbackStatus.stopped())
end

function M.media_fast_forward(driver, device, command)
  send_key(device, remotemessage.KEYCODE.MEDIA_FAST_FORWARD)
end

function M.media_rewind(driver, device, command)
  send_key(device, remotemessage.KEYCODE.MEDIA_REWIND)
end

function M.next_track(driver, device, command)
  send_key(device, remotemessage.KEYCODE.MEDIA_PREVIOUS)
end

function M.previous_track(driver, device, command)
  send_key(device, remotemessage.KEYCODE.MEDIA_NEXT)
end

function M.channel_up(driver, device, command)
  send_key(device, remotemessage.KEYCODE.CHANNEL_UP)
end

function M.channel_down(driver, device, command)
  send_key(device, remotemessage.KEYCODE.CHANNEL_DOWN)
end

-- HDMI input switching was removed after a mixed, inconclusive testing
-- history (worked once, failed twice including a retest specifically
-- designed to reproduce the one success). Not worth the device-page
-- clutter given it can't be trusted to actually work. Full history is in
-- memory/notes if this needs revisiting -- would need a genuinely clean,
-- repeatable positive result (not just one ambiguous success) before
-- re-adding.

function M.mute(driver, device, command)
  send_key(device, remotemessage.KEYCODE.MUTE)
  device:emit_event(capabilities.audioMute.mute.muted())
end

function M.unmute(driver, device, command)
  send_key(device, remotemessage.KEYCODE.MUTE)
  device:emit_event(capabilities.audioMute.mute.unmuted())
end

function M.volume_up(driver, device, command)
  send_key(device, remotemessage.KEYCODE.VOLUME_UP)
end

function M.volume_down(driver, device, command)
  send_key(device, remotemessage.KEYCODE.VOLUME_DOWN)
end

-- audioVolume's setVolume takes an absolute 0-100 target. This protocol
-- only exposes relative up/down key presses, so we approximate by nudging
-- toward the target from the last volume level we were told about (via a
-- RemoteSetVolumeLevel push from the TV) -- this is a best-effort
-- approximation, not a guarantee, since the TV's actual step size per key
-- press isn't something this protocol reports.
function M.set_volume(driver, device, command)
  local target = command.args.volume
  local last = device:get_field('last_volume_level')
  local handle = get_handle(device)
  if not handle or not handle.connected then
    log.warn('[googletv] ' .. device.label .. ': not connected, ignoring setVolume')
    return
  end
  if not last then
    log.warn('[googletv] ' .. device.label .. ': no known current volume yet, cannot compute a relative move for setVolume')
    return
  end
  local steps = target - last
  local keycode = steps > 0 and remotemessage.KEYCODE.VOLUME_UP or remotemessage.KEYCODE.VOLUME_DOWN
  for _ = 1, math.abs(steps) do
    remote.send_key(handle, keycode)
  end
end

-- Tapping "refresh" in the app runs a full connectivity/TLS diagnostic
-- and logs a clean report -- this is the go-to first step for triaging a
-- report from someone else ("tap the refresh icon on the device, then
-- send me the logcat output").
function M.refresh(driver, device, command)
  diagnostics.run(device)
end

-- A curated set of popular apps, launched via Android app-link deep links
-- through the existing remote_app_link_launch_request mechanism. There's
-- no way to get a full dynamic list of installed apps from this protocol
-- -- it simply doesn't expose that at all (this is the same protocol
-- Google's own Android TV Remote app uses, and even that can't enumerate
-- installed apps through it) -- so this is a fixed, curated list rather
-- than a live app picker. Each preset's "id" is what the app sends back
-- in playPreset's presetId argument.
--
-- Only YouTube has actually been confirmed working. The rest are each
-- service's own web URL, which Android *should* resolve to the
-- corresponding app via verified app links if it's installed -- but
-- that's untested here and may not work for every app/region.
M.APP_PRESETS = {
  { id = 'kan_box', name = 'Kan Box', url = 'market://launch?id=com.applicaster.il.ch1' },
  { id = 'channel_14', name = 'Channel 14', url = 'market://launch?id=com.channelfourteen.univ' },
  { id = 'reshet_13', name = 'Reshet 13', url = 'market://launch?id=com.applicaster.iReshet' },
  { id = 'n12', name = 'N12', url = 'market://launch?id=com.keshet.mako.VODAndroidTV' },
  { id = 'hot', name = 'HOT', url = 'market://launch?id=il.net.hot.hot' },
  { id = 'yes', name = 'yes', url = 'market://launch?id=il.co.yes.yesplus' },
  { id = 'cellcom_tv', name = 'Cellcom TV', url = 'market://launch?id=com.cellcom.cellcom_tv' },
  { id = 'free_tv', name = 'Free TV', url = 'market://launch?id=tv.freetv.androidtv' },
  { id = 'i24news', name = 'i24NEWS', url = 'market://launch?id=tv.accedo.ott.flow.i24news' },
  { id = 'channel_10', name = 'Channel 10', url = 'market://launch?id=il.co.tv10.vod.atv' },
  { id = 'partner_tv', name = 'Partner TV', url = 'market://launch?id=il.co.partnertv.atv' },
  { id = 'sting_tv', name = 'Sting TV', url = 'market://launch?id=il.co.stingtv.atv' },
  { id = 'youtube', name = 'YouTube', url = 'market://launch?id=com.google.android.youtube.tv' },
  { id = 'youtube_music', name = 'YouTube Music', url = 'market://launch?id=com.google.android.youtube.tvmusic' },
  { id = 'netflix', name = 'Netflix', url = 'market://launch?id=com.netflix.ninja' },
  { id = 'prime_video', name = 'Prime Video', url = 'market://launch?id=com.amazon.amazonvideo.livingroom' },
  { id = 'disney_plus', name = 'Disney+', url = 'market://launch?id=com.disney.disneyplus' },
  { id = 'spotify', name = 'Spotify', url = 'market://launch?id=com.spotify.tv.android' },
  { id = 'hulu', name = 'Hulu', url = 'market://launch?id=com.hulu.livingroomplus' },
  { id = 'max', name = 'Max', url = 'market://launch?id=com.wbd.stream' },
  { id = 'apple_tv', name = 'Apple TV', url = 'market://launch?id=com.apple.atve.androidtv.appletv' },
  { id = 'plex', name = 'Plex', url = 'market://launch?id=com.plexapp.android' },
  { id = 'twitch', name = 'Twitch', url = 'market://launch?id=tv.twitch.android.app' },
  { id = 'peacock', name = 'Peacock', url = 'market://launch?id=com.peacocktv.peacockandroid' },
  { id = 'paramount_plus', name = 'Paramount+', url = 'market://launch?id=com.cbs.app' },
  { id = 'pluto_tv', name = 'Pluto TV', url = 'market://launch?id=tv.pluto.android' },
  { id = 'tubi', name = 'Tubi', url = 'market://launch?id=com.tubitv' },
  { id = 'apple_music', name = 'Apple Music', url = 'market://launch?id=com.apple.android.music' },
}

-- Any user-defined additions, via the "Custom apps" device setting --
-- format: "Name|https://url.com, Name2|https://url2.com". This is how
-- someone gets an app that isn't in the curated list above, since there's
-- no way for the driver to discover what's actually installed.
local function parse_custom_apps(setting_value)
  local out = {}
  if not setting_value or setting_value == '' then return out end
  for entry in setting_value:gmatch('[^,]+') do
    local name, url = entry:match('^%s*(.-)%s*|%s*(.-)%s*$')
    if name and url and name ~= '' and url ~= '' then
      out[#out + 1] = { id = 'custom_' .. #out, name = name, url = url }
    end
  end
  return out
end
M.parse_custom_apps = parse_custom_apps

-- Builds the full preset list (curated + custom) for a specific device,
-- and a matching id->url lookup table for play_preset to use.
local function all_presets_for(device)
  local custom = parse_custom_apps(device.preferences.customApps)
  local all = {}
  for _, p in ipairs(custom) do all[#all + 1] = p end
  for _, p in ipairs(M.APP_PRESETS) do all[#all + 1] = p end
  return all
end
M.all_presets_for = all_presets_for

function M.play_preset(driver, device, command)
  local preset_id = command.args.presetId
  local search = tostring(preset_id):lower()
  local target
  for _, p in ipairs(all_presets_for(device)) do
    if p.id:lower() == search or p.name:lower() == search then target = p end
  end
  if not target then
    log.warn('[googletv] ' .. device.label .. ': unknown preset "' .. tostring(preset_id) ..
      '" -- doesn\'t match any preset by id or name')
    return
  end
  ensure_awake_then(driver, device, function(handle)
    local ok, err = remote.send_app_link(handle, target.url)
    if ok then
      log.info('[googletv-diag] play_preset: send_app_link succeeded for "' .. target.name .. '" (' .. target.url .. ')')
    else
      log.warn('[googletv-diag] play_preset: send_app_link FAILED for "' .. target.name .. '": ' .. tostring(err))
    end
  end)
end

-- Home/Back/D-pad navigation via the standard "keypadInput" capability --
-- this gets a native circular D-pad UI from the SmartThings app itself
-- (confirmed via a real device screenshot), no custom capability/
-- presentation needed. Enum values confirmed directly from the platform
-- via `smartthings capabilities keypadInput --capability-version 1 --standard`.
local KEYPAD_KEYCODE_MAP = {
  UP = remotemessage.KEYCODE.DPAD_UP,
  DOWN = remotemessage.KEYCODE.DPAD_DOWN,
  LEFT = remotemessage.KEYCODE.DPAD_LEFT,
  RIGHT = remotemessage.KEYCODE.DPAD_RIGHT,
  SELECT = remotemessage.KEYCODE.DPAD_CENTER,
  BACK = remotemessage.KEYCODE.BACK,
  EXIT = remotemessage.KEYCODE.ESCAPE,
  HOME = remotemessage.KEYCODE.HOME,
  MENU = remotemessage.KEYCODE.MENU,
  SETTINGS = remotemessage.KEYCODE.SETTINGS,
  NUMBER0 = remotemessage.KEYCODE.NUMBER_0,
  NUMBER1 = remotemessage.KEYCODE.NUMBER_1,
  NUMBER2 = remotemessage.KEYCODE.NUMBER_2,
  NUMBER3 = remotemessage.KEYCODE.NUMBER_3,
  NUMBER4 = remotemessage.KEYCODE.NUMBER_4,
  NUMBER5 = remotemessage.KEYCODE.NUMBER_5,
  NUMBER6 = remotemessage.KEYCODE.NUMBER_6,
  NUMBER7 = remotemessage.KEYCODE.NUMBER_7,
  NUMBER8 = remotemessage.KEYCODE.NUMBER_8,
  NUMBER9 = remotemessage.KEYCODE.NUMBER_9,
}
M.SUPPORTED_KEYPAD_CODES = {
  'UP', 'DOWN', 'LEFT', 'RIGHT', 'SELECT', 'BACK', 'EXIT', 'HOME', 'MENU', 'SETTINGS',
  'NUMBER0', 'NUMBER1', 'NUMBER2', 'NUMBER3', 'NUMBER4',
  'NUMBER5', 'NUMBER6', 'NUMBER7', 'NUMBER8', 'NUMBER9',
}

function M.send_keypad_key(driver, device, command)
  local key_code = command.args.keyCode
  local mapped = KEYPAD_KEYCODE_MAP[key_code]
  if not mapped then
    log.warn('[googletv] ' .. device.label .. ': unsupported keypad key ' .. tostring(key_code))
    return
  end
  send_key(device, mapped)
end

-- Dedicated Home button via a separate "home" component's momentary
-- capability -- momentary's "push" command takes no arguments, so unlike
-- keypadInput's sendKey (which needs a keyCode argument), this one shows
-- up as an available action in the Routines builder.
-- Both the "home" and "screensaver" components use the standard momentary
-- capability (same reasoning as before: no-argument commands are what
-- actually show up as Routine actions), so this one handler dispatches by
-- which component triggered it.
local CREATOR_DEVICE_NETWORK_ID = 'googletv-creator-device'

function M.momentary_press(driver, device, command)
  if device.device_network_id == CREATOR_DEVICE_NETWORK_ID then
    -- This is the permanent "Add new Google TV" button device, not a real
    -- TV. Pressing it is the explicit user action that creates an actual
    -- pairable Google TV device -- see init.lua's discovery_handler for
    -- why this replaced creating a real device directly from discovery.
    local id = 'googletv-' .. tostring(math.random(100000, 999999))
    local ok, err = driver:try_create_device({
      type = 'LAN',
      device_network_id = id,
      label = 'Google TV',
      profile = 'googletv.v1',
      manufacturer = 'Generic',
      model = 'Google TV',
      vendor_provided_label = 'Google TV',
    })
    if not ok then
      log.error('[googletv] failed to create new TV device: ' .. tostring(err))
    end
    return
  end

  local DPAD_COMPONENT_KEYCODE = {
    dpadUp = remotemessage.KEYCODE.DPAD_UP,
    dpadDown = remotemessage.KEYCODE.DPAD_DOWN,
    dpadLeft = remotemessage.KEYCODE.DPAD_LEFT,
    dpadRight = remotemessage.KEYCODE.DPAD_RIGHT,
    dpadCenter = remotemessage.KEYCODE.DPAD_CENTER,
  }
  if command.component == 'liveTv' then
    ensure_awake_then(driver, device, function(handle)
      remote.send_key(handle, remotemessage.KEYCODE.TV)
    end)
  elseif command.component == 'home' then
    ensure_awake_then(driver, device, function(handle)
      remote.send_key(handle, remotemessage.KEYCODE.HOME)
    end)
  elseif command.component == 'back' then
    ensure_awake_then(driver, device, function(handle)
      remote.send_key(handle, remotemessage.KEYCODE.BACK)
    end)
  elseif command.component == 'screensaver' then
    -- Go home first so this works reliably regardless of what's on screen,
    -- then a single Back press triggers the screensaver. (History: tried
    -- launching Google TV's own Ambient Mode app directly via
    -- com.google.android.apps.tv.dreamx -- confirmed NOT to work, opens
    -- the Play Store listing instead of launching. Also originally sent
    -- Back twice based on a commonly-misread "press Back twice" trick --
    -- that description covers two separate steps, an implicit first Back
    -- to reach home then a second Back to activate the screensaver, so
    -- since Home already guarantees the starting state, only one
    -- subsequent Back is actually needed. Delay after Home increased from
    -- 1.5s -- a tester reported it's less reliable coming from a deep app
    -- screen, which likely needs more time to settle back to the home
    -- screen before the Back press. Also now wakes the TV first via
    -- Wake-on-LAN if it's fully off, rather than silently doing nothing --
    -- another gap the same tester reported.)
    ensure_awake_then(driver, device, function(handle)
      log.info('[googletv-diag] screensaver: sending HOME')
      remote.send_key(handle, remotemessage.KEYCODE.HOME)
      cosock_socket.sleep(2.5)
      log.info('[googletv-diag] screensaver: sending BACK')
      remote.send_key(handle, remotemessage.KEYCODE.BACK)
    end)
  elseif DPAD_COMPONENT_KEYCODE[command.component] then
    ensure_awake_then(driver, device, function(handle)
      remote.send_key(handle, DPAD_COMPONENT_KEYCODE[command.component])
    end)
  else
    log.warn('[googletv] ' .. device.label .. ': momentary press on unknown component ' .. tostring(command.component))
  end
end

return M
