גרסה v1.2.0-public-final

מה כלול:

- מבוסס על v1.1.8 שנבדקה באפליקציית SmartThings והציגה את פרטי המכשיר בצורה תקינה.
- Auto Discovery קודם: הדרייבר מחפש אוטומטית מכשירי Switcher ברשת המקומית.
- Manual Setup נשאר כגיבוי בלבד כאשר הגילוי האוטומטי לא מצליח או כאשר המשתמש מזין ערכים ידנית.
- TCP-only: אין UDP, אין UDP binding ואין תלות בענן.
- סריקת IP מתבצעת רק באותו subnet של ההאב, עם אפשרות override ל-scanPrefix.
- זיהוי IP מהיר לפי תגובת TCP שנראית כמו Switcher Type-1.
- לפני סריקת מפתח: בדיקת כפילות לפי Device ID ולפי IP כדי לא ליצור מכשירים כפולים.
- Device Key scan מתבצע רק על IP שנראה כמו Switcher, על אותו TCP socket, בסדר 00 עד ff, עם delay של 10ms ועצירה ב-FULL identity ראשון.
- Rediscovery למכשיר קיים אחרי שינוי IP משתמש רק ב-Device ID וב-Device Key שכבר שמורים; הוא לא מחפש מפתח מחדש ולא יוצר מכשיר חדש.
- אם ה-IP הישן לא נגיש, הדרייבר מדלג על key recovery ועובר ישר ל-known-device rediscovery.
- infoChanged / manual refresh / פקודות ON/OFF עוקפים cooldown של rediscovery כדי לאפשר חזרה מהירה אחרי שינוי ידני של IP.
- תצוגת Info נקייה באפליקציה: IP, Device ID, Device Key, Device Type.
- אין עדכון דינמי של Model Name במסך שלוש הנקודות; פרטי המכשיר מוצגים רק ב-Capability.
- שמירה על כל מה שעבד ב-v1.0.4: ON/OFF, timer, delay, local monitor, runtime, W/A, ותיקון order של Routine timer.

נתמך ונבדק בפועל:

- Switcher Touch / type_hex 030b.

נתמך ניסיונית לפי מיפוי Type-1:

- 030f = Switcher Mini
- 01a7 = Switcher V2 ESP
- 01a1 = Switcher V2 QCA
- 0317 = Switcher V4

לא נתמך:

- Type-2 / port 10000.
- מכשירים שדורשים token.
- שליטה בענן.

הערה:

זו אינה גרסה רשמית של Switcher או Samsung.
