# Test catalog: Money reports, Day Close, Defaulters, Reminders, Dashboard money

Pages: `/ERP/Fee/DayClose`, `/ERP/Fee/Reports` (Collection Register, Defaulters / Outstanding, Concessions & Cancellations), `/ERP/FeeDueReminders`, and the money tiles on the landing Dashboard.
SQL suite: `EduCoreDataAccessLayer/Database/tests/money_reports_dayclose_tests.sql`. A cell like `SQL DC-10` names a check in that suite.

First run (2026-10-10, local DB, rolled back): **83 passed, 31 failed**. All 31 failures are checks named `BUG ...`, which means they fail because of an app bug, not a test bug. No test rows leaked: students, enquiries, receipts, refunds, day closes, reminder rows and ledger rows were all checked after the run.

**Update (same day, phase 2 fixes).** Every bug in my area is fixed and the suite now asserts the corrected behaviour; the `BUG` prefixes are gone. Latest run: **138 passed, 2 failed**. The two red checks, DC-21 and DC-21a, belong to the collection owner: `sp_fee_receipt_cancel` must refuse when `core.fn_fee_day_closed(tenant, school, canceller, today)` is true. The Result column below still shows the state before the fixes.

What changed, and the rules the checks now hold the app to:
- **Money comes from the tenders.** `core.fn_fee_money_lines` (`fee_day_close.sql`) feeds Day Close, the Collection Register and the Dashboard, so cash is the cash handed over and there is no "Mixed" mode. Fixes DC-10, DC-11, DC-13, RPT-07 and DASH-04.
- **A cancel counts on the cancel day.**
  - The receipt stays on its own day.
  - The cancellation is a negative line on the day it was cancelled, in the canceller's drawer. On the register it shows as its own red row (RPT-03, DC-22..22e).
  - So a closed day's figure never changes (DC-22).
- **A closed day is locked.**
  - `core.fn_fee_day_closed` is called by the collect proc; DC-19 is green.
  - Closing a closed day again is refused (DC-24).
  - Re-open needs a reason (DC-24b..c). Re-close writes a new count (DC-24d).
  - `core.fee_day_close_log` keeps every close and re-open (DC-18b, DC-24e).
  - A future date and negative counted cash are refused (DC-25, DC-26).
- **Outstanding means "fallen due"**, with one rule for Defaulters, the Fee Due list, reminders and the Dashboard:
  - students who left are listed while they owe, marked with their status;
  - the "Not due" column shows next instalments apart.
  - Fixes DEF-06, DEF-08, DEF-09, DEF-11, DEF-13, REM-01 and REM-02.
  - A part-paid registration balance before admission is a `Registration` row on Defaulters (DEF-20).
- **Audit "who".**
  - The cancel register names who cancelled and who had collected (RPT-22).
  - The refund register names who refunded (RPT-23).
  - The concession register names who gave it (RPT-24) and now includes registration discounts (RPT-20).
- **Smaller fixes.**
  - Dashboard top-10 no longer multiplies by receipt count (DASH-06/07).
  - Recent receipts includes registration receipts (DASH-05).
  - The register shows the school's own registration head name (RPT-09).
  - Blank-range defaults agree across registers (RPT-29).
  - The register gained a class/section filter (RPT-12c/d).
  - The Defaulters section filter is case-insensitive (DEF-16).
  - The Concessions tab has CSV export.
  - The reminder log refuses another school's student (REM-07).
  - SendReminders and Export read the whole list in pages of 200 instead of one capped page (REM-08, REM-09).
  - DayClose's "school took ₹X at other counters" note never showed because the JSON lacked `schoolCollected`; it is returned now.
- **Not fixed:** DEF-21 (session filter on Defaulters). The ledger has no session column, so it would need an enrolment join. Left as a gap.

Abbreviations used in the citations:
- Ctl = `educore/Areas/ERP/Controllers/FeeController.cs`
- RemCtl = `educore/Areas/ERP/Controllers/FeeDueRemindersController.cs`
- Svc = `EduCoreDataAccessLayer/Services/Repository/ERP/FeePaymentService.cs`
- View DC = `educore/Areas/ERP/Views/Fee/DayClose.cshtml`, View RP = `.../Fee/Reports.cshtml`
- Procs (each checked against the live DB with `pg_get_functiondef`): `core.sp_fee_day_collection_get`, `core.sp_fee_day_close` (script `fee_day_close.sql`), `core.sp_fee_collection_register` + `core.sp_fee_defaulters_get` (`fee_reports.sql`), `core.sp_fee_refund_register` (`fee_refund_register.sql`), `core.sp_fee_concession_cancel_register` (`fee_concession_cancel_report.sql`), `core.sp_fee_due_list` (`fee_due_list.sql`), `core.sp_fee_reminder_record` / `core.sp_fee_reminder_history` (`fee_reminder_log.sql`), `core.sp_dashboard_summary` (`dashboard_summary.sql`). The live definitions match these scripts.

