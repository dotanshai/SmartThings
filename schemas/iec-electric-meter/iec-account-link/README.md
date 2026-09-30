# IEC Account-Link Server

Plays the role of an OAuth2 authorization server towards **SmartThings**, while internally
driving IEC's real login (Okta: ID number -> SMS/email OTP -> PKCE authorize -> token exchange).
SmartThings never talks to Okta directly - it only ever talks to this Lambda.

Endpoints IEC's real Okta org (from `py-iec-api`'s `login.py` - a public PKCE client,
no secret needed):

- `https://iec-ext.okta.com/api/v1/authn`
- `https://iec-ext.okta.com/api/v1/authn/factors/{id}/verify`
- `https://iec-ext.okta.com/oauth2/default/v1/authorize`
- `https://iec-ext.okta.com/oauth2/default/v1/token`

## 1. DynamoDB table

Create one table:

- Table name: `IecSchemaConnectorTokens` (or set `TABLE_NAME` env var to anything else)
- Partition key: `pk` (String)
- TTL attribute: `ttl` (Number, epoch seconds) - enable TTL on this attribute so used
  authorization codes and access tokens clean themselves up automatically. The `REFRESH#`
  items have no `ttl` and live until the user unlinks their account.

Item shapes it writes:
| pk | contents |
|---|---|
| `AUTHCODE#<code>` | one-time, 5 min TTL, holds the freshly obtained IEC refresh_token |
| `TOKEN#<accessToken>` | 1 hr TTL, maps your access token to the IEC refresh_token |
| `REFRESH#<refreshToken>` | long-lived, maps your refresh token to the IEC refresh_token |

## 2. Lambda

- Runtime: Node.js 20.x (uses the global `fetch`, no extra HTTP lib needed)
- `npm install` in this folder, zip it up (or use `sam`/`serverless`/CDK - whatever you used for Dolphin)
- Env vars:
  - `TABLE_NAME` - if not using the default name above
  - `MY_CLIENT_ID` / `MY_CLIENT_SECRET` - the credentials *you* invent for SmartThings to
    authenticate itself against your `/token` endpoint. Put the same values into the
    Developer Workspace project config.
- IAM: needs `dynamodb:GetItem`, `PutItem`, `DeleteItem` on the table above.
- Expose via API Gateway HTTP API (Lambda proxy integration), routes `ANY /{proxy+}` is fine,
  or explicit routes for `GET /authorize`, `POST /iec/start`, `POST /iec/verify`, `POST /token`.

## 3. SmartThings Developer Workspace config

In your Schema Connector project's OAuth settings:

- Authorization URI: `https://<your-api-gateway-domain>/authorize`
- Token URI: `https://<your-api-gateway-domain>/token`
- Client ID / Client Secret: same values as `MY_CLIENT_ID` / `MY_CLIENT_SECRET` above
- Scope: anything, e.g. `read` - it's not meaningful to IEC, only to your own token endpoint

## What this piece does NOT do yet

It only gets you a valid, refreshable **IEC refresh_token**, stored against your own
opaque SmartThings-facing token. The next piece (discovery/state-refresh Lambda) needs to:

1. Look up `TOKEN#<accessToken>` to get the IEC refresh_token.
2. Call Okta's `/oauth2/default/v1/token` with `grant_type=refresh_token` to get a fresh
   IEC `id_token`/`access_token` (IEC's own tokens expire quickly - that's normal and expected).
3. Use that id_token as a Bearer token against IEC's actual data endpoints
   (`get_customer`, `get_contracts`, `get_last_meter_reading`, etc. - same ones the
   Postman collection and `py-iec-api`'s `data.py` use).

Happy to build that piece next.
