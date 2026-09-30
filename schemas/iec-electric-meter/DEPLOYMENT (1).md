# IEC SmartThings Integration - Full Deployment (corrected)

Three Lambdas, three regions. Read this once before running anything - it captures real
mistakes made building this the first time, not theoretical advice.

## Folder layout - avoid this bug

Each of these three folders needs its OWN `index.js` - they are NOT interchangeable:

```
IEC-Lambda/
  iec-account-link/      (index.js, package.json)             -> us-east-1
  iec-schema-backend/    (index.js, package.json)              -> us-east-1 AND eu-west-1
  iec-il-caller/         (index.js, iecClient.js, package.json) -> il-central-1
  deploy.ps1
  capability-connection-capacity.json
  device-profile-iec-meter.json
```

**The recurring failure mode**: downloading/copying files from three different Lambda
projects into one flat folder silently overwrites `index.js`/`package.json` since the
filenames collide. If a deploy ever behaves strangely (wrong error, unexpected missing
module), the first thing to check is:

```powershell
Select-String -Path .\iec-il-caller\index.js -Pattern "require"
```

`iec-il-caller` should only ever show `require('./iecClient')` - if you see `st-schema` or
`@aws-sdk`, the wrong file landed there. Delete the folder and re-extract fresh rather than
trying to patch it in place.

## Why three regions

- `iecapi.iec.co.il` **blocks requests from AWS's us-east-1/eu-west-1** (confirmed: a
  generic WAF 403 page, not an IEC-specific error). It does not block Okta.
- SmartThings' own routing calls a region-specific Lambda ARN based on the user's account
  location - an Israel-based location routes through **eu-west-1**, not something you get to
  choose.
- The fix: `iec-schema-backend` stays in eu-west-1 (SmartThings requires this), but it makes
  a plain Lambda-to-Lambda `invoke` call (AWS SDK, IAM-authenticated, no public endpoint) to
  `iec-il-caller`, which runs in **il-central-1** (AWS's real Israel/Tel Aviv region) and does
  the actual IEC API calls from a genuinely Israeli AWS IP range.
- `il-central-1` needs to be opted in on new accounts: `aws ec2 describe-regions
  --region-names il-central-1` - if it errors, `aws account enable-region --region-name
  il-central-1` first.

## SmartThings CLI - exact command names (these are easy to get wrong)

The CLI has changed naming conventions across commands - don't guess, these are confirmed:

| What you want | Correct command |
|---|---|
| Create a custom capability | `capabilities:create` |
| Create a capability's presentation (required, separate step) | `capabilities:presentation:create <id> -i <file.json> --capability-version 1` |
| Create a Device Profile | `deviceprofiles:create` (no dash, plural - NOT `deviceprofile:create` or `device-profiles:create`) |
| View profile + presentation together | `deviceprofiles:view <id> -j` (add `-j` for real JSON instead of a formatted table that hides custom capabilities) |
| Update profile + presentation | `deviceprofiles:view:update <id> -i <file.json>` (needs a JSON file via `-i`, not interactive) |
| Register the Schema App | `schema:create` |
| Edit an existing Schema App | `schema:update <id>` (interactive) |
| List installed schema app instances | `installedschema` |
| Create an install invite | `invites:schema:create` |
| List/delete Lambda permission grants | plain `aws lambda add-permission` / `aws iam put-role-policy` (not a smartthings command) |

Also: `smartthings.exe` directly, not the `smartthings` npm wrapper - the wrapper crashes
with `ERR_INVALID_URL` in this environment.

## Deployment order

1. IAM role with DynamoDB access (reused from an existing Lambda role is fine)
2. `deploy.ps1` (fill in variables at top first) - creates the DynamoDB table, deploys all
   three Lambdas across three regions, grants the IAM invoke policy for `iec-il-caller`,
   grants SmartThings resource-based permission on `iec-schema-backend` in both its regions,
   stands up API Gateway for `iec-account-link`
3. `capabilities:create -i capability-connection-capacity.json` - **check the returned `id`**;
   it won't necessarily match your primary namespace (ours came back under a secondary one,
   `vehiclepatch55148`, not the expected `perfectworld33337`) - update
   `CONNECTION_CAPACITY_CAPABILITY` in `iec-schema-backend/index.js` if it differs, redeploy
