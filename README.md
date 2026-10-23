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
| ARAD Water Meter | [Invite link](https://invitations.smartthings.com/schemaApp/d0752d6c-6dd4-43ab-b820-c8123207a0d8) | 2026-10-30 | [code](schemas/arad-water-meter) |
| Dolphin Boiler | [Invite link](https://invitations.smartthings.com/schemaApp/96459033-b004-49d3-b023-f10a03b162ff) | 2026-11-18 | [code](schemas/dolphin-boiler) |
| IEC Electric Meter | [Invite link](https://invitations.smartthings.com/schemaApp/147990f6-e861-4b1b-94e5-aae52006861c) | 2026-11-18 | [code](schemas/iec-electric-meter) |
| LG ThinQ Laundry | [Invite link](https://invitations.smartthings.com/schemaApp/f19ad31d-e680-40d5-8d0b-4d409e2b8273) | 2026-11-18 | [code](schemas/lg-thinq-laundry) |
| LG ThinQ Fridge | [Invite link](https://invitations.smartthings.com/schemaApp/a53a155d-aae7-4046-a7da-eca12e560f41) | 2026-10-30 | [code](schemas/lg-thinq-fridge) |
| Shabbat Switch | [Invite link](https://invitations.smartthings.com/schemaApp/f17d560c-b5bc-445e-a79d-187cf55edd8f) | 2026-11-18 | [code](schemas/shabbat-switch) |
| Tadiran AC | [Invite link](https://invitations.smartthings.com/schemaApp/3528d96c-9484-420b-bf01-02b62884dacf) | 2026-11-18 | [code](schemas/tadiran-ac) |
| Tornado AC | [Invite link](https://invitations.smartthings.com/schemaApp/467ddf56-644f-473b-85f3-0f361253edfe) | 2026-11-18 | [code](schemas/tornado-ac) |
| Electra AC | [Invite link](https://invitations.smartthings.com/schemaApp/2b6fae7f-826a-4e8e-8c4d-26a26574ed16) | 2026-11-18 | [code](schemas/electra-ac) |

Invite links are renewed about every 30 days. If a link has expired, ask in the Facebook group.

Secrets (client secrets, tokens, passwords, AWS account ID) are not included.
Set them as Lambda environment variables when deploying your own copy.

## Legacy
Old Groovy device handlers (pre-Edge) are in `legacy-groovy/`.
