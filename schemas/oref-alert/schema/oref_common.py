import json, os, time, uuid, urllib.request, urllib.parse, urllib.error
from datetime import datetime, timezone, timedelta
import boto3

INST = boto3.resource("dynamodb", region_name=os.environ.get("INSTALLS_REGION", "il-central-1")).Table(os.environ.get("INSTALLS_TABLE", "OrefInstalls"))
ST_CLIENT_ID = os.environ.get("ST_CLIENT_ID", "")
ST_CLIENT_SECRET = os.environ.get("ST_CLIENT_SECRET", "")
NS = os.environ.get("CAP_NS", "vehiclepatch55148")
OREF_H = {"Referer": "https://www.oref.org.il/", "X-Requested-With": "XMLHttpRequest", "User-Agent": "Mozilla/5.0"}
EMO = {"alert": "\U0001F6A8", "preAlert": "⚠️", "ended": "\U0001F7E2", "safe": "✅"}
SAFE_TXT = "שגרה"
NONE_TXT = "אין"
SEC_TXT = "שניות"

def log(**kw): print(json.dumps(kw, ensure_ascii=False, default=str))

def req(url, data=None, headers=None, form=False, timeout=8):
    h = dict(headers or {})
    body = None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode(); h["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data, ensure_ascii=False, default=str).encode(); h["Content-Type"] = "application/json"
    r = urllib.request.Request(url, data=body, headers=h)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        t = resp.read().decode("utf-8-sig", "replace")
        return resp.status, (json.loads(t) if t.strip() else {})

def il_time(ts=None):
    try:
        from zoneinfo import ZoneInfo
        return datetime.fromtimestamp(ts or time.time(), ZoneInfo("Asia/Jerusalem"))
    except Exception:
        return datetime.fromtimestamp(ts or time.time(), timezone(timedelta(hours=2)))

def build_states(inst, area_state=None):
    s = (area_state or {}).get("state", "safe")
    title = (area_state or {}).get("title") or ""
    status = EMO.get(s, "") + " " + (title if s != "safe" and title else SAFE_TXT)
    sh = inst.get("shelter")
    def cap(c, a, v): return {"component": "main", "capability": NS + "." + c, "attribute": a, "value": v}
    return [
        cap("orefStatus", "alertStatus", status[:250]),
        cap("orefAlertState", "alertState", s),
        cap("orefArea", "areaName", inst.get("area", "")),
        cap("orefShelterTime", "shelterTime", ("%d %s" % (int(sh), SEC_TXT)) if sh is not None else "-"),
        cap("orefLastAlert", "lastAlert", inst.get("lastAlert") or NONE_TXT),
        {"component": "main", "capability": "st.contactSensor", "attribute": "contact", "value": "open" if s == "alert" else "closed"},
        {"component": "main", "capability": "st.healthCheck", "attribute": "healthStatus", "value": "online"},
    ]

def hdr(t): return {"schema": "st-schema", "version": "1.0", "interactionType": t, "requestId": str(uuid.uuid4())}

def cb_token_request(inst, grant):
    it = "accessTokenRequest" if grant["grantType"] == "authorization_code" else "refreshAccessTokens"
    body = {"headers": hdr(it), "callbackAuthentication": dict(grant, clientId=ST_CLIENT_ID, clientSecret=ST_CLIENT_SECRET)}
    _, r = req(inst["cbTokenUrl"], body)
    ca = r["callbackAuthentication"]
    inst["cbAccess"] = ca["accessToken"]
    inst["cbRefresh"] = ca.get("refreshToken") or inst.get("cbRefresh")
    inst["cbExpires"] = int(time.time()) + int(ca.get("expiresIn", 86400)) - 300
    INST.update_item(Key={"pk": inst["pk"]}, UpdateExpression="SET cbAccess=:a, cbRefresh=:r, cbExpires=:e",
                     ExpressionAttributeValues={":a": inst["cbAccess"], ":r": inst["cbRefresh"], ":e": inst["cbExpires"]})

def push(inst, states):
    if not inst.get("cbStateUrl"): return False
    for attempt in (1, 2):
        try:
            if attempt == 2 or int(inst.get("cbExpires", 0)) < time.time():
                cb_token_request(inst, {"grantType": "refresh_token", "refreshToken": inst["cbRefresh"]})
            body = {"headers": hdr("stateCallback"), "authentication": {"tokenType": "Bearer", "token": inst["cbAccess"]},
                    "deviceState": [{"externalDeviceId": inst["iid"], "states": states}]}
            req(inst["cbStateUrl"], body)
            return True
        except urllib.error.HTTPError as e:
            log(warn="push", iid=inst.get("iid"), code=e.code, body=e.read().decode("utf-8", "replace")[:300])
            if e.code != 401: return False
        except Exception as e:
            log(warn="push", iid=inst.get("iid"), err=str(e)); return False
    return False

_D = None
def districts():
    global _D
    if _D is None:
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "districts.json")
        if os.path.exists(p):
            with open(p, encoding="utf-8-sig") as fh: arr = json.load(fh)
        else:
            _, arr = req("https://alerts-history.oref.org.il/Shared/Ajax/GetDistricts.aspx?lang=he", headers=OREF_H)
        _D = {}
        for d in arr: _D.setdefault(d["label"], d.get("migun_time"))
    return _D
