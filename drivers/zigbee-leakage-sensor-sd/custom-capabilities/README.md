# Custom capabilities for Zigbee Leakage Sensor SD

The driver's profiles reference 7 custom capabilities (battery-low flag, plus
the ZG-226Z siren controls and ZG-223Z tuning knobs). These need to exist
under YOUR SmartThings developer account before you publish the driver -
right now the profiles and Lua reference a placeholder "__NAMESPACE__".

## 1. Create each capability

From this folder, run (requires SmartThings CLI, already logged in):

    smartthings capabilities:create -i batteryLow.json
    smartthings capabilities:create -i mufflingWaterLeak.json
    smartthings capabilities:create -i alarmVolumeHobeian.json
    smartthings capabilities:create -i alarmRingHobeian.json
    smartthings capabilities:create -i alarmDurationSiren.json
    smartthings capabilities:create -i illuminanceSamplingZg223zMinutes.json
    smartthings capabilities:create -i zg223zSensitivity.json

Each command prints the created capability's full ID, e.g.
"a1b2c3d4-namespace.batteryLow" or similar - the part before the first "."
is YOUR namespace (same for all 7, tied to your account).

## 2. Substitute your namespace into the driver

Once you have your namespace, run this from the driver folder
(zigbee-leakage-sensor-sd/):

    grep -rl '__NAMESPACE__' . | xargs sed -i 's/__NAMESPACE__/yournamespace/g'

Replace "yournamespace" with what the CLI actually gave you. This updates
both the profiles/*.yml files and src/runtime/capability_metadata.lua in
one pass.

## 3. Package and publish

    smartthings edge:drivers:package .
    smartthings edge:drivers:publish <driver-id>
    smartthings edge:channels:assign ...

## What each capability is for

- batteryLow: read-only flag (normal/low), used by all ZCL leak sensors
- mufflingWaterLeak (off/on), alarmVolumeHobeian (low/middle/high/mute),
  alarmRingHobeian (mute/beep/music), alarmDurationSiren (0-1800s):
  ZG-226Z's siren controls
- zg223zSensitivity (0-9), illuminanceSamplingZg223zMinutes (1-480):
  ZG-223Z's tuning preferences
