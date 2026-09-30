# Tadiran IoT (My Tadiran) — Reverse-Engineered Cloud API

**Purpose:** Technical reference for building a Home Assistant custom integration for Tadiran WiFi-connected air conditioners, controlled via the "My Tadiran" mobile app.

**Status:** Reverse-engineered via HTTPS traffic capture against a real device (GREE-manufactured Tadiran split A/C unit, model `alpha-pro-or-inv`). Confirmed working for authentication, device discovery, and control (power, temperature, mode, fan speed, swing, light).

**Disclaimer:** This is an unofficial, reverse-engineered API. Tadiran/GREE may change it without notice. Not affiliated with or endorsed by Tadiran.

---

## 1. Architecture Overview

- **Backend:** AWS (Cognito for auth, API Gateway + Lambda behind CloudFront, likely AWS IoT Device Shadow under the hood based on GraphQL/AppSync references found in the app bundle — though all control observed in practice went through a plain REST endpoint, documented below)
- **App:** React Native (Android), package `com.tadiran.mytadiran.prod`
- **Auth:** AWS Cognito, phone number + SMS OTP (no password)
- **API host:** `https://api.tadiran-iot.co.il`

---

## 2. Authentication Flow

Cognito User Pool details:
- **Region:** `eu-west-1`
- **User Pool ID:** `eu-west-1_WG1VW4YTe`
- **App Client ID:** `312eed498hlvku8pdup0lvfpir`

### Step 1 — Initiate custom auth challenge

```
POST https://cognito-idp.eu-west-1.amazonaws.com/
Content-Type: application/x-amz-json-1.1
X-Amz-Target: AWSCognitoIdentityProviderService.InitiateAuth

{
  "ClientId": "312eed498hlvku8pdup0lvfpir",
  "AuthFlow": "CUSTOM_AUTH",
  "AuthParameters": {
    "USERNAME": "+972501234567"
  }
}
```

Phone number must be in E.164 format (`+` + country code + number, no spaces/dashes).

**Response** contains a `Session` token and (implicitly) triggers Tadiran's backend to send an SMS OTP to that number.

### Step 2 — Respond to challenge with OTP

```
POST https://cognito-idp.eu-west-1.amazonaws.com/
Content-Type: application/x-amz-json-1.1
X-Amz-Target: AWSCognitoIdentityProviderService.RespondToAuthChallenge

{
  "ClientId": "312eed498hlvku8pdup0lvfpir",
  "ChallengeName": "CUSTOM_CHALLENGE",
  "ChallengeResponses": {
    "USERNAME": "+972501234567",
    "ANSWER": "123456"
  },
  "Session": "<Session value from step 1 response>"
}
```

**Response:**
```json
{
  "AuthenticationResult": {
    "AccessToken": "<JWT>",
    "IdToken": "<JWT>",
    "RefreshToken": "<opaque token>",
    "ExpiresIn": 5400,
    "TokenType": "Bearer"
  },
  "ChallengeParameters": {}
}
```

`ExpiresIn` is in seconds (5400 = 90 minutes). Both `AccessToken` and `IdToken` are needed for API calls (see §4) — unusual but confirmed required.

### Step 3 — Refreshing tokens

Standard Cognito refresh flow, callable any time before expiry:

```
POST https://cognito-idp.eu-west-1.amazonaws.com/
X-Amz-Target: AWSCognitoIdentityProviderService.InitiateAuth

{
  "ClientId": "312eed498hlvku8pdup0lvfpir",
  "AuthFlow": "REFRESH_TOKEN_AUTH",
  "AuthParameters": {
    "REFRESH_TOKEN": "<stored RefreshToken>"
  }
}
```

Returns a fresh `AccessToken`/`IdToken` pair (refresh token itself is typically long-lived / reusable — standard Cognito behavior, not separately confirmed here).

---

## 3. Tenant / Organization ID

Every API call to `api.tadiran-iot.co.il` requires an `organizationid` header:

