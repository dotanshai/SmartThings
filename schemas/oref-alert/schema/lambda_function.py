import json, os, time, base64, secrets, html, urllib.parse, traceback
from oref_common import INST, log, req, build_states, push, cb_token_request, districts, SEC_TXT

BASE = os.environ.get("BASE_URL", "")
CID = os.environ.get("SCHEMA_CLIENT_ID", ""); CSEC = os.environ.get("SCHEMA_CLIENT_SECRET", "")
OIN_ID = os.environ.get("OAUTHIN_CLIENT_ID", ""); OIN_SEC = os.environ.get("OAUTHIN_CLIENT_SECRET", "")
PROFILE = os.environ.get("PROFILE_ID", "")
NOCACHE = {"Cache-Control": "no-store, no-cache, must-revalidate", "Pragma": "no-cache"}
T_TITLE = "בחירת אזור התרעה"
T_HOME = "מיקום הבית"
T_SEARCH = "חיפוש"
T_OK = "אישור"
T_DISC = "משלים ואינו מחליף את אפליקציית פיקוד העורף"
T_OREF = "פיקוד העורף"

PAGE = """<!doctype html><html dir="rtl" lang="he"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Oref Alert</title>
<style>body{font-family:sans-serif;margin:16px;background:#f4f4f4}.c{background:#fff;border-radius:12px;padding:16px}
h2{margin:0 0 12px;font-size:20px}input,select,button{width:100%;font-size:17px;padding:10px;margin:6px 0;box-sizing:border-box;border-radius:8px;border:1px solid #ccc}
button{background:#c62828;color:#fff;border:0}small{color:#666}</style></head><body><div class="c">
<h2>&#x1F6A8; @@TITLE@@ / Choose alert area</h2><p>@@HOME@@: <b>@@LOC@@</b>@@CITY@@</p>
<form method="post" action="/confirm"><input type="hidden" name="pid" value="@@PID@@">
<input id="q" placeholder="@@SEARCH@@ / Search" oninput="f()">
<select id="s" name="area" size="8" required>@@OPTS@@</select>
<button type="submit">@@OK@@ / Confirm</button></form>
<p><small>@@DISC@@<br>Supplements, not replaces, the official Home Front Command app.</small></p></div>
<script>var all=[].slice.call(document.querySelectorAll('#s option'));
function f(){var q=document.getElementById('q').value.trim();all.forEach(function(o){o.hidden=!!q&&o.value.indexOf(q)<0;});}
var sel=document.querySelector('#s option[selected]');if(sel)sel.scrollIntoView({block:'center'});</script></body></html>"""

def resp(code, body="", ctype="application/json", headers=None):
    h = {"Content-Type": ctype + "; charset=utf-8"}; h.update(NOCACHE); h.update(headers or {})
    if not isinstance(body, str): body = json.dumps(body, ensure_ascii=False, default=str)
    return {"statusCode": code, "headers": h, "body": body}

def redirect(url): return resp(302, "", "text/plain", {"Location": url})

def match(city, D):
    if not city: return None
    for cand in (city, city.split(" - ")[0].strip(), city.split("-")[0].strip()):
        if cand in D: return cand
        c = [l for l in D if l.startswith(cand)] or [l for l in D if cand in l]
        if c: return min(c, key=len)
    return None

def handler(event, context):
    path = event.get("rawPath", "/"); method = event["requestContext"]["http"]["method"]
    qs = event.get("queryStringParameters") or {}
    body = event.get("body") or ""
    if event.get("isBase64Encoded"): body = base64.b64decode(body).decode("utf-8")
    hdrs = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    try:
        if path == "/health": return resp(200, {"ok": True})
        if path == "/icon.png":
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon.png"), "rb") as fh:
                return {"statusCode": 200, "headers": {"Content-Type": "image/png", "Cache-Control": "public, max-age=86400"},
                        "body": base64.b64encode(fh.read()).decode(), "isBase64Encoded": True}
        if path == "/authorize" and method == "GET": return authorize(qs)
        if path == "/oauthin" and method == "GET": return oauthin(qs)
        if path == "/confirm" and method == "POST": return confirm(dict(urllib.parse.parse_qsl(body)))
        if path == "/token" and method == "POST": return token(dict(urllib.parse.parse_qsl(body)), hdrs)
        if path == "/" and method == "POST": return resp(200, webhook(json.loads(body)))
        return resp(404, {"error": "not found"})
    except Exception as e:
        log(error=str(e), path=path); traceback.print_exc()
        return resp(500, {"error": str(e)})

def authorize(qs):
    if qs.get("client_id") != CID: return resp(400, "bad client", "text/plain")
    pid = secrets.token_urlsafe(16)
    INST.put_item(Item={"pk": "pend#" + pid, "redirect": qs.get("redirect_uri", ""), "state": qs.get("state", ""), "ttl": int(time.time()) + 3600})
    return redirect("https://api.smartthings.com/oauth/authorize?" + urllib.parse.urlencode({
        "client_id": OIN_ID, "response_type": "code", "redirect_uri": BASE + "/oauthin", "scope": "r:locations:*", "state": pid}))

