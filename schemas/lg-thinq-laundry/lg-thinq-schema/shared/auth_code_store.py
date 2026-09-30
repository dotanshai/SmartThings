"""
auth_code_store.py — short-lived storage for OAuth authorization codes.

WHY THIS EXISTS: the account-link flow has two separate HTTP calls that
need to share data:
  1. The user's browser submits the login form (PAT + client ID + country)
     to the /authorize endpoint. At this point we don't yet have
     SmartThings' final installedAppId-linked access/refresh tokens.
  2. Moments later, SmartThings' backend calls /token with the auth code
     we minted in step 1, to exchange it for real access/refresh tokens.

The auth code is the bridge between these two calls. It's stored here
with a short TTL (5 minutes is plenty) and deleted once exchanged, so it
can't be replayed.

Table: LgThinqAuthCodes (create in the SAME region(s) as LgThinqTokens)
  Partition key: code (String)
  Attributes: lgPat, lgClientId, lgCountryCode, installedAppId, createdAt
  TTL attribute: expiresAt (enable DynamoDB TTL on this table for this
  attribute so expired codes are auto-deleted — no manual cleanup Lambda
  needed)
"""

import os
import secrets
import time
import boto3
from botocore.exceptions import ClientError

TABLE_NAME = os.environ.get("LG_THINQ_AUTH_CODES_TABLE", "LgThinqAuthCodes")
REGION = os.environ.get("AWS_REGION", "us-east-1")
CODE_TTL_SECONDS = 300  # 5 minutes — plenty of time for the redirect round trip

_dynamodb = boto3.resource("dynamodb", region_name=REGION)
_table = _dynamodb.Table(TABLE_NAME)


def create_code(*, lg_pat: str, lg_client_id: str, lg_country_code: str,
                installed_app_id: str) -> str:
    """Mint a new one-time auth code and store its associated data."""
    code = secrets.token_urlsafe(32)
    now = int(time.time())
    _table.put_item(Item={
        "code": code,
        "lgPat": lg_pat,
        "lgClientId": lg_client_id,
        "lgCountryCode": lg_country_code,
        "installedAppId": installed_app_id,
        "createdAt": now,
        "expiresAt": now + CODE_TTL_SECONDS,  # DynamoDB TTL attribute
    })
    return code


def consume_code(code: str) -> dict | None:
    """
    Look up and DELETE an auth code atomically-ish (read then delete —
    good enough here since codes are single-use by convention and short
    lived; a true race is extremely unlikely for this use case).
    Returns None if the code doesn't exist or has expired.
    """
    try:
        resp = _table.get_item(Key={"code": code})
    except ClientError as e:
        raise RuntimeError(f"DynamoDB get_item failed: {e}") from e

    item = resp.get("Item")
    if not item:
        return None

    if item.get("expiresAt", 0) < int(time.time()):
        _table.delete_item(Key={"code": code})
        return None

    _table.delete_item(Key={"code": code})
    return item
