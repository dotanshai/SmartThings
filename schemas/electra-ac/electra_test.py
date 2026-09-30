"""
Electra Smart A/C - API test (step 1 of ElectraAcSchema)
Install:  pip install pyElectra aiohttp
Run:      python electra_test.py            -> login (first time) + list devices + state
          python electra_test.py toggle     -> also toggles power on the first A/C
Creds are cached in electra_creds.json (imei + token) so OTP is needed only once.
"""
import asyncio, json, os, sys
import aiohttp
from electrasmart.api import STATUS_SUCCESS, Attributes, ElectraAPI, ElectraApiError
from electrasmart.api.utils import generate_imei

CREDS_FILE = "electra_creds.json"


async def login(session):
    phone = input("Phone number (05XXXXXXXX): ").strip()
    imei = generate_imei()
    api = ElectraAPI(session)
    resp = await api.generate_new_token(phone, imei)
    if resp[Attributes.STATUS] != STATUS_SUCCESS or resp[Attributes.DATA][Attributes.RES] != STATUS_SUCCESS:
        sys.exit(f"SEND OTP failed: {resp}")
    otp = input("OTP from SMS: ").strip()
    resp = await api.validate_one_time_password(otp, imei, phone)
    if resp[Attributes.DATA][Attributes.RES] != STATUS_SUCCESS:
        sys.exit(f"OTP validation failed: {resp}")
    creds = {"phone": phone, "imei": imei, "token": resp[Attributes.DATA][Attributes.TOKEN]}
    with open(CREDS_FILE, "w", encoding="utf-8") as f:
        json.dump(creds, f, indent=2)
    print("Login OK, creds saved.")
    return creds


def show(ac):
    def g(name):
        fn = getattr(ac, name, None)
        try:
            return fn() if callable(fn) else fn
        except Exception as e:
            return f"<err {e}>"
    print(f"\n=== {ac.name} ===")
    for attr in ["mac", "model", "is_on", "get_mode", "get_temperature", "get_sensor_temperature",
                 "get_fan_speed", "is_vertical_swing", "is_horizontal_swing",
                 "get_turbo_mode", "get_shabat_mode", "is_disconnected"]:
        print(f"  {attr:24} {g(attr)}")


async def main():
    toggle = len(sys.argv) > 1 and sys.argv[1] == "toggle"
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=15)) as session:
        if os.path.exists(CREDS_FILE):
            with open(CREDS_FILE, encoding="utf-8") as f:
                creds = json.load(f)
        else:
            creds = await login(session)

        api = ElectraAPI(session, creds["imei"], creds["token"])
        try:
            await api.fetch_devices()      # fills api.devices, returns None
            devices = api.devices
        except ElectraApiError as e:
            sys.exit(f"fetch_devices failed (token expired? delete {CREDS_FILE}): {e}")

        print(f"Found {len(devices)} device(s)")
        for ac in devices:
            await api.get_last_telemtry(ac)   # (sic) typo is in the library
            show(ac)

        if toggle and devices:
            ac = devices[0]
            ac.turn_off() if ac.is_on() else ac.turn_on()
            await api.set_state(ac)
            print(f"\nToggled power on '{ac.name}'. Waiting 5s and re-reading...")
            await asyncio.sleep(5)
            await api.get_last_telemtry(ac)
            show(ac)


asyncio.run(main())
