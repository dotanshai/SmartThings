Switcher Water Heater LAN / SmartThings Edge - סיכום טכני להפצה
גרסת מסמך: 1.2
תאריך: 2026-06-30
דרייבר תואם: switcher-touch-lan v1.0.4-water-heater-type-guard
סטטוס: תיעוד קהילתי לא רשמי, מבוסס בדיקות בפועל + השוואה לספרייה הציבורית aioswitcher

================================================================================
0. מה השתנה בגרסה 1.2
================================================================================

עדכון עיקרי לעומת v1.1:

  1. הדרייבר כבר לא מוצג כמתאים רק ל-Touch ברמת הזיהוי.
  2. נוסף guard לפי device_type של מתגי דוד Type 1 מוכרים.
  3. Touch נשאר הדגם היחיד שנבדק אצלנו בפועל.
  4. Mini / V2 / V4 מתקבלים כ-experimental בלבד לפי המיפוי הציבורי של aioswitcher.
  5. מכשירי Switcher שאינם מתגי דוד Type 1 נחסמים בגילוי ולא נוצרים כמכשיר SmartThings.
  6. שדה length ב-frame מחושב כעת דינמית לפני חישוב CRC.
  7. עודכן ההסבר על fef0300002320103: זה template של GET_STATE Type 1, לא מזהה אישי ולא prefix לכל מוצרי Switcher.

================================================================================
1. מטרת הדרייבר
================================================================================

המטרה הייתה לבנות דרייבר SmartThings Edge מקומי לדוד Switcher, בלי תלות בענן של Switcher ובלי Home Assistant.

הדרייבר עושה:

  - גילוי מקומי ברשת.
  - Login ב-TCP.
  - זיהוי Device ID.
  - זיהוי סוג מכשיר מתוך תשובת Login.
  - סינון לפי סוגי מתגי דוד נתמכים/ניסיוניים.
  - שליטה ON/OFF.
  - הפעלה לפי טיימר בדקות.
  - Delay פנימי בדרייבר.
  - הצגת זמן עבר, זמן נשאר וסה"כ זמן ריצה.
  - הצגת IP נוכחי.
  - קריאת W מתוך פקטת state.
  - חישוב A מתוך W.
  - שליחת W/A כ-powerMeter/currentMeasurement רגילים של SmartThings כדי לאפשר היסטוריה.
  - תיקון Routine: אם setTimerMinutes מגיע עד 2 שניות אחרי ON, הדרייבר מפעיל שוב עם הזמן החדש.

הגרסה הנוכחית אינה דרייבר גנרי לכל מוצרי Switcher.
היא מיועדת למשפחת מתגי דוד Switcher Type 1 בלבד.

================================================================================
2. סטטוס תמיכה לפי סוג מכשיר
================================================================================

נבדק אצלנו בפועל:

  030b = Switcher Touch       | Water Heater | Protocol Type 1 | Token: No | Status: tested

מתקבל בדרייבר כ-experimental, לפי המיפוי הציבורי של aioswitcher:

  030f = Switcher Mini        | Water Heater | Protocol Type 1 | Token: No | Status: experimental
  01a7 = Switcher V2 (esp)    | Water Heater | Protocol Type 1 | Token: No | Status: experimental
  01a1 = Switcher V2 (qca)    | Water Heater | Protocol Type 1 | Token: No | Status: experimental
  0317 = Switcher V4          | Water Heater | Protocol Type 1 | Token: No | Status: experimental

לא נתמך בדרייבר הזה:

  01a8 = Switcher Power Plug  | Protocol Type 1, אבל לא דוד.
  0e01 = Switcher Breeze      | Protocol Type 2.
  0c01 = Switcher Runner      | Protocol Type 2.
  0c02 = Switcher Runner Mini | Protocol Type 2.
  0f01 = Runner S11           | Protocol Type 2 + token.
  0f02 = Runner S12           | Protocol Type 2 + token.
  0f04/0f05/0f06 וכו' = Lights | Protocol Type 2 + token.
  031f = Switcher Heater      | Protocol Type 2 + token.

