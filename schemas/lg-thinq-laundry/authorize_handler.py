"""
oauth_lambda/authorize_handler.py — the /authorize endpoint SmartThings
sends the user's browser to when they tap "Connect" for this integration
in the SmartThings app.

Register this Lambda's URL (via API Gateway) as the "Authorization URI"
in your Schema App's OAuth config in Developer Workspace — same slot
where Dolphin/IEC/ARAD point to their own login pages.

FLOW:
  1. GET  request: SmartThings redirects the browser here with query
     params including client_id, redirect_uri, state, response_type.
     We render a simple HTML form asking for the LG PAT, client ID, and
     country code — carrying redirect_uri/state through as hidden fields.
  2. POST request: user submits the form. We validate the PAT actually
     works (a cheap async_get_device_list call), mint a one-time auth
     code via auth_code_store, and redirect the browser to
     redirect_uri?code=...&state=...  — exactly like a normal OAuth
     authorization response.

NOT YET DONE:
  - installedAppId isn't reliably available at this stage in every
    SmartThings OAuth flow shape — some send it in `state`, some don't
    until later. TODO: confirm exactly how your other connectors read
    it here (check their authorize handlers for the actual param name)
    and adjust `_extract_installed_app_id` below to match. Left as an
    explicit function so it's a one-line fix once confirmed.
  - No CSRF protection on the form itself (fine for a low-traffic
    community tool, but worth knowing).
  - HTML is unstyled — functional, not pretty. Fine to reskin later to
    match your other connectors' login pages if you want visual
    consistency.
"""

import os
import sys
from urllib.parse import urlencode

sys.path.append(os.path.join(os.path.dirname(__file__), "..", "shared"))

import auth_code_store  # noqa: E402
import lg_client  # noqa: E402
from lg_client import LgThinqError  # noqa: E402


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method") \
        or event.get("httpMethod", "GET")

    if method == "GET":
        return _render_form(event)
    if method == "POST":
        return _handle_submit(event)

    return _response(405, "Method Not Allowed")


def _render_form(event, error: str | None = None):
    params = event.get("queryStringParameters") or {}
    redirect_uri = params.get("redirect_uri", "")
    state = params.get("state", "")
    client_id = params.get("client_id", "")

    error_html = f'<p style="color:red">{error}</p>' if error else ""

    html = f"""<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Connect LG ThinQ</title></head>
<body style="font-family: sans-serif; max-width: 480px; margin: 40px auto;">
  <h2>Connect your LG ThinQ account</h2>
  <p>Get your Personal Access Token at
     <a href="https://connect-pat.lgthinq.com" target="_blank">connect-pat.lgthinq.com</a>
     (must be a native LG account, not Google/Facebook/Amazon login).</p>
  {error_html}
  <form method="POST">
    <input type="hidden" name="redirect_uri" value="{redirect_uri}">
    <input type="hidden" name="state" value="{state}">
    <input type="hidden" name="st_client_id" value="{client_id}">

    <label>LG Personal Access Token<br>
      <input type="text" name="lg_pat" required style="width:100%">
    </label><br><br>

    <label>Country code (e.g. IL)<br>
      <input type="text" name="lg_country" value="IL" required style="width:100%">
    </label><br><br>

    <button type="submit">Connect</button>
  </form>
</body>
</html>"""
    return _response(200, html, content_type="text/html")


def _handle_submit(event):
    body = _parse_form_body(event)
    lg_pat = body.get("lg_pat", "").strip()
    lg_country = body.get("lg_country", "IL").strip()
    redirect_uri = body.get("redirect_uri", "")
    state = body.get("state", "")

    if not lg_pat or not redirect_uri:
        return _render_form(event, error="Missing required fields.")

    # A fresh client ID per link attempt is fine — thinqconnect only
    # requires it be stable for a GIVEN pat/session going forward, and
    # storing it alongside the PAT keeps everything self-contained.
    import uuid
    lg_client_id = str(uuid.uuid4())

    try:
        lg_client.list_devices(lg_pat, lg_client_id, lg_country)
    except LgThinqError as e:
        return _render_form(event, error=f"Couldn't connect to LG: {e}")

    installed_app_id = _extract_installed_app_id(event, body)

    code = auth_code_store.create_code(
        lg_pat=lg_pat,
        lg_client_id=lg_client_id,
        lg_country_code=lg_country,
        installed_app_id=installed_app_id,
    )

    redirect_qs = urlencode({"code": code, "state": state})
    return {
        "statusCode": 302,
        "headers": {"Location": f"{redirect_uri}?{redirect_qs}"},
        "body": "",
    }


def _extract_installed_app_id(event, body) -> str:
    """
    TODO: confirm against your other connectors' authorize handlers
    exactly where SmartThings puts this at this stage of the flow (it
    may be embedded in `state`, or not available until the token
    exchange step — in which case this can return "" here and get
    filled in later in token_handler.py instead).
    """
    return body.get("installedAppId", "") or ""


def _parse_form_body(event) -> dict:
    from urllib.parse import parse_qs
    raw = event.get("body", "") or ""
    parsed = parse_qs(raw)
    return {k: v[0] for k, v in parsed.items()}


def _response(status: int, body: str, content_type: str = "text/plain"):
    return {
        "statusCode": status,
        "headers": {"Content-Type": content_type},
        "body": body,
    }
