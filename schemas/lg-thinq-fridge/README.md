# LG Fridge Schema Connector — build plan

Separate project from the LG washer/dryer connector. Same overall pattern
(Node.js Lambda + st-schema SDK + DynamoDB token store + API Gateway),
but its own Lambda, table, and Gateway so the two don't share blast radius.

## Capabilities (5 files ready to create)

| File | Card | Notes |
|---|---|---|
| `capabilities/fridge-temperature.json` | Fridge Temperature | setpoint, 1–8°C, r/w |
| `capabilities/freezer-temperature.json` | Freezer Temperature | setpoint, -21 to -13°C, r/w |
| `capabilities/express-mode.json` | Express Mode | boolean, r/w |
| `capabilities/power-save.json` | Power Save | boolean, read-only |
| `capabilities/water-filter.json` | Water Filter | 0–6 months, read-only |

**Door is NOT a custom capability** — use the stock `contactSensor`
capability (open/closed) for the MAIN door. That gets free Routine
support ("notify if door left open X minutes") without any custom code.

## CLI commands to create these (run from your PowerShell setup)

```powershell
cd C:\Users\dotan\Desktop\smartthings_win\
.\smartthings.exe capabilities:create -i fridge-temperature.json
.\smartthings.exe capabilities:create -i freezer-temperature.json
.\smartthings.exe capabilities:create -i express-mode.json
.\smartthings.exe capabilities:create -i power-save.json
.\smartthings.exe capabilities:create -i water-filter.json
```

Each returns an `id`/`version` — SmartThings derives the real capability
`id` from `name`, ignoring what's in the JSON (same as last time), so
capture the actual returned ids for the Device Profile step.

## Known traps to avoid (carried over from the laundry project)

- Capabilities are effectively immutable after creation — if you need to
  change an attribute later, create a new capability, don't try to update.
- Build the Device Profile + presentation in one step with
  `deviceprofiles:view:create`, not a plain `deviceprofiles:create`.
- For a full-width card per concept (not grid-packed 3-per-row), each
  concept needs to be its own capability — already done above.
- Dashboard tile with multiple capabilities needs `composite:true` on
  every entry and `label` nested inside `values: [{ label: ... }]`.

## Not yet built (next steps)
1. Create the 5 capabilities above + stock `contactSensor` reference
2. Build Device Profile (switch? or just presence-based on/off — a fridge
   has no real on/off, so the profile probably skips `switch` entirely
   and just shows the cards)
3. Lambda: discovery/state/control handlers reusing the ThinQ Connect
   API call pattern from `lg_thinq_test.py`, mapped to `DEVICE_REFRIGERATOR`
4. New DynamoDB table + API Gateway + Lambda (separate from the laundry stack)
5. Test against Homeagain's real device profile/status shape once the
   Lambda is deployed

Want me to draft the Device Profile JSON and the Lambda's discovery/state
handlers next, or start with getting the capabilities actually created
and confirmed first?
