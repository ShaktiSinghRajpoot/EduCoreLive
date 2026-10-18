# WhatsApp messages to parents — setup

SmartSchoolWala sends absent alerts, fee reminders and notices from **one** WhatsApp Business
number (the platform's). Until that number is connected, every screen works in **test mode**:
messages are built, shown and saved in **Message Log** as "Test", and nothing is sent.

## 1. Get the number (once)
1. Create a Meta Business account and verify the business (business.facebook.com).
2. In Meta for Developers create an app → add **WhatsApp** → add the phone number the school
   messages should come from. (A number already used on the WhatsApp phone app must be removed
   from it first.)
3. Create a **permanent access token** (System User with `whatsapp_business_messaging`).
4. Note the number's **Phone number ID** (WhatsApp → API Setup).

## 2. Create the three templates (WhatsApp Manager → Message templates)
Category **Utility**, language as you like (the code goes in `Language` below). The body must be
exactly this, with the variables in this order:

| Name | Body |
|---|---|
| `absent_alert` | Dear Parent, {{1}} ({{2}}) was absent on {{3}}. Please inform the school if this is unexpected. - {{4}} |
| `fee_reminder` | Dear Parent, a fee of Rs {{1}} for {{2}} is due. Please pay at the earliest; ignore if already paid. - {{3}} |
| `school_notice` | {{1}}: {{2}} - {{3}} |

({{1}}… are filled by the app: student, class, date, school / amount, student, school /
school, notice title, notice text.) Other names are fine — put them in the settings.

## 3. Put the settings in Railway (Variables)
```
Notifications__WhatsApp__Enabled        = true
Notifications__WhatsApp__ApiKey         = <permanent access token>
Notifications__WhatsApp__PhoneNumberId  = <phone number ID>
Notifications__WhatsApp__FromNumber     = <the number, for display>
Notifications__WhatsApp__Language       = en        (the templates' language code)
# only if your template names differ:
Notifications__WhatsApp__AbsentTemplate = absent_alert
Notifications__WhatsApp__FeeTemplate    = fee_reminder
Notifications__WhatsApp__NoticeTemplate = school_notice
```
Never put the token in `appsettings.json` (it is committed). Railway redeploys on save.

## 4. Switch it on per school
Super Admin → Schools → **Modules** → **WhatsApp messages**. Off by default (every message costs
money). The page shows how many were sent this month.

## Where messages come from
- **Attendance** → Absent students → **Send to all parents** (from the saved register).
- **Fee Due Reminders** → tick WhatsApp (sends the `fee_reminder` template; the typed text is for SMS / email).
- **Notice Board** → **Send to parents** on a notice (its audience; one message per number).
- **Message Log** (admin) — every message: Sent / Failed (with Meta's reason) / Test / No number.

Code: `Services/Notifications/WhatsAppChannel.cs` (Meta Cloud API), `SchoolMessenger.cs`,
`EduCoreDataAccessLayer/Database/messaging.sql`.
