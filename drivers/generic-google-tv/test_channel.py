"""
test_channel.py

Standalone test of Channel up/down key codes, using the reference
androidtvremote2 library directly -- completely independent of the
SmartThings driver. If Channel doesn't work here either, that's strong
evidence this is a genuine device/protocol limitation, not a driver bug.

Requires: python -m pip install androidtvremote2

Usage:
    python test_channel.py <TV_IP>

Will pair fresh (a code will appear on the TV screen -- enter it when
prompted), then send Channel Up and Channel Down one at a time, pausing
after each so you can watch the TV and confirm whether the channel
actually changes.

IMPORTANT: make sure the TV is actually tuned to a live-TV/antenna
source (not Home screen or a streaming app) before running this --
otherwise there's nothing for Channel Up/Down to meaningfully do,
regardless of whether the underlying key send works.
"""
import asyncio
import sys


async def main():
    if len(sys.argv) < 2:
        print("Usage: python test_channel.py <TV_IP>")
        sys.exit(1)

    host = sys.argv[1]

    from androidtvremote2 import AndroidTVRemote

    remote = AndroidTVRemote(
        client_name="Channel Test",
        certfile="channel_test_cert.pem",
        keyfile="channel_test_key.pem",
        host=host,
    )
    await remote.async_generate_cert_if_missing()

    print("Starting pairing -- a code should appear on the TV screen now.")
    await remote.async_start_pairing()
    code = input("Enter the code shown on the TV: ").strip()
    await remote.async_finish_pairing(code)
    print("Paired. Connecting to the remote-control channel...")

    await remote.async_connect()
    await asyncio.sleep(1.5)

    input("\nMake sure the TV is on a live-TV/antenna channel right now, "
          "then press Enter to send CHANNEL_UP...")
    remote.send_key_command("KEYCODE_CHANNEL_UP")
    print("Sent CHANNEL_UP. Watch the TV now -- did the channel actually change?")

    input("\nPress Enter to send CHANNEL_DOWN...")
    remote.send_key_command("KEYCODE_CHANNEL_DOWN")
    print("Sent CHANNEL_DOWN. Watch the TV now -- did the channel actually change?")

    print("\nDone. If neither changed the channel, this confirms it's a real "
          "device/protocol limitation, not anything in the driver's code.")


if __name__ == "__main__":
    asyncio.run(main())
