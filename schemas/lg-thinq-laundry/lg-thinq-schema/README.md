# LG ThinQ Laundry — Schema Connector (v1, laundry-only, monitoring + control)

## Status: core logic fully verified live; SmartThings platform side done; account-link Lambda scaffolded but NOT production-safe yet

### Verified live against your real machine
- ✅ Device discovery, status polling (including finding/fixing a real
  stale-cloud-sync bug via re-pairing in the ThinQ app)
- ✅ Remote-start prerequisite identified and confirmed (hold "Add Item"
  3+ sec, door closed, machine on)
- ✅ Control payload shape confirmed (`location` + `operation` fields)
- ✅ Real `START` command sent and confirmed (runState: INITIAL -> DETECTING)

### Verified on the SmartThings platform
- ✅ `vehiclepatch55148.laundryState` capability created via CLI
- ✅ Its presentation (dashboard tile, detail view, automation condition)
  created via CLI — confirmed by SmartThings' API echo, after two rounds
  of fixing displayType schema mistakes against the real error messages

## What's built

- `shared/lg_client.py` — verified `list_devices`, `get_status`,
  `send_washer_command` (correct payload shape, confirmed live).
- `shared/token_store.py` — DynamoDB helper for the final linked
  credentials (SmartThings tokens + LG PAT/client ID), one row per
  installedAppId.
- `shared/auth_code_store.py` — DynamoDB helper for short-lived OAuth
  authorization codes, bridging the login form to the token exchange.
- `schema_lambda/handler.py` — discovery, state refresh, and command
  execution (switch -> START/STOP).
- `laundryState-capability.json` / `laundryState-presentation.json` —
  already applied to your SmartThings account, kept here for reference /
  re-deploying to another account.
- `oauth_lambda/authorize_handler.py` — serves the PAT/client-ID/country
  login form, validates the PAT actually works with a real LG API call,
  mints a one-time auth code, redirects back to SmartThings.
- `oauth_lambda/token_handler.py` — exchanges that auth code for
  SmartThings access/refresh tokens and calls `token_store.save_link()`.

## What's NOT built yet / not production-safe

1. **Client authentication on `/token`** — this is the important one.
   The token endpoint currently does NOT verify the incoming
   client_id/client_secret against what SmartThings issued you in
   Developer Workspace. Without this, anyone who discovers the URL could
   mint themselves a valid token. Needs adding before this goes live —
   check how your other connectors' token endpoints do this and port the
   same approach here.

2. **`installedAppId` resolution** — flagged with TODOs in both OAuth
   files. Exactly where SmartThings makes this available (in the
   `/authorize` query params, in `state`, or only later) depends on
   details of your Schema App's OAuth config that weren't available to
   check here — needs confirming against how your other connectors
   handle this same step, since they've already solved it.

3. **`refresh_token` grant** — stubbed with a clear `not_implemented`
   response. Needs a way to look up an installedAppId by refresh token
   value (a secondary index, or a small schema change to
   `LgThinqTokens`) — deliberately not guessed at, since it's a real
   schema decision rather than a small fix.

4. **Deployment specifics** — API Gateway routes for the two new
   Lambdas, `LgThinqAuthCodes` DynamoDB table (with TTL enabled on
   `expiresAt`) alongside `LgThinqTokens`, both in both regions, IAM
   permissions, registering both URLs (Authorization URI / Token URI) in
   Developer Workspace.

## A real-world caveat worth remembering

Remote start requires the physical button pressed immediately before
each use, cancels on power-off or door-open, and times out after ~10 min
idle (at which point `WAKE_UP`, not `START`, is the correct first
command). Anyone using the finished connector should expect "press a
button on the machine, then use the app," not pure remote convenience.
