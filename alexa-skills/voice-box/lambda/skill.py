import os, re, time, hashlib, secrets
import boto3
from botocore.config import Config
from xml.sax.saxutils import escape

B = os.environ["BUCKET"]; T = os.environ["TABLE"]; PAGE = os.environ.get("PAGE_URL", "")
s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "us-east-1"), endpoint_url="https://s3." + os.environ.get("AWS_REGION", "us-east-1") + ".amazonaws.com", config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}))
ddb = boto3.resource("dynamodb").Table(T)
CHIME = '<audio src="soundbank://soundlibrary/musical/amzn_sfx_trumpet_bugle_04"/>'
DEMO = ("dinner", "laundry", "test")

def uid(evt):
    return hashlib.sha256(evt["context"]["System"]["user"]["userId"].encode()).hexdigest()[:32]

def slug(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())

def resp(ssml, card=None):
    r = {"outputSpeech": {"type": "SSML", "ssml": "<speak>" + ssml + "</speak>"}, "shouldEndSession": True}
    if card:
        r["card"] = {"type": "Simple", "title": "Voice Box", "content": card}
    return {"version": "1.0", "response": r}

def code_resp(u, intro=""):
    code = str(secrets.randbelow(900000) + 100000)
    ddb.put_item(Item={"pk": "CODE#" + code, "user": u, "ttl": int(time.time()) + 600})
    d = '<say-as interpret-as="digits">' + code + "</say-as>"
    return resp(intro + "Your upload code is " + d + ". Again: " + d + ". It is valid for 10 minutes. "
                "The code and the upload page address are also in your Alexa app.",
                card="Your Voice Box code: " + code + "\nValid for 10 minutes.\n\nUpload page:\n" + PAGE)

def handler(evt, ctx):
    req = evt["request"]; t = req["type"]
    if t == "SessionEndedRequest":
        return {"version": "1.0", "response": {}}
    if t == "LaunchRequest":
        u0 = uid(evt)
        if not s3.list_objects_v2(Bucket=B, Prefix="users/" + u0 + "/", MaxKeys=1).get("KeyCount"):
            return code_resp(u0, CHIME + " Welcome to Voice Box! To upload your messages, open the upload page from your Alexa app. ")
        return resp(CHIME + " Voice Box is ready. Say: ask voice box to play, and a message name. For a new upload code, say: ask voice box for my code.")
    if t != "IntentRequest":
        return resp("Goodbye.")
    u = uid(evt); name = req["intent"]["name"]
    if name == "CodeIntent":
        return code_resp(u)
    if name == "PlayIntent":
        slots = req["intent"].get("slots") or {}
        v = (slots.get("message") or {}).get("value") or ""
        k = slug(v)
        if k:
            key = "users/" + u + "/" + k + ".mp3"
            try:
                s3.head_object(Bucket=B, Key=key)
                url = s3.generate_presigned_url("get_object", Params={"Bucket": B, "Key": key}, ExpiresIn=3600)
                return resp('<audio src="' + escape(url) + '"/>')
            except Exception:
                pass
            if k in DEMO:
                return resp(CHIME + " This is a Voice Box demo message. Say: ask voice box for my code, to upload your own messages.")
        return resp("Sorry, I don't have a message called " + escape(v or "that") + ". To upload messages, say: ask voice box for my code.")
    if name == "AMAZON.HelpIntent":
        return resp("Voice Box plays audio messages you upload. Say: ask voice box for my code, to get a code for the upload page. "
                    "Then say: ask voice box to play, and the message name.")
    if name in ("AMAZON.StopIntent", "AMAZON.CancelIntent", "AMAZON.NavigateHomeIntent"):
        return resp("Goodbye.")
    return resp("Sorry, I didn't get that. Say: ask voice box to play, and a message name.")
