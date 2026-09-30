"""
test_hdmi_input.py

Standalone test of HDMI input-switching key codes, using the reference
androidtvremote2 library directly -- completely independent of the
SmartThings driver.

This version also logs the TV's reported state (its "current app", which
Google TV sometimes uses to represent the active HDMI input as a
pseudo-app, plus power state) before and after each key press. NOTE: this
protocol has no dedicated "current input" field the way it has one for
volume or power -- so this state log may or may not show a visible change
even if the input genuinely switched. Treat it as a helpful extra data
point on top of watching the TV directly, not a replacement for it.

Requires: python -m pip install androidtvremote2

Usage:
    python test_hdmi_input.py <TV_IP>

Will pair fresh (a code will appear on the TV screen -- enter it when
prompted), then send a sequence of different key codes one at a time,
logging state before/after each and pausing so you can also watch the TV.
"""
import asyncio
import sys


def log_state(remote, label):
    current_app = getattr(remote, "current_app", "<unavailable>")
    is_on = getattr(remote, "is_on", "<unavailable>")
    print(f"  [{label}] current_app={current_app!r}  is_on={is_on!r}")


async def main():
    if len(sys.argv) < 2:
        print("Usage: python test_hdmi_input.py <TV_IP>")
        sys.exit(1)

    host = sys.argv[1]

    from androidtvremote2 import AndroidTVRemote

    remote = AndroidTVRemote(
        client_name="HDMI Input Test",
        certfile="hdmi_test_cert.pem",
        keyfile="hdmi_test_key.pem",
        host=host,
    )
    await remote.async_generate_cert_if_missing()

    print("Starting pairing -- a code should appear on the TV screen now.")
    await remote.async_start_pairing()
    code = input("Enter the code shown on the TV: ").strip()
    await remote.async_finish_pairing(code)
    print("Paired. Connecting to the remote-control channel...")

    await remote.async_connect()
    await asyncio.sleep(1.5)  # let the initial remote_configure/current-app info arrive
    log_state(remote, "initial state, before any key sent")

    tests = [
        ("KEYCODE_TV_INPUT (178) -- generic cycle-input key", "KEYCODE_TV_INPUT"),
        ("KEYCODE_TV_INPUT_HDMI_1 (243) -- direct HDMI1 select", "KEYCODE_TV_INPUT_HDMI_1"),
        ("KEYCODE_TV_INPUT_HDMI_2 (244) -- direct HDMI2 select", "KEYCODE_TV_INPUT_HDMI_2"),
    ]

    for description, key_name in tests:
        input(f"\nPress Enter to send: {description}")
        try:
            remote.send_key_command(key_name)
            print(f"  Sent {key_name}.")
        except Exception as e:
            print(f"  FAILED to send {key_name}: {e}")
            continue
        await asyncio.sleep(2)  # give the TV a moment to report any state change
        log_state(remote, f"after {key_name}")
        print("  Watch the TV now -- did the picture/input actually change?")

    print("\nDone. Full state log is above -- compare current_app across each")
    print("step even if nothing visibly changed on screen.")


if __name__ == "__main__":
    asyncio.run(main())