3b. `capabilities:presentation:create <capability-id> -i capability-connection-capacity-presentation.json --capability-version 1`
    - **required for any custom capability to actually render in the app** - being listed in
    a Device Profile's `detailView` is not enough on its own; without this step the capability
    reports state correctly (visible via CloudWatch logs / API) but shows literally nothing in
    the SmartThings app, with no error anywhere. Version is a flag (`--capability-version`),
    not a positional argument, despite what `--help`'s own usage line for the command suggests.
4. `deviceprofiles:create -i device-profile-iec-meter.json` (`categories` must include
   `"categoryType": "manufacturer"` or this 400s) - feed the returned profile id into
   `$DeviceProfileId` in `deploy.ps1`, re-run
5. `schema:create` - OAuth URLs are your account-link API Gateway's `/authorize` and `/token`;
   Lambda ARN is `iec-schema-backend`'s **us-east-1** ARN for the "US region" field, and its
   **eu-west-1** ARN for "EU region" (do not leave EU blank if any user is Israel-based -
   this alone caused a full failure loop earlier)
6. `invites:schema:create` - generates a 30-day, shareable install link
7. Test via the invite URL in a **PC browser** (works fine, doesn't need the mobile app) -
   only click it once and wait ~15-20s even if it looks stuck; a premature retry can leave a
   duplicate, empty device behind that needs manual removal from the SmartThings app's device
   list afterward

## Known, confirmed-unfixable platform quirk

The detail-view energy history chart auto-scales to MWh for large cumulative values,
regardless of the `kWh` unit the schema backend declares in its state updates. This is a
long-standing SmartThings app limitation - see the SmartThings Community thread "Change Power
Usage Units From MWh to KWh" (2022, still unresolved as of a 2024 follow-up, no fix posted).
The dashboard tile (which we do control via the `dashboard.states` presentation config)
correctly shows kWh; only the deeper detail/history chart is affected. Worked around for the
main reading via a separate plain-Wh custom capability (`iecMeterReadingWh`), which has no
built-in scaling since custom capabilities don't get that special chart treatment at all.

## Billing information - removed, may return later

Real invoice-based billing cards (`iecLastBilledPeriod`/`iecPreviousBilledPeriod`) were built,
tested, and worked correctly - but became useless after switching electricity suppliers
(Pazgaz, then Partner). IEC only bills you directly if you're on their own default tariff;
once you switch to a private supplier, IEC's billing system stops generating real invoices for
your account even though the meter/consumption data keeps working fine (that's grid-side, not
supplier-side). Removed from the profile for now. If billing data becomes relevant again
(e.g. building a separate integration against Pazgaz/Partner's own billing, or reverting back
to IEC's own tariff), that would need a new Device Profile version (v3) and repeating the
capability-create + presentation + device-config regeneration dance documented above - the v2
profile is published and permanently locked once that step is taken.

## Debugging checklist

- CloudWatch Logs, in order of where things actually break: `/aws/lambda/iec-il-caller`
  (region **il-central-1**) for the real IEC/Okta call failures, `/aws/lambda/iec-schema-backend`
  (region **eu-west-1** for Israel-based accounts, not us-east-1) for discovery/state-refresh
  flow issues, `/aws/lambda/iec-account-link` (region **us-east-1**) for the OTP login flow.
- A 403 with a generic `<title>403 Forbidden</title>` HTML body (not IEC-specific JSON) from
  `iecapi.iec.co.il` means the call originated from a blocked (non-Israeli/datacenter) IP -
  confirms it never reached `iec-il-caller`, or `iec-il-caller`'s own outbound call somehow
  isn't really running from il-central-1.
- If the SmartThings app shows a generic auth/link error but the logs show a full successful
  discoveryResponse/stateRefreshResponse, it's very likely just a client-side timeout in the
  browser-based linking flow - check the device list in the app directly before assuming
  failure.
