"""
lg_thinq_test.py — quick standalone test script for LG's official ThinQ Connect API.

Purpose: sanity-check that a Personal Access Token (PAT) can reach LG's ThinQ
Connect API, list your devices, and pull the profile + live status for any
washer/dryer/fridge it finds. No SmartThings involved yet — this is purely to
confirm the LG side works before wrapping it in a Schema Connector Lambda.

SETUP
------
1. pip install thinqconnect --break-system-packages
2. Get a Personal Access Token (PAT):
   - Log into https://connect-pat.lgthinq.com/ with the SAME LG account
     your ThinQ app devices are registered under (must be a native LG
     account, NOT a Google/Facebook/Amazon social login — those don't work
     with the API).
   - Generate a PAT there.
3. Pick a CLIENT_ID: any random uuid4 string, unique to this "device"/app.
   Generate one with `python3 -c "import uuid; print(uuid.uuid4())"` and
   reuse the SAME value on every run (don't regenerate it each time).
4. Set the three env vars below and run: python3 lg_thinq_test.py

NOTES
-----
- Country code: use the country tied to your LG account's locale.
- LG rate-limits polling. Don't loop this script — it's a one-shot check.
"""

import asyncio
import json
import os
import sys

from aiohttp import ClientSession

from thinqconnect import ThinQApi, ThinQAPIException

# ---- Config: set these as environment variables before running ----------
ACCESS_TOKEN = os.environ.get("LG_THINQ_PAT", "")
CLIENT_ID = os.environ.get("LG_THINQ_CLIENT_ID", "")
COUNTRY_CODE = os.environ.get("LG_THINQ_COUNTRY", "US")

# Device types this script cares about — includes fridges now, not just laundry.
INTERESTING_TYPES = {
    "DEVICE_WASHER", "DEVICE_DRYER", "DEVICE_WASHTOWER",
    "DEVICE_WASHCOMBO_MAIN", "DEVICE_WASHCOMBO_MINI",
    "DEVICE_REFRIGERATOR",
}


async def main() -> int:
    if not ACCESS_TOKEN or not CLIENT_ID:
        print("Missing LG_THINQ_PAT or LG_THINQ_CLIENT_ID environment variables.")
        print("See the SETUP section at the top of this script.")
        return 1

    async with ClientSession() as session:
        api = ThinQApi(
            session=session,
            access_token=ACCESS_TOKEN,
            country_code=COUNTRY_CODE,
            client_id=CLIENT_ID,
        )

        try:
            print("Fetching device list...")
            devices = await api.async_get_device_list()
        except ThinQAPIException as e:
            print(f"ThinQ API error: {e}")
            return 1

        if not devices:
            print("No devices returned. Check that your PAT's LG account has "
                  "devices registered (native LG login, not social login).")
            return 0

        print(f"\nFound {len(devices)} device(s):\n")
        interesting_devices = []
        for d in devices:
            device_id = d.get("deviceId")
            device_info = d.get("deviceInfo", {})
            device_type = device_info.get("deviceType")
            alias = device_info.get("alias", "(no alias)")
            model = device_info.get("modelName", "(unknown model)")
            print(f"  - {alias!r}  type={device_type}  model={model}  id={device_id}")
            if device_type in INTERESTING_TYPES:
                interesting_devices.append((device_id, alias, device_type))

        if not interesting_devices:
            print("\nNo washer/dryer/fridge-type devices found on this account.")
            return 0

        for device_id, alias, device_type in interesting_devices:
            print(f"\n=== {alias} ({device_type}) ===")

            try:
                profile = await api.async_get_device_profile(device_id)
                fname = f"device_{device_type.lower()}_profile.json"
                with open(fname, "w", encoding="utf-8") as f:
                    json.dump(profile, f, indent=2, ensure_ascii=False)
                print(f"-- profile written to {fname} ({len(json.dumps(profile))} chars) --")
            except ThinQAPIException as e:
                print(f"  profile fetch failed: {e}")

            try:
                status = await api.async_get_device_status(device_id)
                fname = f"device_{device_type.lower()}_status.json"
                with open(fname, "w", encoding="utf-8") as f:
                    json.dump(status, f, indent=2, ensure_ascii=False)
                print(f"-- status written to {fname} ({len(json.dumps(status))} chars) --")
            except ThinQAPIException as e:
                print(f"  status fetch failed: {e}")

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
