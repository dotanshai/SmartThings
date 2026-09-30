# SmartThings Integrations by Shai D.

Free SmartThings integrations for the Israeli SmartThings community.

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
| Zigbee Multi Switch Child SD | [14 Zigbee models](drivers/zigbee-multi-switch-child-sd#supported-devices) |
| Zigbee Switch SD | [129 Zigbee models](drivers/zigbee-switch-sd#supported-devices) |
| Zigbee Siren SD | [13 Zigbee models](drivers/zigbee-siren-sd#supported-devices) |
| Switcher Breeze | [LAN](drivers/switcher-breeze#supported-devices) |
| Dolphin Boiler SD (LAN) | [LAN](drivers/dolphin-boiler-sd-lan#supported-devices) |

## Schema Connectors (cloud, AWS Lambda)
| Integration | Install | Link valid until | Source |
|---|---|---|---|
| ARAD Water Meter | [Invite link](https://invitations.smartthings.com/schemaApp/d0752d6c-6dd4-43ab-b820-c8123207a0d8) | 2026-10-30 | [code](schemas/arad-water-meter) |
| Dolphin Boiler | [Invite link](https://invitations.smartthings.com/schemaApp/80f11bd9-e6ba-4f91-9b64-d7c1dff12eaa) | 2026-10-17 | [code](schemas/dolphin-boiler) |
| IEC Electric Meter | [Invite link](https://invitations.smartthings.com/schemaApp/aeaa0458-4957-4d75-8f09-7563df54ac63) | 2026-10-19 | [code](schemas/iec-electric-meter) |
| LG ThinQ Laundry | [Invite link](https://invitations.smartthings.com/schemaApp/90400f87-b219-4e22-a6ef-0110f46cdff3) | 2026-10-17 | [code](schemas/lg-thinq-laundry) |
| LG ThinQ Fridge | [Invite link](https://invitations.smartthings.com/schemaApp/a53a155d-aae7-4046-a7da-eca12e560f41) | 2026-10-30 | [code](schemas/lg-thinq-fridge) |
| Shabbat Switch | [Invite link](https://invitations.smartthings.com/schemaApp/c085282d-3cde-4bea-8fc0-a450ee30d561) | 2026-10-17 | [code](schemas/shabbat-switch) |
| Tadiran AC | [Invite link](https://invitations.smartthings.com/schemaApp/9a1ad8b1-be50-4d2b-8c44-5b577904f789) | 2026-10-18 | [code](schemas/tadiran-ac) |
| Tornado AC | [Invite link](https://invitations.smartthings.com/schemaApp/73af62b5-54dd-422e-914f-73956bddc69b) | 2026-10-23 | [code](schemas/tornado-ac) |
| Electra AC | [Invite link](https://invitations.smartthings.com/schemaApp/d3c01559-68c4-4c6b-b46b-94ccd8449e1d) | 2026-10-25 | [code](schemas/electra-ac) |

Invite links are renewed about every 30 days. If a link has expired, ask in the Facebook group.

Secrets (client secrets, tokens, passwords, AWS account ID) are not included.
Set them as Lambda environment variables when deploying your own copy.

## Legacy
Old Groovy device handlers (pre-Edge) are in `legacy-groovy/`.
