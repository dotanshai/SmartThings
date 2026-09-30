import base64, getpass, json, time, requests
from tornado_test import Aux, SERVERS, LICENSE

def act(api, dev, values):
    c = json.loads(base64.b64decode(dev["cookie"]))
    cookie = base64.b64encode(json.dumps({"device": {
        "id": c["terminalid"], "key": c["aeskey"], "devSession": dev["devSession"],
        "aeskey": c["aeskey"], "did": dev["endpointId"], "pid": dev["productId"],
        "mac": dev["mac"]}}, separators=(",", ":")).encode()).decode()
    data = {"directive": {
        "header": {"namespace": "DNA.KeyValueControl", "name": "KeyValueControl",
                   "interfaceVersion": "2", "senderId": "sdk",
                   "messageId": f"{dev['endpointId']}-{int(time.time())}"},
        "endpoint": {"devicePairedInfo": {"did": dev["endpointId"], "pid": dev["productId"],
                                          "mac": dev["mac"], "devicetypeflag": dev["devicetypeFlag"],
                                          "cookie": cookie},
                     "endpointId": dev["endpointId"], "cookie": {}, "devSession": dev["devSession"]},
        "payload": {"act": "set", "params": list(values.keys()),
                    "vals": [[{"val": v, "idx": 1}] for v in values.values()]}}}
    r = requests.post(f"{api.url}/device/control/v2/sdkcontrol", params={"license": LICENSE},
                      data=json.dumps(data, separators=(",", ":")), headers=api.headers(), timeout=20)
    return r.text

api = Aux(SERVERS["usa"])
ok, j = api.login(input("Tornado email: ").strip(), getpass.getpass("Tornado password: "))
if not ok: raise SystemExit(f"Login failed: {j}")
dev = next(d for f in api.families() for d in api.devices(f["familyid"]))
print("Device:", dev.get("friendlyName"))
print("Before:", api.params(dev).get("pwr"))
print("SET pwr=1 ->", act(api, dev, {"pwr": 1}))
time.sleep(10)
print("After ON:", api.params(dev).get("pwr"))
print("SET pwr=0 ->", act(api, dev, {"pwr": 0}))
time.sleep(3)
print("After OFF:", api.params(dev).get("pwr"))