## Real-world scenario

**Sunrise Public School** (tenant 24 / school 34, session `FY 26-27`). Six children were admitted on 1 April with Tuition at 1,000 a month plus a one-time charge. Today is 10 October.

1. **The counter day (cashier A, user 39).**
   - **M1.** Admission fee 5,000 in cash, taken at admission.
   - **M2.** Apr+May tuition 2,000, paid as 1,200 cash and 800 UPI.
   - **M3.** Part payment: 3,000 by cheque against a 5,000 admission fee, plus a 500 sibling concession.
   - **M4.** The parent hands over 1,500 cash for a 1,000 due, so 500 goes to the wallet.
   - **M5.** The next month: 700 cash plus 300 from the wallet.
   - **M6.** A receipt taken from the wrong child, cancelled on the Principal's authority.
   - **M7.** A 2,000 deposit, then 500 refunded in cash and 200 by UPI.
   - **M8.** A registration fee on a walk-in enquiry: 900 cash plus a 100 staff-ward discount.
   - **M10.** One family pays everything it owes.
   - **M11.** Another family pays every instalment due so far by card.
2. **A second counter (cashier B)** takes 700 cash (M9).
3. **Yesterday** cashier A took 1,000 (M12) and closed the drawer.
4. **Evening.** Cashier A counts **10,800**, which is exactly right (11,300 cash in, 500 cash out), and closes the day.
5. **Principal.** Opens the dashboard and the defaulters list. One child (S6) has left with unpaid fees. Reminders go out: one by email (delivered), one by SMS (no provider).
6. **Afterwards.**
   - A late payment is taken into the closed day.
   - Yesterday's receipt is cancelled.
   - The cashier re-closes the day with a different count.
7. **Month end.** The auditor lays the Collection Register, Refund register, Concession & Cancellation register, Day Close sheets and Dashboard side by side.

What the run showed:

**Money in is reported consistently.** Collected total, register, dashboard "today", trend and school total all agree at **25,600**. Refunds net correctly to **24,900**. Cancelled receipts drop out everywhere and appear in the cancel register with reason, authoriser and time.

**Cash and payment mode are not.**
- **Expected cash is wrong.** Day Close reads the receipt header, not the tenders, so it says **9,400**. A correct count of 10,800 is recorded as **"Excess 1,400"**.
- **"Mixed" is shown as a payment mode** on Day Close, the register and the dashboard chart.

**A closed day is not locked.** Money can still be collected into it, and its receipts can be cancelled afterwards. The page total then disagrees with what was closed.

**The defaulters and due lists disagree with each other and overstate the debt.**
- A family that is fully up to date is listed as a defaulter because next months are unpaid.
- Reminder amounts include instalments that are not due yet.
- An exited student is on Defaulters but missing from the reminders list.
- The dashboard "Highest outstanding" multiplies each child's dues by their number of receipts.

## Reconciliation map

Each figure, the query that produces it, and the figures it must equal. ✔ = holds in the run. ✘ = broken (BUG id).

