--[[
  Copyright 2022 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  ONVIF Video camera driver for SmartThings Edge

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"                   -- cosock used only for sleep timer in this module
local socket = require "cosock.socket"
local log = require "log"


-- Driver-specific libraries
local Thread = require "st.thread"
local classify = require "classify"
local Semaphore = require "semaphore"

local discover = require "discover"
local commands = require "commands"
local events = require "events"
local common = require "common"

-- Custom capabilities
local cap_status = capabilities["partyvoice23922.onvifstatus"]
local cap_info = capabilities["partyvoice23922.onvifinfo"]
local cap_refresh = capabilities["partyvoice23922.refresh"]
local cap_motion = capabilities["partyvoice23922.motionevents2"]
local linecross_capname = "partyvoice23922.linecross"
local cap_linecross = capabilities[linecross_capname]

-- Module Variables

local devcreate_sem
local resub_thread
local resub_timer
local newly_added = {}
local created_ips = {}          -- SD PATCH: IPs already created by this driver run
local discovered_num = 1

local ONVIFDEVSERVPATH = '/onvif/device_service'

local LINECROSSREVERTDELAY = 1

-- Global Variables
onvifDriver = {}


math.randomseed(socket.gettime())


local function build_html(list)

  local html_list = ''

  for itemnum, item in ipairs(list) do
    html_list = html_list .. '<tr><td>' .. item .. '</td></tr>\n'
  end

  local html =  {
                  '<!DOCTYPE html>\n',
                  '<HTML>\n',
                  '<HEAD>\n',
                  '<style>\n',
                  'table, td {\n',
                  '  border: 1px solid black;\n',
                  '  border-collapse: collapse;\n',
                  '  font-size: 11px;\n',
                  '  padding: 3px;\n',
                  '}\n',
                  '</style>\n',
                  '</HEAD>\n',
                  '<BODY>\n',
                  '<table>\n',
                  html_list,
                  '</table>\n',
                  '</BODY>\n',
                  '</HTML>\n'
                }
    
  return (table.concat(html))
end

local function is_array(t)
  if type(t) ~= "table" then return false end
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then return false end
  end
  return true
end

-- SD PATCH: channel = preference if changed from default, else the channel assigned at creation
local function get_channel(device)
  local pref = tonumber(device.preferences.channel) or 1
  if pref ~= 1 then; return pref; end
  return device:get_field('sd_channel') or 1
end

local function init_infolist(device, ipcam)

  local infolist = {}

  table.insert(infolist, 'IP addr: ' .. ipcam.ip)
  if ipcam.vendname then; table.insert(infolist, 'Name: ' .. ipcam.vendname); end
  if ipcam.hardware then; table.insert(infolist, 'Hardware: ' .. ipcam.hardware); end
  if ipcam.location then; table.insert(infolist, 'Location: ' .. ipcam.location); end
  for _, profile in ipairs(ipcam.profiles) do
    table.insert(infolist, 'Profile: ' .. profile)
  end
  if ipcam.urn then; table.insert(infolist, ipcam.urn); end
  
  device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
  
  device:set_field('onvif_info', infolist)
  
  return infolist
end


local function handle_motion_event(device, cam_func, msg)

  local name, value

  if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
      
    name = msg.Message.Message.Data.SimpleItem._attr.Name
    value = msg.Message.Message.Data.SimpleItem._attr.Value

    if name == cam_func.motion_eventrule.item then
      log.info (string.format('Message for %s: %s', device.label, msg.Topic[1]))
      log.info (string.format('\tMotion value = "%s"', value))
      
      if (value == 'true') or (value == '1') then
        if (socket.gettime() - device:get_field('LastMotion')) >= device.preferences.minmotioninterval then
          device:emit_event(capabilities.motionSensor.motion('active'))
          device:set_field('LastMotion', socket.gettime())
          if device.preferences.autorevert == 'yesauto' then
            device.thread:call_with_delay(device.preferences.revertdelay, function() 
              device:emit_event(capabilities.motionSensor.motion('inactive')); end, 'revert motion')
          end
        else
          log.info ('Motion event ignored due to configured min interval')
        end
        
      else
        device:emit_event(capabilities.motionSensor.motion('inactive'))
      end
    else
      log.error ('Item name mismatch with event message:', name)
    end
  else
    log.error ('Missing event item name/value')
  end
end


local function handle_linecross_event(device, cam_func, msg)
  
  if device:supports_capability_by_id(linecross_capname) == false then; return; end
  
  local name, value

  if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
    name = msg.Message.Message.Data.SimpleItem._attr.Name
    value = msg.Message.Message.Data.SimpleItem._attr.Value

    if name == cam_func.linecross_eventrule.item then
      log.info (string.format('Linecross notification for %s: %s', device.label, msg.Topic[1]))
      log.info (string.format('\tValue = "%s"', value, type(value)))
    
      if type(value) == 'string' then; value = string.lower(value); end
      
      if (value ~= 'false') and (value ~= '0') then
        if (socket.gettime() - device:get_field('LastLinecross')) >= device.preferences.minlinecrossinterval then
          device:emit_component_event(device.profile.components.line, cap_linecross.linecross('active'))
          device:set_field('LastLinecross', socket.gettime())
          device.thread:call_with_delay(LINECROSSREVERTDELAY, function() 
              device:emit_component_event(device.profile.components.line, cap_linecross.linecross('inactive'))
            end, 'revert linecross')
        else
          log.info ('Linecross event ignored due to configured min interval')
        end
      else
        device:emit_component_event(device.profile.components.line, cap_linecross.linecross('inactive'))
      end
    else
      log.error ('Item name mismatch with event message:', name)
    end
  else
    log.error ('Missing linecross event item name/value')
  end
end


local function handle_tamper_event(device, cam_func, msg)

  if device:supports_capability_by_id('tamperAlert') == false then; return; end

  local name, value

  if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
    name = msg.Message.Message.Data.SimpleItem._attr.Name
    value = msg.Message.Message.Data.SimpleItem._attr.Value

    if name == cam_func.tamper_eventrule.item then
      log.info (string.format('Tamper notification for %s: %s', device.label, msg.Topic[1]))
      log.info (string.format('\tValue = "%s"', value))
    
      if (value == 'true') or (value == '1') then
        if (socket.gettime() - device:get_field('LastTamper')) >= device.preferences.mintamperinterval then
          device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('detected'))
          device:set_field('LastTamper', socket.gettime())
          if device.preferences.autorevert == 'yesauto' then
            device.thread:call_with_delay(device.preferences.revertdelay, function() 
                device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('clear'))
              end, 'revert tamper')
          end
        else
          log.info ('Tamper event ignored due to configured min interval')
        end
        
      else
        device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('clear'))
      end
    else
      log.error ('Item name mismatch with event message:', name)
    end
  else
    log.error ('Missing tamper event item name/value')
  end