המשמעות בדרייבר v1.0.4:

  - אם discovery מוצא Switcher עם type_hex שאינו ברשימת מתגי הדוד Type 1, הוא מדלג עליו.
  - אם משתמש מגדיר ידנית IP של מכשיר לא נתמך, get_state / set_power יחזירו שגיאת unsupported במקום לנסות לשלוט בו.
  - כך נמנע מצב שבו הדרייבר יוצר בטעות מכשיר דוד עבור תריס, תאורה, מזגן/תרמוסטט, Plug או מכשיר token.

================================================================================
3. מה נבדק בפועל אצלנו
================================================================================

מכשיר שנבדק:

  Device name: Boiler
  Device ID:   4fc5e6
  Device type: Switcher Touch
  Type hex:    030b
  TCP port:    9957

דברים שאומתו בפועל:

  - TCP 9957 פתוח ועובד.
  - TCP 10000 נבדק ונמצא סגור במכשיר הזה.
  - המכשיר משדר UDP broadcast מ-20000 אל 255.255.255.255:10002.
  - SmartThings Edge לא איפשר bind/listen ל-UDP 10002/20002 וזרק forbidden.
  - אפשר לבצע Login דרך TCP 9957.
  - אפשר להוציא Device ID מתשובת Login.
  - אפשר להוציא Session ID מתשובת Login.
  - אפשר להוציא type code מתשובת Login.
  - אפשר לשלוח GET_STATE ולקבל state תקין.
  - אפשר לקרוא זמן נשאר / זמן עבר / W מתשובת state.
  - אפשר לשלוח ON/OFF דרך TCP 9957.
  - אפשר לשלוח ON עם טיימר בדקות.
  - Routine fix של 2 שניות נבדק ועבד בפועל.

מה לא אומת אצלנו:

  - לא אומת פיזית מול Switcher Mini.
  - לא אומת פיזית מול Switcher V2.
  - לא אומת פיזית מול Switcher V4.
  - לא אומת מול מכשירי Type 2.
  - לא אומת מול מכשירים שדורשים token.

לכן חשוב לנסח:

  Touch = supported/tested.
  Mini / V2 / V4 = experimental, expected Type 1 water-heater compatibility.

================================================================================
4. למה בחרנו TCP 9957 ולא UDP
================================================================================

נבדקו שתי דרכים:

1. UDP Broadcast

  המכשיר אכן משדר מידע ב-UDP:

    source:      <device_ip>:20000
    destination: 255.255.255.255:10002
    observed len: בערך 165 bytes

  במחשב רגיל אפשר לראות את ה-broadcast הזה.
  לפי בדיקות עם aioswitcher / sniffing ראינו שמידע כמו W/A מופיע שם.

  אבל ב-SmartThings Edge ניסיון לפתוח listener נכשל:

    UDP listener bind failed ... forbidden

  לכן UDP לא מתאים כבסיס לדרייבר Edge יציב.

2. TCP Local API

  TCP 9957 איפשר:

    Login
    Discovery
    GET_STATE
    ON/OFF
    ON with timer

  לכן הדרייבר מבוסס TCP 9957.

לפי aioswitcher:

  - Type 1 devices: Heaters / v2 / touch / v4 / Mini / Plug => TCP 9957.
  - Type 2 devices: Breeze / Runners / Heater => TCP 10000.

================================================================================
5. fef0300002320103 - מה זה כן ומה זה לא
================================================================================

הרצף:

  fef0300002320103

לא צריך להיות מתואר כ-prefix לכל המכשירים.

הניסוח המדויק:

  זה template/header של חבילת GET_STATE עבור פרוטוקול Type 1.
  הוא נבדק בפועל אצלנו על Switcher Touch.
  הוא מופיע גם ב-aioswitcher כ-GET_STATE_PACKET_TYPE1.

פירוק לוגי:

  fef0      = פתיח frame.
  3000      = אורך הודעה ב-little endian: 0x0030 = 48 bytes כולל 4 בתי CRC.
  02320103  = חלק פקודה / header של GET_STATE בפרוטוקול Type 1.

