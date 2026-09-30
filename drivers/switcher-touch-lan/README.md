# Switcher Touch LAN

Install from the **Shai D. Shared Drivers** channel: [Join the channel](https://bestow-regional.api.smartthings.com/invite/Q1jP7By0KVlL)

> Original driver by a community developer, shared here with his approval.

## Supported Devices

LAN (local TCP). Tested: Switcher Touch (`030b`). Experimental: Switcher Mini (`030f`), Switcher V2 ESP (`01a7`).

---

# Switcher Water Heater LAN - SmartThings Edge Driver

גרסה ציבורית נקייה: `v1.2.0-public-final`

דרייבר SmartThings Edge מקומי לשליטה ב-Switcher Water Heater Type-1 דרך TCP מקומי.

## עיקרי הגרסה

- TCP-only. אין UDP, אין UDP binding ואין תלות בענן.
- Auto Discovery קודם; Manual Setup רק כגיבוי.
- סריקת IP באותו subnet של ההאב.
- זיהוי Switcher-like TCP response לפני כל סריקת מפתח.
- מניעת כפילויות לפי Device ID ולפי IP לפני יצירת מכשיר.
- Device Key scan רק על IP שנראה כמו Switcher, על אותו TCP socket, מ-00 עד ff.
- Rediscovery למכשיר קיים אחרי שינוי IP לפי Device ID + Device Key שמורים בלבד.
- לא מתבצע key scan בזמן Recovery של מכשיר קיים אם ה-IP הישן לא נגיש.
- תצוגת Info נקייה באפליקציה: IP, Device ID, Device Key, Device Type.
- ON/OFF, Timer Minutes, Delay, Runtime, Power W ו-Current A.
- Local monitor כל 30 שניות כברירת מחדל.

## נתמך

נבדק בפועל:

- Switcher Touch / `030b`

תמיכה ניסיונית לפי מיפוי Type-1:

- `030f` Switcher Mini
- `01a7` Switcher V2 ESP
- `01a1` Switcher V2 QCA
- `0317` Switcher V4

## לא נתמך

- Type-2 / port 10000
- מכשירים שדורשים token
- שליטה דרך ענן

## התקנה

פתח PowerShell מתוך תיקיית החבילה והריץ:

```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\Install-Release-PowerShell.txt" `
  -SmartThingsCli "C:\Users\omers\Downloads\smartthings-windows-x64\smartthings.exe" `
  -CapabilityNamespace "laughpeace58575" `
  -HubId "834eba52-3ad7-4a02-bcbe-273235c8341e" `
  -ChannelId "efbe2169-107d-45be-8b62-ff33216b19b8"
```

## Logcat

```powershell
$ST = "C:\Users\omers\Downloads\smartthings-windows-x64\smartthings.exe"
$DRIVER_ID = "5d5c83db-f480-4946-aeb3-53de1e6c277b"

& $ST edge:drivers:logcat $DRIVER_ID --hub-address 192.168.68.66 --connect-timeout 60000 --log-level warn
```

שורת גרסה צפויה:

```text
Switcher Water Heater LAN release driver loaded v1.2.0-public-final
```

## הערה

זו אינה גרסה רשמית של Switcher או Samsung.
