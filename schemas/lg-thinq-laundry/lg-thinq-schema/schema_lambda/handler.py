"""
schema_lambda/handler.py — the Schema Connector Lambda that SmartThings
invokes directly (register this function's ARN in Developer Workspace).

CONTROL IS BACK IN SCOPE (confirmed working live 2026-08-11). Declares a
"switch" capability mapped to START/STOP, using the verified payload
shape (location + operation) in shared/lg_client.py. A real START command
was tested and confirmed working (runState: INITIAL -> DETECTING).

IMPORTANT — physical prerequisite the Lambda cannot satisfy on its own:
commands only succeed while the machine is in remote-start mode
(remoteControlEnabled=true), which requires the user to hold the "Add
Item" button (labeled "*Remote Start") for 3+ seconds, door closed,
machine powered on, IMMEDIATELY before sending a command — powering off
or opening the door cancels it. If a command fails, it's very likely
because this wasn't done recently; there's no API-side way to detect or
trigger this state ahead of time except checking remoteControlEnabled in
the last known status (which itself may be stale by the time the user
acts on it).

Handles:
  - discoveryRequest    -> list the user's LG washer/dryer as a ST device
  - stateRefreshRequest -> report current status for known devices
  - commandRequest      -> execute switch on/off (mapped to START/STOP)

NOT YET IMPLEMENTED in this file (left as clearly marked TODOs):
  - grantCallbackAccess / interactionResult handling — only needed once
    you wire up async discovery or push-based state updates via MQTT.
    For a first working version, synchronous discovery + polled state
    refresh is enough and matches how your other connectors started.
  - Surfacing a clear "turn on Remote Start first" message back to the
    user when a command fails — SmartThings' error-response format for
    this isn't wired up yet, currently just logs and returns no state
    change, which will look like the command silently did nothing.

CAPABILITY NAMESPACE: vehiclepatch55148 (reused from your other
connectors). See laundryState-capability.json for the capability
definition to create via the SmartThings API before discovery works
end-to-end.

STATUS: the discovery/state-refresh shape has been built directly from the
real profile JSON we pulled from your device, using only fields confirmed
by a real device_status read.
"""

import json
import logging
import sys
import os

sys.path.append(os.path.join(os.path.dirname(__file__), "..", "shared"))

from token_store import get_link  # noqa: E402
import lg_client  # noqa: E402
from lg_client import LgThinqError  # noqa: E402

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

NAMESPACE = "vehiclepatch55148"
LAUNDRY_CAPABILITY = f"{NAMESPACE}.laundryState"

# LG runState values -> friendly bucket, useful if you want a coarser
# "job state" attribute in addition to the raw machineState passthrough.
WASH_PHASE_STATES = {"DETECTING", "RUNNING", "RINSING", "RINSE_HOLD",
                      "SPINNING", "STEAM_SOFTENING", "REFRESHING"}
DRY_PHASE_STATES = {"DRYING", "COOL_DOWN"}
IDLE_STATES = {"POWER_OFF", "INITIAL", "END", "SLEEP", "PAUSE", "RESERVED"}


def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event))

    headers = event.get("headers", {})
    interaction_type = _get_interaction_type(event)

    handlers = {
        "discoveryRequest": handle_discovery,
        "stateRefreshRequest": handle_state_refresh,
        "commandRequest": handle_command,
    }

    handler = handlers.get(interaction_type)
    if handler is None:
        logger.warning("Unhandled interaction type: %s", interaction_type)
        return _error_response(event, "UNKNOWN_INTERACTION_TYPE")

    try:
        return handler(event)
    except Exception:
        logger.exception("Handler failed for %s", interaction_type)
        return _error_response(event, "INTERNAL_ERROR")


def handle_discovery(event):
    installed_app_id = event["headers"]["installedAppId"]
    link = get_link(installed_app_id)
    if not link:
        return _error_response(event, "INTEGRATION_DELETED")

    devices = lg_client.list_devices(
        link["lgPat"], link["lgClientId"], link["lgCountryCode"]
    )

    st_devices = []
    for d in devices:
        info = d.get("deviceInfo", {})
        if info.get("deviceType") != "DEVICE_WASHER":
            continue  # laundry-only for v1, per your scoping decision
        st_devices.append({
            "externalDeviceId": d["deviceId"],
            "friendlyName": info.get("alias", "LG Washer/Dryer"),
            "deviceHandlerType": "c2c-cloud",  # cloud-connected device
            "manufacturerInfo": {
                "manufacturerName": "LG",
                "modelName": info.get("modelName", ""),
                "hwVersion": "1.0",
                "swVersion": "1.0",
            },
            "deviceUniqueId": d["deviceId"],
            "capabilities": [
                {"id": "switch", "version": 1},
                {"id": LAUNDRY_CAPABILITY, "version": 1},
            ],
        })

    return {
        "headers": {"interactionType": "discoveryResponse"},
        "discoveryData": {"devices": st_devices},
    }