end


local function event_handler(device, msgs)

  local function proc_msg(device, cam_func, msg)
  
    if not msg.Topic then
      log.error ('Missing topic in event message')
      return
    end
  
    local topic = msg.Topic[1]
    
    -- SD PATCH: on an NVR, only accept events from this device's channel
    if cam_func.sd_source and common.is_element(msg, {'Message', 'Message', 'Source'}) then
      local items = msg.Message.Message.Source.SimpleItem
      if items and items._attr then; items = { items }; end
      local match, seen = false, false
      for _, it in ipairs(items or {}) do
        if it._attr and it._attr.Value and cam_func.sd_all and cam_func.sd_all[it._attr.Value] then
          seen = true                      -- only values we recognise as NVR channel tokens count
          local v = it._attr.Value
          if v == cam_func.sd_source or (cam_func.sd_vsconf and cam_func.sd_vsconf[v]) then; match = true; end
        end
      end
      if seen and not match then
        log.debug (string.format('Event for another channel ignored by %s', device.label))
        return
      end
    end
  
    -- If Motion event
    if topic:find(cam_func.motion_eventrule.topic, 1, 'plaintext') and (cam_func.motion_events == true) then
      handle_motion_event(device, cam_func, msg)
      
    -- If Tamper event
    elseif topic:find(cam_func.tamper_eventrule.topic, 1, 'plaintext') and (cam_func.tamper_events == true) then
      handle_tamper_event(device, cam_func, msg)
     
    -- If Line Cross event
    elseif topic:find(cam_func.linecross_eventrule.topic, 1, 'plaintext') and (cam_func.linecross_events == true) then
      handle_linecross_event(device, cam_func, msg)
      
    else
      log.warn(string.format('Received message for %s ignored (topic=%s)', device.label, topic))
    end
  end
        
  ----------------------------------------------------------------------
  
  local cam_func = device:get_field('onvif_func')
  
  if is_array(msgs) then
  
    for _, msg in ipairs(msgs) do
      proc_msg(device, cam_func, msg)
    end
  
  else
      proc_msg(device, cam_func, msgs)
  end
end


local function get_services(device)

  local meta = device:get_field('onvif_disco')

  local services = commands.GetServices(device, meta.uri.device_service)
  
  for _, service in ipairs(services.Service) do
    log.debug ('Searching services list:', service.Namespace)
    if service.Namespace:find('/events/') then
      if service.XAddr:find('http://') then
        log.debug ('\tFound events address:', service.XAddr)
        return (service.XAddr)
      end
    end
  end
end


-- SD PATCH: create one extra device per NVR channel (2..count), sharing address + credentials
function create_channel_devices(parent, count)
  local meta = parent:get_field('onvif_disco')
  if not meta then; return; end
  local base = parent.device_network_id
  local existing = {}
  for _, d in ipairs(onvifDriver:get_devices()) do; existing[d.device_network_id] = true; end
  for ch = 2, count do
    local dni = base .. '_ch' .. ch
    if not existing[dni] then
      local cm = {}
      for k, v in pairs(meta) do; cm[k] = v; end
      cm.discotype = 'manual'
      cm.sd_channel = ch
      local pru, prp = common.get_rtsp_creds(parent)
      cm.sd_creds = { userid = common.get_userid(parent), password = common.get_password(parent),
                      rtspuser = pru, rtsppass = prp }
      newly_added[dni] = cm
      log.info (string.format('Creating device for NVR channel %d: %s', ch, dni))
      devcreate_sem:acquire(function()
        assert (onvifDriver:try_create_device({
          type = "LAN",
          device_network_id = dni,
          label = 'ONVIF ' .. tostring(meta.ip) .. ' ch' .. ch,
          profile = 'onvif_cam.v3',
          manufacturer = 'Unknown',
          model = 'Unknown',
          vendor_provided_label = 'ONVIF NVR channel ' .. ch,
        }), "failed to create channel device")
      end)
    end
  end
end

-- SD PATCH: apply the manual IP Address preference to stored device metadata
local function apply_ip_pref(device)
  local addr = tostring(device.preferences.ipaddr or ''):gsub('%s', '')
  if addr:match('^%d+%.%d+%.%d+%.%d+$') then; addr = addr .. ':80'; end
  local ip = addr:match('^(%d+%.%d+%.%d+%.%d+):%d+$')
  if not ip or ip == '0.0.0.0' then; return false; end
  local meta = device:get_field('onvif_disco') or { uri = {}, scopes = {}, profiles = {} }
  meta.uri = meta.uri or {}
  meta.scopes = meta.scopes or {}
  meta.profiles = meta.profiles or {}
  if meta.addr ~= addr or not meta.uri.device_service then
    meta.ip = ip
    meta.addr = addr
    meta.port = tonumber(addr:match(':(%d+)$'))
    meta.uri.device_service = 'http://' .. addr .. ONVIFDEVSERVPATH
    meta.discotype = 'manual'
    device:set_field('onvif_disco', meta, {['persist'] = true })
    log.info ('Device address set from preferences:', meta.uri.device_service)
  end
  return true
end

