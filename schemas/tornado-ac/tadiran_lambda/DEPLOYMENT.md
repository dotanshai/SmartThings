# Tadiran AC Schema Connector — Lambda deployment notes

## Install deps and package

```
cd lambda
npm install
Compress-Archive -Path * -DestinationPath ..\lambda.zip -Force
cd ..
```

## Still needed before this works end-to-end (infra, not code)

1. **DynamoDB table** — same pattern as your other projects:
   ```
   aws dynamodb create-table --table-name TadiranAcTokens --attribute-definitions AttributeName=accessToken,AttributeType=S --key-schema AttributeName=accessToken,KeyType=HASH --billing-mode PAY_PER_REQUEST --region us-east-1
   ```

2. **Lambda function** (both regions, matching your dual-region pattern):
   ```
   aws lambda create-function --function-name TadiranAcSchema --runtime nodejs20.x --role arn:aws:iam::<AWS_ACCOUNT_ID>:role/DolphinBoilerLambdaRole --handler index.handler --zip-file fileb://lambda.zip --timeout 30 --region us-east-1
   aws lambda create-function --function-name TadiranAcSchema --runtime nodejs20.x --role arn:aws:iam::<AWS_ACCOUNT_ID>:role/DolphinBoilerLambdaRole --handler index.handler --zip-file fileb://lambda.zip --timeout 30 --region eu-west-1
   ```

3. **Env vars** (both regions) — write to `env.json` first (per your PowerShell/BOM lesson), then:
   ```
   aws lambda update-function-configuration --function-name TadiranAcSchema --environment file://env.json --region us-east-1
   ```
   `env.json` needs: `TABLE_NAME`, `DYNAMO_REGION` (=eu-west-1, shared table pattern), `ST_CLIENT_ID`, `ST_CLIENT_SECRET`, `DEVICE_PROFILE_ID` (=44986c67-c177-4ff2-9975-69db7459c5ec)

4. **API Gateway** (HTTP API, for the /authorize + /token OAuth endpoints) — same pattern as LG Fridge project (single-wildcard source ARN for invoke permission).

5. **Schema App registration** in SmartThings Developer Workspace — needs:
   - The API Gateway's `/authorize` and `/token` URLs as the OAuth endpoints
   - Lambda ARN(s) for both regions
   - This generates `ST_CLIENT_ID`/`ST_CLIENT_SECRET` to put in step 3

6. **Lambda invoke permission** for SmartThings (both regions):
   ```
   aws lambda add-permission --function-name TadiranAcSchema --statement-id smartthings --principal 148790070172 --action lambda:InvokeFunction --region us-east-1
   aws lambda add-permission --function-name TadiranAcSchema --statement-id smartthings --principal 148790070172 --action lambda:InvokeFunction --region eu-west-1
   ```

## Design notes / things to watch for

- **The OAuth "code" is literally the Cognito AccessToken** — simplification that reuses Tadiran's own tokens as SmartThings' OAuth tokens directly. Simpler than issuing our own opaque tokens, but means DynamoDB records move to a new key every time a token refreshes (matches your LG pattern: "records keyed by whichever OAuth token is currently active").
- **Refresh flow gap to verify**: Cognito refresh tokens are typically reusable across multiple refresh calls, but this is NOT independently confirmed for this Tadiran user pool — if it turns out Cognito issues a NEW refresh token each time, the `/token` refresh_token handler needs updating to store/return that new one instead of echoing the old one back.
- **`organizationid` is hardcoded** — flagged as unconfirmed in the API doc; if this breaks for a different account, this is the first thing to check.
- **`callbackAccessHandler`/scheduled push** — wired up to save callback info like your LG project, but the actual EventBridge scheduled-push (every 5 min) rule still needs to be created separately (infra, not Lambda code) — not included in this pass.
- **UNTESTED END TO END** — this is a first-pass build following your confirmed LG architecture; expect iteration once you actually try the account-linking flow through the real SmartThings app, same as every prior project needed.