| Screen / figure | Produced by | Must equal | Status |
|---|---|---|---|
| Day Close · Collected | `sp_fee_day_collection_get` summary.total_collected (own `created_by`, live, `payment_date`=day) | Σ own live receipts.amount; mode-table sum; stored `fee_day_close.total_collected` at close time | ✔ DC-01, DC-06, DC-14 |
| Day Close · Receipts (+n cancelled) | summary.receipt_count / cancelled_count | own receipts that day / own receipts dated that day that are now cancelled | ✔ DC-02, DC-03 |
| Day Close · Refunds out | summary.total_refunded (own `refunded_by`, `refunded_at::date`) | own rows in the Refund register for the day | ✔ DC-04 |
| Day Close · Cash collected | summary.cash_collected = Σ amount WHERE **header** `payment_mode='Cash'` | Σ Cash tender lines (`v_fee_tender_lines`, mode Cash) | ✘ DC-10 (9,900 vs 11,300) |
| Day Close · Expected in drawer | C# `CashCollected − CashRefunded` (Svc:665) / proc v_expected | physical cash = cash tenders − cash refunds | ✘ DC-13 (difference 1,400 on a correct count) |
| Day Close · Collection by mode | modes cursor GROUP BY header mode | true split by tender (no "Mixed") | ✘ DC-11 |
| Day Close · scope note "school took ₹X" | summary.school_collected | Collection Register total for the day; Σ every cashier's Collected | ✔ DC-08, DC-09 |
| Day Close (closed) · page totals | live recompute | stored close row (frozen) | ✘ DC-20, DC-22 |
| Register · Collected | `sp_fee_collection_register` receipts Σ amount (settled on ledger, incl. registration) | Dashboard today (for 1 day); Σ Day Close Collected over cashiers; by-head Σ; by-mode Σ | ✔ RPT-01, RPT-05, RPT-06, DASH-01 |
| Register · Collected vs tenders | — | Collected + Σ advance_credit − Σ advance_used = Σ non-Advance tenders | ✔ RPT-08 |
| Register · By mode | modes cursor GROUP BY header mode | true split by tender | ✘ RPT-07 |
| Register · Discount column | concession_total + discount_amount | Concession register Σ for the same receipts | ✘ RPT-20 (registration discounts are missing from the concession register) |
| Register · Refunded / Net | `sp_fee_refund_register` Σ amount; Ctl:442 Net = Collected − Refunded | Day Close refunds over cashiers | ✔ RPT-13, RPT-16 |
| Register with blank range | collection: today; refunds: **month start..today** | same period | ✘ RPT-29 |
| Concession register | `concession_total > 0` on live receipts | every discount/concession given in range | ✘ RPT-20 |
| Cancel register | `is_cancelled` by `cancelled_at::date` | every void in range with who/when/why | ✔ RPT-21 for why, when and authoriser; ✘ RPT-22: the user who cancelled is not shown |
| Dashboard · Today's Collection | kpi.today_collection (live, `payment_date`=CURRENT_DATE) | register for today; trend last point | ✔ DASH-01, DASH-02 |
| Dashboard · Yesterday | kpi.yesterday_collection | register for yesterday | ✔ DASH-03 |
| Dashboard · Collection by mode (month) | GROUP BY header mode | tender split | ✘ DASH-04 |
| Dashboard · Recent receipts | INNER JOIN students | every live receipt counted in today | ✘ DASH-05 |
| Dashboard · Outstanding Due | Σ GREATEST(due−paid−conc,0) on ledger (all students, all instalments) | Defaulters total | ✔ DEF-10 |
| Dashboard · students pending | COUNT DISTINCT ledger students with balance | Defaulters count | ✔ DEF-12 |
| Dashboard · Highest outstanding | ledger ⨝ students ⟕ **fee_payments** | per-student ledger due / paid | ✘ DASH-06/07 (×receipts) |
| Defaulters · Outstanding | `sp_fee_defaulters_get` Σ ledger balance per student (incl. inactive, incl. not-yet-due) | Fee Due list; ledger | ✔ vs ledger (DEF-01); ✘ vs Fee Due (DEF-11/13) |
| Defaulters · aging | not_due + 0-30 + 31-60 + 60+ | Outstanding | ✔ DEF-04 |
| Fee Due list · Outstanding / sum / count | `sp_fee_due_list` (active only, incl. not-yet-due) | Defaulters; amount in the reminder message | ✘ DEF-08, DEF-11, DEF-13, REM-01/02 |
| Reminder log | `fee_reminder_log` (sent_by, sent_at, message, outstanding, status) | what was actually sent | ✔ REM-03..06 |

## Test table

Layer codes: P = stored procedure, C = controller, S = service, V = view, D = docs/config.

