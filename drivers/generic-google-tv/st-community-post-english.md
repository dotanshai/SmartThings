# [EDGE] Generic Google TV / Android TV Driver — control any Google TV via SmartThings

Hi all,

I've been building a SmartThings Edge driver that controls **any Google TV / Android TV device** — not tied to a single brand. It talks directly to the same Android TV Remote Service protocol (v2, TLS-based pairing on port 6467, remote control on port 6466) that the official Google Home / Google TV app itself uses, so it should work on any genuine Android TV OS / Google TV device: Sony, TCL, Hisense, the Google TV Streamer, NVIDIA Shield, etc.

Built and tested primarily on a TCL Google TV so far — looking for testers on other brands/models to help shake out any device-specific quirks before I call it stable.

## Features

- Power: on via Wake-on-LAN (if the TV's MAC address is set and WoL is enabled on the TV), off via the standard power key
- Volume up/down/mute, plus an approximate `setVolume`
- Media playback: play/pause/stop/rewind/fast-forward
- Channel up/down
- Full Home/Back/Menu/Settings/D-pad/numeric-keypad navigation via the standard `keypadInput` capability — this gets the app's native circular D-pad UI, not a generic button list
- A built-in diagnostic: tap the refresh icon on the device to get a connectivity/TLS report logged for troubleshooting

## Setup

1. Join my channel: [channel invite link]
2. In the SmartThings app: **Add device → Scan for nearby devices** — creates an empty "Google TV" placeholder device
3. Open the device's Settings and enter the TV's IP address (a static/reserved IP is strongly recommended)
4. A 6-character code will appear on the TV screen — enter it in the device's Settings under "Pairing code"
5. Done

## Known issue

The Media Track Control (next/previous track) buttons on the device's control page don't respond to taps — confirmed this is an app-side rendering bug, not a driver issue: the exact same commands work correctly when triggered via a Routine instead of the direct UI button. Reported to SmartThings support; using a Routine is a solid workaround in the meantime.

## If something doesn't work for you

There's also a standalone Python script (no SmartThings/hub needed) that checks whether a given device actually speaks this protocol before you even try pairing — useful for ruling out non-certified "Android TV-styled" boxes that don't run genuine Android TV OS. Happy to share it if useful.

If you hit an issue, the driver logs a detailed step-by-step trace during pairing (`smartthings edge:drivers:logcat`) — a copy of that log is the fastest way for me to help debug.

Would love feedback from anyone running this on a non-TCL Google TV, especially Sony (I also maintain a Sony-specific driver separately, but curious how this generic one compares) or Hisense.

Thanks!
