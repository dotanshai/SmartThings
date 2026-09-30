--[[
  Copyright 2023 Todd Austin
  Modifications Copyright 2026 Shai D. (changes: unsigned-registration fallback for newer LG
  firmware, automatic re-pairing, real connection status, built-in app list fallback,
  friendly names for system apps)

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  LG TV Driver

  Reference:  https://github.com/klattimer/LGWebOSRemote/tree/master/LGTV

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"                                  -- for time only
local log = require "log"
local utils = require "st.utils"

-- Driver modules
local ws = require 'websocket'
local discovery = require "discovery"
local semaphore = require "semaphore"
local authdata = require "authreq"
local orig_signatures = authdata.payload.manifest.signatures

-- Friendly names for well-known system screens (used when the TV app list is not available)
local FRIENDLY_IDS = {
  ['com.webos.app.home']        = 'Home',
  ['com.palm.app.settings']     = 'Settings',
  ['com.webos.app.discovery']   = 'LG Content Store / Free TV',
  ['com.webos.app.browser']     = 'Web Browser',
  ['com.webos.app.livetv']      = 'Live TV',
  ['spotify-beehive']           = 'Spotify',
  ['spotify-beta']              = 'Spotify',
}
local cx = require "common"
local wol = require "wakeonlan"

newly_added = {}
found_hubs = {}
local applists = {}

-- Device Capabilities

cap_lgmsg = capabilities["partyvoice23922.lgmessage"]
cap_lginput = capabilities["partyvoice23922.lgmediainputsource"]
cap_status = capabilities["partyvoice23922.status"]
cap_channel = capabilities["partyvoice23922.lgcurrentchannel"]
cap_app = capabilities["partyvoice23922.lgcurrentapp"]
cap_channel_number = capabilities["partyvoice23922.lgchannelnumber"]
cap_volup = capabilities["partyvoice23922.lgvolumeup"]
cap_voldown = capabilities["partyvoice23922.lgvolumedown"]

-- Global variables
thisDriver = {}
hubs_auto_discovered = 0
disco_sem = {}

-- Module variables
local initialized = false
local devices_inited = 0

-- WebSocket OpCodes
local CONTINUE_FRAME = 0
local TEXT_FRAME = 1
local BINARY_FRAME = 2
local CONNECTED_CLOSE_FRAME = 8
local PING_FRAME = 9
local PONG_FRAME = 10

-- WebSocket Constants
local SSL_PARMS = {
                    mode = "client",
                    protocol = "any",
                    verify = "none",
                    options = "all"
                  }

-- CONSTANTS
local WSSPORT = 3001

local MAXCMDIDS = 99
local MAX_CMD_AGE = 30000    -- (milliseconds) if sent cmds old, they'll be deleted (assume they were ignored by hub)

local POSTCMD_REFRESH_DELAY = 5   -- number of seconds to wait before issuing refresh after a command

DEVICE_PROFILE = 'lgtv.v2d'

------------------------------------------------------------------------


function send_command(device, msgdata, is_handshake)
  
  -- Do not send requests until the TV has confirmed registration (TV answers 401 otherwise)
  if not is_handshake and device:get_field('reg_ok') ~= true then
    log.warn('Not registered with TV yet - message not sent')
    return
  end
  
  local client = device:get_field('ws_client')
  if client then
  
    local ok, close_was_clean, close_code, close_reason = client:send(msgdata)

    if not ok then
      log.error ('Websocket Send failed:')
      log.error (close_was_clean, close_code, close_reason)
    else
      log.info ('Message sent')
    end

  else
    log.warn ('Cannot send message; not connected', msgdata)
  end

end


local wsmsgid = 0

local function gen_msgid(prefix)

  wsmsgid = wsmsgid + 1
  
  if wsmsgid > 999 then; wsmsgid = 1; end

  if prefix then
    return prefix .. '_' .. tostring(wsmsgid)
  else
    return tostring(wsmsgid)
  end
  
end

local function build_messsage(msgtype, uri, payload, prefix)

  local msgobj = {}
  
  msgobj.type = msgtype
  msgobj.id = gen_msgid(prefix)
  msgobj.uri = uri
  if payload then
    msgobj.payload = payload
  end
  
  return cx.encode_json(msgobj)

end

local function update_device(device)

  send_command(device, build_messsage("request", "ssap://com.webos.service.tvpower/power/getPowerState"))
  
  socket.sleep(.5)
  
  send_command(device, build_messsage("request", "ssap://com.webos.service.apiadapter/audio/getSoundOutput"))
  
  socket.sleep(.5)
  
  send_command(device, build_messsage("request", "ssap://audio/getStatus"))
  
  socket.sleep(.5)
  
  send_command(device, build_messsage("request", "ssap://tv/getCurrentChannel"))
  
  socket.sleep(.5)
  
  send_command(device, build_messsage("request", "ssap://com.webos.applicationManager/getForegroundAppInfo"))

end

local function reset_refresh_timer(device)

  if device:get_field('refresh_timer') then; thisDriver:cancel_timer(device:get_field('refresh_timer')); end
  
  local timer = thisDriver:call_on_schedule(device.preferences.freq, function()
      update_device(device)
    end)
    
  device:set_field('refresh_timer', timer)

end


-- Built-in app list, used when the TV refuses to list its apps (unsigned registration on newer firmware)
local DEFAULT_APPS = {
  { id = 'netflix',                    name = 'Netflix' },
  { id = 'youtube.leanback.v4',        name = 'YouTube' },
  { id = 'amazon',                     name = 'Prime Video' },
  { id = 'com.disney.disneyplus-prod', name = 'Disney+' },
  { id = 'com.apple.appletv',          name = 'Apple TV' },
  { id = 'spotify-beehive',            name = 'Spotify' },
  { id = 'spotify-beta',               name = 'Spotify (older TVs)' },
  { id = 'cdp-30',                     name = 'Plex' },
  { id = 'com.webos.app.livetv',       name = 'Live TV' },
  { id = 'com.webos.app.discovery',    name = 'LG Content Store / Free TV' },
  { id = 'makotv',                     name = 'Mako (Channel 12)' },
  { id = 'com.applicaster.il.ch1',     name = 'Kan 11' },
  { id = 'com.domain.hotapp',          name = 'HOT' },
  { id = 'com.webos.app.browser',      name = 'Web Browser' },
}

local function init_device(device)

  device:set_field('apps_loaded', false)
  update_device(device)
  
  socket.sleep(.5)
  
  send_command(device, build_messsage("request", "ssap://com.webos.applicationManager/listApps", nil, 'listapps'))
  
  socket.sleep(.5)
  
  -- Fallback source of the app list (works even when listApps is refused with an unsigned registration)
  send_command(device, build_messsage("request", "ssap://com.webos.applicationManager/listLaunchPoints", nil, 'launchpts'))
  
  -- If the TV did not give us an app list within a few seconds, use the built-in list
  thisDriver:call_with_delay(6, function()
      if not device:get_field('apps_loaded') then
        log.warn('No app list from TV - using built-in app list')
        device:emit_event(capabilities.mediaPresets.presets(DEFAULT_APPS))
        device:emit_event(cap_status.status('Registered - built-in app list'))
      end
    end)
  
  reset_refresh_timer(device)

end


local function parse_response(device, payload)


  local is_applist = false

  for key, value in pairs(payload) do
  
    if key == 'state' then
      if (value == 'Suspend') or (value == 'Request Suspend') then
        device:emit_event(capabilities.switch.switch('off'))
      else
        device:emit_event(capabilities.switch.switch('on'))
      end
      
    elseif key == 'volume' then
      device:emit_event(capabilities.audioVolume.volume(tonumber(value)))
      
    elseif key == 'mute' then
      local mutestate = {['true'] = 'muted', ['false'] = 'unmuted'}
      device:emit_event(capabilities.audioMute.mute(mutestate[tostring(value)]))
      
    elseif key == 'apps' or key == 'launchPoints' then
    
      local applist = {}
      for _, app in ipairs(value) do
        table.insert(applist, { id = app.id, name = app.title })
      end
      device:set_field('apps_loaded', true)
      device:emit_event(capabilities.mediaPresets.presets(applist))
      device:emit_event(cap_status.status('Registered - ' .. tostring(#applist) .. ' apps (' .. tostring(key) .. ')'))
      is_applist = true
        
    elseif key == 'channelName' then
      
      local channel = payload.channelNumber .. ' - ' .. value
      device:emit_component_event(device.profile.components.main, cap_channel.currentChannel(channel))
      device:emit_component_event(device.profile.components.main, cap_channel_number.channelNumber(tonumber(payload.channelNumber)))
    
    elseif (key == 'appId') or ((key == 'id') and (is_applist == false)) then
    
      local appname
      
      local inputsources = {
                              { appid='com.webos.app.hdmi1', source='HDMI 1' },
                              { appid='com.webos.app.hdmi2', source='HDMI 2' },
                              { appid='com.webos.app.hdmi3', source='HDMI 3' },
                              { appid='com.webos.app.hdmi4', source='HDMI 4' },
                              { appid='com.webos.app.externalinput.av1', source='AV' },
                              { appid='com.webos.app.externalinput.component', source='Component' },
                              { appid='com.webos.app.livetv', source='LIVE TV' },
                            }
      
      local cache = device.state_cache
      local presets = cache and cache.main and cache.main.mediaPresets and cache.main.mediaPresets.presets and cache.main.mediaPresets.presets.value
      if presets then
        for _, element in ipairs(presets) do
          if element.id == value then
            appname = element.name
            break
          end
        end
      end
      
      -- Fallbacks when the app list is not available: input name, else the raw app id
      if not appname then
        for _, rec in ipairs(inputsources) do
          if rec.appid == value then
            appname = rec.source
            break
          end
        end
      end
      if not appname and type(value) == 'string' then
        appname = FRIENDLY_IDS[value] or value
      end
      
      if appname then
    
        log.debug ('App name:', appname)
        
        device:emit_event(cap_app.currentApp(appname))
        
        local mediainputsource
                              
        for _, rec in ipairs(inputsources) do
          if rec.appid == value then
            mediainputsource = rec.source
            break
          end
        end
        
        if mediainputsource then
          device:emit_event(cap_lginput.inputsource(mediainputsource))
        end
        
      else
        log.warn ('App name not determined')
      end
    
    end
  end

end


local handshake_lgtv

local function handle_response_frame(device, payload)

  local response_table = cx.decode_json(payload)
  if response_table == nil then; return; end
  
  --cx.disptable(response_table, '  ', 3)
  
  if response_table.type == 'response' then
    if response_table.id == 'register_0' then
      if response_table.payload.pairingType == 'PROMPT' then
        log.info('Pairing...')
        device:set_field('reg_pairing', true)
        device:emit_event(cap_status.status('Pairing - ACCEPT on TV screen'))
      else
        log.warn('Unexpected pairing type', response_table.payload.pairintType)
        device:emit_event(cap_status.status(response_table.payload.pairingType))
      end
    else
      log.info(string.format('Response message to be handled id=%s:', response_table.id))
      if response_table.payload then
        if not response_table.payload.apps then
          cx.disptable(response_table.payload, '  ', 4)
        end
        
        print ("returnValue:", response_table.payload.returnValue, type(response_table.payload.returnValue))
        if response_table.payload.returnValue == true then
          parse_response(device, response_table.payload)
        else
          log.error('Unexpected returnValue', response_table.payload.returnValue)
          local rid = tostring(response_table.id)
          if string.find(rid, 'listapps', 1, true) or string.find(rid, 'launchpts', 1, true) then
            log.warn('App list request refused by TV (returnValue false)')
          end
        end
      else
        log.warn('Empty payload - no action taken')
      end
    end
  
  elseif response_table.type == 'registered' then
    log.info ('Successfully registered with LG webOS; key=', response_table.payload['client-key'])
    device:set_field('reg_ok', true)
    device:set_field('lg_registration_key', response_table.payload['client-key'], { ['persist'] = true })
    device:emit_event(cap_status.status('Registered'))
    init_device(device)
  
  elseif response_table.type == 'error' then
    local errtext = tostring(response_table.error)
    if response_table.payload and response_table.payload.errorText then
      errtext = errtext .. ' - ' .. tostring(response_table.payload.errorText)
    end
    log.error('Error reported in response: ' .. errtext)
    if response_table.id ~= 'register_0' and device:get_field('reg_ok') == true then
      -- Registered OK; the TV just refused one optional request (e.g. permission not granted). Log only.
      local rid = tostring(response_table.id)
      if string.find(rid, 'listapps', 1, true) or string.find(rid, 'launchpts', 1, true) then
        log.warn('App list request refused by TV: ' .. errtext)
      end
      log.warn('Non-fatal TV error for request id ' .. tostring(response_table.id) .. ' (Status left unchanged)')
      return
    end
    device:set_field('reg_err', true)
    device:emit_event(cap_status.status('TV error: ' .. string.sub(errtext, 1, 80)))
    local blacklisted = string.find(errtext, 'blacklist', 1, true)
    if blacklisted and not device:get_field('use_unsigned') then
      -- Newer LG firmware rejects the old signed test manifest: retry with an unsigned manifest
      log.warn('TV rejected signed manifest - retrying with UNSIGNED manifest')
      device:set_field('use_unsigned', true, { ['persist'] = true })
      device:set_field('lg_registration_key', nil, { ['persist'] = true })
      handshake_lgtv(device)
      return
    end
    -- If the TV says we are not registered / rejected our key: forget the key and pair again (max once per 30s)
    if (not blacklisted) and (response_table.id == 'register_0' or string.find(errtext, '401', 1, true)) and device:get_field('reg_ok') ~= true then
      local now = socket.gettime()
      local last = device:get_field('last_repair') or 0
      if (now - last) > 30 then
        device:set_field('last_repair', now)
        log.warn('Not registered / key rejected - clearing stored key and re-pairing')
        device:set_field('lg_registration_key', nil, { ['persist'] = true })
        handshake_lgtv(device)
      end
    end
  
  else
    log.warn(string.format('Unexpected message type: %s; with following payload:', response_table.type))
    if response_table.payload then
      cx.disptable(response_table.payload, '  ', 4)
    end
  end
  
end


handshake_lgtv = function(device)

  local handshake = authdata

  -- authdata is a shared table: always set (or clear) the key explicitly for THIS device
  handshake.payload['client-key'] = device:get_field('lg_registration_key')
  if handshake.payload['client-key'] then
    log.info('Handshake (with stored key)')
  else
    log.info('Handshake (no key - TV should show a pairing prompt)')
  end
  
  if device:get_field('use_unsigned') then
    handshake.payload.manifest.signatures = nil
    log.info('Using UNSIGNED manifest')
  else
    handshake.payload.manifest.signatures = orig_signatures
  end
  
  device:set_field('reg_ok', false)
  device:set_field('reg_err', false)
  device:set_field('reg_pairing', false)
  send_command(device, cx.encode_json(handshake), true)

  -- Watchdog: if the TV never confirms registration, say so in Status instead of staying 'Connected'
  thisDriver:call_with_delay(12, function()
      if not device:get_field('reg_ok') and not device:get_field('reg_err') and not device:get_field('reg_pairing') and device:get_field('ws_client') then
        log.warn('No registration confirmation from TV after 12 seconds')
        device:emit_event(cap_status.status('No reply from TV - accept prompt on TV'))
      end
    end)

end


local function pingmonitor()

  log.debug('Checking last pings...')

  local devicelist = thisDriver:get_devices()
  
  for _, device in ipairs(devicelist) do
  
    if device:get_field('ws_client') then
    
      local time_since_last_ping = socket.gettime() - device:get_field('lastping')
    
      if (time_since_last_ping) > 60 then
      
        log.warn(string.format('%s has not pinged in %s seconds', device.label, time_since_last_ping))
        
        device:offline()
        device:set_field('ws_client', nil)
        local sock = device:get_field('ws_sock')
        device:set_field('ws_sock', nil)
        thisDriver:unregister_channel_handler(sock)
        
        device.thread:queue_event(init_connection, device)
        
      end
    end
  end

end


-- Initialize hub connection
function init_connection(device)

  local wssaddr = device:get_field('WSSaddr')
  log.debug ('Retrieved device address:', wssaddr)

  device:emit_event(capabilities.switch.switch('off'))

  local uri = 'wss://' .. wssaddr
  --local uri = 'ws://' .. wssaddr
  
  log.info (string.format('Initializing %s at %s', device.label, uri))

  local client = ws.client.sync({timeout=2})
          
  if not client then
    log.error ('Failed to create websocket client')
    return
  end
  
  local ok, code, headers, sock = client:connect(uri,'echo', SSL_PARMS)
  --local ok, code, headers, sock = client:connect(uri,'echo')
  
  log.info (string.format('%s: WS Connect returned: ok=%s, code=%s, headers=%s', device.label, ok, code, headers))
  
  if not ok then
    log.error ('Could not connect:', code)
    log.info(string.format('%s: WS Connect will retry in 15 seconds', device.label))
    device:emit_event(cap_status.status('Connect retry (' .. wssaddr .. ')'))
    --device:offline()
    local retrytimer = thisDriver:call_with_delay(15, function()
        init_connection(device)
      end)
    device:set_field('retrytimer', retrytimer)
    return
  end
  
  -- Get here if connected successfully
  device:online()
  device:emit_event(cap_status.status('Connected, registering...'))
  
  device:set_field('retrytimer', nil)
  device:set_field('ws_client', client)
  device:set_field('ws_sock', sock)

  thisDriver:register_channel_handler(sock, function ()
      local payload, opcode, c, d, err = client:receive()
      
      log.debug (string.format('Received opcode=%s, c=%s, d=%s, err=%s', opcode, c, d, err))
      
      if opcode ~= PING_FRAME then
        
        if opcode == TEXT_FRAME then
          log.info ('WS RX: ' .. tostring(payload))
          handle_response_frame(device, payload)
          
        elseif opcode == CONNECTED_CLOSE_FRAME then
          log.warn ('Connection has been closed by request')
          device:emit_event(cap_status.status('Connection closed'))
          thisDriver:unregister_channel_handler(sock)
          sock:close()
          device:emit_event(capabilities.switch.switch('off'))
          return
        end
        
      else
        client:send(payload, PONG_FRAME)
        device:set_field('lastping', socket.gettime())
      end
      
      if err then
      
        if err == 'closed' then
          log.warn ('Connection has been closed')
          device:emit_event(capabilities.switch.switch('off'))
        else
          log.error ('Receive error:', err)
          device:offline()
        end
        
        device:set_field('ws_client', nil)
        device:set_field('ws_sock', nil)
        thisDriver:unregister_channel_handler(sock)
        device:emit_event(cap_status.status('Connect retry...'))
        log.info(string.format('%s: WS Re-Connect attempt in 15 seconds', device.label))
        local retrytimer = thisDriver:call_with_delay(15, function()
            init_connection(device)
          end)
        device:set_field('retrytimer', retrytimer)
        return
        
      end
    end)
 
  handshake_lgtv(device)
  
end


local function shutdown_device(driver, device, msg)

  if device:get_field('retrytimer') then
    thisDriver:cancel_timer(device:get_field('retrytimer'))
  end
  
  if device:get_field('refresh_timer') then
    thisDriver:cancel_timer(device:get_field('refresh_timer'))
  end

  local client = device:get_field('ws_client')
  if client then
    local was_clean,code,reason = client:close(1000, msg)
    log.debug('Client close result:', was_clean, code, reason)
  end
  
  device:set_field('ws_client', nil)
  device:set_field('ws_sock', nil)

end


------------------------------------------------------------------------
--                    CAPABILITY HANDLERS
------------------------------------------------------------------------


local function handle_refresh(driver, device, command)
  -- note: refreshes can be Edge-induced or user-induced
  log.info (string.format('>>> Refresh requested for %s<<<', device.label))
  
 
  -- Inhibit refreshes during device creation
  local gorefresh = true
  if device:get_field('createtime') then
    local now = socket.gettime()
    local diff = now - device:get_field('createtime')
    log.debug ('Time since creation', diff)
    if diff < 5 then
      gorefresh = false
    end
  end
  
  if gorefresh then
  
    if not device:get_field('ws_client') then
      if device:get_field('retrytimer') then
        driver:cancel_timer(device:get_field('retrytimer'))
      end
      
      device.thread:queue_event(init_connection, device)
      
    else
      init_device(device)
    end
      
    device:set_field('lastrefresh', socket.gettime())
    
  else
    log.info ('>>>> Refresh ignored')
  end
end


local function handle_switch(driver, device, command)

  log.debug ('Switch changed to', command.command)
  device:emit_event(capabilities.switch.switch(command.command))
  
  if command.command == 'on' then
     wol.do_wakeonlan(device.preferences.macaddr, device.preferences.bcastaddr)
  else
    send_command(device, build_messsage("request", "ssap://system/turnOff"))
  end
  
end


local function _handle_volume(device, command)

  local volume = device.state_cache.main.audioVolume.volume.value
  local bump = device.preferences.volbump or 1
  if command.command == 'volumeDown' then; bump = bump * -1; end
  volume = volume + bump
  if volume > 100 then; volume = 100; end
  if volume < 0 then; volume = 0; end
  device:emit_event(capabilities.audioVolume.volume(volume))
  
  for i = 1, device.preferences.volbump do
    send_command(device, build_messsage("request", "ssap://audio/" .. command.command))
    socket.sleep(.1)
  end

end

local function handle_volume(_, device, command)

  log.debug(string.format("Volume command received: %s, arg=%s", command.command, command.args.volume))
  
  if command.command == 'setVolume' then
  
    device:emit_event(capabilities.audioVolume.volume(command.args.volume))
    send_command(device, build_messsage("request", "ssap://audio/setVolume", {volume=command.args.volume}))
    
  elseif (command.command == 'volumeUp') or (command.command == 'volumeDown') then
  
    _handle_volume(device, command)
    
  end
end


local function handle_mute(_, device, command)

  log.debug("Mute set to " .. command.command, command.args.state)
  
  local newstate
  
  if command.command == 'setMute' then
    newstate = command.args.state
  else
    newstate = command.command .. 'd'
  end
  
  device:emit_event(capabilities.audioMute.mute(newstate))
  
  local lgmute = { muted = true, unmuted = false }
  
  send_command(device, build_messsage("request", "ssap://audio/setMute", {mute=lgmute[newstate]}))

end


local function handle_volup(_, device, command)

  _handle_volume(device, {command = 'volumeUp'})

end


local function handle_voldown(_, device, command)

  _handle_volume(device, {command = 'volumeDown'})

end


local function handle_app(driver, device, command)
  
  log.info ('Media Preset action:', command.command, command.args.presetId)

  send_command(device, build_messsage("request", "ssap://system.launcher/launch", {id=command.args.presetId}))
  
end


local function handle_channel(driver, device, command)

  log.debug("Channel set to " .. command.command, command.args.tvChannel)
  
  device:emit_component_event(device.profile.components.main, capabilities.tvChannel.tvChannel(command.command))
  
  send_command(device, build_messsage("request", 'ssap://tv/' .. command.command))
  
  device:emit_component_event(device.profile.components.main, cap_channel.currentChannel(' '), { visibility = { displayed = false } })

  driver:call_with_delay(1, function()
      send_command(device, build_messsage("request", "ssap://tv/getCurrentChannel"))
    end)
    
end


local function handle_lgmessage(_, device, command)

  log.debug("Message set to " .. command.command, command.args.message)
  
  device:emit_event(cap_lgmsg.message(command.args.message))
  
  send_command(device, build_messsage("request", "ssap://system.notifications/createToast", {message=command.args.message}))
  
end


local function handle_lginput(driver, device, command)

  log.debug("Media Input set to " .. command.command, command.args.value)
  
  device:emit_event(cap_lginput.inputsource(command.args.value))
  
  if command.args.value == 'Live_TV' then
    send_command(device, build_messsage("request", "ssap://system.launcher/launch", {id='com.webos.app.livetv'}))
  else
    send_command(device, build_messsage("request", "ssap://tv/switchInput", {inputId=command.args.value}))
    
    driver:call_with_delay(1, function()
      send_command(device, build_messsage("request", "ssap://com.webos.applicationManager/getForegroundAppInfo"))
    end)
  end

end

------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
  log.debug(device.label .. ": " .. device.device_network_id .. "> INITIALIZING")

  initialized = true

  devices_inited = devices_inited + 1
  
  if not device:get_field('ws_client') then
    device.thread:queue_event(init_connection, device)
  end
  
  log.debug('Exiting device initialization')
end


-- Called when device was just created in SmartThings
local function device_added (driver, device)

  log.info(device.label .. ": " .. device.device_network_id .. "> ADDED")
  
  device:set_field('createtime', socket.gettime())
    
  local lgdevice = newly_added[device.device_network_id]
  if lgdevice then
    device:set_field('WSSaddr', lgdevice.ip .. ':' .. WSSPORT, { ['persist'] = true })
    newly_added[device.device_network_id] = nil
    log.debug('IP stored:', lgdevice.ip)
  end

  
  device:emit_event(capabilities.switch.switch.off())
  device:emit_event(cap_lginput.inputsource('HDMI 1'))
  device:emit_event(capabilities.audioVolume.volume(50))
  device:emit_event(capabilities.audioMute.mute('unmuted'))
  device:emit_event(cap_app.currentApp(' '))
  device:emit_event(cap_lgmsg.message(' '))
  device:emit_event(cap_status.status('Created'))
  
  device:emit_component_event(device.profile.components.main, cap_channel.currentChannel(' '))
  device:emit_component_event(device.profile.components.main, cap_channel_number.channelNumber(0))
  device:emit_component_event(device.profile.components.main, capabilities.tvChannel.tvChannel('0'))
    
  disco_sem:release()
    
end

-- Called when device was deleted via mobile app
local function device_removed(driver, device)
  
  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")

  --shutdown_device(driver, device, 'Device removed')
  
  if #driver:get_devices() == 0 then
    log.warn ('All devices removed')
    initialized = false
  end
  
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  log.info ('Device doConfigure lifecycle invoked')

end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked ***')

end

local function shutdown_handler(driver, event)

  if event == 'shutdown' then

    log.warn ('Shutting down all devices')
    local device_list = driver:get_devices()
    for _, device in ipairs(device_list) do
      shutdown_device(driver, device, 'Driver shutdown')
    end
  end
end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')
  
  -- Did preferences change?
  if args.old_st_store.preferences then
    
    if args.old_st_store.preferences.freq ~= device.preferences.freq then
      log.info ('Refresh interval changed to: ', device.preferences.freq)
      reset_refresh_timer(device)
    end
  end
  
end


-- Device discovery handler
local function discovery_handler(driver, _, should_continue)
  
  log.info("Starting discovery")
  local known_devices = {}
  local found_devices = {}

  local device_list = driver:get_devices()
  for _, device in ipairs(device_list) do
    known_devices[device.device_network_id] = true
  end
  
  local retries = 5

  while (retries > 0) and should_continue() do
    discovery.find(nil, function(lgdevice)
      local uuid = lgdevice.uuid
      local ip = lgdevice.ip
      if not known_devices[uuid] and not found_devices[uuid] then
      
        local profile = DEVICE_PROFILE

        -- add device
        local create_device_msg = {
          type = "LAN",
          device_network_id = uuid,
          label = lgdevice.name,
          profile = profile,
          manufacturer = "LG",
          model = lgdevice.model,
          vendor_provided_label = "LGE WebOS TV",
        }
        log.info_with({hub_logs = true},
          string.format("Create device with: %s", utils.stringify_table(create_device_msg)))
        assert(driver:try_create_device(create_device_msg))
        found_devices[uuid] = true
        newly_added[uuid] = lgdevice
      else
        log.info(string.format("Discovered already known device %s", id))
      end
    end)
    
    retries = retries - 1
  end
  log.info("Ending discovery")
end


-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
thisDriver = Driver("thisDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  driver_lifecycle = shutdown_handler,
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch,
      [capabilities.switch.commands.off.NAME] = handle_switch,
    },
    [capabilities.tvChannel.ID] = {
      [capabilities.tvChannel.commands.setTvChannel.NAME] = handle_channel,
      [capabilities.tvChannel.commands.channelUp.NAME] = handle_channel,
      [capabilities.tvChannel.commands.channelDown.NAME] = handle_channel
    },
    [capabilities.audioVolume.ID] = {
      [capabilities.audioVolume.commands.setVolume.NAME] = handle_volume,
      [capabilities.audioVolume.commands.volumeUp.NAME] = handle_volume,
      [capabilities.audioVolume.commands.volumeDown.NAME] = handle_volume
    },
    [capabilities.audioMute.ID] = {
      [capabilities.audioMute.commands.setMute.NAME] = handle_mute,
      [capabilities.audioMute.commands.mute.NAME] = handle_mute,
      [capabilities.audioMute.commands.unmute.NAME] = handle_mute
    },
    [capabilities.mediaPresets.ID] = {
      [capabilities.mediaPresets.commands.playPreset.NAME] = handle_app,
    },
    [cap_lgmsg.ID] = {
      [cap_lgmsg.commands.setMessage.NAME] = handle_lgmessage
    },
    [cap_lginput.ID] = {
      [cap_lginput.commands.setInputSource.NAME] = handle_lginput
    },
    [cap_volup.ID] = {
      [cap_volup.commands.push.NAME] = handle_volup,
    },
		[cap_voldown.ID] = {
      [cap_voldown.commands.push.NAME] = handle_voldown,
    },
  }
})

log.info ('LG TV Driver V1.1 Started')

-- start ping monitor
thisDriver:call_on_schedule(120, pingmonitor)

disco_sem = semaphore()

thisDriver:run()