למה זה לא מזהה אישי של המכשיר שלי:

  החלקים האישיים/דינמיים לא נמצאים שם.
  הם מגיעים בהמשך הפקטה:

    session_id  = מתקבל מה-login.
    timestamp   = נוצר בכל בקשה.
    device_id   = מתקבל מהמכשיר / נשמר לפי המכשיר.
    CRC         = מחושב מחדש לפי כל הפקטה.

לכן:

  - זה כן קבוע של פקודת GET_STATE Type 1.
  - זה לא קבוע של המכשיר שלי.
  - זה לא אמור לשמש לכל מוצרי Switcher.
  - למתגי דוד Type 1 אחרים הוא כנראה מתאים, אבל אצלנו Touch הוא היחיד שנבדק.

================================================================================
6. מבנה frame נכון יותר
================================================================================

התקשורת היא בינארית. בדרייבר אנחנו בונים אותה כמחרוזת hex ואז ממירים ל-bytes.

מבנה כללי:

  frame_start + length + command_header + body + crc1 + crc2

הפתיח:

  fef0

שדה אורך:

  שני בתים אחרי fef0.
  לדוגמה:

    3000 = 0x0030 = 48 bytes
    5200 = 0x0052 = 82 bytes
    5d00 = 0x005d = 93 bytes

האורך כולל את 4 בתי ה-CRC שמתווספים בסוף.
לכן מחשבים:

  length = len(unsigned_packet_bytes) + 4

ואז מחליפים את הבתים 3-4 של ה-frame.

בדרייבר v1.0.4 נוסף חישוב דינמי:

  set_message_length(hex_packet):
    total_length = byte_len(hex_packet) + 4
    length_le = uint16 little endian
    return "fef0" + length_le + hex_packet[8:]

ואז:

  sign_packet(hex_packet):
    hex_packet = set_message_length(hex_packet)
    packet_crc = crc_hqx(hex_packet)
    key_crc = crc_hqx(packet_crc + key)
    return hex_packet + packet_crc + key_crc

בדיקה מול החבילות שלנו:

  Login unsigned length:   78 bytes + 4 CRC = 82  = 0x52 => fef05200
  GET_STATE unsigned len:  44 bytes + 4 CRC = 48  = 0x30 => fef03000
  Control unsigned len:    89 bytes + 4 CRC = 93  = 0x5d => fef05d00

המשמעות:

  גם אם כרגע האורך יוצא אותו דבר, הדרייבר כבר לא תלוי ב-3000/5200/5d00 כערך ידני.
  אם בעתיד נוסיף פקודה באורך אחר, פונקציית length תעדכן את ה-frame לפני CRC.

================================================================================
7. Login - מה נשלח ומה מוציאים
================================================================================

פקטת Login Type 1 בדרייבר:

  fef052000232a100
  + session ראשוני 00000000
  + request format Type 1
  + timestamp
  + 0100
  + 72 אפסים
  + CRC

ב-aioswitcher יש LOGIN_PACKET_TYPE1 דומה.

מה אנחנו מוציאים מתשובת Login:

  device_id:
    אצלנו נשלף מהתשובה במיקום שנבדק מול Touch.

  session_id:
    אצלנו נשלף מהתשובה ונשלח בהמשך GET_STATE / CONTROL.

  device_type_hex:
    נשלף מתשובת Login אחרי marker/name.
    לדוגמה:
      030b = Switcher Touch.

  device_type_name:
    מתורגם לפי מילון ידוע.

אחרי Login הדרייבר בודק:

  if type_hex in SUPPORTED_WATER_HEATER_TYPE1:
      continue
  else:
      skip/error unsupported

================================================================================
8. GET_STATE - איך מוציאים מצב, זמנים ו-W
================================================================================

GET_STATE Type 1 נבנה כך:

  header/template Type 1:
    fef0300002320103

  body דינמי:
    session_id
    REQUEST_FORMAT_TYPE1 עם timestamp
    device_id
    00

  ואז:
    set_message_length
    CRC

מתשובת state אנחנו מחפשים marker:

  031c00

