# EduCore — Fee Collection Module (what we built & why)

> Reference for the Fee Collection counter and everything around it, built up over
> 2026-06. Every section says **what** it is and **why** it exists. File paths are
> relative to the `educore` solution; SQL lives in `EduCoreDataAccessLayer/Database`.

---

## 1. The big idea

The Fee Collection counter (`ERP/Fee/ManageFee`) was redesigned from a **row-by-row
grid** (where the cashier typed an amount + concession on every due) into a
**POS-style "settlement" counter**:

- The cashier picks **what** to collect (a period, or ticks dues) on the left.
- **All the maths happens in one Settlement panel** on the right:
  `Dues − Discount + Extra = Payable`, funded by one or more payment modes.

**Why:** the old grid was slow and error-prone at a busy counter. A cashier should
think about *period → discount? → how much received*, not do per-row arithmetic.
The redesign matches how real school fee counters (and POS terminals) actually work,
and scales from a tiny school to a big one.

Everything is **multi-tenant** (`tenant_id > 1 AND school_id > 0` guard in every
proc) and uses **PostgreSQL stored procedures** via refcursors (no EF Core). Views
are warm-orange **educore-theme.css** (`ec-*` components). Razor runtime compilation
is on in Development, so **view edits hot-reload**, but **C# changes need a rebuild +
app restart**.

---

## 2. Data model (the tables that hold fee money)

