"""
token_store.py — DynamoDB helper for storing/retrieving each SmartThings
installed-app's linked LG ThinQ credentials (PAT + client ID).

Table design (single table, matches the pattern used in your other
connectors — e.g. DolphinBoilerTokens):

  Table name: LgThinqTokens   (create in BOTH us-east-1 and eu-west-1,
                                same as DolphinBoilerTokens / IEC / ARAD)
  Partition key: installedAppId (String)  — SmartThings' installed app ID,
                                             one row per user/location that
                                             links this connector.

  Attributes stored per item:
    installedAppId   (S) — partition key
    accessToken       (S) — SmartThings-issued OAuth access token for THIS
                             connector's own API calls back to SmartThings
                             (needed for async discovery/state callbacks)
    refreshToken      (S) — SmartThings refresh token (rotate per ST's OAuth)
    lgPat             (S) — the user's LG ThinQ Personal Access Token
    lgClientId        (S) — the uuid4 client ID paired with that PAT
    lgCountryCode     (S) — e.g. "IL"
    createdAt         (S) — ISO timestamp
    updatedAt         (S) — ISO timestamp

Notes:
- Unlike Dolphin/IEC/ARAD (which proxy a username+password login), LG's PAT
  has no refresh/expiry cycle to manage on our side — it's a long-lived
  token the user generates and revokes manually in the LG portal. So this
  store is simpler: no LG-side token refresh logic needed, just storage
  and retrieval alongside the SmartThings OAuth tokens.
- Uses the same shared IAM role (DolphinBoilerLambdaRole) — no separate
  role/permissions setup needed, just add this table's ARN if that role
  is scoped per-table rather than wildcarded.
"""

import os
import time
import boto3
from botocore.exceptions import ClientError

TABLE_NAME = os.environ.get("LG_THINQ_TOKENS_TABLE", "LgThinqTokens")
REGION = os.environ.get("AWS_REGION", "us-east-1")

_dynamodb = boto3.resource("dynamodb", region_name=REGION)
_table = _dynamodb.Table(TABLE_NAME)


def save_link(installed_app_id: str, *, access_token: str, refresh_token: str,
              lg_pat: str, lg_client_id: str, lg_country_code: str) -> None:
    """Create or overwrite the link record for a SmartThings installed app."""
    now = _now_iso()
    item = {
        "installedAppId": installed_app_id,
        "accessToken": access_token,
        "refreshToken": refresh_token,
        "lgPat": lg_pat,
        "lgClientId": lg_client_id,
        "lgCountryCode": lg_country_code,
        "updatedAt": now,
    }
    existing = get_link(installed_app_id)
    item["createdAt"] = existing["createdAt"] if existing else now
    _table.put_item(Item=item)


def get_link(installed_app_id: str) -> dict | None:
    """Fetch the stored link record, or None if this app isn't linked yet."""
    try:
        resp = _table.get_item(Key={"installedAppId": installed_app_id})
    except ClientError as e:
        raise RuntimeError(f"DynamoDB get_item failed: {e}") from e
    return resp.get("Item")


def update_smartthings_tokens(installed_app_id: str, *, access_token: str,
                               refresh_token: str) -> None:
    """Update just the rotated SmartThings OAuth tokens (leaves LG PAT as-is)."""
    _table.update_item(
        Key={"installedAppId": installed_app_id},
        UpdateExpression="SET accessToken = :at, refreshToken = :rt, updatedAt = :u",
        ExpressionAttributeValues={
            ":at": access_token,
            ":rt": refresh_token,
            ":u": _now_iso(),
        },
    )


def delete_link(installed_app_id: str) -> None:
    """Remove a link record (SmartThings sends this on integration removal)."""
    _table.delete_item(Key={"installedAppId": installed_app_id})


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
