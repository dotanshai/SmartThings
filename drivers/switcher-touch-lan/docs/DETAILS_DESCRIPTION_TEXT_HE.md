# Details / Description text

זה הטקסט הקצר שמומלץ להדביק בשדה Details / Description של ההפצה או הפוסט.
ההסבר המלא נמצא בקובץ:
DETAILS/PROTOCOL_NOTES_HE.txt

Switcher Water Heater LAN Edge Driver

דרייבר SmartThings Edge מקומי למתגי דוד של Switcher דרך LAN.

נבדק בפועל:
- Switcher Touch
- device_type: 030b
- TCP port: 9957
- Protocol Type 1

תמיכה ניסיונית לפי מיפוי aioswitcher:
- 030f = Switcher Mini
- 01a7 = Switcher V2 ESP
- 01a1 = Switcher V2 QCA
- 0317 = Switcher V4

מה נוסף בגרסה הזו:
- סינון לפי סוג מכשיר כדי לא ליצור בטעות מכשירי Switcher שאינם מתגי דוד.
- תיקון Routine: אם setTimerMinutes מגיע עד 2 שניות אחרי ON, הדרייבר שולח ON מחדש עם הזמן החדש.
- קריאת מצב, זמן נשאר, זמן שעבר והספק דרך TCP 9957.
- שימוש ב-powerMeter ו-currentMeasurement רגילים של SmartThings, כולל היסטוריה.

הערות:
- לא דרייבר רשמי של Switcher או Samsung.
- W נקרא מהמכשיר.
- A מחושב לפי W / 220.
- מכשירי Type 2 או מכשירים שדורשים token אינם נתמכים בגרסה הזו.
