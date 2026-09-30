# IEC Schema Backend (Discovery + State Refresh)

Second half of the Schema Connector. Uses the official `st-schema` SDK, and reads real
IEC data via endpoints reverse-engineered straight from the `iec-api` PyPI package
(`iec_client.py` / `data.py` / `const.py`):

- `GET https://iecapi.iec.co.il/api/customer` - who you are, your `bpNumber`
- `GET https://iecapi.iec.co.il/api/customer/contract/{bpNumber}` - your contract(s)
- `GET https://iecapi.iec.co.il/api/Device/LastMeterReading/{contractId}/{bpNumber}` - the actual reading

Auth is a Bearer `id_token`, refreshed on every call via Okta's refresh_token grant against
the same IEC refresh_token stored by the account-link Lambda (`TOKEN#<accessToken>` in DynamoDB).
IEC's tokens are short-lived by design - refreshing every discovery/state-refresh call is normal
and cheap, no need to cache.

## 1. Create a custom Device Profile

None of SmartThings' pre-made Device Handler Types (`c2c-switch-power`, etc.) cleanly represent
a plain electric meter, so - same as you did for the Dolphin boiler - create your own Device
Profile with:

- `energyMeter` capability (the reading, in kWh)
- `healthCheck` capability (**mandatory** for custom profiles)
- `refresh` capability (**required** for any device with readable attributes)

```bash
smartthings.exe deviceprofile:create
```

Grab the resulting profile ID for the `DEVICE_PROFILE_ID` env var below.

## 2. Lambda

- Runtime: Node.js 20.x
- Deploy to at least one of: `us-east-1`, `eu-west-1`, `ap-northeast-1` (same regions you
  already used for Dolphin - reuse that Lambda/region setup)
- `npm install`, zip `index.js` + `iecClient.js` + `node_modules`
- Env vars:
  - `TABLE_NAME` - same DynamoDB table as the account-link Lambda
  - `DEVICE_PROFILE_ID` - from step 1
- IAM: `dynamodb:GetItem`, `DeleteItem` on that table
- Grant SmartThings permission to invoke it:

```bash
aws lambda add-permission --profile default --function-name <your-function-name> \
  --statement-id smartthings --principal 148790070172 --action lambda:InvokeFunction
```

## 3. Register the Schema App

```bash
smartthings schema:create
```

You'll be asked for the OAuth details (point at the account-link Lambda's `/authorize` and
`/token` endpoints from the previous piece) and the Lambda ARN(s) for the region(s) above.
Save the `Endpoint App Id`, `St Client Id`, `St Client Secret` it gives you - shown once.

## What happens end to end

1. User installs your Schema App in the SmartThings app -> gets sent to `/authorize`
   (previous piece) -> logs in with ID + OTP -> SmartThings gets a code -> exchanges it
   at `/token` for an access token.
2. SmartThings calls `discoveryRequest` with that access token -> this Lambda looks up the
   IEC refresh_token, pulls contracts, returns one device per contract.
3. SmartThings immediately follows with `stateRefreshRequest`, then automatically again
   roughly every 24 hours (per SmartThings' own polling interval) - which is already more
   often than IEC's backend actually updates (~hourly, sometimes with up to 2 days of lag,
   per the HA component's own README).

## Known rough edges to expect on first real test

- **Okta factor selection**: if an IEC account has multiple MFA factors configured
  (e.g. both email and SMS), `iecClient`'s factor selection lives in the *account-link*
  Lambda, not here - double check that still prefers SMS the way you want.
- **Multiple contracts**: if your IEC account has more than one contract (e.g. a
  vacation home), this creates one device per contract automatically - no config needed,
  but worth confirming the labels make sense once you see real data.
- **No reading yet**: reports `healthStatus: offline` rather than a fake value if IEC
  hasn't returned a reading - better than showing a stale/wrong number.
