"""
test_intent_uri.py

Tests whether Android's standard "Intent URI" format can launch an app
through this protocol, as an alternative to market://launch (currently
broken by a Play Store bug) and https:// verified App Links (only works
for apps that register one).

An Intent URI instructs Android's system directly to launch a specific
package -- it does NOT go through Play Store's resolver at all, so if
this works, it should be immune to the market:// / Instant Launcher bug
entirely.

Requires: python -m pip install androidtvremote2

Usage:
    python test_intent_uri.py <TV_IP> <package_name>

Example:
    python test_intent_uri.py 192.168.1.102 com.applicaster.il.ch1

Will pair fresh (a code will appear on the TV screen -- enter it when
prompted), then try a few different Intent URI variants one at a time,
pausing after each so you can watch the TV and confirm whether the app
actually launches.
"""
import asyncio
import sys


async def main():
    if len(sys.argv) < 3:
        print("Usage: python test_intent_uri.py <TV_IP> <package_name>")
        sys.exit(1)

    host = sys.argv[1]
    package = sys.argv[2]

    from androidtvremote2 import AndroidTVRemote

    remote = AndroidTVRemote(
        client_name="Intent URI Test",
        certfile="intent_test_cert.pem",
        keyfile="intent_test_key.pem",
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

    # A few different variants of the Android Intent URI format, since the
    # exact syntax the TV's handler accepts (if any) is unknown. Testing
    # each one individually against a real app that's currently confirmed
    # broken via market://launch.
    variants = [
        (
            "Intent URI -- Chrome-style double-slash format",
            f"intent://launch/#Intent;scheme=https;package={package};"
            "action=android.intent.action.VIEW;end",
        ),
        (
            "Intent URI -- launcher action/category form",
            f"intent:#Intent;package={package};"
            "action=android.intent.action.MAIN;"
            "category=android.intent.category.LAUNCHER;end",
        ),
        (
            "Intent URI -- simple package-only form",
            f"intent:#Intent;package={package};end",
        ),
        (
            "Intent URI -- with launchFlags (new task)",
            f"intent:#Intent;package={package};"
            "launchFlags=0x10000000;end",
        ),
    ]

    for description, uri in variants:
        input(f"\nPress Enter to try: {description}\n  ({uri})")
        try:
            remote.send_launch_app_command(uri)
            print("  Sent. Watch the TV now -- did the app actually launch?")
        except Exception as e:
            print(f"  FAILED to send: {e}")
        input("  Press Enter once you've noted the result to continue...")

    print("\nDone. Did any of the three variants actually launch the app?")


if __name__ == "__main__":
    asyncio.run(main())