def oauthin(qs):
    pid = qs.get("state", ""); p = INST.get_item(Key={"pk": "pend#" + pid}).get("Item")
    if not p: return resp(400, "Session expired - please start again", "text/plain")
    basic = base64.b64encode((OIN_ID + ":" + OIN_SEC).encode()).decode()
    _, tok = req("https://api.smartthings.com/oauth/token", {"grant_type": "authorization_code", "code": qs.get("code", ""),
                 "client_id": OIN_ID, "redirect_uri": BASE + "/oauthin"}, headers={"Authorization": "Basic " + basic}, form=True)
    auth = {"Authorization": "Bearer " + tok["access_token"]}
    _, locs = req("https://api.smartthings.com/v1/locations", headers=auth)
    loc = (locs.get("items") or [{}])[0]
    _, ld = req("https://api.smartthings.com/v1/locations/" + loc["locationId"], headers=auth)
    lat, lon, city = ld.get("latitude"), ld.get("longitude"), ""
    if lat is not None and lon is not None:
        try:
            _, g = req("https://nominatim.openstreetmap.org/reverse?" + urllib.parse.urlencode(
                {"format": "json", "lat": lat, "lon": lon, "zoom": 12, "accept-language": "he"}),
                headers={"User-Agent": "OrefAlertSmartThings/1.0 (github.com/dotanshai/SmartThings)"})
            a = g.get("address", {})
            city = a.get("city") or a.get("town") or a.get("village") or a.get("municipality") or ""
        except Exception as e: log(warn="nominatim", err=str(e))
    D = districts(); guess = match(city, D)
    log(info="oauthin", loc=loc.get("name"), city=city, guess=guess)
    INST.update_item(Key={"pk": "pend#" + pid}, UpdateExpression="SET locId=:l, locName=:n",
                     ExpressionAttributeValues={":l": loc["locationId"], ":n": loc.get("name", "")})
    opts = "".join('<option value="%s"%s>%s (%s %s)</option>' % (html.escape(a), " selected" if a == guess else "", html.escape(a),
                   D[a] if D[a] is not None else "?", SEC_TXT) for a in sorted(D))
    pg = (PAGE.replace("@@TITLE@@", T_TITLE).replace("@@HOME@@", T_HOME).replace("@@LOC@@", html.escape(loc.get("name", "")))
          .replace("@@CITY@@", (" - " + html.escape(city)) if city else "").replace("@@PID@@", pid).replace("@@SEARCH@@", T_SEARCH)
          .replace("@@OK@@", T_OK).replace("@@DISC@@", T_DISC).replace("@@OPTS@@", opts))
    return resp(200, pg, "text/html")

def confirm(f):
    pid = f.get("pid", ""); p = INST.get_item(Key={"pk": "pend#" + pid}).get("Item")
    D = districts(); area = f.get("area", "")
    if not p or area not in D: return resp(400, "Invalid selection - please start again", "text/plain")
    code = secrets.token_urlsafe(24)
    INST.put_item(Item={"pk": "code#" + code, "iid": p["locId"], "area": area, "shelter": D[area],
                        "locName": p.get("locName", ""), "ttl": int(time.time()) + 600})
    sep = "&" if "?" in p["redirect"] else "?"
    return redirect(p["redirect"] + sep + urllib.parse.urlencode({"code": code, "state": p["state"]}))

def token(f, hdrs):
    cid, csec = f.get("client_id"), f.get("client_secret")
    if hdrs.get("authorization", "").lower().startswith("basic "):
        cid, csec = base64.b64decode(hdrs["authorization"][6:]).decode().split(":", 1)
    if cid != CID or csec != CSEC: return resp(401, {"error": "invalid_client"})
    g = f.get("grant_type")
    if g == "authorization_code":
        c = INST.get_item(Key={"pk": "code#" + f.get("code", "")}).get("Item")
        if not c: return resp(400, {"error": "invalid_grant"})
        INST.delete_item(Key={"pk": "code#" + f["code"]})
        iid = c["iid"]
        old = INST.get_item(Key={"pk": "inst#" + iid}).get("Item")
        if old:
            for k in ("tok#" + old.get("accessToken", ""), "ref#" + old.get("refreshToken", "")): INST.delete_item(Key={"pk": k})
        at, rt = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        INST.put_item(Item={"pk": "inst#" + iid, "iid": iid, "area": c["area"], "shelter": c.get("shelter"),
                            "locName": c.get("locName", ""), "accessToken": at, "refreshToken": rt, "created": int(time.time())})
        INST.put_item(Item={"pk": "tok#" + at, "iid": iid})
        INST.put_item(Item={"pk": "ref#" + rt, "iid": iid})
        log(info="install", iid=iid, area=c["area"])
    elif g == "refresh_token":
        r = INST.get_item(Key={"pk": "ref#" + f.get("refresh_token", "")}).get("Item")
        inst = INST.get_item(Key={"pk": "inst#" + r["iid"]}).get("Item") if r else None
        if not inst: return resp(400, {"error": "invalid_grant"})
        at, rt = inst["accessToken"], inst["refreshToken"]
    else:
        return resp(400, {"error": "unsupported_grant_type"})
    return resp(200, {"access_token": at, "refresh_token": rt, "token_type": "Bearer", "expires_in": 315360000})

