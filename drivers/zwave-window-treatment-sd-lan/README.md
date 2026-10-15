# Z-Wave Window Treatment SD LAN

SmartThings Edge driver. Install from the **Shai D. Shared Drivers** channel: [Join the channel](https://bestow-regional.api.smartthings.com/invite/Q1jP7By0KVlL)

Fork of Mariano Colmenarejo's **Z-Wave Window Treatment Mc** ([source](https://github.com/Mariano-Github/Edge-Drivers-Beta/tree/main/zwave-drivers/zwave-window-treatment-mc)), with extra handling for the **Fibaro Roller Shutter 4 (FGR-224)** on hubs where the Z-Wave link to the blind is unreliable.

## What's added for the FGR-224

- **Command retries** - every open / close / level / stop is re-sent up to 3 times (5, 10, 15 s) until the blind reports, so it still moves when Z-Wave ACKs are lost.
- **"(App)" device** - the driver creates an always-online LAN device "<blind name> (App)" with open / close / pause and a slider. Use it in the app, routines, Alexa and SharpTools. The real Z-Wave blind can stay "offline" (the hub decides its health; the driver can't change it).
- **Live position** - while moving, the level is updated every N seconds from the full open / close times.
- **Position after stop** - when stopped mid-way, the position is estimated from the elapsed time.
- **Real reports win** - if the blind ever sends its real position (Switch Multilevel or Window Covering report), it is shown on both devices and the estimate stops.
- Manual check: parameter 156 default fixed (600 = 60 s), `0xFE` "position unknown" reports ignored.

### Settings (on the "(App)" device)

| Setting | Default | Meaning |
|---|---|---|
| Full OPEN time (sec) | 30 | Stopwatch time, fully closed -> fully open |
| Full CLOSE time (sec) | 30 | Stopwatch time, fully open -> fully closed |
| Position update while moving (sec) | 2 | 0 = off |

The slider sends the exact level - the FGR-224 moves there using its own calibration. The times above only affect what the app shows.

### Notes

- The driver needs both `zwave` and `lan` permissions (for the "(App)" device).
- Other blinds supported by Mariano's driver work as in the original.

## Supported Devices

22 Z-Wave fingerprints.

| Device | Manufacturer | Product Type | Product ID | Profile |
|---|---|---|---|---|
| Springs Window Shade | `0x026E` | `0x4353` | `0x5A31` | base-window-treatment |
| Springs Roller Shade | `0x026E` | `0x5253` | `0x5A31` | base-window-treatment |
| iBlinds Window Treatment | `0x0287` | `0x0003` | `0x000D` | window-treatment-preset-reverse |
| iBlinds Window Treatment v3 | `0x0287` | `0x0004` | `0x0071` | iblinds-window-treatment-v3 |
| Fibaro Window Treatment | `0x010F` | `0x1D01` | `0x1000` | fibaro-roller-shutter |
| Fibaro Window Treatment | `0x010F` | `0x0300` | `0x100A` | fibaro-roller-shutter-1 |
| Fibaro Window Treatment | `0x010F` | `0x0302` | `0x1000` | fibaro-roller-shutter-2 |
| Fibaro Window Treatment | `0x010F` | `0x0301` | `0x1001` | fibaro-roller-shutter-2 |
| Fibaro Window Treatment | `0x010F` | `0x0303` | (any) | fibaro-roller-shutter-3 |
| Qubino Window Treatment | `0x0159` | `0x0003` | `0x0052` | qubino-flush-shutter |
| Qubino Window Treatment | `0x0159` | `0x0003` | `0x0053` | qubino-flush-shutter |
| Aeotec Nano Shutter | `0x0086` | (any) | `0x008D` | stateless-curtain-power-button |
| Aeotec Nano Shutter | `0x0371` | (any) | `0x008D` | stateless-curtain-power-button |
| NICE Door IBT4ZWAVE | `0x0441` | `0x2400` | `0x1000` | nice-garage-door |
| Forest Shuttle SML | `0x0207` | `0x0027` | `0x0100` | window-treatment-preset |
| TechniSat ZM5101 | `0x0299` | `0x0005` | `0x1A93` | window-treatment-power |
| Z-uno Windows Treatment | `0x0115` | `0x0110` | `0x0001` | window-treatment-preset-reverse-mc |
| Z-uno Windows Treatment | `0x0258` | `0x0200` | `0x102C` | window-treatment-preset-reverse-mc |
| MCO Windows Treatment | `0x015F` | `0xC521` | `0x5103` | window-treatment-power |
| Cherubini OpenZRX | `0x0455` | `0x0004` | `0x0002` | window-treatment-preset |
| Fibaro Window Treatment FGR-224 | `0x010F` | `0x0304` | `0x1000` | fibaro-roller-shutter-4 |
| Fakro ARZ Komfort Windows Treatment | `0x0085` | `0x0003` | `0x0013` | window-treatment-preset-reverse-mc |