| Table | What it holds | Why |
|---|---|---|
| `core.student_ledger` | One **charge** row per due (tuition Jul, transport Aug, deposit…) with `amount_due / amount_paid / concession / refund_amount / status`. | The single source of "what is owed". Outstanding = `amount_due − amount_paid − concession`. |
| `core.fee_payments` | One **receipt header** per collection (`amount`, `payment_mode`, `concession_total`, discount metadata incl. `discount_approved_by`, advance used/credit, cancel metadata, `client_ref`). | The receipt record + audit of who/when. `client_ref` (unique per school) makes a retried Collect return the first receipt. |
| `core.fee_payment_details` | One **line per receipt** (`ledger_id`, amount, concession, `line_type` = Due/Extra; an extra's note in `installment_label`). | Lets a receipt re-print and reverse exactly what it paid. One line per due (duplicate lines are merged). |
| `core.fee_payment_tenders` | One row per **payment mode** on a receipt (Cash/UPI/Cheque… with its cheque no / UPI ref, plus an `Advance` row for wallet money). Always a positive amount. | Split tender — a Cash+UPI receipt is recorded faithfully and reprints mode by mode. |
| `core.fee_refunds` | A **refund voucher** (`RFD-YYYY-NNNN`, one gapless sequence per school per year; amount, mode, reason, authoriser, who). `ledger_id` NULL = a refund of the advance wallet. | Money returned (deposit / overpayment / wallet at exit) is auditable. |
| `core.student_advance` | One **wallet balance** per student; never below zero (CHECK). | Advance / credit carried forward. |
| `core.fee_day_close` | One **day-close** row per cashier per day (expected vs counted cash); `reopened_at/by/reason` when re-opened. | Shift reconciliation; a closed day is locked (`core.fn_fee_day_closed`). |
| `core.fee_day_close_log` | Every **close and re-open** of a day (counts, who, when, reason). Never updated. | An earlier count is never overwritten. |
| `core.receipt_counters` | Per (tenant, school, financial-year) receipt sequence. | Receipt numbers `RCP-YYYY-NNNN`. |
| `core.v_fee_tender_lines` | **View**: expands each receipt into one row per mode (falls back to header mode when no tenders). | Simple per-receipt mode lines (used by tests and ad-hoc checks). |
| `core.fn_fee_money_lines(t, s, from, to)` | **Function**: every receipt (+, on its day, its cashier) and every cancellation (−, on the day it was cancelled, the canceller) as **tender** lines, plus a negative `To wallet` line for an overpaid surplus. Lines of a receipt sum to its settled `amount`; the `Cash` lines are the cash that crossed the counter. | The ONE source for Day Close, the Collection Register and the Dashboard money tiles, so they cannot disagree. |

---

## 3. Features built (what & why)

### 3.1 Settlement counter redesign — `Areas/ERP/Views/Fee/ManageFee.cshtml`
**What:** the search cascade (Session → Admission No → Class → Section → Student) is
unchanged; below it, a two-pane counter — dues on the left (period chips 1/3/6/12 +
clean selectable rows + Other dues), a sticky **Settlement** card on the right.
**Why:** speed and clarity; the cashier never edits a row, and the **Payable** is the
one number they read.

### 3.2 Discount (modal + persisted) — `fee_discount_meta.sql`
**What:** an **Add discount** modal — **Flat ₹ or Percentage %**, value, and a
**required reason** and a **required "Approved by"**. It spreads across the picked
dues as per-line concession, and the **type + value + reason + approver** are stored
on `fee_payments` (`discount_type`, `discount_value`, `discount_reason`,
`discount_approved_by`) and printed on the receipt.
The collect proc itself refuses a concession **without a reason**, and refuses any
concession on a **refundable deposit** (judged by the head's `is_refundable`, looked
up by `fee_head_id`) — a deposit is held to be given back, so waiving part of it
breaks the refund at exit.
**Why:** a discount must be auditable — *who* gave *what*, *why* and *who approved
it*, not a bare number.

### 3.3 Extra charges (modal) — built in `fee_collection_extras.sql` (pre-existing) + UI
**What:** an **Add extra charge** modal (name + amount + note) → stored as receipt
detail lines with `line_type = 'Extra'` (the note in the line's `installment_label`).
A receipt may consist of extras only (a lost ID card with no due ticked).
**Why:** ad-hoc charges at the counter (late fine, lost book, ID card) without
touching the fee-head catalogue.

### 3.4 Split tender — table/view in `fee_payment_tenders.sql`, rules in `fee_advance.sql`
**What:** a receipt can be paid with **several modes** (₹5000 Cash + ₹5000 UPI). Each
mode + amount + **reference** is stored (the counter asks for a cheque / DD number —
required — and a UPI / card / bank ref — optional); the header mode becomes the lone
mode or **`Mixed`**, and the header `reference_no` carries the tender references.
The proc **validates the split covers the amount settled**, refuses a **negative**
tender, refuses `Advance` as a tender mode (the wallet is drawn only through "Use
advance", which is checked against the balance), and refuses a cheque / DD without
its number. The reprint lists each mode with its reference instead of "Mixed".
**Why:** real parents pay part cash, part UPI. Day Close, the Collection Register and
the Dashboard show the **true** mode split through `core.fn_fee_money_lines`
(`fee_day_close.sql`), so cash reconciliation is correct.

*Correction (2026-10-10):* until that date this paragraph claimed the true split was
already used, but every report proc grouped by the header mode, so a Cash+UPI receipt
read "Mixed" and its cash was missing from Day Close's expected cash (an exact count
was recorded as "Excess"). Fixed; see `money_reports_dayclose_tests.sql` DC-10/11.

### 3.5 Advance / credit wallet — `fee_advance.sql`
**What:** `core.student_advance` holds one balance per student. On collect:
- **Overpay** → the surplus is **credited** to the wallet (`advance_credit`).
- **Use advance** → `advance_used` **debits** the wallet (capped at the balance **and**
  at the amount being settled) and funds part of the bill (shown as a "Use advance"
  settlement line).
Both print on the receipt ("Paid from advance" / "Saved to advance").
- **Refund at exit** → the wallet is listed in Refund as "Advance balance" and refunded
  with a voucher (`sp_fee_refund_record` with ledger id 0).
- A receipt whose credit has **already been spent** cannot be cancelled (the wallet
  would go negative); cancel the receipts that used it first. `chk_student_advance_balance`
  backs this up in the database.
**Why:** parents round up or prepay; the school must hold the credit and draw it down
— or give it back — instead of losing or mishandling it.

### 3.5a The collect engine's guarantees — `fee_advance.sql`
- The **student must belong to this school** (an extras-only receipt once never looked
  at a ledger row, so it was issued for any student id, even another school's).
- Lines for the **same due are merged**, and every due is **locked `FOR UPDATE`** before
  its outstanding is checked — two lines, two tabs or two counters can't over-collect.
- A **retry** carries the same `client_ref` (the counter makes one per settlement) and
  gets the first receipt back ("Already recorded as …") instead of a second payment.
- A counter that has **closed today** can't collect (`core.fn_fee_day_closed`).
- Database guards (`fee_money_guards.sql`): ledger amounts never negative, `paid +
  concession ≤ due`, `refunded ≤ paid`; tender lines positive; deleting a student can't
  cascade into their ledger or wallet.

### 3.6 Cancel / void receipt — `fee_receipt_cancel.sql`
**What:** from Payment History, **Cancel** a receipt with a **required reason +
authoriser**. It **reverses exactly what the receipt applied** to the ledger (gives
back cash + concession, re-opens the due, mirrors the wallet) and marks the receipt
**Cancelled** with `cancelled_by` / `cancelled_at` (kept on record, shown struck-through
in history with who/when/authoriser, and the reprint carries a **CANCELLED** banner).
It is **refused** when: a line's money has already been **refunded**; the advance it
credited has **been spent**; or the **canceller's today is closed** (the reversal
belongs to the day it is made — another cashier with an open drawer can cancel it).
A **registration** receipt: cancelling recomputes the enquiry's
`registration_fee_paid` from its live receipts, and if the family is already a
student, adds a **due** for the reversed amount on the student's ledger so it is chased.
**Why:** cashiers make mistakes daily (wrong student, duplicate). You must be able to
void **without** deleting anything — the receipt stays for audit.

### 3.7 Refund — `fee_refund.sql`
**What:** from Payment History, **Refund** a paid amount (refundable **deposit** at TC
time, an over-collection, or the **advance wallet** at exit). Lists refundable charges
(retained = `amount_paid − refund_amount`; refundability by the head's id) plus the
wallet, writes a **refund voucher** (`RFD-YYYY-NNNN`, gapless per school per year,
with reason + required authoriser + who), and increments `refund_amount` (or debits
the wallet) so the same money can't be refunded twice. Amounts with more than two
decimals are refused (0.004 once made a ₹0.00 voucher). A cashier whose today is
closed can't refund. Refund vouchers show in the student's **Payment History**
(`sp_fee_refund_history_get`) and re-print as a **Refund Voucher**.
**Why:** money the school is holding must be returnable, capped, and auditable. A
refund is money **out** — it never creates a new due.

### 3.8 Day Close / shift reconciliation — `fee_day_close.sql` + `Views/Fee/DayClose.cshtml`
**What:** the cashier totals their day **mode-wise by tender**, sees **expected
cash** (cash tendered − cash refunded), enters **counted cash**, and the
**difference** (Short / Excess / Tallies) is recorded. One close per cashier per day.
- **Cancel counts on the cancel day.** A receipt stays on the day it was issued; a
  cancellation is a negative line on the day it was cancelled, in the canceller's
  drawer. So a closed day's figures never change afterwards.
- **A closed day is locked.** `core.fn_fee_day_closed(tenant, school, user, date)`
  is what the collect / cancel procs check before taking or reversing money.
- **Re-open** (`sp_fee_day_reopen`, reason required) unlocks it; closing again
  writes a new count. Every close and re-open is kept in `core.fee_day_close_log`
  and shown as the page's close history. A future date can't be closed and the
  counted cash can't be negative.
**Why:** any school with a dedicated cashier reconciles the drawer at shift end; this
is the record accounts need, and it must not move after the cashier has signed it.

### 3.9 Reports — `fee_reports.sql` + `fee_concession_cancel_report.sql` + `Views/Fee/Reports.cshtml`
Three tabs (CSV export + print):
- **Collection Register** — receipts issued in a date range plus cancellations (as
  negative lines on the cancel day), **by true mode** and **by fee head**, filterable
  by class / section; refunds and **net**. A blank range is month to date, the same
  as the refund register. *Why:* the daily collection record accounts open first.
- **Defaulters / Outstanding** — what has **fallen due** and is unpaid, with aging
  (0–30 / 31–60 / 60+) and next instalments shown apart as "Not due". Students who
  left are listed while they owe (same rule as the Fee Due / reminders list and the
  Dashboard), and a registration fee part-paid before admission is its own row.
  *Why:* follow-up list for unpaid fees; a family that is up to date is not a defaulter.
- **Concessions & Cancellations** — counter concessions **and** registration
  discounts (with who gave them) + receipts voided (who cancelled, who had collected,
  authoriser, reason). CSV export. *Why:* the audit trail for money given away or reversed.

### 3.10 Cleanup — `fee_cleanup_unused.sql`
**What:** dropped the orphaned `sp_fee_payment_record` (lump-sum proc, no callers) and
a **stale `sp_fee_payment_collect` overload**; removed the dead C# wrapper and the
prototype `Test()` action/view.
**Why:** keep exactly one `sp_fee_payment_collect` overload (duplicate overloads break
name-based `CALL` resolution) and stop carrying dead code.

---

## 4. Stored procedures (current)

| Proc | Purpose |
|---|---|
| `sp_fee_payment_collect` | The collect engine (`fee_advance.sql`): dues + extras + discount + split tender + advance → receipt + ledger update. 19 args — `p_client_ref` and `p_discount_approved_by` come **after** `p_result` so positional callers keep working; **exactly one overload**. |
| `sp_student_dues_get` | A student's outstanding dues. |
| `sp_fee_payment_history_get` | Receipts for a student: cancelled flag, who collected, who cancelled + when + authoriser, advance used/credit. |
| `sp_fee_refund_history_get` | Refund vouchers for a student (charge or "Advance balance"), for the History tab. |
| `sp_fee_receipt_get` | One receipt (header + lines) for re-print; payer-agnostic (student or enquiry). Header also returns `is_cancelled` + cancel who/when/why, `collected_by`, `discount_amount`, `discount_approved_by` and `tenders` (JSON: mode, amount, reference). |
| `sp_fee_receipt_cancel` | Void a receipt + reverse its ledger and wallet (refusals in §3.6). |
| `sp_student_refundables_get` / `sp_fee_refund_record` | List refundable amounts (incl. the wallet) / record a refund (ledger id 0 = wallet). |
| `fn_ledger_head_refundable(ledger_id)` / `fn_user_display_name(user_id)` | Head refundability by id / a user's name for receipts and history. |
| `sp_student_advance_get` | A student's wallet balance. |
| `sp_fee_day_collection_get` / `sp_fee_day_close` | Day totals / record the close. |
| `sp_fee_collection_register` / `sp_fee_defaulters_get` / `sp_fee_concession_cancel_register` | The three reports. |
| `sp_registration_fee_record` | Registration fee against an enquiry (kept). |

---

## 5. Migrations — apply in this order

The collect proc is **drop-then-recreated** by several migrations (each adds params),
so order matters. Apply with psql against `educore`:

1. `fee_collection_full_flow.sql`  *(pre-existing — base collect/dues/history/receipt)*
2. `fee_collection_extras.sql`     *(pre-existing — extras + payer-agnostic receipt)*
3. `fee_receipt_cancel.sql`
4. `fee_refund.sql`
5. `fee_day_close.sql`
6. `fee_reports.sql`
7. `fee_cleanup_unused.sql`
8. `fee_discount_meta.sql`
9. `fee_payment_tenders.sql`
10. `fee_advance.sql`              *(owns the live collect + receipt reprint)*
11. `fee_concession_cancel_report.sql`
12. `fee_money_guards.sql`         *(CHECK constraints + no cascade from students; checks existing data first)*

`fee_refund.sql` and `fee_receipt_cancel.sql` call `core.fn_fee_day_closed`
(`fee_day_close.sql`) and `core.fn_user_display_name` (`fee_advance.sql`) at run time,
and `fn_ledger_head_refundable` reads `student_ledger.fee_head_id`
(`student_money_lifecycle.sql`). Re-running any of these files is safe.

All are **idempotent / safe to re-run** (`IF EXISTS`, `IF NOT EXISTS`, `CREATE OR
REPLACE`). After applying, **rebuild + restart** the app (C# changed).

Apply example:
```
PGPASSWORD=*** psql -U postgres -d educore -f EduCoreDataAccessLayer/Database/<file>.sql
```

---

## 6. Key code files

- **View:** `Areas/ERP/Views/Fee/ManageFee.cshtml` (counter), `DayClose.cshtml`, `Reports.cshtml`
- **Shared receipt:** `Views/Shared/_FeeReceiptModal.cshtml` + `wwwroot/js/fee-receipt.js`
- **Controller:** `Areas/ERP/Controllers/FeeController.cs`
- **Service:** `EduCoreDataAccessLayer/Services/.../Admin/FeePaymentService.cs` (+ `IFeePaymentService`)
- **Models:** `EduCoreDataAccessLayer/Models/Admin/FeeCollection.cs`

---

## 7. Design principles we held to

1. **One source of truth for what's owed** — the ledger; outstanding is always
   *derived*, never a stored "isPaid" flag.
2. **Nothing is edited or deleted** — cancel/refund/adjust leave the original record
   and post a reversing/voucher entry. Everything money-changing is auditable
   (who + when + reason).
3. **All maths in one Settlement panel** — the counter never makes the cashier do
   per-row arithmetic.
4. **Simple over clever** — lean procs, small models, reuse existing pages/components
   (e.g. reports are tabs, the receipt is one shared renderer).
5. **One overload per proc** — duplicate Postgres overloads break name-based `CALL`;
   migrations drop the old signature before creating the new one.

---

## 8. Still open (not built yet)

- Receipt **print formats** (A5 / 80mm thermal).
- **Online payment** (parent app / gateway) reconciling into the same ledger.
- **SMS / WhatsApp** due-reminders & receipt links.
- Role-gating on discount/cancel/refund (currently any cashier with `fees.manage`;
  reason + authoriser / approver are captured and required).
- The counter does not yet mark a **refundable** due in the dues list or keep the
  discount spread off it (the dues proc doesn't return the flag); the collect proc
  refuses a concession on a deposit with a clear message instead.
