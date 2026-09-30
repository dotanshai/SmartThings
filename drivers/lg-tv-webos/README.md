# LG TV webOS - SmartThings Edge driver

Install from the **Shai D. Shared Drivers** channel: [Join the channel](https://bestow-regional.api.smartthings.com/invite/Q1jP7By0KVlL)

Local (LAN) SmartThings Edge driver for LG webOS TVs.

**Based on [LGTV by Todd Austin](https://github.com/toddaustin07/LGTV)** (Apache License 2.0).
This is a modified version. All credit for the original driver goes to Todd Austin.

## What was changed from the original (V1.1)
- Falls back to an **unsigned registration** when the TV rejects the old signed manifest
  (newer LG firmware blacklists it, so no pairing prompt ever appears).
- Clears a stale pairing key and pairs again automatically.
- Does not send commands until the TV has confirmed registration.
- The **Status** field shows the real state or the TV's error text (instead of always "Connected").
- Built-in app list for TVs that refuse to list their apps (includes some Israeli apps).
- Friendly names for system screens (Home, Settings, ...) in Active App.

## Tested on
- LG OLED77B56LA, webOS 25 (10.3.2): pairing, power on/off, volume, mute, input source,
  change app, active app, on-screen message.

## Install
1. Enroll your hub in the channel and install **LG TV webOS**.
2. Turn the TV on. On the TV enable:
   - **TV On With Mobile** (Wi-Fi and Bluetooth) and **Wake on LAN**.
   - On 2025 TVs (no "LG Connect Apps" option): enable **SDDP** and **IP Control**
     (Settings > Support > IP Control Settings, or All Settings > Network and type **82888**
     on the remote to open the hidden menu).
3. SmartThings app: **Add device > Scan for nearby devices** (TV must be on).
4. **Accept the pairing prompt on the TV screen.**
5. In the device settings, enter the TV's **MAC address** in "WOL MAC Address" (needed to turn the TV on).

## Status field
- `Pairing - ACCEPT on TV screen` - accept the prompt on the TV.
- `Registered` - working.
- `TV error: ...` - the TV rejected something; the text says what.
- `No reply from TV` - the TV is not answering (off, wrong network, IP Control/SDDP off).

## Known limitations
- Uses LG's undocumented control interface; a future firmware update may break it.
- With unsigned registration the TV may refuse to list installed apps; the built-in list is used instead.
- Current Channel is empty unless the TV is on live TV.
- Not for LG signage displays.

## Adding an app
Open the app on the TV, refresh the device: **Active App** shows the app's ID. Send the ID and name
to the maintainer to add it to the built-in list.

## License
Apache License 2.0 (see LICENSE). Original work Copyright 2023 Todd Austin.

## Supported Devices

LG webOS TVs on the local network (tested on OLED77B56LA). Added via LAN scan.
