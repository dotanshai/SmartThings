# Capability Presentations — create commands

Run from the `Tadiran-Schema` folder (files are in the `presentations` subfolder):

```
..\smartthings.exe capabilities:presentation:create vehiclepatch55148.acTemperature --capability-version 1 -i presentations\acTemperature.presentation.json
..\smartthings.exe capabilities:presentation:create vehiclepatch55148.acMode --capability-version 1 -i presentations\acMode.presentation.json
..\smartthings.exe capabilities:presentation:create vehiclepatch55148.acFanSpeed --capability-version 1 -i presentations\acFanSpeed.presentation.json
..\smartthings.exe capabilities:presentation:create vehiclepatch55148.acSwingUpDown --capability-version 1 -i presentations\acSwingUpDown.presentation.json
..\smartthings.exe capabilities:presentation:create vehiclepatch55148.acSwingLeftRight --capability-version 1 -i presentations\acSwingLeftRight.presentation.json
..\smartthings.exe capabilities:presentation:create vehiclepatch55148.acLight --capability-version 1 -i presentations\acLight.presentation.json
..\smartthings.exe capabilities:presentation:create vehiclepatch55148.acTurbo --capability-version 1 -i presentations\acTurbo.presentation.json
..\smartthings.exe capabilities:presentation:create vehiclepatch55148.acMute --capability-version 1 -i presentations\acMute.presentation.json
..\smartthings.exe capabilities:presentation:create vehiclepatch55148.acDeviceId --capability-version 1 -i presentations\acDeviceId.presentation.json
```

## Notes

- Used the ACTUAL auto-derived capability IDs from creation output (acSwingUpDown, acSwingLeftRight — not the UD/LR names from the filenames).
- Toggle capabilities (Swing UD/LR, Light, Turbo, Mute) are in BOTH `dashboard.actions` AND `detailView` — required per the confirmed LG Fridge lesson for the toggle to actually be pressable, not just displayed.
- Mode/Fan Speed use `list` displayType with explicit enum→friendly-label mapping, and include `automation.conditions`/`automation.actions` so they're usable in Routines (matches your `list`-based pattern elsewhere).
- Temperature's `numberField` also included in `automation` — per your dev-environment notes, `numberField` is the valid displayType for numeric Routine conditions/actions (not `comparable`).
- Device ID is display-only (`state` displayType), matching your LG Device ID card pattern.
- **Untested — expect some iteration.** This is a first pass based on your documented working patterns from LG Fridge/Laundry; some field names or nesting may need adjustment based on actual API responses, same as those projects needed several rounds. Run these and paste any errors back for fixes.