```
organizationid: tenant-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

(Real value redacted in this doc — reach out for the actual working tenant ID.) **Not yet confirmed** whether this is a single global value for all Tadiran customers, or varies by installer/region/account. Observed identical across two different user accounts (both Israeli numbers) during testing — likely a fixed value for the Israeli consumer tenant, but worth having a real HA user in another region confirm if the integration is ever used outside Israel.

---

## 4. Required Headers (all API calls below)

```
authorization: Bearer <AccessToken>
idtoken: <IdToken>
organizationid: tenant-f365f952-9143-4004-95b6-5042aed5b7cd
accept: application/json, text/plain, */*
Content-Type: application/json   (for PUT/POST requests)
```

---

## 5. Device Discovery

```
GET https://api.tadiran-iot.co.il/mobile-app/api/v1/devices/
```

Returns an array of all devices on the account, **including full current state** — no separate status/shadow-read call needed for polling.

**Example response (one device):**
```json
[
  {
    "device_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "serial_number": "xxxxxxx",
    "name": "סלון",
    "model_id": "alpha-pro-or-inv",
    "manufacturer_name": "GREE",
    "description": "Alpha pro / INV",
    "room_type": "LIVING_ROOM",
    "configurations": {
      "power": true,
      "temp_set": 20,
      "light": true,
      "temp_current": 29,
      "wind_speed": "MEDIUM_HIGH",
      "online": true,
      "swing_ud": true,
      "swing_lr": false,
      "turbo": false,
      "mute": false,
      "mode": "COOL"
    },
    "is_smart_ir": false,
    "longitude": "xx.xxxxxxx",
    "latitude": "xx.xxxxxxx",
    "manufacturer_device_model": "GR-AC_10001_09_da6b_SC",
    "is_owner": true,
    "device_type": 1,
    "connected_at": "2026-08-28T11:14:03.482822Z",
    "segment_type": "AC",
    "connected": null,
    "sub_units": {}
  }
]
```

(GPS coordinates, serial number, and device/tenant IDs above are redacted — they belong to the real household this was tested against.)

For polling/status refresh in HA, simply re-call this endpoint — no per-device GET was observed as necessary.

---

## 6. Device Capability Schema

A separate endpoint returns the full field schema (types, ranges, UI hints) per device — useful for building a generic integration that adapts to different Tadiran/GREE models rather than hardcoding fields:

```
PUT https://api.tadiran-iot.co.il/mobile-app/api/v1/devices/{device_id}/shadow/update/?device_id={device_id}
```

(`{device_id}` is the per-device UUID from the discovery response in §5.) (Note: this same endpoint URL is used for both a no-op "sync" call — small ~31-byte body, fired just from opening the device screen — and real commands. See §7 for the actual command body format. The schema below was observed in the *response* of a no-op sync call.)

**Example schema response (fields relevant to this device):**

| `name` | `display_name` | UI type | Range / values |
|---|---|---|---|
| `power` | Power | Toggle button | boolean |
| `temp_set` | Temperature | Number input | 16–30 |
| `temp_current` | Current temperature | Number input (read-only in practice) | raw value; observed `27` = 27°C (NOT divided by 10 — confirm against `configurations.temp_current` in §5, which shows plain integer Celsius) |
| `mode` | Mode | String input | only `"COOL"` observed; likely also `HEAT`/`FAN`/`DRY`/`AUTO` — **unconfirmed, needs real-device testing** |
| `wind_speed` | Wind speed | String input | `"LOW"`, `"MEDIUM"`, `"MEDIUM_HIGH"` observed; likely also `"HIGH"`, possibly `"AUTO"` — **unconfirmed** |
| `swing_ud` | Swing UD | Toggle button | boolean (vertical swing) |
| `swing_lr` | Swing LR | Toggle button | boolean (horizontal swing) |
| `light` | Light | Toggle button | boolean (display light) |
| `turbo` | Turbo | Toggle button | boolean |
| `mute` | Mute | Toggle button | boolean (quiet mode) |
| `online` | Online | Toggle button (read-only) | boolean, connectivity status |

Each field's response object also includes `desired` vs `reported` values (device-shadow pattern — `desired` is what was last requested, `reported` is what the physical unit last confirmed). For a simpler integration, `reported` values from the device-list endpoint (§5, inside `configurations`) are sufficient for state; the desired/reported distinction mainly matters if you want to show "pending" state while a command is in flight.

---

## 7. Sending Commands

```
PUT https://api.tadiran-iot.co.il/mobile-app/api/v1/devices/{device_id}/shadow/update/?device_id={device_id}
Content-Type: application/json

[
  {
    "name": "power",
    "value": true
  }
]
```

**Body is a flat JSON array** of `{name, value}` objects — one object per field being changed. Only confirmed with a single-field change (`power`); **not yet confirmed whether multiple fields can be sent in one array** (e.g. setting `power` + `temp_set` together) — worth testing, but sending them as separate sequential calls is a safe fallback.

**Confirmed field → value types for commands:**
- `power`: `true` / `false`
- `temp_set`: integer, 16–30
- `mode`: string, `"COOL"` confirmed (others unconfirmed)
- `wind_speed`: string, `"LOW"` / `"MEDIUM"` / `"MEDIUM_HIGH"` confirmed (others unconfirmed)
- `swing_ud`, `swing_lr`, `light`, `turbo`, `mute`: `true` / `false`

**Response:** Full updated shadow object (same shape as §6's schema response), reflecting the new `desired` value.

---

## 8. Known Gaps / Not Yet Verified

- [ ] Full `mode` enum (only `COOL` confirmed live)
- [ ] Full `wind_speed` enum (only `LOW`/`MEDIUM`/`MEDIUM_HIGH` confirmed live)
- [ ] Whether multiple fields can be set in a single PUT call
- [ ] Whether `organizationid` is universal or account/region-specific
- [ ] Behavior for non-AC device types (this account only had an AC; `segment_type: "AC"` and `device_type: 1` suggest other segment/type values may exist for other Tadiran product lines)
- [ ] Rate limits / throttling behavior on the API
- [ ] Real-time push updates: the app bundle contains AWS AppSync GraphQL references (subscription `UpdatedShadow(asset_id, shadow_name)`), suggesting a websocket-based push mechanism for live state updates exists as an alternative to polling the REST endpoint — not captured/confirmed in this investigation. Worth exploring for a more responsive HA integration than polling alone.

---

## 9. Practical Notes for Implementation

- Tokens expire after 90 minutes (`ExpiresIn: 5400`) — implement refresh well before that, e.g. at 75–80 minutes.
- The **initial login (OTP)** requires user interaction (reading an SMS) and can't be automated — this is a one-time setup step per HA installation, after which the refresh token should keep the integration working indefinitely (standard Cognito refresh tokens are typically valid for a long duration, often 30+ days, sometimes non-expiring depending on pool config — not independently confirmed here).
- This API was reached via a real Android app (patched to allow HTTPS traffic inspection) — no rate-limiting or anti-automation behavior was observed during a single interactive testing session, but sustained/high-frequency polling from an HA integration hasn't been tested and should be done cautiously (e.g. start with a 30–60s poll interval).

---

*Compiled by Shai (SmartThings developer, Rehovot) via traffic capture against a real Tadiran A/C unit (family member's household, details redacted above), September 2026. Reachable via the Israeli SmartThings Facebook community, or through his shared-drivers SmartThings channel. Happy to share additional raw capture data or answer questions.*
