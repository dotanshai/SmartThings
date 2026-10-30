import os, re, json, time, base64, secrets
import boto3
from botocore.config import Config

B = os.environ["BUCKET"]; T = os.environ["TABLE"]
s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "us-east-1"), config=Config(signature_version="s3v4"))
ddb = boto3.resource("dynamodb").Table(T)
MAX_FILES = 20; MAX_BYTES = 3 * 1024 * 1024
HTML = open(os.path.join(os.path.dirname(__file__), "index.html"), encoding="utf-8").read()

def out(code, body, ctype="application/json"):
    if not isinstance(body, str):
        body = json.dumps(body)
    return {"statusCode": code, "headers": {"Content-Type": ctype, "Cache-Control": "no-store"}, "body": body}

def user_of(evt):
    tok = (evt.get("headers") or {}).get("x-token", "")
    if not tok:
        return None
    it = ddb.get_item(Key={"pk": "SESS#" + tok}).get("Item")
    if not it or int(it.get("ttl", 0)) < time.time():
        return None
    return it["user"]

def files(u):
    r = s3.list_objects_v2(Bucket=B, Prefix="users/" + u + "/")
    res = []
    for o in r.get("Contents", []):
        n = o["Key"].rsplit("/", 1)[1][:-4]
        url = s3.generate_presigned_url("get_object", Params={"Bucket": B, "Key": o["Key"]}, ExpiresIn=3600)
        res.append({"name": n, "size": o["Size"], "url": url})
    return sorted(res, key=lambda x: x["name"])

def handler(evt, ctx):
    m = evt["requestContext"]["http"]["method"]; p = evt.get("rawPath", "/")
    if m == "GET" and p in ("/", "/index.html"):
        return out(200, HTML, "text/html; charset=utf-8")
    raw = evt.get("body") or ""
    if evt.get("isBase64Encoded") and raw:
        raw = base64.b64decode(raw).decode()
    try:
        body = json.loads(raw) if raw else {}
    except Exception:
        return out(400, {"error": "bad_json"})
    if m == "POST" and p == "/api/pair":
        code = re.sub(r"\D", "", str(body.get("code", "")))
        it = ddb.get_item(Key={"pk": "CODE#" + code}).get("Item") if len(code) == 6 else None
        if not it or int(it.get("ttl", 0)) < time.time():
            return out(403, {"error": "bad_code"})
        ddb.delete_item(Key={"pk": "CODE#" + code})
        prev = user_of(evt)
        if prev and prev != it["user"]:
            for o in s3.list_objects_v2(Bucket=B, Prefix="users/" + prev + "/").get("Contents", []):
                nk = "users/" + it["user"] + "/" + o["Key"].rsplit("/", 1)[1]
                s3.copy_object(Bucket=B, Key=nk, CopySource={"Bucket": B, "Key": o["Key"]}, ContentType="audio/mpeg", MetadataDirective="REPLACE")
                s3.delete_object(Bucket=B, Key=o["Key"])
            ddb.delete_item(Key={"pk": "SESS#" + (evt.get("headers") or {}).get("x-token", "")})
        tok = secrets.token_urlsafe(24)
        ddb.put_item(Item={"pk": "SESS#" + tok, "user": it["user"], "ttl": int(time.time()) + 365 * 86400})
        return out(200, {"token": tok})
    u = user_of(evt)
    if not u:
        return out(401, {"error": "not_paired"})
    if m == "GET" and p == "/api/list":
        return out(200, {"files": files(u), "max": MAX_FILES})
    if m == "POST" and p == "/api/upload":
        n = str(body.get("name", ""))
        if not re.fullmatch(r"[a-z0-9]{1,40}", n):
            return out(400, {"error": "bad_name"})
        try:
            data = base64.b64decode(body.get("data", ""))
        except Exception:
            return out(400, {"error": "bad_data"})
        if not data or len(data) > MAX_BYTES or not (data[:3] == b"ID3" or (data[0] == 0xFF and (data[1] & 0xE0) == 0xE0)):
            return out(400, {"error": "bad_audio"})
        cur = files(u)
        if n not in [f["name"] for f in cur] and len(cur) >= MAX_FILES:
            return out(400, {"error": "too_many"})
        s3.put_object(Bucket=B, Key="users/" + u + "/" + n + ".mp3", Body=data, ContentType="audio/mpeg")
        return out(200, {"ok": True})
    if m == "POST" and p == "/api/delete":
        n = str(body.get("name", ""))
        if not re.fullmatch(r"[a-z0-9]{1,40}", n):
            return out(400, {"error": "bad_name"})
        s3.delete_object(Bucket=B, Key="users/" + u + "/" + n + ".mp3")
        return out(200, {"ok": True})
    if m == "POST" and p == "/api/logout":
        ddb.delete_item(Key={"pk": "SESS#" + (evt.get("headers") or {}).get("x-token", "")})
        return out(200, {"ok": True})
    return out(404, {"error": "not_found"})
