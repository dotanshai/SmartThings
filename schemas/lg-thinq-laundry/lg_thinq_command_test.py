"""
lg_thinq_command_test.py — standalone test for sending a control COMMAND
to your LG washer/dryer, separate from lg_thinq_test.py (which only reads
device list/profile/status).

Purpose: confirm the payload shape for washerOperationMode commands works
against your real machine, before wiring it into the Schema Connector
Lambda's shared/lg_client.py.

WHY WAKE_UP FIRST
------------------
WAKE_UP is the safest command to test:
- It won't start a wash cycle or use water/detergent
- It's easy to visually/audibly confirm (machine's display/panel lights
  up or beeps) or check via a follow-up status poll
- If the payload shape is wrong, LG's API error message will tell us
  how to fix it, without risking an unwanted wash cycle

SETUP
------
Same env vars as lg_thinq_test.py:
  LG_THINQ_PAT, LG_THINQ_CLIENT_ID, LG_THINQ_COUNTRY

USAGE
------
python3 lg_thinq_command_test.py                  -> sends WAKE_UP (safe default)
python3 lg_thinq_command_test.py START             -> sends START (will begin a cycle!)
python3 lg_thinq_command_test.py STOP
python3 lg_thinq_command_test.py POWER_OFF

Only pass START/STOP/POWER_OFF once WAKE_UP has confirmed the payload
shape is correct, and only if you're OK with the machine actually
responding (e.g. START will begin whatever cycle is currently selected
on the machine's dial/panel).
"""

import asyncio
import json
import os
import sys

from aiohttp import ClientSession

from thinqconnect import ThinQApi, ThinQAPIException

ACCESS_TOKEN = os.environ.get("LG_THINQ_PAT", "")
CLIENT_ID = os.environ.get("LG_THINQ_CLIENT_ID", "")
COUNTRY_CODE = os.environ.get("LG_THINQ_COUNTRY", "IL")

VALID_OPERATIONS = {"START", "STOP", "POWER_OFF", "WAKE_UP"}
LAUNDRY_TYPES = {"DEVICE_WASHER", "DEVICE_DRYER", "DEVICE_WASHTOWER",
                  "DEVICE_WASHCOMBO_MAIN", "DEVICE_WASHCOMBO_MINI"}


async def main() -> int:
    operation = sys.argv[1].upper() if len(sys.argv) > 1 else "WAKE_UP"
    if operation not in VALID_OPERATIONS:
        print(f"Invalid operation {operation!r}. Must be one of: {sorted(VALID_OPERATIONS)}")
        return 1

    if not ACCESS_TOKEN or not CLIENT_ID:
        print("Missing LG_THINQ_PAT or LG_THINQ_CLIENT_ID environment variables.")
        return 1

    async with ClientSession() as session:
        api = ThinQApi(session=session, access_token=ACCESS_TOKEN,
                        country_code=COUNTRY_CODE, client_id=CLIENT_ID)

        try:
            devices = await api.async_get_device_list() or []
        except ThinQAPIException as e:
            print(f"ThinQ API error listing devices: {e}")
            return 1

        washer = next((d for d in devices
                        if d.get("deviceInfo", {}).get("deviceType") in LAUNDRY_TYPES), None)
        if not washer:
            print("No washer/dryer found on this account.")
            return 1

        device_id = washer["deviceId"]
        alias = washer.get("deviceInfo", {}).get("alias", "washer")
        print(f"Target device: {alias!r} ({device_id})")

        # Status before, for comparison
        try:
            before = await api.async_get_device_status(device_id)
            print("\n-- status BEFORE command --")
            print(json.dumps(before, indent=2, ensure_ascii=False))
        except ThinQAPIException as e:
            print(f"  status fetch (before) failed: {e}")

        payload = {
            "location": {"locationName": "MAIN"},
            "operation": {"washerOperationMode": operation},
        }
        print(f"\nSending command: {json.dumps(payload)}")

        try:
            result = await api.async_post_device_control(device_id, payload)
            print("\n-- command result --")
            print(json.dumps(result, indent=2, ensure_ascii=False))
        except ThinQAPIException as e:
            print(f"\nCOMMAND FAILED: {e}")
            print("This tells us the payload shape or operation value needs adjusting.")
            return 1

        # Give the machine a moment, then check status again
        await asyncio.sleep(3)
        try:
            after = await api.async_get_device_status(device_id)
            print("\n-- status AFTER command --")
            print(json.dumps(after, indent=2, ensure_ascii=False))
        except ThinQAPIException as e:
            print(f"  status fetch (after) failed: {e}")

    print("\nDone. Compare BEFORE/AFTER runState.currentState and "
          "remoteControlEnable to confirm the command actually took effect.")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
