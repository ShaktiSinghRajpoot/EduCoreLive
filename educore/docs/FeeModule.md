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
| `core.fee_payments` | One **receipt header** per collection (`amount`, `payment_mode`, `concession_total`, discount + advance metadata, cancel metadata). | The receipt record + audit of who/when. |
| `core.fee_payment_details` | One **line per receipt** (`ledger_id`, amount, concession, `line_type` = Due/Extra). | Lets a receipt re-print and reverse exactly what it paid. |
| `core.fee_payment_tenders` | One row per **payment mode** on a receipt (Cash/UPI/Advance…). | Split tender — a Cash+UPI receipt is recorded faithfully. |
| `core.fee_refunds` | A **refund voucher** (`RFD-YYYY-NNNN`, amount, mode, reason, authoriser). | Money returned (deposit / overpayment) is auditable. |
| `core.student_advance` | One **wallet balance** per student. | Advance / credit carried forward. |
| `core.fee_day_close` | One **day-close** row per cashier per day (expected vs counted cash). | Shift reconciliation. |
| `core.receipt_counters` | Per (tenant, school, financial-year) receipt sequence. | Receipt numbers `RCP-YYYY-NNNN`. |
| `core.v_fee_tender_lines` | **View**: expands each receipt into one row per mode (falls back to header mode when no tenders). | So Day Close & Reports break down by the **true** mode, not "Mixed". |

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
**required reason**. It spreads across the picked dues as per-line concession, and the
**type + value + reason** are stored on `fee_payments` (`discount_type`,
`discount_value`, `discount_reason`) and printed on the receipt.
**Why:** a discount must be auditable — *who* gave *what* and *why*, not a bare number.

### 3.3 Extra charges (modal) — built in `fee_collection_extras.sql` (pre-existing) + UI
**What:** an **Add extra charge** modal (name + amount + note) → stored as receipt
detail lines with `line_type = 'Extra'`.
**Why:** ad-hoc charges at the counter (late fine, lost book, ID card) without
touching the fee-head catalogue.

### 3.4 Split tender — `fee_payment_tenders.sql`
**What:** a receipt can be paid with **several modes** (₹5000 Cash + ₹5000 UPI). Each
mode+amount is stored; the header mode becomes the lone mode or **`Mixed`**. The proc
**validates the split sums to the cash collected**.
**Why:** real parents pay part cash, part UPI. Day Close and Reports now show the
**true** mode split (via `v_fee_tender_lines`), so cash reconciliation is correct.

### 3.5 Advance / credit wallet — `fee_advance.sql`
**What:** `core.student_advance` holds one balance per student. On collect:
- **Overpay** → the surplus is **credited** to the wallet (`advance_credit`).
- **Use advance** → `advance_used` **debits** the wallet (capped at balance) and funds
  part of the bill (shown as a "Use advance" settlement line).
Both print on the receipt ("Paid from advance" / "Saved to advance").
**Why:** parents round up or prepay; the school must hold the credit and draw it down
later instead of losing or mishandling it.

### 3.6 Cancel / void receipt — `fee_receipt_cancel.sql`
**What:** from Payment History, **Cancel** a receipt with a **required reason +
authoriser**. It **reverses exactly what the receipt applied** to the ledger (gives
back cash + concession, re-opens the due) and marks the receipt **Cancelled** (kept on
record, still re-prints, shown struck-through).
**Why:** cashiers make mistakes daily (wrong student, duplicate). You must be able to
void same-day **without** deleting anything — the receipt stays for audit.

### 3.7 Refund — `fee_refund.sql`
**What:** from Payment History, **Refund** a paid amount (refundable **deposit** at TC
time, or an over-collection). Lists refundable charges (retained = `amount_paid −
refund_amount`), writes a **refund voucher**, and increments `refund_amount` so the
same money can't be refunded twice.
**Why:** money the school is holding must be returnable, capped, and auditable. A
refund is money **out** — it never creates a new due.

### 3.8 Day Close / shift reconciliation — `fee_day_close.sql` + `Views/Fee/DayClose.cshtml`
**What:** the cashier totals their day **mode-wise** (cancelled excluded), sees
**expected cash** (cash collected − cash refunded), enters **counted cash**, and the
**difference** (Short / Excess / Tallies) is recorded. One close per cashier per day.
**Why:** any school with a dedicated cashier reconciles the drawer at shift end; this
is the record accounts need.

### 3.9 Reports — `fee_reports.sql` + `fee_concession_cancel_report.sql` + `Views/Fee/Reports.cshtml`
Three tabs (CSV export + print):
- **Collection Register** — every receipt in a date range, **by mode** and **by fee
  head**. *Why:* the daily collection record accounts open first.
- **Defaulters / Outstanding** — students who owe, with **class-wise aging**
  (not-due / 0–30 / 31–60 / 60+). *Why:* follow-up list for unpaid fees.
- **Concessions & Cancellations** — discounts given + receipts voided, with reasons.
  *Why:* the audit trail for money given away or reversed.

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
| `sp_fee_payment_collect` | The collect engine: dues + extras + discount + split tender + advance → receipt + ledger update. (17 args; **exactly one overload**.) |
| `sp_student_dues_get` | A student's outstanding dues. |
| `sp_fee_payment_history_get` | Receipts for a student (incl. cancelled flag). |
| `sp_fee_receipt_get` | One receipt (header + lines) for re-print; payer-agnostic (student or enquiry). |
| `sp_fee_receipt_cancel` | Void a receipt + reverse its ledger. |
| `sp_student_refundables_get` / `sp_fee_refund_record` | List refundable amounts / record a refund. |
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
10. `fee_advance.sql`
11. `fee_concession_cancel_report.sql`

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
- Role-gating on discount/cancel/refund (currently any cashier; reason+authoriser captured).
