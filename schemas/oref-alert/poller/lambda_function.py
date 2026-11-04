import json, os, time, uuid, zlib, urllib.request
import boto3
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Attr
from oref_common import INST, log, build_states, push, il_time

TABLE = os.environ.get("TABLE", "OrefAlert")
tbl = boto3.resource("dynamodb").Table(TABLE)
OREF = "https://www.oref.org.il/WarningMessages/alert/alerts.json"
TZOFAR = "https://api.tzevaadom.co.il/notifications"
H = {"Referer": "https://www.oref.org.il/", "X-Requested-With": "XMLHttpRequest", "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36", "Accept": "application/json, text/plain, */*", "Accept-Language": "he-IL,he;q=0.9"}
POLL = float(os.environ.get("POLL_SEC", "2"))
TIMEOUT = {"alert": int(os.environ.get("ALERT_TIMEOUT", "1800")),
           "preAlert": int(os.environ.get("PRE_TIMEOUT", "1800")),
           "ended": int(os.environ.get("ENDED_TIMEOUT", "600"))}
RANK = {"ended": 1, "preAlert": 2, "alert": 3}
W_ENDED = ("הסתיים", "לצאת")
W_PRE = ("בדקות", "צפויות")

def http(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=H), timeout=4) as r:
        return r.read().decode("utf-8-sig", "replace").strip()

def classify(title):
    t = title or ""
    if any(w in t for w in W_ENDED): return "ended"
    if any(w in t for w in W_PRE): return "preAlert"
    return "alert"

def fetch():
    try:
        body = http(OREF)
        if not body: return "oref", []
        j = json.loads(body)
        return "oref", [(classify(j.get("title")), j.get("data") or [], j.get("title", ""),
                         str(j.get("cat", "")), str(j.get("id", "")))]
    except Exception as e:
        log(warn="oref", err=str(e))
    try:
        body = http(TZOFAR)
        out = []
        for n in (json.loads(body) if body else []):
            if n.get("isDrill"): continue
            out.append(("alert", n.get("cities") or [], "tzofar threat %s" % n.get("threat"),
                        str(n.get("threat")), str(n.get("notificationId"))))
        return "tzofar", out
    except Exception as e:
        log(warn="tzofar", err=str(e))
        return "none", None

def apply(mem, events, now, changes):
    best = {}
    for st, areas, title, cat, aid in events:
        for a in areas:
            if a not in best or RANK[st] > RANK[best[a][0]]:
                best[a] = (st, title, cat, aid)
    for a, (st, title, cat, aid) in best.items():
        cur = mem.get(a)
        if st == "alert" and cur and cur["state"] == "ended" and cur.get("alertAid") == aid:
            continue
        if cur and cur["state"] == st:
            cur["since"] = now
            continue
        mem[a] = {"state": st, "since": now, "title": title, "cat": cat, "aid": aid,
                  "alertAid": aid if st == "alert" else (cur or {}).get("alertAid")}
        changes.append(a)
        log(change=a, state=st, title=title, cat=cat)

def expire(mem, now, changes):
    for a, r in list(mem.items()):
        if now - r["since"] > TIMEOUT.get(r["state"], 0):
            del mem[a]
            changes.append(a)
            log(change=a, state="safe", reason="timeout")

# ---------- installs + push ----------
_ic = {"t": 0, "by": {}}
def installs_by_area(force=False):
    if force or time.time() - _ic["t"] > 60:
        items, kw = [], {"FilterExpression": Attr("pk").begins_with("inst#")}
        while True:
            r = INST.scan(**kw); items += r.get("Items", [])
            if "LastEvaluatedKey" not in r: break
            kw["ExclusiveStartKey"] = r["LastEvaluatedKey"]
        by = {}
        for it in items: by.setdefault(it.get("area"), []).append(it)
        _ic.update(t=time.time(), by=by)
    return _ic["by"]