אחרי marker זה הדרייבר קורא:

  byte 0       = מצב הפעלה
                 01 = on
                 00 = off

  bytes 2-5   = current power consumption in watts
                 uint32 little endian

  bytes 14-17 = remaining seconds
                 uint32 little endian

  bytes 18-21 = elapsed seconds
                 uint32 little endian

  bytes 22-25 = שדה זמן נוסף/ברירת מחדל במכשיר
                 בדרייבר לא משתמשים בו כ-active total, כי בבדיקות 60 שניות הוא לא תמיד ייצג את זמן הריצה הנוכחי.

לכן total מוצג כך:

  total_seconds = remaining_seconds + elapsed_seconds

כאשר state = off:

  remaining_seconds = 0
  elapsed_seconds = 0
  total_seconds = 0
  power_watts = 0

================================================================================
9. W ו-A
================================================================================

W נקרא ישירות מתוך GET_STATE:

  power_watts = uint32 little endian מתוך bytes 2-5 אחרי marker 031c00.

A לא התקבל אצלנו כערך נפרד אמין מתוך TCP state.
לכן הדרייבר מחשב:

  current_amps = round(power_watts / 220, 1)

למה 220?

  בבדיקות מול aioswitcher/נתוני מכשיר, ערכים כמו:

    2106W -> 9.6A

  מתאימים בקירוב ל-220V.

SmartThings מקבל:

  powerMeter.power            unit W
  currentMeasurement.current  unit A

בגרסה הנוכחית אין ephemeral/non_archivable, כדי ש-SmartThings יוכל לשמור היסטוריה.

================================================================================
10. CONTROL - ON/OFF וטיימר
================================================================================

פקודת ON/OFF Type 1 נבנית כך:

  header/template:
    fef05d0002320102

  body דינמי:
    session_id
    REQUEST_FORMAT_TYPE1 עם timestamp
    device_id
    PAD_72_ZEROS
    control block
    command
    timer

command:

  1 = ON
  0 = OFF

timer:

  אם ON עם minutes > 0:
    seconds = minutes * 60
    timer_hex = uint32 little endian

  אם OFF או ללא טיימר:
    00000000

דוגמה:

  90 דקות:
    90 * 60 = 5400 seconds
    5400 decimal = 0x1518
    little endian uint32 = 18150000

================================================================================
11. Routine fix - למה צריך 2 שניות
================================================================================

ב-SmartThings Routine הסדר בפועל יכול להיות:

  1. switch.on
  2. setTimerMinutes

כלומר אם המשתמש ביקש Routine של 90 דקות, SmartThings עלול קודם לשלוח ON עם הזמן שהיה שמור במכשיר/דרייבר, ורק אחרי זה לשלוח setTimerMinutes=90.

התיקון:

  אם setTimerMinutes מגיע עד 2 שניות אחרי ON:
    הדרייבר מניח שזה Routine command order.
    הוא שולח שוב ON פיזי עם הזמן החדש.

בדיקה בפועל:

  ON נשלח עם 38 דקות.
  אחרי בערך 1 שנייה הגיע setTimerMinutes=90.
  הדרייבר זיהה את זה:

    timerMinutes changed shortly after ON; assuming Routine command order and updating physical timer

  ואז שלח:

    ON requested from routine_timer_order_fix, using selected minutes=90

למה לא 1 שנייה?

  SmartThings לא תמיד שולח פקודות Routine באותו מרווח זמן.
  2 שניות נותן מרווח ביטחון בלי להפריע לשימוש ידני רגיל.

================================================================================
12. איך הדרייבר מתרגם device type
================================================================================

מילון כללי שמצאנו/אימתנו מול aioswitcher:

  030f = Switcher Mini
  01a8 = Switcher Power Plug
  030b = Switcher Touch
  01a7 = Switcher V2 (esp)
  01a1 = Switcher V2 (qualcomm)
  0317 = Switcher V4
  0e01 = Switcher Breeze
  0c01 = Switcher Runner
  0c02 = Switcher Runner Mini
  0f01 = Switcher Runner S11
  0f02 = Switcher Runner S12
  0f04 = Switcher Light SL01
  0f07 = Switcher Light SL01 Mini
  0f05 = Switcher Light SL02
  0f08 = Switcher Light SL02 Mini
  0f06 = Switcher Light SL03
  031f = Switcher Heater

