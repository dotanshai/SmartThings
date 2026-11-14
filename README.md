# SmartThings Integrations by Shai D.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/dotan_shai)

Free SmartThings integrations for the Israeli and global SmartThings community.

### 🆕 New: [PalGate – open gates from SmartThings](schemas/palgate)
Open PalGate gates from the SmartThings app, by voice (Alexa / Google / Bixby) or from Routines, with a "last result" tile showing if the gate opened. Needs remote-open permission from your gate admin and a second screen for one minute while linking. Unofficial, not affiliated with PAL Electronics.

### 🆕 New: [Oref Alert – Pikud HaOref alerts](schemas/oref-alert)
Real-time Home Front Command alerts in SmartThings – direct connection to the official alerts feed, no Tasker / MacroDroid / phone needed. Alert, pre-alert, event ended, time to shelter, and a contact sensor for Routines. Supplements, not replaces, the official app.

### 🆕 New: [Voice Box – Alexa skill](alexa-skills/voice-box)
Your own audio messages on Alexa – upload any recording, TTS or short music clip and play it by voice or from a Routine. Free, no ads – no more My Pod. [Enable in the Alexa store](https://www.amazon.com/dp/B0H8GGHJNB/) · Upload: https://tinyurl.com/voicebox-il

### 🆕 New: [Z-Wave Window Treatment SD LAN](drivers/zwave-window-treatment-sd-lan)
For Fibaro Roller Shutter 4 (FGR-224) blinds that keep showing "offline" or don't respond from the app. Adds an always-online "(App)" device with open / close / pause and a slider (works with routines, Alexa and SharpTools), automatic command retries, a live position display while the blind moves, and an estimated position when you stop it mid-way. Based on Mariano's Z-Wave Window Treatment Mc, so all its other blinds are still supported.

### 🆕 New: [WiFi Presence SD](drivers/wifi-presence-sd)
Phone presence by home WiFi – no GPS, no app, any phone. Runs locally on the hub.
## Offline Devices Monitor
Daily Telegram / Pushover alert listing your offline SmartThings devices – no PAT, no SharpTools.
👉 https://tinyurl.com/st-offline-monitor · [Details](OfflineDevicesMonitor/README.md)
## Edge Drivers
Install from the **Shai D. Shared Drivers** channel:

👉 **[Join the channel](https://bestow-regional.api.smartthings.com/invite/Q1jP7By0KVlL)** → enroll your hub → Available Drivers → install.

| Driver | Supported Devices |
|---|---|
| Generic Google TV | [LAN](drivers/generic-google-tv#supported-devices) |
| LG TV webOS | [LAN](drivers/lg-tv-webos#supported-devices) |
| ONVIF Camera NVR SD (Hikvision) | [LAN](drivers/onvif-camera-nvr-sd#supported-devices) |
| RF Cloner 8ch (Tuya) | [1 Zigbee model](drivers/rf-cloner-8ch#supported-devices) |
| Zigbee Leakage Sensor SD | [30 Zigbee models](drivers/zigbee-leakage-sensor-sd#supported-devices) |
| Zigbee Multi Switch Light Curtain SD | [20 Zigbee models](drivers/zigbee-multi-switch-light-curtain-sd#supported-devices) |
| Zigbee Multi Switch Child SD (source only, not in channel) | [14 Zigbee models](drivers/zigbee-multi-switch-child-sd#supported-devices) |
| Zigbee Switch SD | [129 Zigbee models](drivers/zigbee-switch-sd#supported-devices) |
| Zigbee Siren SD | [13 Zigbee models](drivers/zigbee-siren-sd#supported-devices) |
| Z-Wave Window Treatment SD LAN | [22 Z-Wave models](drivers/zwave-window-treatment-sd-lan#supported-devices) |
| WiFi Presence SD | [Any phone (LAN)](drivers/wifi-presence-sd#supported-devices) |
| Switcher Breeze | [LAN](drivers/switcher-breeze#supported-devices) |
| Switcher Touch LAN (community driver) | [LAN](drivers/switcher-touch-lan#supported-devices) |
| Dolphin Boiler SD (LAN) (source only, not in channel) | [LAN](drivers/dolphin-boiler-sd-lan#supported-devices) |

## Schema Connectors (cloud, AWS Lambda)
| Integration | Install | Link valid until | Source |
|---|---|---|---|
| ARAD Water Meter | [Invite link](https://invitations.smartthings.com/schemaApp/cfe42894-6b7c-4f0a-83d5-18e7e8e251ab) | 2026-11-29 | [code](schemas/arad-water-meter) |
| Dolphin Boiler | [Invite link](https://invitations.smartthings.com/schemaApp/8a428650-aeef-4392-b347-7199926cfaaa) <br>Official version now available: SmartThings app, Add device, Partner devices, Dolphin Boiler ([partner page](https://partners.smartthings.com/partners/dolphin-boiler)) | 2026-11-29 | [code](schemas/dolphin-boiler) |
| IEC Electric Meter | [Invite link](https://invitations.smartthings.com/schemaApp/b00287e7-21e9-41fe-b860-1db1f36d954d) | 2026-11-29 | [code](schemas/iec-electric-meter) |
| LG ThinQ Laundry | [Invite link](https://invitations.smartthings.com/schemaApp/0e7e41bf-3421-4bd1-9173-c88b1f46fee1) | 2026-11-29 | [code](schemas/lg-thinq-laundry) |
| LG ThinQ Fridge | [Invite link](https://invitations.smartthings.com/schemaApp/38df91e7-d06b-4df5-847d-ee1529201a40) | 2026-11-29 | [code](schemas/lg-thinq-fridge) |
| Shabbat Switch | [Invite link](https://invitations.smartthings.com/schemaApp/b270b129-8d22-4e65-904e-6805c5669c7a) | 2026-11-29 | [code](schemas/shabbat-switch) |
| Tadiran AC | [Invite link](https://invitations.smartthings.com/schemaApp/a628c756-db56-43fa-a941-5736965262be) | 2026-11-29 | [code](schemas/tadiran-ac) |
| Tornado AC | [Invite link](https://invitations.smartthings.com/schemaApp/b35a7966-cbfa-4949-a96c-7747683f39e4) | 2026-11-29 | [code](schemas/tornado-ac) |
| Electra AC | [Invite link](https://invitations.smartthings.com/schemaApp/4ca11785-2aed-4d43-8ddc-07989a6305d6) | 2026-11-29 | [code](schemas/electra-ac) |
| Oref Alert (Pikud HaOref) | [Invite link](https://invitations.smartthings.com/schemaApp/f1f3bde9-df3c-494c-9829-309572a4a9a4) | 2026-11-29 | [docs](schemas/oref-alert) |
| PalGate | [Invite link](https://invitations.smartthings.com/schemaApp/47903f19-c9a8-41b8-b061-70ed8bc578e2) | 2026-12-13 | [code](schemas/palgate) |

Invite links are renewed about every 30 days. If a link has expired, ask in the Facebook group.

Secrets (client secrets, tokens, passwords, AWS account ID) are not included.
Set them as Lambda environment variables when deploying your own copy.

## Alexa Skills
| Skill | Install | Source |
|---|---|---|
| Voice Box | [Alexa store](https://www.amazon.com/dp/B0H8GGHJNB/) | [code](alexa-skills/voice-box) |

## Legacy
Old Groovy device handlers (pre-Edge) are in `legacy-groovy/`.

## Supporters

Thank you to my supporters:

- Gil Rozenberg

<!-- ZIGBEE-MAP START -->
## 📡 Zigbee Live Map

Live map of your SmartThings Zigbee network, in the browser (PC or phone):
- **Signal map** – RSSI / LQI per device, refreshed every minute
- **Mesh** – real neighbor tables: who connects through whom, link quality per link, weak devices
- **Ghost removal** – ask a router to drop devices that were deleted from the app but are still in the mesh

**Open:** https://dotanshai.github.io/SmartThings/zigbee-map/

**Token:** create one at https://account.smartthings.com/tokens with *Devices → List all devices + See all devices* (add *Control all devices* for ghost removal). The token stays in your browser and is sent only to SmartThings.

The **Mesh** tab is built from neighbor tables reported by routers (plugs, switches, bulbs, repeaters) running the ✓ drivers below. Battery devices appear automatically through their parent router.

## Edge drivers in my channel

[Join the channel](https://bestow-regional.api.smartthings.com/invite/Q1jP7By0KVlL)

| Driver | Mesh | Code |
|---|---|---|
| rf-cloner-8ch | ✓ | [source](rf-cloner-8ch) |
| Zigbee Multi Switch and Child SD | ✓ | [source](drivers/zigbee-driver-SD) |
| Zigbee Multi Switch Light Curtain SD | ✓ | [source](drivers/zigbee-multi-switch-light-curtain-sd) |
| Zigbee Range Extender SD | ✓ | [source](drivers/zigbee-range-extender-SD) |
| Zigbee Switch Power SD | ✓ | [source](drivers/zigbee-switch-power-v5-SD) |
| Zigbee Switch SD | ✓ | [source](drivers/zigbee-switch-sd) |
| Zigbee Thing SD | ✓ | [source](drivers/zigbee-thing-mc-htlm-text-SD) |
| Zigbee Window Treatment SD | ✓ | [source](drivers/Zigbee%20Window%20Treatment%20SD) |
| Aqara/Xiaomi Switch and Button SD | ✓ | [source](drivers/xiaomi-switch-sd) – fork of [veonua/smartthingsedge-xiaomi](https://github.com/veonua/smartthingsedge-xiaomi) |
| zigbee_siren_sd_metrics_v2 | ✓ | [source](drivers/zigbee-siren-sd) |
| Generic Google TV |  | [source](drivers/generic-google-tv) |
| LG TV webOS |  | [source](drivers/lg-tv-webos) |
| ONVIF Camera NVR SD |  | [source](drivers/onvif-camera-nvr-sd) |
| WiFi Presence SD |  | [source](drivers/wifi-presence-sd) |
| Zigbee Leakage Sensor SD |  | [source](drivers/zigbee-leakage-sensor-sd) |
| Z-Wave Window Treatment SD LAN |  | [source](drivers/zwave-window-treatment-sd-lan) |
### 🏠 Floor plan mode
- In the **Mesh** tab click **Upload plan…** and choose a PNG/JPG of your apartment (screenshot a PDF first).
- Drag each device to its room – it stays pinned; right-click a device to un-pin it.
- Links and the click-to-see route to the hub are drawn on top of your plan.
- Your plan is saved **only in your browser** – it is never uploaded.
- **Export layout** saves the plan + positions to a file; **Import layout** loads it on another browser, PC or phone.
- **+ Floor** adds another level (or the stairs); switch floors from the selector. Devices on other floors show faded at the edge with their links.

### 🔄 Live routes
- **Scan now** asks every SD router to report its tables immediately (token needs *Control all devices*); otherwise they report every 15 min.
- **History** (in *Parent/child links only*): faded dotted lines show earlier parents / next hops – useful after adding a repeater. **Clear history** starts fresh.
- A router that misses two neighbor polls is marked **offline** by the SD drivers within ~3 min, and its stale table is ignored by the map.
<!-- ZIGBEE-MAP END -->