def webhook(b):
    h = b.get("headers", {}); t = h.get("interactionType", ""); rid = h.get("requestId")
    rtype = t.replace("Request", "Response") if t.endswith("Request") else t + "Response"
    def out(**kw): return dict({"headers": {"schema": "st-schema", "version": "1.0", "interactionType": rtype, "requestId": rid}}, **kw)
    tk = (b.get("authentication") or {}).get("token", "")
    m = INST.get_item(Key={"pk": "tok#" + tk}).get("Item") if tk else None
    inst = INST.get_item(Key={"pk": "inst#" + m["iid"]}).get("Item") if m else None
    log(interaction=t, iid=inst["iid"] if inst else None)
    if t == "interactionResult": return out()
    if not inst: return out(globalError={"errorEnum": "TOKEN-EXPIRED", "detail": "unknown token"})
    if t == "discoveryRequest":
        return out(requestGrantCallbackAccess=True, devices=[{
            "externalDeviceId": inst["iid"], "deviceUniqueId": inst["iid"],
            "friendlyName": T_OREF + " - " + inst["area"],
            "manufacturerInfo": {"manufacturerName": "Pikud HaOref", "modelName": "Oref Alert"},
            "deviceHandlerType": PROFILE}])
    if t in ("stateRefreshRequest", "commandRequest"):
        return out(deviceState=[{"externalDeviceId": inst["iid"], "states": build_states(inst, inst.get("areaState"))}])
    if t == "grantCallbackAccess":
        ca, cu = b.get("callbackAuthentication", {}), b.get("callbackUrls", {})
        inst["cbTokenUrl"], inst["cbStateUrl"] = cu.get("oauthToken"), cu.get("stateCallback")
        INST.update_item(Key={"pk": inst["pk"]}, UpdateExpression="SET cbTokenUrl=:t, cbStateUrl=:s",
                         ExpressionAttributeValues={":t": inst["cbTokenUrl"], ":s": inst["cbStateUrl"]})
        cb_token_request(inst, {"grantType": "authorization_code", "code": ca.get("code")})
        log(info="callback granted", iid=inst["iid"], pushed=push(inst, build_states(inst, inst.get("areaState"))))
        return out()
    if t == "integrationDeleted":
        for k in ("inst#" + inst["iid"], "tok#" + inst["accessToken"], "ref#" + inst["refreshToken"]): INST.delete_item(Key={"pk": k})
        log(info="deleted", iid=inst["iid"])
        return out()
    return out()

_oauthin_st = oauthin
def oauthin(qs):
    try:
        return _oauthin_st(qs)
    except Exception as e:
        log(warn="oauthin fallback", err=str(e))
    pid = qs.get("state", ""); p = INST.get_item(Key={"pk": "pend#" + pid}).get("Item")
    if not p: return resp(400, "Session expired - please start again", "text/plain")
    iid = p.get("locId") or ("m-" + secrets.token_hex(12))
    INST.update_item(Key={"pk": "pend#" + pid}, UpdateExpression="SET locId=:l, locName=:n",
                     ExpressionAttributeValues={":l": iid, ":n": p.get("locName", "")})
    D = districts()
    hint = "\u05d4\u05e7\u05dc\u05d9\u05d3\u05d5 \u05d0\u05ea \u05e9\u05dd \u05d4\u05d9\u05d9\u05e9\u05d5\u05d1 \u05d1\u05d7\u05d9\u05e4\u05d5\u05e9 / Type your town in the search"
    opts = "".join('<option value="%s">%s (%s %s)</option>' % (html.escape(a), html.escape(a),
                   D[a] if D[a] is not None else "?", SEC_TXT) for a in sorted(D))
    pg = (PAGE.replace("@@TITLE@@", T_TITLE).replace("@@HOME@@", hint).replace("@@LOC@@", "").replace("@@CITY@@", "")
          .replace("@@PID@@", pid).replace("@@SEARCH@@", T_SEARCH).replace("@@OK@@", T_OK)
          .replace("@@DISC@@", T_DISC).replace("@@OPTS@@", opts))
    return resp(200, pg, "text/html")
