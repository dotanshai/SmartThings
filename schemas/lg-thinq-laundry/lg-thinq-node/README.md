# LG ThinQ Laundry — Schema Connector (Node.js, single Lambda)

## Why this replaces the earlier Python scaffold

The first pass at this (in `/lg-thinq-schema/`) was built from public
SmartThings docs, hand-rolling the ST Schema protocol in Python across
three separate Lambdas. After seeing your actual **DolphinBoilerSchema**
source, it's clear your real infrastructure looks quite different — and
better:

- **One Lambda**, not three — routes both the OAuth HTTP endpoints
  (`/authorize`, `/token`) and the SmartThings Schema callback (via the
  `st-schema` npm SDK) based on whether `event.requestContext` is present.
- **No `installedAppId` tracking** — records are keyed by whatever OAuth
  token is currently active (session id → auth code → access/refresh
  token), each step just carrying the same data blob forward under a new
  key. SmartThings hands you the `accessToken` directly on every
  discovery/state/command callback, so lookups are a single `getData()`
  call — no separate ID-resolution problem to solve.
- **No client_id/secret verification on `/token`** — your working
  Dolphin/IEC/ARAD connectors don't do this either, so this file matches
  that same (existing, working) pattern rather than adding a check none
  of your other connectors have.

This file (`index.js`) is a straight structural port of your Dolphin
Lambda, swapping Dolphin's username/password + REST calls for LG's
PAT + ThinQ Connect REST calls.

## What's genuinely verified vs. what's new

**Verified against your real washer** (from earlier testing this session):
- Device discovery, status fields, control payload shape
  (`location` + `operation`), the remote-start prerequisite

**New in this port, not yet tested live:**
- The **Node.js HTTP calls to LG's API** (`lgFetch` / `LG.listDevices` /
  `LG.getStatus` / `LG.control`) — these replicate the exact base URL,
  headers, and endpoint paths pulled directly from `thinqconnect`'s
  Python source (`thinq_api.py`), not guessed. Verified so far:
  - Module loads cleanly, no syntax/dependency errors (checked with
    `node --check` and a real `require()` in this sandbox)
  - The hostname derivation (`api-eic.lgthinq.com` for `IL`) and the
    control payload shape match what you confirmed working earlier
  - **NOT yet tested**: an actual live HTTPS call from this code against
    LG's servers — that needs running on your side, since my sandbox
    can't reach `lgthinq.com`.
- The `/authorize` PAT-collection form and the LG device-list check
  during account linking — logically follows Dolphin's pattern exactly,
  but hasn't been run end-to-end.

## Region coverage

`REGION_BY_COUNTRY` only maps a handful of countries (IL + a few EU +
US/CA) to `eic`/`aic`. `thinqconnect`'s `country.py` has the full table
if you ever need broader coverage — worth porting the complete list
before opening this up beyond your own testing.

## Deploy steps (matching your existing pattern)

1. `npm install` in this folder (installs `st-schema`,
   `@aws-sdk/client-dynamodb`, `@aws-sdk/util-dynamodb`, `uuid` — exact
   versions in `package.json`)
2. Create DynamoDB table `LgThinqTokens` (partition key `pk`, String) in
   both `us-east-1` and `eu-west-1`, same as `DolphinBoilerTokens`
3. Zip and deploy to a new Lambda function in both regions, reusing
   `DolphinBoilerLambdaRole` (add `LgThinqTokens` table ARN if the role
   is scoped per-table rather than wildcarded)
4. Set env vars: `ST_CLIENT_ID`, `ST_CLIENT_SECRET`, `TABLE_NAME`,
   `DYNAMO_REGION`
5. Register the Lambda ARN + `/authorize` and `/token` URLs in Developer
   Workspace, same as your other three connectors

## First test once deployed

Point a browser at your Lambda's `/authorize` URL directly (with dummy
`redirect_uri`/`state` query params) to confirm the PAT form renders and
that submitting a real PAT successfully finds your washer — that
isolates the new LG HTTP calls before wiring up the full SmartThings
OAuth round-trip.