def notify(area, rec, only=None):
    st = {"state": rec["state"], "title": rec.get("title", "")} if rec else {"state": "safe"}
    for inst in [x for x in installs_by_area().get(area, []) if not only or x["iid"] == only]:
        expr, vals = "SET areaState=:s", {":s": st}
        if st["state"] in ("alert", "preAlert"):
            inst["lastAlert"] = (il_time().strftime("%d/%m %H:%M") + " " + st.get("title", ""))[:200]
            expr += ", lastAlert=:l"; vals[":l"] = inst["lastAlert"]
        inst["areaState"] = st
        try: INST.update_item(Key={"pk": inst["pk"]}, UpdateExpression=expr, ExpressionAttributeValues=vals)
        except Exception as e: log(warn="inst update", err=str(e))
        log(push=inst["iid"], area=area, state=st["state"], ok=push(inst, build_states(inst, st)))

# ---------- lease + state handoff ----------
def load():
    it = tbl.get_item(Key={"pk": "__state__"}).get("Item")
    if not it: return {}
    try: return json.loads(zlib.decompress(bytes(it["blob"].value)).decode())
    except Exception as e:
        log(warn="load", err=str(e)); return {}

def save(mem):
    tbl.put_item(Item={"pk": "__state__", "ts": int(time.time()),
                       "blob": zlib.compress(json.dumps(mem, ensure_ascii=False).encode())})

def acquire(me, ctx):
    while ctx.get_remaining_time_in_millis() > 30000:
        now = int(time.time())
        until = now + ctx.get_remaining_time_in_millis() // 1000 + 5
        try:
            tbl.put_item(Item={"pk": "__lease__", "owner": me, "until": until},
                         ConditionExpression="attribute_not_exists(pk) OR #u < :n",
                         ExpressionAttributeNames={"#u": "until"}, ExpressionAttributeValues={":n": now})
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] != "ConditionalCheckFailedException": raise
            time.sleep(2)
    return False

def release(me):
    try:
        tbl.delete_item(Key={"pk": "__lease__"}, ConditionExpression="#o = :me",
                        ExpressionAttributeNames={"#o": "owner"}, ExpressionAttributeValues={":me": me})
    except ClientError: pass

def handler(event, context):
    event = event or {}
    if "test" in event:
        mem, out = {}, []
        for step in event["test"]:
            st = classify(step["title"])
            apply(mem, [(st, step["areas"], step["title"], "test", step["id"])], time.time(), [])
            out.append({"step": step["id"], "classified": st, "state": {a: r["state"] for a, r in mem.items()}})
        return out
    if "inject" in event:
        i = event["inject"]; installs_by_area(force=True)
        if not i.get("iid"): return {"error": "iid required - inject targets one device only"}
        rec = None if i.get("state") == "safe" else {"state": i["state"], "title": i.get("title", "TEST")}
        notify(i["area"], rec, i["iid"])
        return {"injected": i["state"], "devices": len(installs_by_area().get(i["area"], []))}
    me = str(uuid.uuid4())
    if not acquire(me, context):
        log(info="lease busy, exiting"); return {"skipped": True}
    mem = load()
    log(info="started", active=len(mem), installs=sum(len(v) for v in installs_by_area(force=True).values()))
    polls = errs = 0; src = {}
    try:
        while context.get_remaining_time_in_millis() > 6000:
            t0 = time.time(); changes = []
            s, ev = fetch(); polls += 1
            if ev is None: errs += 1
            else:
                src[s] = src.get(s, 0) + 1
                apply(mem, ev, t0, changes)
            expire(mem, time.time(), changes)
            for a in changes:
                try: notify(a, mem.get(a))
                except Exception as e: log(warn="notify", area=a, err=str(e))
            d = POLL - (time.time() - t0)
            if d > 0: time.sleep(d)
    finally:
        try: save(mem)
        except Exception as e: log(warn="save", err=str(e))
        release(me)
        log(summary={"polls": polls, "errors": errs, "sources": src, "active": len(mem)})
    return {"polls": polls}
