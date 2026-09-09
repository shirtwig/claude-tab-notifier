# Claude Tab Notifier

> תיעוד זה הוא תרגום/גרסה עברית של [README.md](README.md). בכל מקרה של סתירה, הגרסה האנגלית היא הקובע.

**Claude Tab Notifier** מסמן את הטאב ב-Windows Terminal שבו רץ session של [Claude Code](https://claude.com/claude-code) בתחילית `✨`, ומשמיע צליל, ברגע ש-Claude מסיים לענות או מחכה לקלט ממך. שליחת prompt חדש מנקה את הסימון.

```
לפני:  PowerShell
אחרי:  ✨ PowerShell
```

## הבעיה שהכלי פותר

כשעובדים עם כמה טאבים/sessions של Claude Code במקביל, קשה לדעת איזה טאב סיים לענות ואיזה עדיין "חושב" — בלי לעבור פיזית על כל טאב ולבדוק. הכלי הזה נותן איתות ויזואלי (כותרת הטאב) ואיתות שמיעתי (צליל) בכל פעם שסשן מסוים דורש את תשומת הלב שלך, כך שאפשר לעבוד על כמה משימות בו-זמנית בלי לפספס מתי Claude סיים.

## איך זה עובד, בקצרה

```
Claude Code hook (Notification / Stop / UserPromptSubmit)
    -> קורא את ה-WT_SESSION של עצמו מהסביבה
    -> כותב %LOCALAPPDATA%\ClaudeTabNotifier\state\<WT_SESSION>.json
           { "status": "needsAttention" | "clear" }

Watcher (רץ בתוך הטאב שלך ב-Windows Terminal)
    -> בודק כל 500ms את קובץ ה-state של ה-WT_SESSION שלו
    -> כאשר "needsAttention": מוסיף ✨ לכותרת הטאב ומשמיע צליל
    -> כאשר "clear": מחזיר את הכותרת המקורית
```

`WT_SESSION` הוא GUID ש-Windows Terminal מקצה לכל pane (טאב/חלונית). זהו המזהה המשותף שמאפשר ל-hook (שמכיר רק את הסביבה של עצמו) ול-watcher (שגם הוא מכיר רק את הסביבה של עצמו) "להסכים" לאיזה טאב שייך session נתון של Claude Code — בלי שאף אחד מהם צריך לאתר או לספור את השני.

## דרישות מערכת

- **Windows** עם **Windows Terminal** — הסימון מתבסס על `WT_SESSION`, משתנה סביבה ש-Windows Terminal מזריק לכל pane. הכלי **לא** יעבוד בחלון `conhost.exe` הישן, בטרמינל המשולב של VS Code, או באמולטורים אחרים.
- **PowerShell** (Windows PowerShell 5.1, הגרסה שמגיעה מובנית עם Windows) — נתמך במלואו, כולל הפעלה אוטומטית של ה-watcher.
- **CMD.exe** — ה-watcher עצמו (`watcher-cmd.ps1`) קיים ונבדק, אבל ה-installer עדיין לא מחבר אותו להפעלה אוטומטית בטאבי CMD. פרטים בהמשך תחת [תמיכה ב-CMD](#תמיכה-ב-cmd).
- נדרש **.NET SDK** בזמן ההתקנה (כדי לבנות את ה-hook עם `dotnet publish`).

## התקנה — למשתמש שמוריד ZIP מ-GitHub

1. הורידו את ה-Release ZIP מ-GitHub: [github.com/shirtwig/claude-tab-notifier](https://github.com/shirtwig/claude-tab-notifier), וחלצו (Extract) אותו לתיקייה כלשהי במחשב.
2. פתחו **PowerShell** בתוך התיקייה שחילצתם אליה (לדוגמה: `cd "$HOME\Downloads\claude-tab-notifier-master"`).
3. הריצו בדיוק את הפקודה הבאה:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
   ```
   הרצה של `.\install.ps1` בלבד — או לחיצה כפולה על הקובץ, או "Run with PowerShell" מהתפריט שנפתח בלחיצה ימנית — **אינה** דרך ההתקנה הנתמכת: PowerShell לא טוען סקריפטים מהתיקייה הנוכחית בלי קידומת `.\` מפורשת, וגם עם ה-`.\`, מדיניות ה-Execution Policy הנפוצה עדיין עלולה לחסום את ההרצה ללא `-ExecutionPolicy Bypass`. הפקודה המלאה למעלה היא זו שבאמת נדרשת.
4. עקבו אחר ההנחיות של ה-installer ובחרו Sound (צליל) ו-Emoji (לחיצה על Enter בכל אחת מהשאלות שומרת על הבחירה הנוכחית/ברירת המחדל).
5. בסיום, פתחו טאב חדש של **Windows Terminal** והפעילו את `claude` כרגיל — ה-watcher יתחיל לרוץ אוטומטית דרך ה-`$PROFILE`.

ה-installer מבצע שבעה שלבים:
1. בונה את `ClaudeAttention.exe` (ה-hook) ופורס אותו לתוך `~/.claude/tools/ClaudeAttention.exe`.
2. פורס את קובץ ה-watcher, קובצי הצליל, ואת `config.json` לתוך `%LOCALAPPDATA%\ClaudeTabNotifierPOC\`.
3. שואל אתכם לבחור צליל התראה, ושומר את הבחירה ל-`config.json` (הרצה חוזרת של ה-installer מציגה את הבחירה הנוכחית ושומרת עליה בלחיצת Enter).
4. שואל אתכם לבחור אימוג'י התראה, באותו אופן.
5. מוסיף hooks בשם `Notification`, `Stop`, ו-`UserPromptSubmit` לקובץ `~/.claude/settings.json`, וקובע `env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (למה זה נדרש — [ראו למטה](#הגדרת-claude_code_disable_terminal_title)). כל תוכן אחר שכבר קיים ב-`settings.json` — hooks אחרים, משתני env אחרים, כל דבר אחר — נשאר בדיוק כפי שהיה.
6. מוסיף בלוק קצר של הפעלה אוטומטית ל-`$PROFILE` שלכם ב-PowerShell, כך שה-watcher יתחיל לרוץ אוטומטית בכל טאב PowerShell חדש. כל תוכן אחר שכבר קיים ב-profile נשאר כפי שהיה.
7. מוודא (verify) שכל מה שלמעלה אכן נפרס/הוגדר כראוי, ומדווח על כך.

בטוח להריץ את ה-installer יותר מפעם אחת: כל שלב בודק קודם אם הוא כבר בוצע, כך שהרצה חוזרת לא יוצרת hooks כפולים או בלוקים כפולים ב-profile, ולא מאפסת בחירת צליל/אימוג'י קיימת. ה-installer גם שומר גיבוי אוטומטי (`<file>.backup-<timestamp>`) של `settings.json` ושל `$PROFILE`, ממש לפני שהוא בפועל משנה אותם.

לאחר ההתקנה — **סגרו ופתחו מחדש את טאבי ה-PowerShell שלכם** (או טענו מחדש את ה-`$PROFILE`) כדי שה-watcher יתחיל לרוץ.

## מה עושים אם PowerShell חוסם את הסקריפט

קבצים שמגיעים מ-ZIP שהורדתם מהאינטרנט מקבלים ב-Windows תיוג פנימי הנקרא **"Mark of the Web"** (זרם נתונים בשם `Zone.Identifier`). תחת מדיניות ההרצה (Execution Policy) הנפוצה `RemoteSigned`, קובץ `.ps1` שמתויג כך חייב להיות חתום דיגיטלית כדי לרוץ — אחרת תקבלו שגיאה בסגנון:

```
File ...\watcher-background.ps1 cannot be loaded. The file ... is not
digitally signed. You cannot run this script on the current system.
```

**זו בעיה ידועה שכבר תוקנה בקוד:** `install.ps1` בגרסה הנוכחית מריץ אוטומטית `Unblock-File` על כל הקבצים שהוא פורס (ה-watcher, `test-sound.ps1`, וקובץ ה-hook), ומסיר מהם את התיוג הזה — בלי לגעת ב-Execution Policy הכללי של המשתמש. אם התקנתם מה-ZIP העדכני ביותר, זה אמור לקרות אוטומטית ולא אמור להטריד אתכם.

אם בכל זאת נתקלתם בשגיאה כזו (למשל, אם העתקתם קובץ `.ps1` ידנית ולא דרך ה-installer), אפשר לפתור זאת ידנית באחת מהדרכים הבאות:

```powershell
# הסרת התיוג מקובץ ספציפי
Unblock-File -Path "C:\Path\To\watcher-background.ps1"
```

או: לחיצה ימנית על הקובץ ← **Properties** ← לסמן **Unblock** בתחתית החלון ← **OK**.

## שימוש ב-Windows Terminal ו-PowerShell

לאחר ההתקנה, כל טאב PowerShell חדש שתפתחו ב-Windows Terminal יטען את ה-`$PROFILE` שלכם, שיפעיל אוטומטית את ה-watcher ברקע (thread נפרד בתוך אותו תהליך של הטאב עצמו — לכן ה-watcher "מת" אוטומטית כשסוגרים את הטאב, בלי להשאיר תהליכים תקועים). תראו הודעת פתיחה קצרה כמו:

```
=== Claude Tab Notifier -- background watcher (runs on a separate thread in THIS process) ===
...
Background watcher thread started -- this prompt is free.
You can now run 'claude' normally in this same tab to start a second session.
```

אחרי זה אפשר פשוט להריץ `claude` כרגיל באותו טאב.

## איך עובד הסימון ✨

1. Claude מסיים לענות, או מחכה שתקלידו לו קלט (hooks בשם `Stop` / `Notification` נורים) ← כותרת הטאב מקבלת תחילית `✨`, והצליל המוגדר מתנגן פעם אחת.
2. אתם שולחים את ה-prompt הבא (ה-hook `UserPromptSubmit` נורה) ← ה-`✨` מוסר והכותרת חוזרת למצבה המקורי.
3. אם Claude מסיים שוב **לפני** ששלחתם prompt חדש, הטאב כבר מסומן ושום דבר לא נורה שוב (אין צליל כפול או כתיבת כותרת מיותרת עבור מצב שלא השתנה).

**מגבלה חשובה:** הניקוי של הסימון קורה בעת **שליחת prompt חדש**, ולא בעת **מעבר לטאב**. ל-Windows Terminal אין API שמאפשר לתהליך חיצוני לגלות איזה טאב פעיל/ממוקד כרגע ([microsoft/terminal#19783](https://github.com/microsoft/terminal/issues/19783), [#19818](https://github.com/microsoft/terminal/issues/19818)), ולכן אי אפשר להבחין בין "כבר הסתכלתם על הטאב" לבין "עדיין לא הסתכלתם" — ניתן להבחין רק ב-"עכשיו שלחתם ל-Claude הודעה חדשה". בפועל, המשמעות היא של-`✨` יכול להישאר על טאב שכבר ראיתם, עד שתקלידו בו את ההודעה הבאה בפועל.

## הגדרות (config.json)

ערכו את `%LOCALAPPDATA%\ClaudeTabNotifierPOC\config.json`:

```json
{
  "soundEnabled": true,
  "selectedSound": "classic",
  "customSoundFile": "",
  "selectedEmoji": "sparkle"
}
```

כדי לשנות שדה כלשהו ידנית, ערכו רק את השדה שאתם רוצים לשנות והשאירו את שאר הקובץ בדיוק כפי שהוא — כל שדה עצמאי לחלוטין: עריכת `selectedEmoji` לעולם לא נוגעת ב-`selectedSound`/`soundEnabled`/`customSoundFile`, ולהפך (זו גם בדיוק ההתנהגות של שאלות הצליל והאימוג'י ב-installer עצמו — כל אחת כותבת רק לשדה שלה). ערך לא-מוכר באחד מ-`selectedSound`/`selectedEmoji` מטופל בדיוק כמו ערך חסר — נופל בשקט לברירת המחדל (`classic` / `sparkle`) ולא גורם לשגיאה.

### איך עובד הצליל, והחלפת צליל

- `selectedSound` קובע איזה צליל מובנה מתנגן. שנו את הערך לאחד מהשמות בטבלה למטה כדי להחליף צליל.
- הקובץ נקרא מחדש בכל פעם שה-watcher מתחיל לרוץ (כלומר, בכל פעם שנפתח טאב חדש) — הוא **לא** נטען מחדש (hot-reload) ל-watchers שכבר רצים. יש לפתוח טאב חדש כדי שהחלפת צליל תיכנס לתוקף.

הריצו `%LOCALAPPDATA%\ClaudeTabNotifierPOC\test-sound.ps1` כדי להאזין לצליל שמוגדר כרגע, או `test-sound.ps1 -Sound <name>` כדי להאזין לכל צליל מובנה, ללא קשר להגדרה הנוכחית.

#### רשימת הצלילים המובנים

| שם | תיאור |
|---|---|
| `classic` | סוויפ סינוסי דו-טוני (ברירת המחדל) |
| `chime` | טון סינוסי רך עם אוברטון עדין |
| `soft` | טון סינוסי בודד, נמוך ושקט |
| `alert` | שני פולסים חדים |
| `retro` | גל ריבועי מדורג |
| `magic` | ארפג'יו עולה בן 4 תווים |
| `digital` | שני "בזמזומים" קצרים בתדר גבוה |
| `double` | שני צפצופים זהים |
| `scifi` | סוויפ תדר רציף |
| `success` | ארפג'יו מז'ורי עולה בן 3 תווים |

כל עשרת הצלילים נוצרו באופן פרוצדורלי (סינתזה) במיוחד עבור הפרויקט הזה (ראו `sounds/SOUNDS.md`) — לא נעשה שימוש בקבצי סאונד של צד שלישי.

### איך משביתים צליל

קבעו `"soundEnabled": false` בקובץ `config.json`. סימון הכותרת (`✨`) ימשיך לעבוד כרגיל — רק הצליל יושתק.

### שימוש בקובץ WAV מותאם אישית

1. קבעו `"selectedSound": "custom"`.
2. קבעו `"customSoundFile"` לנתיב אל קובץ ה-`.wav` שלכם. נתיב יחסי (relative) ייפתר ביחס לתיקיית ההתקנה (`%LOCALAPPDATA%\ClaudeTabNotifierPOC\`); נתיב מוחלט (absolute) ישמש כפי שהוא.

קובץ `.wav` שאינו תקין (לדוגמה, קובץ שאינו באמת בפורמט WAV) יידלג עליו בשקט — לא יגרום לקריסה, אבל גם לא ישמיע צליל; בדקו את ה-log של ה-watcher (ראו [Troubleshooting](#פתרון-בעיות-troubleshooting)) אם הצליל לא מתנגן.

תצורה (`config.json`) חסרה או פגומה תיפול חזרה לברירות המחדל שמופיעות למעלה, ולא תגרום לקריסה של ה-watcher.

### האימוג'י, ואיך עובד ה-pulse

- `selectedEmoji` קובע איזה אימוג'י מסמן כרטיסייה שזקוקה לתשומת לב. שנו את הערך לאחד מ-12 השמות בטבלה למטה כדי להחליף אימוג'י.

| שם | אימוג'י |
|---|---|
| `sparkle` | ✨ (ברירת המחדל) |
| `star` | ⭐ |
| `bell` | 🔔 |
| `bolt` | ⚡ |
| `fire` | 🔥 |
| `target` | 🎯 |
| `check` | ✅ |
| `reddot` | 🔴 |
| `eyes` | 👀 |
| `chat` | 💬 |
| `heart` | ❤️ |
| `music` | 🎵 |

האימוג'י שבחרתם מופיע כתחילית בכותרת הכרטיסייה כל עוד ה-session זקוק לתשומת לב, ומבצע שם **pulse**: זהו אותו אימוג'י בדיוק לאורך כל הזמן (הוא לעולם לא מוחלף באימוג'י אחר) — רק שהוא חוזר על עצמו מספר פעמים משתנה: עותק אחד, ואז שניים, ואז שלושה, וחזרה לשניים, וחוזר חלילה. זו הדרך הקרובה ביותר ל"גדילה/הקטנה" שניתן להשיג בתוך מחרוזת טקסט פשוטה של כותרת — ל-Windows Terminal אין שום מנגנון לשליטה בגודל גופן של תו בודד בתוך הכותרת. שליחת prompt חדש עוצרת את ה-pulse ומחזירה את הכותרת המקורית בדיוק כפי שהייתה.

הקובץ נקרא מחדש בכל פעם שה-watcher מתחיל לרוץ (בדיוק כמו הגדרות הצליל) — הוא **לא** נטען מחדש (hot-reload) ל-watchers שכבר רצים. יש לפתוח טאב חדש כדי שהחלפת אימוג'י תיכנס לתוקף.

## תמיכה ב-CMD

`watcher-cmd.ps1` מממש בדיוק את אותה התנהגות (סימון, מניעת כפילויות, צליל, rotation ללוגים, ניקוי תהליכים יתומים) כמו ה-watcher של PowerShell, אבל מותאם ל-CMD.exe — הוא רץ כתהליך נפרד לחלוטין (מופעל דרך `start /B`), ולא כ-thread ברקע בתוך אותו תהליך, מכיוון של-CMD אין מקבילה למנגנון ה-runspace הפנימי של PowerShell. ההתנהגות הזו נבדקת באופן מלא ב-automated test suite של הפרויקט, לצד ה-watcher של PowerShell.

**עם זאת, `install.ps1` עדיין לא פורס את `watcher-cmd.ps1` באופן אוטומטי, ואינו מחבר שום מנגנון הפעלה אוטומטית עבור טאבי CMD** — רק הנתיב של PowerShell `$PROFILE` מטופל אוטומטית. כדי להשתמש בכך ידנית בטאב CMD כיום:

1. העתיקו את `watcher-cmd.ps1` ואת `watcher-cmd.cmd` לתוך `%LOCALAPPDATA%\ClaudeTabNotifierPOC\`.
2. בתחילת session של CMD, לפני הרצת `claude`, הריצו:
   ```
   %LOCALAPPDATA%\ClaudeTabNotifierPOC\watcher-cmd.cmd
   ```

זוהי מגבלה ידועה ומתועדת של הגרסה הנוכחית, לא באג.

## הגדרת `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`

Claude Code מנהל בעצמו את כותרת הקונסולה — ספינר (אנימציית טעינה) בזמן עבודה, וכותרת סיכום כשהוא מסיים — וזה "מתחרה" (race condition) עם הכתיבה של ה-watcher לאותה כותרת סביב אותו hook (`Stop`); מי שכותב אחרון "מנצח", בצורה לא דטרמיניסטית. קביעת `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (מה שה-installer עושה אוטומטית, בתוך בלוק ה-`env` ב-`settings.json`) עוצרת את Claude Code מלגעת בכותרת בכלל, ומשאירה את ה-watcher כבעלים הבלעדי שלה.

המשתנה הזה **אינו** חלק מהתיעוד הרשמי של Claude Code — הוא עלה בפומבי בהצהרה של מהנדס מ-Anthropic, ויש לפחות רגרסיה מדווחת אחת שספציפית ל-Windows ([anthropics/claude-code#16572](https://github.com/anthropics/claude-code/issues/16572)). ה-hook כותב אזהרה לקובץ `~/.claude/tools/claudeattention.log` בכל הפעלה שלו, אם הוא לא רואה שהמשתנה הזה מוגדר ל-`"1"` בסביבה של עצמו — כך שאם תהיה רגרסיה בעתיד, היא תהיה גלויה בלוג ולא תיצור race מחדש בשקט.

## הסרת ההתקנה (uninstall.ps1)

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1
```

מסיר בדיוק את מה שה-installer הוסיף:
- שלושת ה-hooks מתוך `settings.json` (כלום אחר בקובץ הזה לא נוגע).
- `env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE` — **משוחזר לערך שהיה לו לפני ההתקנה**, אם הוא היה קיים קודם; או מוסר לחלוטין, אם ה-installer הוא זה שהוסיף אותו מאפס. המידע הזה נשמר במניפסט התקנה (install manifest), כך שההסרה לעולם לא "מנחשת".
- הבלוק להפעלה אוטומטית מתוך `$PROFILE` (כלום אחר בקובץ הזה לא נוגע).
- קובץ ה-hook, סקריפט ה-watcher, קובצי הצליל, וקובץ ה-config שנפרסו.
- קובץ המניפסט עצמו, ותיקיית ההתקנה — אם היא נשארת ריקה.

מצב זמן-ריצה (runtime state) תחת `%LOCALAPPDATA%\ClaudeTabNotifier\state\` (heartbeats, לוגים לכל session, לוג הניקוי) **נשאר ללא שינוי** — זהו מידע דיבאג, לא קובץ מותקן, והוא מתנקה מעצמו עם הזמן דרך מנגנון ניקוי התהליכים היתומים המובנה בכל watcher.

## פתרון בעיות (Troubleshooting)

- **הסימון אף פעם לא מופיע:** ודאו שאתם ב-Windows Terminal, לא ב-`conhost.exe` או בטרמינל אחר — בדקו ש-`$env:WT_SESSION` מוגדר. ודאו שה-watcher רץ (טאב PowerShell חדש אמור להדפיס באנר קצר של פתיחה, מיד לאחר ההתקנה).
- **הסימון "עולה" ואז נעלם/נדרס:** בדקו בקובץ `~/.claude/tools/claudeattention.log` אם מופיעה שורת `WARNING: CLAUDE_CODE_DISABLE_TERMINAL_TITLE=...` — אם כן, המשתנה לא נכנס לתוקף (ייתכן שמדובר ברגרסיה בגרסת Claude Code; ראו הקישור למעלה).
- **אין צליל:** ודאו ש-`soundEnabled` מוגדר ל-`true` בתוך `config.json`, ושקובץ הצליל הנבחר קיים. הריצו `test-sound.ps1` כדי לבדוק זאת בנפרד מה-watcher. בדקו את ה-log הפרטי לכל session בנתיב `%LOCALAPPDATA%\ClaudeTabNotifier\state\_watcherlog_<WT_SESSION>.txt`, וחפשו שורות `sound SKIPPED` או `sound FAILED`.
- **שגיאת Execution Policy / "not digitally signed":** ראו את הסעיף [מה עושים אם PowerShell חוסם את הסקריפט](#מה-עושים-אם-powershell-חוסם-את-הסקריפט) למעלה.
- **אבחון כללי:** כל session של watcher כותב log פרטי משלו לנתיב `%LOCALAPPDATA%\ClaudeTabNotifier\state\_watcherlog_<WT_SESSION>.txt`, וסריקת הניקוי החוצה-sessions כותבת ל-`_cleanup.log` באותה תיקייה. ה-hook עצמו כותב log לכל הפעלה שלו לתוך `~/.claude/tools/claudeattention.log`.

## פיתוח ובדיקות

נדרש [Pester](https://pester.dev/) (הגרסה המובנית שמגיעה עם Windows PowerShell 5.1 — ה-test suite משתמש בתחביר הישן שלה, `Should Be`, ולא בתחביר המודרני `Should -Be`).

```powershell
.\tests\RunAll.ps1
```

מריץ את כל ה-suite: `HookExe.Tests.ps1`, `WatcherCore.Tests.ps1`, `OrphanCleanup.Tests.ps1`, `ConcurrentSessions.Tests.ps1`, `LogRotation.Tests.ps1`, `InstallUninstall.Tests.ps1`. כל הבדיקות רצות מול נתיבי sandbox מבודדים (`%LOCALAPPDATA%` מדומה, `~/.claude/settings.json` מדומה, `$PROFILE` מדומה) — שום דבר לא נוגע בסביבה האמיתית שלכם. כל בדיקה מנקה את התהליכים והקבצים שלה בעצמה, גם במקרה של כישלון.

**נבדק ה-suite האוטומטי המלא, במצב סופי מאומת: 78/78 בדיקות עוברות (78 passed, 0 failed).**

**מכוסה על ידי הבדיקות האוטומטיות:** ניתוח ה-payload של ה-hook וכתיבת state, מיפוי WT_SESSION ל-state, מחזור החיים המלא mark → clear → mark, מניעת כפילויות (deduplication — אין צליל/כתיבת כותרת חוזרת עבור מצב שלא השתנה), כל 10 הצלילים המובנים בתוספת קבצי צליל מותאמים-אישית/חסרים/פגומים, `config.json` חסר/פגום, קבצי state חסרים/פגומים, ניקוי תהליכים מתים חוצה-sessions עם אימות זהות בטוח מפני שימוש חוזר ב-PID, סגירה עצמית של תהליכי CMD יתומים, לוג הניקוי, מבנה קובץ ה-heartbeat, סבב לוגים (log rotation) בתקרה של 1MB, זיהוי `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`, מספר sessions מקבילים ללא זליגה בין sessions, והתנהגות ה-installer/uninstaller (התקנה ראשונית, התקנה חוזרת אידמפוטנטית, גיבוי ושימור תוכן לא-קשור ב-settings/profile, שחזור מבוסס-מניפסט של משתנה הסביבה) — **וכן** תיקון ה-Mark of the Web (ראו [מה עושים אם PowerShell חוסם את הסקריפט](#מה-עושים-אם-powershell-חוסם-את-הסקריפט)).

**לא מכוסה על ידי הבדיקות האוטומטיות** (מטבען דורשות סביבה אמיתית): הופעה חזותית בפועל של ה-`✨` בטאב אמיתי של Windows Terminal, שמיעת הצליל בפועל, אספקת `WT_SESSION` בפועל על ידי Windows Terminal עצמו, הפעלת ה-hook בפועל על ידי session אמיתי של `claude`, והפעלה אוטומטית של `$PROFILE` ב-shell אינטראקטיבי אמיתי וטרי. כל אלה **אומתו ידנית בסביבת Windows Terminal אמיתית** (הפעלה אוטומטית בטאב טרי, חיווט אמיתי של ה-hook/`WT_SESSION`, מחזור החיים המלא mark → sound → clear → mark, ושני טאבים מקבילים ללא זליגה ביניהם) — הן נשארות מחוץ ל-suite האוטומטי מעצם טבען, לא מפני שהן לא אומתו.

## הפרויקט ב-GitHub

[github.com/shirtwig/claude-tab-notifier](https://github.com/shirtwig/claude-tab-notifier)

## רישיון (License)

הפרויקט מופץ תחת רישיון **MIT** — ראו את הקובץ [LICENSE](LICENSE) בשורש ה-repository לנוסח המלא.

### אחריות

התוכנה מסופקת כפי שהיא (AS IS), ללא התחייבות שהיא תהיה נקייה מתקלות או תתאים לכל סביבה. השימוש בתוכנה הוא באחריות המשתמש. לפרטים נוספים, יש לעיין בתנאי רישיון ה-MIT המצורף לפרויקט.
