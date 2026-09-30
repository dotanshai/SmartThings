"""
oauth_lambda/token_handler.py — the /token endpoint SmartThings' backend
calls (server-to-server, not the user's browser) to exchange the
authorization code minted in authorize_handler.py for access/refresh
tokens.

Register this Lambda's URL as the "Token URI" in your Schema App's OAuth
config in Developer Workspace.

Handles two grant types, per standard OAuth2 (SmartThings will call this
same endpoint for both):
  - grant_type=authorization_code -> first-time linking
  - grant_type=refresh_token      -> SmartThings periodically refreshing
    its access token

NOT YET DONE:
  - Client authentication: a real implementation MUST verify the
    incoming request's client_id/client_secret (sent as HTTP Basic auth
    or form fields, depending on how you registered the Schema App)
    against the values SmartThings issued you in Developer Workspace.
    This file does NOT do that yet — add it before going live, or anyone
    who finds this URL could mint themselves a token. Same pattern your
    other connectors' token endpoints should already follow — check
    theirs and port it here.
  - installedAppId resolution: if authorize_handler.py couldn't capture
    it (see its TODO), it needs to come from somewhere in this request
    instead — SmartThings typically includes it, but the exact field
    depends on your Schema App's OAuth config. Currently this file
    trusts whatever auth_code_store already had stored from step 1.
"""

import json
import os
import secrets
import sys
import time

sys.path.append(os.path.join(os.path.dirname(__file__), "..", "shared"))

import auth_code_store  # noqa: E402
import token_store  # noqa: E402

ACCESS_TOKEN_TTL_SECONDS = 3600  # 1 hour — SmartThings will refresh as needed


def lambda_handler(event, context):
    body = _parse_form_body(event)
    grant_type = body.get("grant_type", "")

    if grant_type == "authorization_code":
        return _handle_authorization_code(body)
    if grant_type == "refresh_token":
        return _handle_refresh_token(body)

    return _error_response(400, "unsupported_grant_type")


def _handle_authorization_code(body):
    code = body.get("code", "")
    if not code:
        return _error_response(400, "invalid_request")

    data = auth_code_store.consume_code(code)
    if not data:
        return _error_response(400, "invalid_grant")

    installed_app_id = data.get("installedAppId") or _fallback_installed_app_id(body)
    if not installed_app_id:
        # Can't proceed without something to key the link on — see TODO
        # in authorize_handler.py about confirming where this comes from.
        return _error_response(400, "invalid_request",
                                 description="missing installedAppId")

    access_token = secrets.token_urlsafe(32)
    refresh_token = secrets.token_urlsafe(32)

    token_store.save_link(
        installed_app_id,
        access_token=access_token,
        refresh_token=refresh_token,
        lg_pat=data["lgPat"],
        lg_client_id=data["lgClientId"],
        lg_country_code=data["lgCountryCode"],
    )

    return _token_response(access_token, refresh_token)


def _handle_refresh_token(body):
    refresh_token = body.get("refresh_token", "")
    if not refresh_token:
        return _error_response(400, "invalid_request")

    # TODO: token_store currently looks up by installedAppId, not by
    # refresh token value. For a real refresh flow you'd want a
    # secondary index on refreshToken (or scan — fine at small scale,
    # but a GSI is cleaner) to find which installedAppId this refresh
    # token belongs to. Left unimplemented since it needs a table
    # schema decision — flagging rather than guessing.
    return _error_response(501, "not_implemented",
                             description="refresh_token grant needs a "
                                          "refreshToken lookup index — see TODO")


def _fallback_installed_app_id(body) -> str:
    return body.get("installedAppId", "") or ""


def _token_response(access_token: str, refresh_token: str):
    payload = {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "token_type": "Bearer",
        "expires_in": ACCESS_TOKEN_TTL_SECONDS,
    }
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _error_response(status: int, error: str, description: str = ""):
    payload = {"error": error}
    if description:
        payload["error_description"] = description
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _parse_form_body(event) -> dict:
    from urllib.parse import parse_qs
    raw = event.get("body", "") or ""
    content_type = event.get("headers", {}).get("content-type", "")
    if "application/json" in content_type:
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {}
    parsed = parse_qs(raw)
    return {k: v[0] for k, v in parsed.items()}