local function get_cam_config(device)

  log.info('Starting Device Initialization routine for', device.label)
  
  -- SD PATCH: channel devices always take the CURRENT login from their NVR (parent) device
  if device:get_field('sd_channel') then
    local base = device.device_network_id:match('^(.+)_ch%d+$')
    for _, d in ipairs(onvifDriver:get_devices()) do
      if base and d.device_network_id == base then
        local pru, prp = common.get_rtsp_creds(d)
        local own = device:get_field('sd_creds') or {}
        local new = { userid = common.get_userid(d), password = common.get_password(d),
                      rtspuser = pru, rtsppass = prp }
        if own.userid ~= new.userid or own.password ~= new.password or
           own.rtspuser ~= new.rtspuser or own.rtsppass ~= new.rtsppass then
          log.info ('Login updated from NVR device', d.label)
          device:set_field('sd_creds', new, {['persist'] = true })
          device:set_field('onvif_authinfo', nil)
        end
        break
      end
    end
  end
  
  -- SD PATCH: manual devices wait for an IP address
  local has_ip = apply_ip_pref(device)
  if device.device_network_id:match('^MAN_SD') and not has_ip then
    log.warn ('No IP address configured yet for', device.label)
    device:emit_component_event(device.profile.components.info, cap_status.status('Set IP in Settings'))
    return
  end
  
  local meta = device:get_field('onvif_disco')
  if meta then
    
    local infolist = init_infolist(device, meta)
    
    local datetime = commands.GetSystemDateAndTime(device, meta.uri.device_service)
    
    if datetime then
    
      device:emit_component_event(device.profile.components.info, cap_status.status('Responding'))
      device:online()
      device:set_field('onvif_online', true)
      
      table.insert(infolist, 'Last refresh hub: ' .. datetime.hub .. ' UTC')
      table.insert(infolist, 'Last refresh cam: ' .. datetime.cam .. ' UTC')
      device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
      device:set_field('onvif_info', infolist)
      
      
      if (common.get_userid(device) ~= '*****') and (common.get_password(device) ~= '*****') then
        
        -- GET SCOPES --------------------------------------------------
        
        local scopes = commands.GetScopes(device, meta.uri.device_service)
        
        if not scopes then
          local e = commands.get_last_error and commands.get_last_error() or 'no data'
          device:emit_component_event(device.profile.components.info, cap_status.status('Failed GetScopes: ' .. tostring(e)))
          return
        end
        
        --log.debug(string.format('Found scopes for %s:', device.label))
        
        local foundflag = false
        
        for _, item in ipairs(scopes) do
          item = tostring(item):gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)   -- SD PATCH
          --log.debug ('\t' .. item)
          
          if meta.discotype == 'manual' then
            table.insert(meta.scopes, item)
            foundflag = true
            
            if item:find('/name/') then
              meta.vendname = item:match('/name/(.+)$')
              table.insert(infolist, 'Name: ' .. meta.vendname)
            elseif item:find('/location/') then
              meta.location = item:match('/location/(.+)$')
              table.insert(infolist, 'Location: ' .. meta.location)
            elseif item:find('/hardware/') then
              meta.hardware = item:match('/hardware/(.+)$')
              table.insert(infolist, 'Hardware: ' .. meta.hardware)
            elseif item:find('/Profile/') then
              local profile = item:match('/Profile/(.+)$')
              table.insert(meta.profiles, profile)
              table.insert(infolist, 'Profile: ' .. profile)
            elseif not item:match('^onvif') then
              table.insert(infolist, item)
            end
          
          else  
            if not item:match('^onvif') then
              table.insert(infolist, item)
              foundflag = true
            end
          end
        end
            
        if foundflag and (meta.discotype == 'manual') then
          meta.discotype = 'manual_inited'
          device:set_field('onvif_disco', meta, {['persist'] = true })
        end
            
        if foundflag or (meta.discotype == 'manual') then
          device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
          device:set_field('onvif_info', infolist)
        end
        
        -- GET DEVICE INFO ---------------------------------------------
        
        local infotable = commands.GetDeviceInformation(device, meta.uri.device_service)
        
        if not infotable then
          local e = commands.get_last_error and commands.get_last_error() or 'no data'
          device:emit_component_event(device.profile.components.info, cap_status.status('Failed GetDeviceInformation: ' .. tostring(e)))
          return
        end
        
        for key, value in pairs(infotable) do
          log.debug ('\t' .. key, value)
          if type(value) ~= 'table' then
            table.insert(infolist, key .. ': ' .. value)
          end
        end
            
        device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
        device:set_field('onvif_info', infolist)
          
        -- GET CAPABILITIES --------------------------------------------
        
        local capabilities = commands.GetCapabilities(device, meta.uri.device_service)
        
        if not capabilities then
          local e = commands.get_last_error and commands.get_last_error() or 'no data'
          device:emit_component_event(device.profile.components.info, cap_status.status('Failed GetCapabilities: ' .. tostring(e)))
          return
        end
        
        local onvif_func = {}
        
        if capabilities['Events'] then
        
          log.debug ('Events section of Capabilities response:')
          common.disptable(capabilities.Events, '  ', 5)
          
          onvif_func.event_service_addr = capabilities['Events']['XAddr']
          if type(onvif_func.event_service_addr) == 'table' then; onvif_func.event_service_addr = nil; end
          onvif_func.ws_subscription = capabilities['Events']['WSSubscriptionPolicySupport']
          onvif_func.PullPointSupport = capabilities['Events']['WSPullPointSupport']
          
          if onvif_func.event_service_addr == nil then
            log.warn ('Event service address is blank; trying getServices request')
            local services = commands.GetServices(device, meta.uri.device_service)
            for _, service in ipairs(services.Service) do
              log.debug ('Found service:', service.Namespace)
              if service.Namespace:find('/events/') then
                log.debug ('\tFound event service containing address', service.XAddr)
                if service.XAddr:find('http://') then
                  onvif_func.event_service_addr = service.XAddr
                else
                  log.warn ('Could NOT find service address; motion events not supported')
                end
              end
            end
          end  
          
        else
          log.warn ('Camera does not have an Events Capability')
          onvif_func.motion_events = false
        end
        
        if capabilities['Media'] then
          onvif_func.media_service_addr = capabilities['Media']['XAddr']
          if capabilities['Media']['StreamingCapabilities'] then
            onvif_func.RTP_TCP = capabilities['Media']['StreamingCapabilities']['RTP_TCP']
            onvif_func.RTP_RTSP_TCP = capabilities['Media']['StreamingCapabilities']['RTP_RTSP_TCP']
          end
        end
        
        device:set_field('onvif_func', onvif_func)
        
        ----------------------------------------------------------------
        -- TEST
        --get_services(device)
        ----------------------------------------------------------------
        
        --[[
        -- GET VIDEO SOURCES -------------------------------------------
        
        local videosources = commands.GetVideoSources(device, onvif_func.media_service_addr)
        
        if not videosources then
          local e = commands.get_last_error and commands.get_last_error() or 'no data'
          device:emit_component_event(device.profile.components.info, cap_status.status('Failed GetVideoSources: ' .. tostring(e)))
          return
        end
        
        --common.disptable(videosources, '  ', 12)
        
        onvif_func.video_source_token = nil
        
        if common.is_element(videosources, {'_attr', 'token'}) then
          onvif_func.video_source_token = videosources._attr.token
        else
          if is_array(videosources) then
            log.debug ('Number of video sources:', #videosources)
            
            if common.is_element(videosources[1], {'_attr', 'token'}) then
              onvif_func.video_source_token = videosources[1]._attr.token
            end
            
            if #videosources > 1 then
              if device.preferences.stream == 'substream' then
                if #videosources > 2 then
                  if common.is_element(videosources[#videosources], {'_attr', 'token'}) then
                    onvif_func.video_source_token = videosources[#videosources]._attr.token
                    log.debug (string.format('Video resolution selected: %sw x %sh', videosources[#videosources].Resolution.Width, videosources[#videosources].Resolution.Height))
                  end
                else
                  if common.is_element(videosources[2], {'_attr', 'token'}) then
                    onvif_func.video_source_token = videosources[2]._attr.token
                  end
                end
              end
            end
          end
        end
        
        if onvif_func.video_source_token then
          log.debug ('Video source token:', onvif_func.video_source_token)
          device:set_field('onvif_func', onvif_func)
        else
          log.error ('Video source cannot be determined')
        end
        --]]
        
        -- GET PROFILES -------------------------------------------------
        
        local profiles = commands.GetProfiles(device, onvif_func.media_service_addr)
        
        if not profiles then
          local e = commands.get_last_error and commands.get_last_error() or 'no data'
          device:emit_component_event(device.profile.components.info, cap_status.status('Failed GetProfiles: ' .. tostring(e)))
          return
        end
        
        --common.disptable(profiles, '  ', 12)
        
        -- SD PATCH: NVR channel selection
        if is_array(profiles) then
          local sources, seen = {}, {}
          for _, prof in ipairs(profiles) do
            if common.is_element(prof, {'VideoSourceConfiguration', 'SourceToken'}) then
              local tok = prof.VideoSourceConfiguration.SourceToken
              if not seen[tok] then; seen[tok] = true; table.insert(sources, tok); end
            end
          end
          -- SD PATCH: sort channels by the number in the source token (NVRs may list profiles out of order)
          table.sort(sources, function(a, b)
            local na, nb = tonumber(tostring(a):match('(%d+)%D*$')), tonumber(tostring(b):match('(%d+)%D*$'))
            if na and nb and na ~= nb then return na < nb end
            return tostring(a) < tostring(b)
          end)
          log.info (string.format('Video channels (sources) found: %d', #sources))
          onvif_func.sd_all = {}                 -- SD PATCH: every source/config token of the NVR
          for _, tok in ipairs(sources) do; onvif_func.sd_all[tok] = true; end
          for _, prof in ipairs(profiles) do
            if common.is_element(prof, {'VideoSourceConfiguration', '_attr', 'token'}) then
              onvif_func.sd_all[prof.VideoSourceConfiguration._attr.token] = true
            end
          end
          if #sources > 1 then
            local ch = get_channel(device)
            if ch < 1 or ch > #sources then; ch = 1; end
            local wanted = sources[ch]
            local filtered = {}
            for _, prof in ipairs(profiles) do
              if common.is_element(prof, {'VideoSourceConfiguration', 'SourceToken'}) and
                 prof.VideoSourceConfiguration.SourceToken == wanted then
                table.insert(filtered, prof)
              end
            end
            log.info (string.format('Using channel %d (source %s): %d profile(s)', ch, wanted, #filtered))
            onvif_func.sd_source = wanted
            onvif_func.sd_vsconf = {}
            for _, fp in ipairs(filtered) do
              if common.is_element(fp, {'VideoSourceConfiguration', '_attr', 'token'}) then
                onvif_func.sd_vsconf[fp.VideoSourceConfiguration._attr.token] = true
              end
            end
            -- SD PATCH: the first (parent) device creates one device per additional NVR channel
            if not device:get_field('sd_channel') then
              create_channel_devices(device, #sources)
            end
            table.insert(infolist, string.format('Channel: %d of %d', ch, #sources))
            onvif_func.sd_chan = string.format('ch %d/%d', ch, #sources)
            if #filtered == 1 then
              profiles = filtered[1]
            elseif #filtered > 1 then
              profiles = filtered
            end
          end
        end
        
        local substream_token, profile_name
        local stream_idx = 1
        local res_width, res_height
        
        if is_array(profiles) then
        
          if #profiles == 1 then
            log.warn ('Only one video profile available')
            
          else
            if device.preferences.stream ~= 'mainstream' then
              if #profiles > 2 then

                -- Scan table for low resolution profile
                for i, profile in ipairs(profiles) do
                  if common.is_element(profile, { 'VideoEncoderConfiguration', 'Resolution' }) then
                    local width = profile.VideoEncoderConfiguration.Resolution.Width
                    local height = profile.VideoEncoderConfiguration.Resolution.Height
                    log.debug (string.format('\tProfile #%d resolution: %s x %s', i, width, height))
                    if ((tonumber(width) < 1000) and (tonumber(height) < 1000)) then
                      stream_idx = i
                      break
                    end
                  end
                end
              else
                stream_idx = 2
              end
            end
          end  
            
          profile_name = profiles[stream_idx].Name
          substream_token = profiles[stream_idx]._attr.token
          if common.is_element(profiles[stream_idx], { 'VideoEncoderConfiguration', 'Resolution' }) then
            res_width = profiles[stream_idx].VideoEncoderConfiguration.Resolution.Width
            res_height = profiles[stream_idx].VideoEncoderConfiguration.Resolution.Height
          end
        
        else
          log.warn ('Single video profile only')
          profile_name = profiles.Name
          substream_token = profiles._attr.token
          if common.is_element(profiles, { 'VideoEncoderConfiguration', 'Resolution' }) then
            res_width = profiles.VideoEncoderConfiguration.Resolution.Width
            res_height = profiles.VideoEncoderConfiguration.Resolution.Height
          end
        end
        
        log.info (string.format('Using profile name=%s, token=%s', profile_name, substream_token))
        
        if res_width and res_height then
          local restext = string.format('Resolution: %dw x %dh', res_width, res_height)
          log.info (string.format('\t%s', restext))
          table.insert(infolist, restext)
          device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
          device:set_field('onvif_info', infolist)
        end
        
        -- GET STREAM URI---------------------------------------------
      
        if onvif_func.RTP_RTSP_TCP == 'true' then
      
          local uri_info = commands.GetStreamUri(device, substream_token, onvif_func.media_service_addr)
          
          if uri_info then
            onvif_func.stream_uri = uri_info['Uri']
            device:set_field('onvif_func', onvif_func)
            
            log.debug('Stream URI:', onvif_func.stream_uri)
          end
        else
          log.warn ('RTSP over TCP is not supported; Streaming disabled')
        end
        
        
        -- GET EVENT PROPERTIES ----------------------------------------
        
        local function parserule(ruletable)
        
          local l2topic, l2table
          for rule2, ruletable2 in pairs(ruletable) do
            if rule2 ~= '_attr' then
              l2topic = rule2                         -- we'll only scan for the 2nd level part of topic in received events
              l2table = ruletable2                    -- because some cams (e.g.Tapo) erroneously report linecross/tamper under CellMotionDetector
              break
            end
          end
          
          if common.is_element(l2table, {'MessageDescription','Data','SimpleItemDescription','_attr','Name'}) then
            local itemname = l2table.MessageDescription.Data.SimpleItemDescription._attr.Name
            log.debug (string.format('\tL2 Topic: %s, name=%s', l2topic, itemname))
            return true, { ['topic'] = l2topic, ['item'] = itemname }
          else
            log.error ('\tData item not found')
          end
          
          return false
        end
        
        
        onvif_func.motion_events = false
        onvif_func.tamper_events = false
        onvif_func.linecross_events = false
        
        if onvif_func.event_service_addr then
        
          local event_properties = commands.GetEventProperties(device, onvif_func.event_service_addr)
          
          -- SD PATCH: remember available event topics for the summary Status
          if type(event_properties) == 'table' then
            local tl = {}
            for k, v in pairs(event_properties) do
              if k ~= '_attr' then
                local sub = {}
                if type(v) == 'table' then
                  for k2, _ in pairs(v) do; if k2 ~= '_attr' then; table.insert(sub, k2); end; end
                end
                table.insert(tl, k .. (#sub > 0 and ('[' .. table.concat(sub, ',') .. ']') or ''))
              end
            end
            onvif_func.sd_topics = table.concat(tl, ' ')
          end
          
          if event_properties then 
            if event_properties['RuleEngine'] then
            
              -- These motion rules appear to be standard across ONVIF cameras
              local CELLMOTION = { ['topic'] = 'RuleEngine/CellMotionDetector/Motion', ['item'] = 'IsMotion' }
              local MOTIONALARM = { ['topic'] = 'VideoSource/MotionAlarm', ['item'] = 'State' }
              
              local rules = event_properties['RuleEngine']
              local motionOK = false
              local eventrule
              
              common.disptable(rules, '  ', 12)
              
              -- Check for configured Motion rule
              if (device.preferences.motionrule == 'cell') or (device.preferences.motionrule == nil) then
            
                if rules.CellMotionDetector then
                  if common.is_element(rules, {'CellMotionDetector','Motion','MessageDescription','Data','SimpleItemDescription','_attr','Name'}) then
                    if rules.CellMotionDetector.Motion.MessageDescription.Data.SimpleItemDescription._attr.Name == CELLMOTION.item then
                      motionOK = true
                      eventrule = CELLMOTION
                      log.info ('CellMotionDetector found')
                    end
                  else
                    log.error ('isMotion item not found in CellMotionDetector XML')
                  end
                else
                  log.warn ('CellMotionDetector rule is not available from this camera')
                end  
                
              elseif device.preferences.motionrule == 'alarm' then
                motionOK = true
                eventrule = MOTIONALARM
              end
              
              if motionOK == true then
                log.info (string.format('Motion events enabled; using topic %s, item %s', eventrule.topic, eventrule.item))
                onvif_func.motion_events = true
                onvif_func.motion_eventrule = eventrule
              else
                log.warn ('Motion events not enabled')
              end
              
              -- Check for Tamper Rule
              if rules.TamperDetector then                -- this assumes rule name consistency across brands
                log.debug ('Found Tamper L1 Topic: TamperDetector')
                
                local enabled, eventrule = parserule(rules.TamperDetector)
                
                onvif_func.tamper_events = enabled
                if enabled then
                  onvif_func.tamper_eventrule = eventrule
                  log.info ('Tamper events available')
                end
              end
              
              -- Check for Linecross Rule (exact topic and data item varies from brand to brand) :-(
              for rule, ruletable in pairs(rules) do
                
                if string.find(rule, 'Line') and string.find(rule, 'Detector') then
                  log.debug ('Found Line-crossed L1 Topic:', rule)
                  
                  local enabled, eventrule = parserule(ruletable)
                  
                  onvif_func.linecross_events = enabled
                  if enabled then
                    onvif_func.linecross_eventrule = eventrule
                    log.info ('LineCross events available')
                  end
                end
              end
              
            else
              log.error ('Missing rule engine section in event properties response')
            end
            
          else
            log.error ('Event properties not available')
          end
        end 
        
        device:set_field('onvif_func', onvif_func)
        
        -- SD PATCH: one-line summary so testers can report without logcat
        local summary = string.format('Ready %s | video:%s | motion:%s | events: %s',
          onvif_func.sd_chan or 'ch 1/1',
          onvif_func.stream_uri and 'yes' or 'no',
          onvif_func.motion_events and 'yes' or 'no',
          onvif_func.sd_topics or (onvif_func.event_service_addr and 'none' or 'no event service'))
        log.info (summary)
        device:emit_component_event(device.profile.components.info, cap_status.status(summary:sub(1, 250)))
        return true
        
      else
        log.warn ('Userid/Password not configured:', device.label)
      end
      
    end
  
  else
    log.error ('Cannot initialize: persistent ONVIF discovery info missing')
  end

  return false
  
end


local function resetlastevents(device)

	device:set_field('LastMotion', socket.gettime() - device.preferences.minmotioninterval)
  device:set_field('LastLinecross', socket.gettime() - device.preferences.minmotioninterval)
  device:set_field('LastTamper', socket.gettime() - device.preferences.minmotioninterval)	

end


local function start_events(device)

  local cam_func = device:get_field('onvif_func')
  
  if cam_func.motion_events == true then

    local response = events.subscribe(onvifDriver, device, device:get_field('onvif_func').motion_event_name, event_handler)
    if response then
      local cam_func = device:get_field('onvif_func')
      cam_func.event_source_addr = response.SubscriptionReference.Address
      device:set_field('onvif_func', cam_func)
      
			resetlastevents(device)
      
      device:emit_component_event(device.profile.components.info, cap_status.status('Subscribed to events'))
      return true
    else
      log.error ('Failed to subscribe to motion events', device.label)
    end
  else
    log.warn('Motion events are not available from this camera')
  end
end


-- Here is where we perform all our device startup tasks
function init_device(device)

  local okc, resc = pcall(get_cam_config, device)          -- SD PATCH: report Lua errors in Status
  if not okc then
    log.error ('get_cam_config error:', resc)
    device:emit_component_event(device.profile.components.info, cap_status.status(('Driver error: ' .. tostring(resc)):sub(1, 150)))
    return
  end
  if resc then
    
    if device:get_field('onvif_func').motion_events == true then
    
      local curstate = device:get_latest_state("main", cap_motion.ID, cap_motion.motionSwitch.NAME)
      log.debug ('Current motion switch value: ', curstate)
      if curstate == 'On' then
        start_events(device)
      end
      
    else
      device:emit_event(cap_motion.motionSwitch('Off'))
    end
    
    log.info(string.format('%s initialized', device.label))
    device:online()
    device:set_field('init_retries', 0)
      
  else
    log.error ('Failed to initialize device', device.label)
    -- SD PATCH: show the actual error so users can report it without logcat
    local err = commands.get_last_error and commands.get_last_error()
    local meta_e = device:get_field('onvif_disco')
    local target = (meta_e and meta_e.addr) or '?'
    local msg = 'Not responding'
    if err then; msg = 'Error ' .. err; end
    msg = msg .. ' @' .. target
    if #msg > 120 then; msg = msg:sub(1, 120); end
    device:emit_component_event(device.profile.components.info, cap_status.status(msg))
    
    -- Device may no longer be available at known address, so schedule rediscovery
    if device:get_field('onvif_online') == false then
      device:offline()
      local discotype = device:get_field('onvif_disco').discotype
      if (discotype == nil) or (discotype == 'auto') then
        discover.schedule_rediscover(onvifDriver, device, 20, init_device)
      end

    -- Device didn't successfully respond for some reason; setup re-attempts
    else
      device:set_field('init_retries', device:get_field('init_retries') + 1)
      -- SD PATCH: never auto-retry on 401 - repeated bad logins make Hikvision lock out the hub
      local e401 = commands.get_last_error and commands.get_last_error()
      if e401 and (e401:match('^401') or e401:match('^fault') or e401:match('^no credentials')) then
        log.warn ('Authentication failed; not retrying automatically')
      elseif device:get_field('init_retries') < 5 then
        onvifDriver:call_with_delay(14 + math.random(1, 8), function ()
            device.thread:queue_event(init_device, device)
          end)
      end
    end
  end

end

------------------------------------------------------------------------
--                      CAPABILITY HANDLERS
------------------------------------------------------------------------

local function handle_refresh(driver, device, command)

  log.info ('Refresh requested')

  discover.cancel_rediscover(driver, device)      -- in case an outstanding rediscover timer

  init_device(device)
    
end


local function handle_switch(driver, device, command)

  log.debug (string.format('%s switch command received: %s', command.component, command.command))
  
  local cam_func = device:get_field('onvif_func')
  
  if cam_func then
    if cam_func.motion_events == true then
    
      if command.command == 'switchOn' then
        if start_events(device) then
          device:emit_event(cap_motion.motionSwitch('On'))
          return
        end
      elseif command.command == 'switchOff' then
        commands.Unsubscribe(device, cam_func.event_service_addr)
        log.info('Unsubscribed to events for', device.label)
        events.shutdownserver(driver, device)
        device:emit_component_event(device.profile.components.info, cap_status.status('Unsubscribed to events'))
        device:emit_event(capabilities.motionSensor.motion('inactive'))
      end
    else
      log.debug('Motion events not available for', device.label)
    end
  else
    log.warn(string.format('Cannot enable motion events - %s not yet initialized', device.label))
  end
  
  device:emit_event(cap_motion.motionSwitch('Off'))
  
end


local function handle_stream(driver, device, command)

  log.debug('Streaming handler invoked with command', command.command)
  
  local live_video = {
     ['InHomeURL'] = '',
     ['OutHomeURL'] = ''
  }
  
  local cam_func = device:get_field('onvif_func')
  
  if cam_func then
  
    if command.command == 'startStream' then
    
      if cam_func.stream_uri then
      
        local function urlenc(str)
          return (tostring(str):gsub('[^%w%-%._~]', function(c) return string.format('%%%02X', string.byte(c)) end))
        end
        local ru, rp = common.get_rtsp_creds(device)          -- SD PATCH: optional separate RTSP user
        local suri = cam_func.stream_uri:gsub('/Streaming/Unicast/channels/', '/Streaming/Channels/')  -- SD PATCH: Hikvision format
        local build_url = 'rtsp://' .. urlenc(ru) .. ':' .. urlenc(rp) .. '@' .. suri:match('//(.+)') 
        log.debug ('Providing stream URL to SmartThings:', cam_func.stream_uri)
        live_video.InHomeURL = build_url
        -- SD PATCH: show (password-masked) URL so testers can verify it, e.g. in VLC
        device:emit_component_event(device.profile.components.info,
          cap_status.status(('Video URL sent: rtsp://' .. tostring(ru) .. ':***@' .. cam_func.stream_uri:match('//(.+)')):sub(1, 250)))
        --live_video.OutHomeURL = build_url
      end
    
    end
    
    if command.command == 'startStream' and not cam_func.stream_uri then
      device:emit_component_event(device.profile.components.info, cap_status.status('Video requested but no stream URL - tap Refresh'))
    end
    device:emit_event(capabilities.videoStream.stream(live_video, { visibility = { displayed = false } }))
    
  end

end
  
------------------------------------------------------------------------
--                    DRIVER LIFECYCLE HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
  log.debug(string.format("INIT handler for: <%s (%s)>", device.device_network_id, device.label))
  
  device:try_update_metadata({profile='onvif_cam.v3'})                                              				-- *** Remove for next update
  device:emit_component_event(device.profile.components.line, cap_linecross.linecross('inactive'))  				-- *** Remove for next update
  device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('clear'))		-- *** Remove for next update

  device:set_field('init_retries', 0)
	resetlastevents(device)
  device.thread:queue_event(init_device, device)
  
end


-- Called when device is initially discovered and created in SmartThings
local function device_added (driver, device)

  local urn = device.device_network_id

  log.info(string.format('ADDED handler: <%s (%s)> successfully added; device_network_id = %s', device.id, device.label, device.device_network_id))

  -- get camera metadata that was squirreled away when device was discovered
  local ipcam = newly_added[urn]
  
  if ipcam then
    device:set_field('onvif_disco', ipcam, {['persist'] = true })
    if ipcam.sd_channel then                 -- SD PATCH: auto-created NVR channel device
      device:set_field('sd_channel', ipcam.sd_channel, {['persist'] = true })
      device:set_field('sd_creds', ipcam.sd_creds, {['persist'] = true })
    end
    newly_added[urn] = nil                   -- we're done with it
  else
    -- device may be transferring in from manual camera device creator
    if device.device_network_id:match('^MAN_') then
      log.debug ('Processing manually-created device')
      ipcam = {}
      ipcam.uri = {}
      ipcam.scopes = {}
      ipcam.profiles = {}
      ipcam.urn, ipcam.addr = device.device_network_id:match('MAN_(.+)_(.+)$')
      ipcam.ip = ipcam.addr:match('([%d%.]+):')
      ipcam.port = tonumber(ipcam.addr:match(':(%d+)'))
      ipcam.uri.device_service = 'http://' .. ipcam.addr .. ONVIFDEVSERVPATH
      ipcam.discotype = 'manual'
      device:set_field('onvif_disco', ipcam, {['persist'] = true })
    end
  end
    
  if ipcam ~= nil then
    
    device:emit_event(capabilities.motionSensor.motion('inactive'))
    device:emit_event(cap_motion.motionSwitch('Off'))
    device:emit_component_event(device.profile.components.line, cap_linecross.linecross('inactive'))
    device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('clear'))
    device:emit_component_event(device.profile.components.info, cap_info.info(" "))
    device:emit_component_event(device.profile.components.info, cap_status.status('Not configured'))
    
  else
    log.error ('IPCam meta data not found for new device')               -- this should never happen!
  end

  log.debug ('ADDED handler exiting for ' .. device.label)
  
  devcreate_sem:release()         -- allow next device to be created

end

-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  -- Nothing to do here!

end


-- Called when device was deleted via mobile app
local function device_removed(driver, device)
  
  log.info("<" .. device.id .. "> removed")
  local rm_meta = device:get_field('onvif_disco')          -- SD PATCH: allow re-discovery after delete
  if rm_meta and rm_meta.ip then
    local still = false
    for _, d in ipairs(driver:get_devices()) do
      local m = d:get_field('onvif_disco')
      if d.id ~= device.id and m and m.ip == rm_meta.ip then; still = true; end
    end
    if not still then; created_ips[rm_meta.ip] = nil; end
  end
  
  if device:get_field('onvif_func') then
    commands.Unsubscribe(device, device:get_field('onvif_func').event_service_addr)
  end
  
  events.shutdownserver(driver, device)
  discover.cancel_rediscover(driver, device)
  
  local device_list = driver:get_devices()
  
  if #device_list == 0 then
    log.warn ('No more devices')
  end  
end

local function shutdown_handler(driver, event)

  log.debug ('Driver lifecycle handler invoked; event=', event)
  
  if event == 'shutdown' then

    log.info ('*** Driver being shut down ***')
    
    local device_list = driver:get_devices()
    
    for _, device in ipairs(device_list) do
    
      if device:get_field('onvif_func') then
        commands.Unsubscribe(device, device:get_field('onvif_func').event_service_addr)
      end
      
      events.shutdownserver(driver, device)
      discover.cancel_rediscover(driver, device)
      
    end
    
    log.info ('Shutdown complete')
  end
end


local function handler_infochanged(driver, device, event, args)

  log.debug ('INFOCHANGED handler; event=', event)
  
  if args.old_st_store.preferences then
  
    local reinit = false
    
    -- SD PATCH: IP / channel checked independently (several settings may change at once)
    if args.old_st_store.preferences.ipaddr ~= device.preferences.ipaddr then
      log.info ('IP address setting changed to', device.preferences.ipaddr)
      if apply_ip_pref(device) then
        device:emit_component_event(device.profile.components.info, cap_status.status('Tap Refresh to connect'))
      else
        device:emit_component_event(device.profile.components.info, cap_status.status('Invalid IP address'))
      end
    end
    if args.old_st_store.preferences.channel ~= device.preferences.channel then
      log.info ('NVR channel changed to', device.preferences.channel)
      reinit = true
    end
    -- SD PATCH: credentials changed on the NVR (parent) device -> copy to its channel devices
    if (args.old_st_store.preferences.rtspuser ~= device.preferences.rtspuser) or
       (args.old_st_store.preferences.rtsppass ~= device.preferences.rtsppass) or
       (args.old_st_store.preferences.userid ~= device.preferences.userid) or
       (args.old_st_store.preferences.password ~= device.preferences.password) then
      if not device:get_field('sd_channel') then
        local pru, prp = common.get_rtsp_creds(device)
        for _, d in ipairs(driver:get_devices()) do
          if d.device_network_id:find(device.device_network_id .. '_ch', 1, true) == 1 then
            d:set_field('sd_creds', { userid = common.get_userid(device), password = common.get_password(device),
                                      rtspuser = pru, rtsppass = prp }, {['persist'] = true })
            log.info ('Credentials copied to', d.label)
          end
        end
      end
      if (args.old_st_store.preferences.rtspuser ~= device.preferences.rtspuser) or
         (args.old_st_store.preferences.rtsppass ~= device.preferences.rtsppass) then
        log.info ('RTSP credentials updated')
      end
    end
  
    if args.old_st_store.preferences.userid ~= device.preferences.userid then 
      log.info ('UserID updated to', device.preferences.userid)
      if (device.preferences.userid ~= '*****') and (device.preferences.password ~= '*****') then
        device:emit_component_event(device.profile.components.info, cap_status.status('Tap Refresh to connect'))
      end
    elseif args.old_st_store.preferences.password ~= device.preferences.password then 
      log.info ('Password updated')
      if (device.preferences.userid ~= '*****') and (device.preferences.password ~= '*****') then
        device:emit_component_event(device.profile.components.info, cap_status.status('Tap Refresh to connect'))
      end
      
    elseif args.old_st_store.preferences.minmotioninterval ~= device.preferences.minmotioninterval then 
      log.info ('Min Motion interval updated to', device.preferences.minmotioninterval)
      
    elseif args.old_st_store.preferences.stream ~= device.preferences.stream then 
      log.info ('Video stream changed to', device.preferences.stream)  
      reinit = true
      
    elseif args.old_st_store.preferences.motionrule ~= device.preferences.motionrule then 
      log.info ('Motion rule changed to', device.preferences.motionrule)
      reinit = true
      
    elseif args.old_st_store.preferences.eventmethod ~= device.preferences.eventmethod then 
      log.info ('Event subscription method updated to', device.preferences.eventmethod)
    
    elseif args.old_st_store.preferences.autorevert ~= device.preferences.autorevert then 
      log.info ('Motion auto-revert updated to', device.preferences.autorevert)
      
    elseif args.old_st_store.preferences.revertdelay ~= device.preferences.revertdelay then 
      log.info ('Motion auto-revert delay updated to', device.preferences.revertdelay)
      
    else
      -- Assume driver is restarting - shutdown everything
      log.debug ('****** DRIVER RESTART ASSUMED ******')
    end


    --[[
    if reinit == true then
      if (device.preferences.userid ~= '*****') and (device.preferences.password ~= '*****') then
        init_device(device)
      end
    end
    --]]
  end
end


-- If the hub's IP address changes, this handler is called
local function lan_info_changed_handler(driver, hub_ipv4)
  if driver.listen_ip == nil or hub_ipv4 ~= driver.listen_ip then
    log.info("Hub IP address has changed; need to restart driver")
    
  end
end


-- Perform WS discovery to find target device(s) on the LAN
local function discovery_handler(driver, _, should_continue)
  log.debug ("Discovery handler invoked")
  
  local known_devices = {}
  local found_devices = {}

  local device_list = driver:get_devices()
  local known_ips, found_ips = {}, {}          -- SD PATCH: de-duplicate by IP address
  for _, device in ipairs(device_list) do
    known_devices[device.device_network_id] = true
    local m = device:get_field('onvif_disco')
    if m and m.ip then; known_ips[m.ip] = true; end
    local pip = tostring(device.preferences.ipaddr or ''):match('^(%d+%.%d+%.%d+%.%d+)')
    if pip and pip ~= '0.0.0.0' then; known_ips[pip] = true; end
  end
  for ip, _ in pairs(created_ips) do; known_ips[ip] = true; end
  for _, cam in pairs(newly_added) do; if cam.ip then; known_ips[cam.ip] = true; end; end

  local waittime = 10
  local reset_option = true
  local cycle = 0
  local newcreates = 0

  while should_continue() and (cycle < 4) do
  
    cycle = cycle + 1
    log.info (string.format('Starting Discovery cycle #%s', cycle))
    
    --****************************************************************************
    discover.discover(waittime,    
                  function (ipcam)
    
                    local urn = ipcam.urn
                    local ip = ipcam.ip

                    if known_ips[ip] or found_ips[ip] then
                      log.debug ('Device at ' .. tostring(ip) .. ' already known or found; skipped')
                    elseif not known_devices[urn] and not found_devices[urn] then
                      found_devices[urn] = true
                      found_ips[ip] = true
                      created_ips[ip] = true

                      local modelname = 'Unknown'
                      local name = 'ONVIF ' .. tostring(ip) .. ' (configure!)'
                      discovered_num = discovered_num + 1
                      local manufacturer = 'Unknown'
                      
                      local vendlabel
                      if ipcam.vendname then
                        vendlabel = ipcam.vendname
                      else
                        vendlabel = name
                      end
                      
                      local devprofile = 'onvif_cam.v3'

                      local create_device_msg = {
                        type = "LAN",
                        
                        device_network_id = urn,
                        label = name,
                        profile = devprofile,
                        manufacturer = manufacturer,
                        model = modelname,
                        vendor_provided_label = vendlabel,
                      }
                      
                      newly_added[urn] = ipcam          -- squirrel away device metadata for device_added handler
                                                          -- ... because there's currently no way to attach it to the new device here :-(
                                                          
                      -- Device creation protected by a semaphore,
                      --   since rapid sequential creation calls causes problems with Edge right now.
                      --   Semaphore is released at the end of ADDED lifecycle.
                      devcreate_sem:acquire(function()
                        log.info(string.format('Creating discovered IP Camera found at %s', ip))
                        log.info("\tdevice_network_id = " .. urn)
                        assert (
                          driver:try_create_device(create_device_msg),
                          "failed to create device record"
                        )
                      end)
                      
                      newcreates = newcreates + 1

                    else
                      log.debug("Discovered device was already known")
                    end
                  end,
                  reset_option
    )
    --***************************************************************************
    cosock.socket.sleep(waittime + 1)
    cosock.socket.sleep(newcreates)
      -- SD PATCH: nothing found in first two cycles and no existing devices -> create one manual device
      if cycle == 2 and newcreates == 0 and #device_list == 0 and next(created_ips) == nil then
      local have_manual = false
      for dni, _ in pairs(known_devices) do
        if dni:match('^MAN_SD') then; have_manual = true; break; end
      end
      if not have_manual then
        local dni = 'MAN_SD' .. tostring(os.time()) .. '_0.0.0.0:80'
        log.info ('Creating manual device', dni)
        devcreate_sem:acquire(function()
          assert (driver:try_create_device({
            type = "LAN",
            device_network_id = dni,
            label = 'ONVIF NVR (set IP in Settings)',
            profile = 'onvif_cam.v3',
            manufacturer = 'Unknown',
            model = 'Unknown',
            vendor_provided_label = 'ONVIF Manual',
          }), "failed to create manual device record")
        end)
      end
    end
    reset_option = false
  end
  log.info("Exiting discovery")
end

-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
onvifDriver = Driver("onvifDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    deleted = device_removed,
    removed = device_removed,
  },
  driver_lifecycle = shutdown_handler,
  lan_info_changed_handler = lan_info_changed_handler,
  capability_handlers = {
  
    [cap_refresh.ID] = {
      [cap_refresh.commands.push.NAME] = handle_refresh,
    },
    [cap_motion.ID] = {
      [cap_motion.commands.setSwitch.NAME] = handle_switch,
      [cap_motion.commands.switchOn.NAME] = handle_switch,
      [cap_motion.commands.switchOff.NAME] = handle_switch,
    },
    [capabilities.videoStream.ID] = {
      [capabilities.videoStream.commands.startStream.NAME] = handle_stream,
      [capabilities.videoStream.commands.stopStream.NAME] = handle_stream,
    },
  }
})

log.debug("**** ONVIF Driver V1.3 Start ****")

devcreate_sem = Semaphore()

onvifDriver:run()
