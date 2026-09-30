# SmartThings Integrations by Shai D.

Free SmartThings integrations for the Israeli SmartThings community.

## Edge Drivers
Install from the **Shai D. Shared Drivers** channel.

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
| Integration | Folder |
|---|---|
| ARAD Water Meter | `schemas/arad-water-meter` |
| Dolphin Boiler | `schemas/dolphin-boiler` |
| IEC Electric Meter | `schemas/iec-electric-meter` |
| LG ThinQ Laundry | `schemas/lg-thinq-laundry` |
| LG ThinQ Fridge | `schemas/lg-thinq-fridge` |
| Shabbat Switch | `schemas/shabbat-switch` |
| Tadiran AC | `schemas/tadiran-ac` |
| Tornado AC | `schemas/tornado-ac` |
| Electra AC | `schemas/electra-ac` |

Secrets (client secrets, tokens, passwords, AWS account ID) are not included.
Set them as Lambda environment variables when deploying your own copy.

## Legacy
Old Groovy device handlers (pre-Edge) are in `legacy-groovy/`.