### Day Close (DC)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| DC-01 | Collected = own receipts | 9 live receipts by A today | 24,900 | P | SQL DC-01 | PASS |
| DC-02 | Receipt count | same | 9 (cancelled excluded) | P | SQL DC-02 | PASS |
| DC-03 | Cancelled count | M6 voided | +1 cancelled | P | SQL DC-03 | PASS |
| DC-04 | Refunds out | 500 Cash + 200 UPI | 700 | P | SQL DC-04 | PASS |
| DC-05 | Cash refunded | same | 500 (Cash only) | P | SQL DC-05 | PASS |
| DC-06 | Mode table sums | — | = Collected | P | SQL DC-06 | PASS |
| DC-07 | Per-cashier isolation | B took 700 | B sees 700 only | P | SQL DC-07 | PASS |
| DC-08 | A + B = school | — | 25,600 | P | SQL DC-08 | PASS |
| DC-09 | School = register | — | equal | P | SQL DC-09 | PASS |
| DC-10 | Cash collected = cash tendered | Mixed, overpay, part-wallet receipts | 11,300 | P | SQL DC-10; static `fee_day_close.sql:70,138` | **BUG** (9,900) |
| DC-11 | Mode table is the true split | Cash+UPI receipt | no "Mixed" row | P | SQL DC-11; `fee_day_close.sql:105,159` | **BUG** |
| DC-12 | Close succeeds | counted 10,800 | success | P | SQL DC-12 | PASS |
| DC-13 | Correct count reconciles | 11,300 − 500 counted | difference 0 | P | SQL DC-13 | **BUG** (+1,400 "Excess") |
| DC-14..16 | Stored close row | — | totals, refunds, mode breakup = page | P | SQL DC-14..16 | PASS |
| DC-17 | Close audit | — | closed_by, closed_at set | P | SQL DC-17 | PASS |
| DC-18 | Page shows closed | — | is_closed, counted | P | SQL DC-18 | PASS |
| DC-19 | Collect into a closed day | collect after close | refused | P | SQL DC-19 | **BUG** (accepted) |
| DC-20 | Closed day's page total stays | after DC-19 | 24,900 | P/V | SQL DC-20; View DC:135 shows stored difference next to live expected | **BUG** (25,900) |
| DC-21 | Cancel a closed day's receipt | close yesterday, cancel M12 today | refused (or posted to today) | P | SQL DC-21 | **BUG** |
| DC-22 | Closed figure never changes | after DC-21 | yesterday still 1,000 | P | SQL DC-22 | **BUG** (0) |
| DC-23 | Late cancel visible somewhere | — | in today's cancel register | P | SQL DC-23 | PASS |
| DC-24 | Re-close keeps history | close again with 1 | first count kept | P/V | SQL DC-24; `fee_day_close.sql:167` ON CONFLICT DO UPDATE; View DC:135 "Saving again updates it" | **BUG** |
| DC-25 | Future date close | close tomorrow | refused | P | SQL DC-25 | **BUG** |
| DC-26 | Negative counted cash | -500 | refused | P | SQL DC-26 (view has `min=0`, proc/controller don't check) | **BUG** |
| DC-27 | Close permission | — | CloseDay needs `fees.manage` + CSRF; GetDayCollection needs `fees.view` | C | static Ctl:385-388, 361 | PASS |
| DC-28 | Day Close is per cashier by design | — | page says "Your own counter"; zero is explained | V | static View DC:25, 125-130 | PASS |

### Registers (RPT)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| RPT-01 | Register total | today | 25,600 | P | SQL RPT-01 | PASS |
| RPT-02 | Lists every live receipt | 10 receipts incl. registration | 10 | P | SQL RPT-02 | PASS |
| RPT-03 | Cancelled excluded | M6 | absent | P | SQL RPT-03 | PASS |
| RPT-04 | Other day excluded | M12 | absent | P | SQL RPT-04 | PASS |
| RPT-05 | By-head Σ = total | incl. registration (no detail lines) | equal | P | SQL RPT-05 | PASS |
| RPT-06 | By-mode Σ = total | — | equal | P | SQL RPT-06 | PASS |
| RPT-07 | By-mode is the true split | — | no "Mixed" | P | SQL RPT-07; `fee_reports.sql:80` | **BUG** |
| RPT-08 | Collected ↔ tenders identity | wallet credit/use | Collected + credit − used = tenders | P | SQL RPT-08 | PASS |
| RPT-09 | Registration row labelled | enquiry, not admitted | name, type, "Registration Fee" | P | SQL RPT-09 | PASS |
| RPT-10/11 | Discount column | concession 500; reg discount 100 | shown | P | SQL RPT-10/11 | PASS |
| RPT-12 | Wallet-funded receipt amount | M5 | 1,000 settled | P | SQL RPT-12 | PASS |
| RPT-13..15 | Refund register | 2 refunds | 700; who/why/head; mode split | P | SQL RPT-13..15 | PASS |
| RPT-16 | Net | — | Collected − Refunded | C | SQL RPT-16; Ctl:442 | PASS |
| RPT-17/18 | Refund keeps the receipt | — | receipt 2,000; retained 1,300 | P | SQL RPT-17/18 | PASS |
| RPT-19 | Concession register | M3 | 500, Flat, reason | P | SQL RPT-19 | PASS |
| RPT-20 | Registration discount in concession register | M8 discount 100 | listed | P | SQL RPT-20; `fee_concession_cancel_report.sql:38` filters `concession_total > 0`, registration writes `discount_amount` | **BUG** |
| RPT-21 | Cancel register why/when/authoriser | M6 | all present | P | SQL RPT-21 | PASS |
| RPT-22 | Cancel register names the user | — | `cancelled_by` shown | P/V | SQL RPT-22; `fee_concession_cancel_report.sql:44` | **BUG** |
| RPT-23 | Refund register names the user | — | `refunded_by` shown | P | SQL RPT-23 | **BUG** |
| RPT-24 | Concession register names the user | — | `created_by` shown | P | SQL RPT-24 | **BUG** |
| RPT-25 | User is stored | — | cancelled_by = 39 | P | SQL RPT-25 | PASS |
| RPT-26..28 | Range inclusive / backwards | — | inclusive; from>to = empty | P | SQL RPT-26..28 | PASS |
| RPT-29 | Blank range same in both registers | NULL from/to | same period | P/C | SQL RPT-29; `fee_refund_register.sql:33` vs collection register's CURRENT_DATE; Ctl:426-442 nets them | **BUG** (low; page always sends dates) |
| RPT-30 | Cancel after refund | refund 820, then cancel deposit receipt | refused | P | SQL RPT-30; `fee_receipt_cancel.sql` never checks `refund_amount` | **BUG** (retained goes to -820) |
| RPT-31 | Session / class / section filter on the Collection Register | — | available | V/C/P | static: View RP:40-41 has dates only; Ctl:426 takes from/to only | GAP |
| RPT-32 | Concession & Cancellation tab export | — | CSV like other tabs | V | static View RP:135 (print only, no CSV button) | GAP |
| RPT-33 | CSV = screen | register/refund/defaulters CSV | built from the same JSON rows as the table | V | static View RP:237, 230, 260 | PASS |
| RPT-34 | Docs agree with code | FeeModule.md 3.4 says Day Close & Reports use `v_fee_tender_lines` | true | D | static `docs/FeeModule.md:74`; no live proc reads the view | **BUG** (doc wrong; root of DC-10) |

### Dashboard (DASH)

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| DASH-01 | Today's Collection | = register today | P | SQL DASH-01 | PASS |
| DASH-02 | Trend last point | = Today's | P | SQL DASH-02 | PASS |
| DASH-03 | Yesterday | = register yesterday | P | SQL DASH-03 | PASS |
| DASH-04 | Mode chart | no "Mixed" | P | SQL DASH-04; `dashboard_summary.sql:148` | **BUG** |
| DASH-05 | Recent receipts include registration | listed | P | SQL DASH-05; `dashboard_summary.sql:173` INNER JOIN | **BUG** (low) |
| DASH-06/07 | Highest outstanding due/paid | = ledger | P | SQL DASH-06/07; `dashboard_summary.sql:160` LEFT JOIN fee_payments fans out | **BUG** (27,000 vs 9,000) |
| DASH-08 | Outstanding / students pending | = Defaulters | P | SQL DEF-10, DEF-12 | PASS |

### Defaulters / Fee Due list (DEF)

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| DEF-01 | Both lists = ledger due − paid − concession | per student | P | SQL DEF-01 | PASS |
| DEF-02 | Part payment leaves balance | 1,500 | P | SQL DEF-02 | PASS |
| DEF-03 | Cancel reopens due; refund adds none | 1,000 | P | SQL DEF-03 | PASS |
| DEF-04 | Aging buckets add up | — | P | SQL DEF-04 | PASS |
| DEF-05 | Paid-up student absent | S4 | P | SQL DEF-05 | PASS |
| DEF-06 | Up-to-date student not a defaulter | S5 (all due paid, Nov..Mar future) | P | SQL DEF-06; `fee_reports.sql:135` counts not-yet-due rows | **BUG** |
| DEF-07 | Exited debtor on Defaulters | S6 | P | SQL DEF-07 | PASS |
| DEF-08 | Exited debtor on Fee Due list | listed (so it can be chased) | P | SQL DEF-08; `fee_due_list.sql:69` `is_active` | **BUG** |
| DEF-09 | Exited student not billed after leaving | 7,000 (Apr..Oct) | P | SQL DEF-09; `sp_student_exit` leaves future rows | **BUG** (12,000) |
| DEF-10 | Dashboard Outstanding = Defaulters | — | P | SQL DEF-10 | PASS |
| DEF-11 | Fee Due total = Defaulters | — | P | SQL DEF-11 | **BUG** |
| DEF-12 | Dashboard pending = Defaulters count | — | P | SQL DEF-12 | PASS |
| DEF-13 | Fee Due count = Defaulters count | — | P | SQL DEF-13 | **BUG** |
| DEF-14..19 | Class, section, search, bucket filters | correct rows | P | SQL DEF-14..19 | PASS |
| DEF-20 | Part-paid registration balance visible | 400 shown somewhere | P | SQL DEF-20 | **BUG** (low) |
| DEF-21 | Session filter on Defaulters | — | V/P | static: Ctl:511 class/section only; ledger across all sessions | GAP |
| DEF-22 | Section filter matching | case-insensitive / dropdown | V | static View RP:103 free-text exact match | GAP (low) |

### Reminders (REM)

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| REM-01/02 | `{due_amount}` = what has fallen due | S5 = 0; S1 = 4,000 | P/C | SQL REM-01/02; RemCtl FillTokens uses total_outstanding | **BUG** (5,000 / 9,000) |
| REM-03 | Log who/when/what/amount/channel | all stored | P | SQL REM-03 | PASS |
| REM-04 | History shows attempts with names | — | P | SQL REM-04 | PASS |
| REM-05 | Sent today counts delivered only | +1 | P | SQL REM-05 | PASS |
| REM-06 | Last reminder = delivered only | S1 set, S2 blank | P | SQL REM-06 | PASS |
| REM-07 | Log refuses other school's student | refused | P | SQL REM-07; `fee_reminder_log.sql:60` | **BUG** (low; controller re-reads, so not reachable from the UI) |
| REM-08 | SendReminders finds every selected student | small debtor found | C | SQL REM-08 reproduces the lookup; RemCtl:89-91 | **BUG** |
| REM-09 | Export = whole filter | all rows | C/S | static RemCtl:163 sets 10,000 but ListModelBase.cs:28 clamps to 200 | **BUG** (also caps the REM-08 lookup) |
| REM-10 | Amount/recipient from server, not client | yes | C | static RemCtl:86-91, 101 | PASS |
| REM-11 | Permissions | Index/Export `fees.view`; Send `fees.manage` + CSRF | C | static RemCtl:14, 72-73 | PASS |

### Day boundary (TZ) and scope (SC)

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| TZ-01..03 | DB clock = school clock | Asia/Kolkata at session and database level; CURRENT_DATE = IST date | D | SQL TZ-01..03 | PASS |
| TZ-04 | Receipt stamped with school date | today IST | P | SQL TZ-04 | PASS |
| TZ-05/06 | 23:30 IST refund → yesterday; 00:15 IST → today | — | P | SQL TZ-05/06 | PASS |
| TZ-07 | Drawer of that day carries it | — | P | SQL TZ-07 | PASS |
| TZ-08 | Fragility note | a UTC session would move 00:15 to yesterday; correct only because of the DB-level `TimeZone` (school_timezone.sql) — Npgsql sets no Timezone | D | SQL TZ-08 | PASS (documented) |
| TZ-09 | App clock | `Dates.Today` = +05:30 | S | static `Helpers/Dates.cs:44-47`; pages default the date from the browser (View DC:102-103) | PASS |
| SC-01..07 | Another school sees none of our money | — | P | SQL SC-01..07 | PASS |
| SC-08 | Platform tenant refused | 8 procs raise | P | SQL SC-08 | PASS |
| SC-09 | Platform dashboard | zeros | P | SQL SC-09 | PASS |
| SC-10 | Fixture rows only on school 34 | — | P | SQL SC-10 | PASS |
| SC-11 | Ids come from claims | Ctl/RemCtl TenantId()/SchoolId()/UserId() | C | static Ctl:674-676 | PASS |
