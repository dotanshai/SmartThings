"""
Checks whether Sabbath mode can be read AND written on your LG fridge,
using LG's official ThinQ Connect Python SDK.

Setup:
1. pip install thinqconnect
2. Get a Personal Access Token (PAT):
   - Go to https://smartsolution.developer.lge.com
   - Sign in with your LG account
   - Go to Cloud Developer -> Docs -> ThinQ Connect -> PAT
   - Generate a Personal Access Token and copy it
3. Fill in ACCESS_TOKEN and COUNTRY_CODE below, then run:
   python lg_sabbath_check.py
"""

import asyncio
import uuid
from aiohttp import ClientSession
from thinqconnect.thinq_api import ThinQApi

ACCESS_TOKEN = "PASTE_YOUR_PERSONAL_ACCESS_TOKEN_HERE"
COUNTRY_CODE = "IL"  # change if you're not in Israel
CLIENT_ID = str(uuid.uuid4())


async def main():
    async with ClientSession() as session:
        thinq_api = ThinQApi(session=session, access_token=ACCESS_TOKEN, country_code=COUNTRY_CODE, client_id=CLIENT_ID)

        devices = await thinq_api.async_get_device_list()
        print("=== Your devices ===")
        for d in devices["response"]:
            print(f"  {d['deviceInfo']['deviceType']}  |  {d['deviceInfo']['modelName']}  |  {d['deviceInfo']['alias']}  |  id={d['deviceId']}")

        fridge = next((d for d in devices["response"] if d["deviceInfo"]["deviceType"] == "DEVICE_REFRIGERATOR"), None)
        if not fridge:
            print("No refrigerator found on this account.")
            return

        device_id = fridge["deviceId"]
        print(f"\nUsing refrigerator: {fridge['deviceInfo']['alias']} ({device_id})")

        profile = await thinq_api.async_get_device_profile(device_id=device_id)
        print("\n=== Full device profile (look for 'sabbath') ===")
        print(profile)

        status = await thinq_api.async_get_device_status(device_id=device_id)
        print("\n=== Current status (look for 'sabbath') ===")
        print(status)

        print("\nIf 'sabbath' appears in the profile with a writable/settable indication,")
        print("share the profile section above - that confirms whether it's controllable.")


asyncio.run(main())
