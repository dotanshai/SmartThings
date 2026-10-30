# SmartThings Integrations by Shai D.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/dotan_shai)

Free SmartThings integrations for the Israeli SmartThings community.

### 🆕 New: [Z-Wave Window Treatment SD LAN](drivers/zwave-window-treatment-sd-lan)
For Fibaro Roller Shutter 4 (FGR-224) blinds that keep showing "offline" or don't respond from the app. Adds an always-online "(App)" device with open / close / pause and a slider (works with routines, Alexa and SharpTools), automatic command retries, a live position display while the blind moves, and an estimated position when you stop it mid-way. Based on Mariano's Z-Wave Window Treatment Mc, so all its other blinds are still supported.

### 🆕 New: [WiFi Presence SD](drivers/wifi-presence-sd)
Phone presence by home WiFi – no GPS, no app, any phone. Runs locally on the hub.

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
| Dolphin Boiler | [Invite link](https://invitations.smartthings.com/schemaApp/8a428650-aeef-4392-b347-7199926cfaaa) | 2026-11-29 | [code](schemas/dolphin-boiler) |
| IEC Electric Meter | [Invite link](https://invitations.smartthings.com/schemaApp/b00287e7-21e9-41fe-b860-1db1f36d954d) | 2026-11-29 | [code](schemas/iec-electric-meter) |
| LG ThinQ Laundry | [Invite link](https://invitations.smartthings.com/schemaApp/0e7e41bf-3421-4bd1-9173-c88b1f46fee1) | 2026-11-29 | [code](schemas/lg-thinq-laundry) |
| LG ThinQ Fridge | [Invite link](https://invitations.smartthings.com/schemaApp/38df91e7-d06b-4df5-847d-ee1529201a40) | 2026-11-29 | [code](schemas/lg-thinq-fridge) |
| Shabbat Switch | [Invite link](https://invitations.smartthings.com/schemaApp/b270b129-8d22-4e65-904e-6805c5669c7a) | 2026-11-29 | [code](schemas/shabbat-switch) |
| Tadiran AC | [Invite link](https://invitations.smartthings.com/schemaApp/a628c756-db56-43fa-a941-5736965262be) | 2026-11-29 | [code](schemas/tadiran-ac) |
| Tornado AC | [Invite link](https://invitations.smartthings.com/schemaApp/b35a7966-cbfa-4949-a96c-7747683f39e4) | 2026-11-29 | [code](schemas/tornado-ac) |
| Electra AC | [Invite link](https://invitations.smartthings.com/schemaApp/4ca11785-2aed-4d43-8ddc-07989a6305d6) | 2026-11-29 | [code](schemas/electra-ac) |
| Oref Alert (Pikud HaOref) | [Invite link](https://invitations.smartthings.com/schemaApp/f1f3bde9-df3c-494c-9829-309572a4a9a4) | 2026-11-29 | - |

Invite links are renewed about every 30 days. If a link has expired, ask in the Facebook group.

Secrets (client secrets, tokens, passwords, AWS account ID) are not included.
Set them as Lambda environment variables when deploying your own copy.

## Legacy
Old Groovy device handlers (pre-Edge) are in `legacy-groovy/`.

## Offline Devices Monitor
Daily Telegram / Pushover alert listing your offline SmartThings devices – no PAT, no SharpTools.
👉 https://tinyurl.com/st-offline-monitor · [Details](OfflineDevicesMonitor/README.md)