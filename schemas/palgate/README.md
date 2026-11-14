# 🚪 PalGate for SmartThings

Open PalGate gates from SmartThings — from the app, by voice (Alexa / Google / Bixby) or from Routines.

> ⚠️ Unofficial community integration. Not affiliated with PAL Electronics Systems.
> It uses PalGate's unofficial API (via [pylgate](https://github.com/DonutByte/pylgate)), so it may stop working if PalGate changes something.

### Features
- Each gate appears as a **switch**: turn it on → the gate opens → the switch returns to Off by itself
- **Gate Last Result** tile: `✔ 13/11 19:05 Opened / נפתח` or `✖ 13/11 19:05 No response / לא הגיב`
- Gates with **Bluetooth-only** permission are skipped (they can't be opened over the internet)
- Gates with 2 outputs appear as two switches
- A failed open never leaves the gate stuck "offline" in the app

### Requirements
- Your PalGate user must have **remote (internet) open permission** from the gate admin
- A **second screen for one minute** while linking (computer, tablet or another phone) — the PalGate app scans the QR code with its camera only

### Install
1. Open the invite link (see the [main README](../../README.md#schema-connectors-cloud-aws-lambda)) on your phone and accept in SmartThings
2. The linking page shows a short link — tap **Share** and open it on the second device
3. On your phone: PalGate → ⋮ → **Linked Devices** → **Link a Device**, give it a name and scan the QR
4. Go back to SmartThings and tap the green **המשך / Continue** button
5. Your gates appear as switches

To disconnect: PalGate → ⋮ → Linked Devices → delete the "SmartThings" entry, and remove PalGate in SmartThings.

### Privacy
- Your PalGate login is never shared — linking creates a separate **linked device** on your own account
- Only the linked-device session token is stored (DynamoDB, encrypted at rest), used only to list gates and send open commands

### How it works
- One Python Lambda (`lambda/app.py`) behind an API Gateway HTTP API serves:
  - `/authorize` – phone linking page (short link + Continue button)
  - `/l/<code>` – second-device page with the QR code; it waits for PalGate's device-linking response
  - `/status`, `/poll` – linking progress
  - `/token` – OAuth token endpoint for SmartThings
  - `/schema` – ST Schema webhook (discovery, state refresh, commands)
  - `/icon.png` – app icon (put an `icon.png` next to `app.py`)
- PalGate API: `https://api1.pal-es.com/v1/bt/` — `devices/` to list gates, `device/<id>/open-gate?outputNum=N` to open; each call carries a time-based `X-Bt-Token` generated with pylgate
- An open counts as successful only when PalGate returns `confirmed: true`

### Deploy (AWS, us-east-1)
- DynamoDB table `PalGateSchema` (key `pk` string, TTL attribute `ttl`)
- Lambda `PalGateSchema`, Python 3.12, handler `app.handler`, timeout 30 s; package `app.py` + `qrcode` + `pylgate` (both pure Python, `pip install --no-deps -t`)
- Env vars: `TABLE`, `CLIENT_ID`, `CLIENT_SECRET`, `PROFILE_ID` (device profile id), `CAP_RESULT` (`vehiclepatch55148.gateLastResult`)
- HTTP API quick-create pointing at the Lambda
- SmartThings: create the capability + presentation + device profile from `smartthings/`, then `schema:create -i` with your own copy of `smartthings/schema-app.example.json`

Credits: [pylgate](https://github.com/DonutByte/pylgate) (GPLv3) for the token generation; [ha-palgate](https://github.com/doron1/ha-palgate) and [homebridge-palgate](https://www.npmjs.com/package/homebridge-palgate) for API reference.