def handle_state_refresh(event):
    installed_app_id = event["headers"]["installedAppId"]
    link = get_link(installed_app_id)
    if not link:
        return _error_response(event, "INTEGRATION_DELETED")

    devices_in = event["stateRefreshData"]["devices"]
    devices_out = []

    for dev in devices_in:
        external_id = dev["externalDeviceId"]
        try:
            status = lg_client.get_status(
                link["lgPat"], link["lgClientId"], link["lgCountryCode"],
                external_id,
            )
        except LgThinqError:
            logger.exception("status fetch failed for %s", external_id)
            continue

        devices_out.append({
            "externalDeviceId": external_id,
            "states": _status_to_states(status),
        })

    return {
        "headers": {"interactionType": "stateRefreshResponse"},
        "stateRefreshData": {"devices": devices_out},
    }


def handle_command(event):
    """
    Executes switch on/off, mapped to LG's START/STOP washerOperationMode.
    Requires the machine to already be in remote-start mode
    (remoteControlEnabled=true) — see module docstring. If the command
    fails (most likely because that wasn't done recently), it's logged
    and no state change is returned; the user will need to try again
    after re-arming remote start on the panel.
    """
    installed_app_id = event["headers"]["installedAppId"]
    link = get_link(installed_app_id)
    if not link:
        return _error_response(event, "INTEGRATION_DELETED")

    devices_in = event.get("commandData", {}).get("devices", [])
    devices_out = []

    for dev in devices_in:
        external_id = dev["externalDeviceId"]
        results = []
        for cmd in dev.get("commands", []):
            result = _execute_command(link, external_id, cmd)
            if result is not None:
                results.append(result)
        devices_out.append({"externalDeviceId": external_id, "states": results})

    return {
        "headers": {"interactionType": "commandResponse"},
        "commandData": {"devices": devices_out},
    }


def _execute_command(link, external_id, cmd):
    capability = cmd.get("capability")
    command = cmd.get("command")

    operation_map = {("switch", "on"): "START", ("switch", "off"): "STOP"}
    operation = operation_map.get((capability, command))

    if operation is None:
        logger.warning("Unhandled command: %s.%s", capability, command)
        return None

    try:
        lg_client.send_washer_command(
            link["lgPat"], link["lgClientId"], link["lgCountryCode"],
            external_id, operation,
        )
        value = "on" if operation == "START" else "off"
        return {"capability": "switch", "attribute": "switch", "value": value}
    except LgThinqError:
        logger.exception(
            "command failed: %s.%s on %s — machine may not be in remote-"
            "start mode (physical button press required before each use)",
            capability, command, external_id,
        )
        return None


def _status_to_states(status: dict) -> list:
    """Translate one LG status payload into ST Schema state entries."""
    run_state = status.get("runState", {}).get("currentState", "POWER_OFF")
    timer = status.get("timer", {})
    cycle = status.get("cycle", {})
    remote = status.get("remoteControlEnable", {})

    is_on = run_state != "POWER_OFF"
    remain_minutes = (timer.get("remainHour", 0) or 0) * 60 + (timer.get("remainMinute", 0) or 0)
    total_minutes = (timer.get("totalHour", 0) or 0) * 60 + (timer.get("totalMinute", 0) or 0)

    return [
        {"capability": "switch", "attribute": "switch", "value": "on" if is_on else "off"},
        {"capability": LAUNDRY_CAPABILITY, "attribute": "machineState", "value": run_state},
        {"capability": LAUNDRY_CAPABILITY, "attribute": "remainingTimeMinutes", "value": remain_minutes},
        {"capability": LAUNDRY_CAPABILITY, "attribute": "totalTimeMinutes", "value": total_minutes},
        {"capability": LAUNDRY_CAPABILITY, "attribute": "cycleCount", "value": cycle.get("cycleCount", 0)},
        {"capability": LAUNDRY_CAPABILITY, "attribute": "remoteControlEnabled",
         "value": remote.get("remoteControlEnabled", False)},
    ]


def _get_interaction_type(event) -> str:
    return event.get("headers", {}).get("interactionType", "")


def _error_response(event, error_enum: str):
    return {
        "headers": {"interactionType": "errorResponse"},
        "errorData": {
            "requestId": event.get("headers", {}).get("requestId", ""),
            "errorEnum": error_enum,
            "detail": error_enum,
        },
    }