אבל הדרייבר שלנו מאשר רק:

  030b, 030f, 01a7, 01a1, 0317

כל השאר:

  unsupported for this driver

================================================================================
13. האם צריך לעדכן את הדרייבר הציבורי בגלל ה-header הקשיח?
================================================================================

כן, בוצע עדכון ב-v1.0.4.

לא בגלל שה-header היה קשיח למכשיר שלי, אלא בגלל שתי סיבות הנדסיות:

  1. שדה length עדיף לחשב דינמית.
  2. חשוב למנוע יצירה/שליטה במכשירי Switcher שאינם מתגי דוד Type 1.

לפני העדכון:

  - הדרייבר היה מכוון בפועל ל-Touch.
  - GET_STATE/CONTROL היו Type 1.
  - אם מכשיר אחר ב-9957 היה עונה מספיק דומה, היה סיכוי שהדרייבר ינסה ליצור אותו.

אחרי העדכון:

  - Touch מזוהה כ-tested.
  - Mini/V2/V4 מתקבלים כ-experimental.
  - Plug/Runner/Breeze/Light/Heater נחסמים.
  - length מחושב דינמית לפני CRC.

================================================================================
14. איך להרחיב לדגם נוסף בצורה מסודרת
================================================================================

כדי להוסיף דגם נוסף לא מספיק להוסיף קוד type למילון.
צריך לבצע בדיקות:

  1. לוודא device_type_hex.
  2. לוודא protocol_type.
  3. לוודא פורט TCP.
  4. לוודא האם צריך token.
  5. להריץ Login ולוודא session_id/device_id/type.
  6. לשלוח GET_STATE ולבדוק marker/offsets.
  7. לבדוק ON/OFF.
  8. לבדוק ON עם טיימר.
  9. לבדוק שינוי ידני באפליקציה הרשמית/במתג פיזי.
  10. לבדוק Routine עם Timer.
  11. לבדוק W/A אם רלוונטי.

רק אחרי זה להעביר סטטוס:

  experimental -> tested

================================================================================
15. מקורות ציבוריים ששימשו להשוואה
================================================================================

aioswitcher - פרויקט קהילתי לא רשמי:

  https://github.com/TomerFi/aioswitcher

DeviceType mapping:

  https://raw.githubusercontent.com/TomerFi/aioswitcher/dev/src/aioswitcher/device/__init__.py

Packet templates:

  https://raw.githubusercontent.com/TomerFi/aioswitcher/dev/src/aioswitcher/api/packets.py

TCP port mapping:

  https://raw.githubusercontent.com/TomerFi/aioswitcher/dev/src/aioswitcher/api/__init__.py

Message length / CRC / time conversion helpers:

  https://raw.githubusercontent.com/TomerFi/aioswitcher/dev/src/aioswitcher/device/tools.py

================================================================================
16. סיכום קצר להפצה
================================================================================

הדרייבר v1.0.4 הוא דרייבר SmartThings Edge מקומי למתגי דוד Switcher Type 1.

נבדק בפועל:

  Switcher Touch / 030b.

נתמך כניסיוני לפי מיפוי ציבורי:

  Switcher Mini / 030f.
  Switcher V2 ESP / 01a7.
  Switcher V2 QCA / 01a1.
  Switcher V4 / 0317.

לא נתמך:

  Plug, Runner, Breeze, Light, Heater, Type 2, token devices.

הפרוטוקול:

  TCP 9957.
  Login Type 1.
  GET_STATE Type 1.
  CONTROL Type 1.
  length מחושב דינמית.
  CRC מחושב מחדש בכל פקטה.

הערה חשובה:

  התאימות ל-Mini/V2/V4 היא על בסיס מיפוי ציבורי והיגיון פרוטוקולי, לא בדיקת חומרה אצלנו.
  כל מי שבודק דגם כזה צריך לשלוח logcat כדי לוודא state/timer/W.
