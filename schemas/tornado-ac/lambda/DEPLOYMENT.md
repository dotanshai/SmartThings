# Tornado AC Schema Connector - deployment (PowerShell)

Run everything from `C:\Users\dotan\Desktop\smartthings_win\Tornado_AC\lambda`.

## 0. Install + local test (before touching AWS)
```powershell
npm install
node test_local.js you@example.com "YOUR_PASSWORD"
```
Should print `login OK` and the A/C params, same as the Python test.

## 1. Package
```powershell
Remove-Item ..\lambda.zip -ErrorAction SilentlyContinue
Compress-Archive -Path index.js, package.json, node_modules -DestinationPath ..\lambda.zip -Force
```

## 2. Secrets (generate once, keep them - same values in both regions)
```powershell
function New-Hex($n) { $b = New-Object byte[] $n; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ($b | ForEach-Object { $_.ToString('x2') }) -join '' }
$ENC_KEY = New-Hex 32
$OAUTH_ID = "tornado-" + (New-Hex 6)
$OAUTH_SECRET = New-Hex 24
"ENC_KEY=$ENC_KEY`nOAUTH_ID=$OAUTH_ID`nOAUTH_SECRET=$OAUTH_SECRET" | Out-File ..\secrets.txt
```

## 3. DynamoDB table
```powershell
aws dynamodb create-table --table-name TornadoAcTokens --attribute-definitions AttributeName=accessToken,AttributeType=S --key-schema AttributeName=accessToken,KeyType=HASH --billing-mode PAY_PER_REQUEST --region us-east-1 --no-cli-pager
```

## 4. Lambda (both regions)
```powershell
foreach ($r in "us-east-1","eu-west-1") {
  aws lambda create-function --function-name TornadoAcSchema --runtime nodejs20.x --role arn:aws:iam::<AWS_ACCOUNT_ID>:role/DolphinBoilerLambdaRole --handler index.handler --zip-file fileb://../lambda.zip --timeout 30 --region $r --no-cli-pager
  aws lambda add-permission --function-name TornadoAcSchema --statement-id smartthings --principal 148790070172 --action lambda:InvokeFunction --region $r --no-cli-pager
}
```

## 5. API Gateway (OAuth /authorize + /token)
```powershell
$api = aws apigatewayv2 create-api --name TornadoAcOAuth --protocol-type HTTP --target arn:aws:lambda:us-east-1:<AWS_ACCOUNT_ID>:function:TornadoAcSchema --region us-east-1 --no-cli-pager --output json | ConvertFrom-Json
aws lambda add-permission --function-name TornadoAcSchema --statement-id apigw --principal apigateway.amazonaws.com --action lambda:InvokeFunction --source-arn "arn:aws:execute-api:us-east-1:<AWS_ACCOUNT_ID>:$($api.ApiId)/*" --region us-east-1 --no-cli-pager
"Authorize URL: $($api.ApiEndpoint)/authorize"
"Token URL:     $($api.ApiEndpoint)/token"
```

## 6. Register the Schema App
```powershell
cd C:\Users\dotan\Desktop\smartthings_win
.\smartthings.exe schema:create
```
Enter:
- OAuth client ID / secret: `$OAUTH_ID` / `$OAUTH_SECRET` from `secrets.txt`
- Authorize / Token URLs: from step 5
- Lambda ARNs: `arn:aws:lambda:us-east-1:<AWS_ACCOUNT_ID>:function:TornadoAcSchema` and the eu-west-1 one
- Save the returned **stClientId / stClientSecret** (and endpointAppId)

## 7. Env vars (both regions) - written without BOM
```powershell
cd C:\Users\dotan\Desktop\smartthings_win\Tornado_AC
$cfg = @{ Variables = @{
  TABLE_NAME = "TornadoAcTokens"; DYNAMO_REGION = "us-east-1"
  ST_CLIENT_ID = "PASTE_stClientId"; ST_CLIENT_SECRET = "PASTE_stClientSecret"
  DEVICE_PROFILE_ID = "4400f391-09cb-4366-b290-69512ff4a2d7"
  OAUTH_CLIENT_ID = "PASTE_OAUTH_ID"; OAUTH_CLIENT_SECRET = "PASTE_OAUTH_SECRET"
  ENC_KEY = "PASTE_ENC_KEY" } } | ConvertTo-Json -Compress
[IO.File]::WriteAllText("$PWD\env.json", $cfg)
foreach ($r in "us-east-1","eu-west-1") { aws lambda update-function-configuration --function-name TornadoAcSchema --environment file://env.json --region $r --no-cli-pager }
```

## 8. Link
SmartThings app -> Add device -> Partner devices -> My Testing Devices -> Tornado -> log in with the Tornado email/password.

## Logs
```powershell
aws logs tail /aws/lambda/TornadoAcSchema --since 10m --region us-east-1 --no-cli-pager
```

## Design notes
- Own opaque tokens (not AUX's): access token = DynamoDB key and never moves; refresh token = `accessToken.secret`.
- Password stored AES-256-GCM encrypted (ENC_KEY) - needed because AUX sessions expire and must be re-logged in.
- `/token` validates OAuth client id/secret (fixes the open Tadiran TODO).
- Reuses Tadiran capabilities + profile v8. Fan turbo -> acTurbo toggle, silent -> acMute toggle, display -> acLight.
- Setpoint capped at 30 by acTemperature (Tornado supports 32).
- Eco / sleep / health / clean / child lock not exposed yet (no capability).
