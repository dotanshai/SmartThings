"""
lg_client.py — thin synchronous wrapper around the thinqconnect SDK for use
inside AWS Lambda handlers (which are sync, while thinqconnect is asyncio-based).

Each call opens a fresh aiohttp session and event loop, since Lambda
execution contexts are short-lived and this keeps things simple and
crash-resistant (no dangling connections between invocations).

v1 SCOPE: control is back in scope (confirmed working live against the
real machine on 2026-08-11). send_washer_command's payload now includes
the required "location" field alongside "operation" — omitting it caused
every command to fail with INVALID_COMMAND_ERROR even when
remoteControlEnabled was true. With location included, commands succeed;
runState was confirmed moving INITIAL -> DETECTING after a real START.

IMPORTANT PREREQUISITE (not enforceable from code): the physical machine
must be in remote-start mode (remoteControlEnabled=true) for any command
to succeed — the user must hold the "Add Item" button (labeled "*Remote
Start" on this model) for 3+ seconds, with the door closed and the
machine powered ON, immediately before sending a command. Powering off or
opening the door cancels it. There's no way to enable this remotely.
WAKE_UP is only valid when the device is in SLEEP state (not e.g.
INITIAL) — use it only after ~10 min of remote-start inactivity, not as
a blind first command.
"""

import asyncio

from aiohttp import ClientSession
from thinqconnect import ThinQApi, ThinQAPIException


class LgThinqError(Exception):
    pass


def _run(coro):
    """Run a coroutine to completion, safe for a fresh Lambda invocation."""
    return asyncio.run(coro)


def list_devices(pat: str, client_id: str, country_code: str) -> list[dict]:
    async def _inner():
        async with ClientSession() as session:
            api = ThinQApi(session=session, access_token=pat,
                            country_code=country_code, client_id=client_id)
            try:
                return await api.async_get_device_list() or []
            except ThinQAPIException as e:
                raise LgThinqError(str(e)) from e
    return _run(_inner())


def get_status(pat: str, client_id: str, country_code: str, device_id: str) -> dict:
    async def _inner():
        async with ClientSession() as session:
            api = ThinQApi(session=session, access_token=pat,
                            country_code=country_code, client_id=client_id)
            try:
                status = await api.async_get_device_status(device_id)
            except ThinQAPIException as e:
                raise LgThinqError(str(e)) from e
            # LG returns a list with one status dict per sub-device/location;
            # for the washer/dryer combo there's a single MAIN entry.
            if isinstance(status, list):
                return status[0] if status else {}
            return status or {}
    return _run(_inner())


def send_washer_command(pat: str, client_id: str, country_code: str,
                         device_id: str, operation: str,
                         location_name: str = "MAIN") -> dict:
    """
    operation: one of START / STOP / POWER_OFF / WAKE_UP
    (matches washerOperationMode.value.w from the device profile)

    CONFIRMED LIVE 2026-08-11: the payload must include "location"
    alongside "operation", matching the profile's property structure —
    without it, LG's API rejects every command with INVALID_COMMAND_ERROR
    even when remoteControlEnabled is true. With location included, a
    real START command succeeded (runState: INITIAL -> DETECTING).

    Also confirmed: WAKE_UP fails with COMMAND_NOT_SUPPORTED_IN_STATE if
    the device isn't actually in SLEEP state — don't send it as a blind
    first command; only use it after remote-start mode has likely timed
    out (~10 min idle). For a fresh remote-start session, go straight to
    START.
    """
    if operation not in {"START", "STOP", "POWER_OFF", "WAKE_UP"}:
        raise LgThinqError(f"invalid washer operation: {operation}")

    async def _inner():
        async with ClientSession() as session:
            api = ThinQApi(session=session, access_token=pat,
                            country_code=country_code, client_id=client_id)
            payload = {
                "location": {"locationName": location_name},
                "operation": {"washerOperationMode": operation},
            }
            try:
                return await api.async_post_device_control(device_id, payload)
            except ThinQAPIException as e:
                raise LgThinqError(str(e)) from e
    return _run(_inner())


def set_delayed_start_hours(pat: str, client_id: str, country_code: str,
                             device_id: str, hours: int,
                             location_name: str = "MAIN") -> dict:
    """
    Writable range is 3-19 per the profile (timer.relativeHourToStop).
    Includes "location" in the payload for the same reason as
    send_washer_command above — not individually tested live, but the
    profile structure is identical, so this should hold.
    """
    if not 3 <= hours <= 19:
        raise LgThinqError(f"delayed start hours must be 3-19, got {hours}")

    async def _inner():
        async with ClientSession() as session:
            api = ThinQApi(session=session, access_token=pat,
                            country_code=country_code, client_id=client_id)
            payload = {
                "location": {"locationName": location_name},
                "timer": {"relativeHourToStop": hours},
            }
            try:
                return await api.async_post_device_control(device_id, payload)
            except ThinQAPIException as e:
                raise LgThinqError(str(e)) from e
    return _run(_inner())
