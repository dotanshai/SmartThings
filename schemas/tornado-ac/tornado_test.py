"""
Tornado A/C (AUX cloud) - read-only test.
Logs in with your Tornado WIFI 3 account, lists homes + devices + current params.
Ported from romfreiman/tornado-aircon-custom-component (MIT).

Install:  pip install requests pycryptodome
Run:      python tornado_test.py
"""
import base64, getpass, hashlib, json, sys, time
import requests
from Crypto.Cipher import AES

TIMESTAMP_KEY = "kdixkdqp54545^#*"
PASSWORD_KEY = "4969fj#k23#"
BODY_KEY = "xgx3d*fe3478$ukx"
IV = bytes((b + 256) % 256 for b in
           [-22, -86, -86, 58, -69, 88, 98, -94, 25, 24, -75, 119, 29, 22, 21, -86])
LICENSE = ("PAFbJJ3WbvDxH5vvWezXN5BujETtH/iuTtIIW5CE/SeHN7oNKqnEajgljTcL0fBQQWM0XAAAAAAnBh"
           "JyhMi7zIQMsUcwR/PEwGA3uB5HLOnr+xRrci+FwHMkUtK7v4yo0ZHa+jPvb6djelPP893k7SagmffZ"
           "mOkLSOsbNs8CAqsu8HuIDs2mDQAAAAA=")
LICENSE_ID = "3c015b249dd66ef0f11f9bef59ecd737"
COMPANY_ID = "48eb1b36cf0202ab2ef07b880ecda60d"
SERVERS = {
    "usa": "https://app-service-usa-fd7cc04c.smarthomecs.com",
    "eu": "https://app-service-deu-f0e9ebbb.smarthomecs.de",
}

MODES = {0: "cool", 1: "heat", 2: "dry", 3: "fan", 4: "auto"}
FANS = {0: "auto", 1: "low", 2: "medium", 3: "high", 4: "turbo", 5: "silent"}


class Aux:
    def __init__(self, url):
        self.url, self.session, self.userid = url, "", ""

    def headers(self, **extra):
        return {
            "Content-Type": "application/x-java-serialized-object",
            "licenseId": LICENSE_ID, "lid": LICENSE_ID, "language": "en",
            "appVersion": "2.2.10.456537160",
            "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 12; SM-G991B Build/SP1A.210812.016)",
            "system": "android", "appPlatform": "android",
            "loginsession": self.session, "userid": self.userid, **extra,
        }

    def login(self, email, password):
        now = time.time()
        body = json.dumps({
            "email": email,
            "password": hashlib.sha1(f"{password}{PASSWORD_KEY}".encode()).hexdigest(),
            "companyid": COMPANY_ID, "lid": LICENSE_ID,
        }, separators=(",", ":"))
        token = hashlib.md5(f"{body}{BODY_KEY}".encode()).hexdigest()
        key = hashlib.md5(f"{now}{TIMESTAMP_KEY}".encode()).digest()
        raw = body.encode()
        raw += b"\x00" * (16 - len(raw) % 16)
        enc = AES.new(key, AES.MODE_CBC, IV).encrypt(raw)
        r = requests.post(f"{self.url}/account/login", data=enc,
                          headers=self.headers(timestamp=f"{now}", token=token), timeout=20)
        j = r.json()
        if j.get("status") != 0:
            return False, j
        self.session, self.userid = j["loginsession"], j["userid"]
        return True, j

    def post(self, path, data="", **hdr):
        r = requests.post(f"{self.url}{path}", data=data, headers=self.headers(**hdr), timeout=20)
        return r.json()

    def families(self):
        j = self.post("/appsync/group/member/getfamilylist")
        return j["data"]["familyList"] if j.get("status") == 0 else []

    def devices(self, fid):
        out = []
        j = self.post("/appsync/group/dev/query?action=select", '{"pids":[]}', familyid=fid)
        if j.get("status") == 0:
            out += j["data"].get("endpoints") or []
        j = self.post("/appsync/group/sharedev/querylist?querytype=shared",
                      '{"endpointId":""}', familyid=fid)
        if j.get("status") == 0:
            out += [d["devinfo"] for d in j["data"].get("shareFromOther") or []]
        return out

    def params(self, dev, names=None):
        names = names or []
        c = json.loads(base64.b64decode(dev["cookie"]))
        cookie = base64.b64encode(json.dumps({"device": {
            "id": c["terminalid"], "key": c["aeskey"], "devSession": dev["devSession"],
            "aeskey": c["aeskey"], "did": dev["endpointId"], "pid": dev["productId"],
            "mac": dev["mac"]}}, separators=(",", ":")).encode()).decode()
        payload = {"act": "get", "params": names, "vals": []}
        if names == ["mode"]:  # ambient temperature query
            payload["did"] = dev["endpointId"]
            payload["vals"] = [[{"val": 0, "idx": 1}]]
        data = {"directive": {
            "header": {"namespace": "DNA.KeyValueControl", "name": "KeyValueControl",
                       "interfaceVersion": "2", "senderId": "sdk",
                       "messageId": f"{dev['endpointId']}-{int(time.time())}"},
            "endpoint": {"devicePairedInfo": {"did": dev["endpointId"], "pid": dev["productId"],
                                              "mac": dev["mac"],
                                              "devicetypeflag": dev["devicetypeFlag"],
                                              "cookie": cookie},
                         "endpointId": dev["endpointId"], "cookie": {},
                         "devSession": dev["devSession"]},
            "payload": payload}}
        r = requests.post(f"{self.url}/device/control/v2/sdkcontrol", params={"license": LICENSE},
                          data=json.dumps(data, separators=(",", ":")),
                          headers=self.headers(), timeout=20)
        j = r.json()
        resp = json.loads(j["event"]["payload"]["data"])
        return {p: resp["vals"][i][0]["val"] for i, p in enumerate(resp["params"])}


def main():
    email = input("Tornado email: ").strip()
    password = getpass.getpass("Tornado password: ")

    api = None
    for region, url in SERVERS.items():
        a = Aux(url)
        ok, j = a.login(email, password)
        print(f"[{region}] login -> {'OK' if ok else j}")
        if ok:
            api = a
            break
    if not api:
        sys.exit("Login failed on both servers.")

    fams = api.families()
    print(f"\nHomes: {len(fams)}")
    for f in fams:
        print(f"\n== Home: {f.get('name')}  (familyid={f['familyid']})")
        devs = api.devices(f["familyid"])
        if not devs:
            print("   (no devices)")
        for d in devs:
            print(f"   Device: {d.get('friendlyName')}  endpointId={d['endpointId']}  "
                  f"productId={d['productId']}")
            try:
                p = api.params(d)
                try:
                    p["envtemp"] = api.params(d, ["mode"]).get("envtemp")
                except Exception as e:
                    print(f"     (ambient temp failed: {e})")
                print(f"     power={'on' if p.get('pwr') else 'off'}  "
                      f"mode={MODES.get(p.get('ac_mode'), p.get('ac_mode'))}  "
                      f"setpoint={p.get('temp', 0) / 10}C  "
                      f"room={(p.get('envtemp') or 0) / 10}C  "
                      f"fan={FANS.get(p.get('ac_mark'), p.get('ac_mark'))}  "
                      f"vswing={p.get('ac_vdir')}  hswing={p.get('ac_hdir')}")
                print("     raw:", json.dumps(p, ensure_ascii=False))
            except Exception as e:
                print(f"     params failed: {e}")


if __name__ == "__main__":
    main()

