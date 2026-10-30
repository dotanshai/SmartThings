# Offline Devices Monitor

Daily Telegram / Pushover alert listing your SmartThings devices that are **offline**.

👉 **Connect:** https://tinyurl.com/st-offline-monitor

## Features
- Daily message at the hour you choose (your location's time zone)
- Offline devices grouped by room
- Exclude list for devices that are offline on purpose
- Telegram (free) and/or Pushover (one-time ~$5), with Pushover sound selection
- Nothing is sent when everything is online
- English / Hebrew UI, mobile and desktop

## No tokens, no SharpTools
- No PAT or other token – sign in with your SmartThings account (OAuth); access refreshes automatically
- No SharpTools or other third-party service

## Privacy
- Read-only scopes: `r:devices:*`, `r:locations:*` – cannot control anything
- One-click unsubscribe deletes all stored data and revokes access

## Setup
1. Open the link and tap **Connect SmartThings**
2. Approve access
3. Connect Telegram (tap the link → Start) or enter your Pushover User Key
4. Tap **Save & send test**

## How it works
Single AWS Lambda (Node.js 22) with a Function URL, a DynamoDB table for per-user settings and tokens, and an hourly EventBridge rule that sends each user's check at their chosen hour.
Secrets (SmartThings OAuth client, Telegram bot token, Pushover app token) are Lambda environment variables and are not in this repo.

---
Free to use. If you find it useful: [☕ Buy me a coffee](https://buymeacoffee.com/dotan_shai)