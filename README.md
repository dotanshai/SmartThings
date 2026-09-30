# SmartThings Integrations by Shai D.

Free SmartThings integrations for the Israeli SmartThings community.

## Edge Drivers
Install from the **Shai D. Shared Drivers** channel.

| Driver | Folder |
|---|---|
| Generic Google TV | `drivers/generic-google-tv` |
| LG TV webOS | `drivers/lg-tv-webos` |
| ONVIF Camera NVR SD (Hikvision) | `drivers/onvif-camera-nvr-sd` |
| RF Cloner 8ch (Tuya) | `drivers/rf-cloner-8ch` |
| Zigbee Leakage Sensor SD | `drivers/zigbee-leakage-sensor-sd` |
| Zigbee Multi Switch Light Curtain SD | `drivers/zigbee-multi-switch-light-curtain-sd` |
| Zigbee Multi Switch Child SD | `drivers/zigbee-multi-switch-child-sd` |
| Zigbee Switch SD | `drivers/zigbee-switch-sd` |
| Zigbee Siren SD | `drivers/zigbee-siren-sd` |
| Switcher Breeze | `drivers/switcher-breeze` |
| Dolphin Boiler SD (LAN) | `drivers/dolphin-boiler-sd-lan` |

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
