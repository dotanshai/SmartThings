# Generic Google TV / Android TV SmartThings Edge Driver

Controls **any** Google TV / Android TV device (TCL, Sony, Hisense, Chromecast
with Google TV, etc.) over the standard Android TV Remote Service protocol
that ships with the OS itself — not a brand-specific API. This is a
different transport from the Sony Simple IP Control driver, so it's a
separate device/driver, not a replacement for it.

## Status — please read before installing

This was built by working from the protocol's official and
community-reverse-engineered documentation, and the cryptography-heavy
pieces (base64 decoding, DER/X.509 parsing, SHA-256, the pairing secret
algorithm) were unit-tested against known-correct values and a real
generated certificate during development — see the `self_test.lua` results
below.

What has **not** been tested is the actual end-to-end flow against a real
TV from a real SmartThings hub, because that requires your hub and your
TV's LAN — nothing I have access to. Two spots most likely to need a small
fix once you try it for real:

1. The exact method names on the TLS peer certificate object
   (`tls:getpeercertificate()` returning something with a `:pem()` method)
   — this is standard LuaSec behavior but hasn't been confirmed against
   SmartThings' specific bundled version.
2. The remote-port (6466) handshake order in `src/remote.lua` — documented
   by community clients, but not from Google's own source the way the
   pairing secret algorithm was.

If pairing fails, turn on live logging (`smartthings edge:drivers:logcat`)
and send me the output — that'll usually pin down which of the two it is.

## Security note

This driver uses **one certificate shared by every install**, baked into
`src/cert.lua`, rather than generating a unique one per user. That was a
deliberate choice for simplicity (SmartThings Edge can't generate
certificates on-hub) over security: since the private key is public (it's
in this source), anyone on a paired TV's local network who also has a copy
of this driver could control it without repeating the on-screen pairing
step. That's a LAN-only risk — someone would need to already be on your
network — but worth knowing before distributing this widely.

## Setup (per TV)

1. Install the driver on your hub via the channel invite, then add a
   device: choose "Add device" → "Scan nearby" under this driver — it
   creates one placeholder "Google TV" device (there's no way to
   auto-discover which LAN devices are Google TVs, so you do this once per
   TV).
2. Open the device → Settings → **TV IP address**: enter the TV's LAN IP
   (a static/reserved one is strongly recommended, or you'll need to
   re-pair whenever it changes). Save.
3. The TV should now show a 6-character pairing code on screen. Go back
   into the device's Settings → **Pairing code**, enter it, save.
4. (Optional) Settings → **TV MAC address**: needed only if you want the
   `switch.on()` command to wake the TV from fully off via Wake-on-LAN —
   also requires enabling Wake-on-LAN in the TV's own network settings,
   and works far more reliably over Ethernet than Wi‑Fi. **On TCL Google TV
   sets, check Settings → Energy modes**: the power-saving "optimized
   consumption" mode drops Wi‑Fi entirely in standby, which breaks
   Wake-on-LAN over Wi‑Fi outright — switch to "high consumption" mode if
   you want WoL to work wirelessly.

## What it controls

Power (on via Wake-on-LAN if MAC is set, off via the power key), volume
up/down/mute, an approximate `setVolume`, play/pause/stop/rewind/fast-forward,
next/previous track, channel up/down, Home/Back/Menu/Settings/Exit/0-9/
D-pad navigation via the standard `keypadInput` capability (native D-pad +
numeric keypad UI), and launching apps via the standard `mediaPresets`
capability. There's no way to get a live list of installed apps at all
(the protocol doesn't expose that), so the app list is a fixed, curated
set that you can extend yourself via the **Custom apps** device setting.

Two ways to specify an app in **Custom apps** (format:
`Name|target, Name2|target2`):
- **By package name (recommended, most reliable):**
  `market://launch?id=<package.name>` — launches the app directly by its
  Android package name, regardless of whether it has any web presence.
  Easiest way to find it: on the TV, go to **Settings → Apps**, select the
  app, and the package name is shown right under the app's name (e.g.
  `com.google.android.youtube.tvmusic`) — no computer needed. Alternatively,
  it's the `id=` parameter in the app's Google Play Store URL.
- **By web URL:** `https://example.com/` — only works if the app has
  registered that URL as a "verified Android app link", which not every
  app does (this is why some curated entries below may open a browser
  instead of the app).

Curated apps included by default (mixed reliability — YouTube is
confirmed working via web URL; YouTube Music uses the more reliable
package-name method after the web URL didn't launch the app for a
tester; the rest are untested guesses, mostly web URLs):

## Known compatibility caveat

Some older Android TV (not Google TV UI) sets — TCL included — have been
reported to fail the TLS handshake with this exact protocol on very old
firmware (Android TV 9-era). Since your TCL is running the newer Google TV
interface, this is unlikely to affect you, but worth knowing if a group
member's older TCL Android TV set doesn't pair.

## Connection resilience

The driver maintains a persistent connection and automatically reconnects
on any drop (Wi-Fi hiccup, TV reboot, router restart, etc.) with
exponential backoff (retrying every 5s, then 10s, 20s... capped at 5
minutes), forever, in the background. You shouldn't need to manually
refresh or re-pair after a temporary network blip — it self-heals within
seconds to a couple of minutes on its own. Watch for
`[googletv] ... connection lost, will retry reconnecting` in the logs if
you want to confirm this is happening.

## If pairing fails for someone

This driver logs its progress in detail — every step of the pairing
handshake, the raw bytes exchanged, and a driver version marker — so a
failure on a different TV brand/firmware can actually be diagnosed instead
of guessed at. If someone in the group hits a problem, ask them for:

1. **Which TV brand/model** they're using.
2. **A `[googletv-report]` diagnostic**: on the device page in the app, tap
   the refresh/sync icon. This runs a connectivity + TLS check *from the
   hub itself* (not just their PC) and logs a clean report — have logcat
   running first, then copy everything between `===== Google TV
   diagnostic report =====` and `===== end of report =====`. This alone
   usually tells you whether it's a network problem or a driver problem.
3. **A full log capture** from the moment they enter the IP address through
   at least 30 seconds after (long enough to see it either succeed or time
   out). To capture this, they (or you, if you're doing the packaging for
   them) need the SmartThings CLI running on a PC with the driver
   installed:
   ```
   smartthings edge:drivers:logcat
   ```
   then pick this driver from the list, and copy everything printed after
   they save the IP address in the device's Settings screen.
3. Whether a code ever appeared on the TV screen at all.

The log lines starting with `[googletv]` are the normal status messages;
`[googletv-diag]` lines are the step-by-step protocol trace. Both are safe
to share — they don't contain the private key or anything sensitive, just
protocol bytes and connection status.

## File layout

```
config.yml                  driver metadata
profiles/googletv.yml       capabilities + settings shown in the app
src/init.lua                driver entry point, lifecycle + capability wiring
src/commands.lua            capability command -> key press mapping
src/pairing.lua             pairing handshake + secret computation (port 6467)
src/remote.lua              persistent remote-control connection (port 6466)
src/pairingmessage.lua      pairing.proto message builders/parsers
src/remotemessage.lua       remote.proto message builders/parsers + keycodes
src/protobuf.lua            minimal hand-rolled protobuf wire format
src/der.lua                 minimal DER/X.509 parser (RSA key extraction)
src/base64.lua              base64 decoder
src/sha256.lua              pure-Lua SHA-256
src/wol.lua                 Wake-on-LAN magic packet
src/cert.lua                the shared bundled TLS client certificate
src/frame.lua                length-prefixed message framing
```
