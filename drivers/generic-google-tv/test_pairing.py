"""
test_pairing.py

Uses the reference androidtvremote2 library (the same protocol
implementation the Google TV mobile app itself uses) to attempt pairing
directly against the TV. This is independent of the SmartThings driver and
independent of the custom PowerShell script -- if THIS also stalls waiting
for a pairing code, it strongly points to a TV-side issue rather than
anything in the driver. If it succeeds, it tells us pairing is possible at
all from this network, which would point back at something specific to
the driver's TLS stack on the hub.

Usage:
    python test_pairing.py 192.168.1.137
"""
import asyncio
import sys

from androidtvremote2 import AndroidTVRemote


async def main():
    if len(sys.argv) < 2:
        print("Usage: python test_pairing.py <TV_IP>")
        return

    host = sys.argv[1]
    remote = AndroidTVRemote(
        client_name="SmartThings Test",
        certfile="cert.pem",
        keyfile="key.pem",
        host=host,
    )

    print("Generating certificate (first run only)...")
    await remote.async_generate_cert_if_missing()

    print(f"Reading TV name/MAC from {host}...")
    try:
        name, mac = await remote.async_get_name_and_mac()
        print(f"TV name: {name}, MAC: {mac}")
    except Exception as e:
        print(f"Could not get name/mac (not fatal, continuing): {e}")

    print("Starting pairing -- watch the TV screen now...")
    await remote.async_start_pairing()

    code = input("Enter the pairing code shown on the TV: ")
    try:
        await remote.async_finish_pairing(code)
        print("PAIRED SUCCESSFULLY.")
    except Exception as e:
        print(f"Pairing failed: {e}")


if __name__ == "__main__":
    asyncio.run(main())
