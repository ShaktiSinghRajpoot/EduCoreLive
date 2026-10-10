# Fee collection core: money history test cases

**Scope:** the Fee Collection counter (`Areas/ERP/Views/Fee/ManageFee.cshtml`), `FeeController`
(ManageFee, Collect, FindByAdmission, GetStudents, GetStudentDues, GetHistory, GetReceipt,
CancelReceipt, Refund, GetRefundables, GetAdvance, SaveReceiptFormat), `FeePaymentService`, and the
live procedures behind them: `sp_fee_payment_collect`, `sp_fee_receipt_cancel`,
`sp_fee_refund_record`, `sp_student_refundables_get`, `sp_student_advance_get`,
`sp_student_dues_get`, `sp_fee_payment_history_get`, `sp_fee_receipt_get`, `fn_receipt_year`,
`sp_school_receipt_format_manage`, plus `sp_fee_day_collection_get` / `sp_fee_day_close` /
`sp_fee_collection_register` / `sp_fee_concession_cancel_register`, to check that the reports agree.

**The requirement under test:** wherever money is taken, refunded, cancelled, waived, discounted,
carried forward as advance, or reversed, there has to be a lasting **history** of who, when, how
much, which mode or tender, the receipt number, the student and the fee head. Nothing may be
silently hard-deleted or overwritten. The history must be visible in the UI (student fee history,
receipt reprint) and must agree with day close and the reports.

**Suite:** `EduCoreDataAccessLayer/Database/tests/money_fee_collection_tests.sql`. Fixture is
tenant 24 / school 34 / user 39, with 23 / 33 as the other school. It runs in one transaction and
rolls back. Probes that would damage the fixture when a bug is present run in a sub-block that is
always undone.

**Live definitions were confirmed with `pg_get_functiondef`** (2026-10-10, local PG 16). Which
script holds each live proc: collect + receipt reprint = `fee_advance.sql`; cancel + history =
`fee_receipt_cancel.sql`; refund = `fee_refund.sql`; day close = `fee_day_close.sql`; register =
`fee_reports.sql`.

**Phase 1 run (test only):** `RESULT: 73 passed, 27 failed (27 of them BUG-marked)`.

**Phase 2 run (after the fixes, 2026-10-10):** `RESULT: 122 passed, 0 failed (0 of them BUG-marked)`.
Every bug below is fixed and its check now asserts the fixed behaviour (the "BUG" prefix is gone).
New checks were added for the fixes themselves (COL-04b, COL-19/19b, COL-24, COL-25, RCP-06b,
RCP-09, CAN-02c/d, CAN-12a/b/c, CAN-14, CAN-15, ADV-09a–c, ADV-10, ADV-11, REF-14, SEC-05/06,
DAY-07, TRL-03a/b). No rows leak. The tables below still describe each case and say **BUG** where
Phase 1 found one. The fix for each is listed here:

| Phase 1 bug | Fixed in |
|---|---|
| COL-04 duplicate due lines, COL-18 concurrency | `fee_advance.sql` collect: lines merged per ledger id, rows locked `FOR UPDATE` in id order, running total re-checked |
| COL-10 negative tender, COL-11 `Advance` tender | `fee_advance.sql` collect: both refused |
| COL-12/13 extras-only receipt for a foreign/ghost student | `fee_advance.sql` collect: student must belong to the school |
| COL-19 retry duplicates | `client_ref` on `fee_payments` (unique per school) + counter sends one per settlement |
| COL-20 extras-only impossible | `FeeController.Collect` no longer requires dues |
| CON-02 no reason, CON-03 no approver, CON-06 concession on deposit | collect refuses no-reason / deposit concession (head by `fee_head_id`); `discount_approved_by` column + required "Approved by" in the modal |
| ADV-04 advance beyond the bill | collect refuses it |
| ADV-06 cancel after credit spent, ADV-08 negative wallet | `fee_receipt_cancel.sql` refuses; `chk_student_advance_balance` (`fee_money_guards.sql`) |
| ADV-09 wallet not refundable | `fee_refund.sql`: wallet in refundables, refunded with ledger id 0; Refund modal offers it |
| REF-08 0.00 voucher, REF-14 global numbering | `fee_refund.sql`: max two decimals; per-school per-year `RFD-YYYY-NNNN` |
| REF-09 cancel after refund | `fee_receipt_cancel.sql` refuses |
| REF-10/16 refunds invisible, no voucher reprint | `sp_fee_refund_history_get`; History tab lists refunds; `EcReceipt.showRefund` prints a voucher |
| RCP-04/05/06 reprint: cancelled / cashier / tenders | `sp_fee_receipt_get` header + `fee-receipt.js` (CANCELLED banner, cashier, mode-by-mode with refs) |
| CAN-08 history who/when | `sp_fee_payment_history_get` + History tab |
| CAN-12 cancel after close | user decision: a reversal counts on the cancel day; a cashier whose today is closed can't cancel or refund (`fn_fee_day_closed`); collecting after close is refused (DAY-07) |
| STA-02 no cheque/UPI reference | per-tender reference input; cheque / DD number required (UI + proc) |
| STA-04 extra note dropped | sent and kept on the receipt line |
| TRL-02 cascade, TRL-03 no DB guards | `fee_money_guards.sql`: ledger/advance FKs RESTRICT; ledger amount CHECK; tender CHECK |
| DAY-01..04, DAY-06 | the reports agent's `fee_day_close.sql` / `fee_reports.sql` (tender-based money lines, close log) |
| — registration receipt cancel | flag recomputed from live receipts; after admission a reversal due is raised (CAN-14/15) |
| STA-05 refundable tag on dues | **not fixed**: needs the dues proc (`student_dues.sql`, another owner) to return the flag |
| SEC-05 one permission for everything | left to the coordinator (`[HasPermission]` attributes) |

---

## 1. Real-world scenario: a busy April morning at the counter

| # | What happens | What must be left behind | Checks |
|---|---|---|---|
| 1 | **Mrs Sharma pays April-June tuition for Aarav**: ₹2000 cash plus ₹1000 by UPI (ref UPI-778899). | One receipt, RCP-2026-0001, for ₹3000. Mode reads Mixed. Two tender rows (Cash 2000, UPI 1000 + ref). Three receipt lines, each naming its ledger row. Three months Paid. Cashier and time stamped. | COL-01a..g, COL-02 |
| 2 | Day close for that receipt. | Expected cash in the drawer goes up by **2000**. | **DAY-01 FAILS**: it goes up by 0, because the receipt mode is "Mixed". |
| 3 | **Mr Khan can pay only ₹400 of July**, and brings the rest later. | July goes Partial with 600 left. The next receipt pays 600. Both receipts trace to the July row. Numbers are consecutive. | COL-03a..c |
| 4 | **A ₹4700 cheque bounces** (it paid a 600 month, a 5000 admission charge minus a ₹1000 staff-ward concession, and a ₹100 ID card). It gets cancelled. | Every ledger row goes back exactly. The receipt stays, marked Cancelled with reason, who, when and authoriser, its lines and tender intact. The number is never reused. | CAN-01, 02a/b, 04, 11 |
| 5 | The cheque number on that receipt. | The cheque number and bank are recorded so the bounce can be matched. | **STA-02**: the counter UI has no reference field at all. The suite passed the reference straight to the proc. |
| 6 | **Sibling concession**: ₹300 flat across three months, reason "Sibling concession". | The receipt is for cash only (2700). Concession is 300 with type, value and reason. It sits on the waived ledger row and appears in the concession register. | CON-01a..c |
| 7 | Who approved it? | An approver is recorded. | **CON-03 FAILS**: there is no approver column. A concession with *no reason* is accepted by the proc (**CON-02**). |
| 8 | **Over-payment**: a parent hands ₹2500 for a ₹1000 month. | Credit of 1500 on the receipt and in the wallet. Day close expects 2500 cash. | ADV-01 passes. **DAY-02 FAILS**: day close expects only 1000. |
| 9 | Next month is paid from the wallet, then the following month by wallet 400 + cash 600. | An Advance tender row, the wallet drawn down, and day close expecting **600** cash. | ADV-02, ADV-05 pass. **DAY-03 FAILS**: day close expects 1000. |
| 10 | The over-payment cheque later bounces and the receipt is cancelled, after its credit was spent. | The cancel is refused, or the dependent receipts are reversed. The wallet never goes below 0. | **ADV-06 FAILS**: the wallet goes to **-1400**. |
| 11 | **Exit**: refund of the ₹2000 deposit, 1500 then 500. | Vouchers with number, mode, reason, who, when, authoriser. Over-refund refused. The due is not re-opened and the receipt is not rewritten. | REF-01..07, REF-11 |
| 12 | The deposit receipt is then cancelled "as entered twice". | Refused, because its money has already gone back. | **REF-09 FAILS**: the cancel succeeds and the ledger reads paid 0 / refunded 2000. |
| 13 | The family looks at the student's fee history. | Receipts **and refunds** are both shown. | **REF-10 FAILS**: refunds never appear. Leftover wallet credit cannot be refunded at all (**ADV-09**). |
| 14 | The cashier closes the day, recounts and closes again, then cancels a receipt from that day. | The first count stays on record. The cancel is refused or the close is flagged stale. | **DAY-06, CAN-12 FAIL**: the first close is overwritten, and the cancel silently changes a closed day. |

---

## 2. Money trail map

Where each money event is recorded, and where it surfaces.

| Event | Written to | Who / when | Shown in UI | Day close / reports | Gaps found |
|---|---|---|---|---|---|
| Collect (cash / UPI / card / cheque) | `fee_payments` header, `fee_payment_details` (one per ledger row / extra), `fee_payment_tenders` (one per mode), `student_ledger.amount_paid` | `created_by`, `created_at`, `payment_date` | History tab (receipt no, date, amount, header mode, concession); reprint | Day close uses `fee_payments.amount` where **header** `payment_mode='Cash'`; register groups by header mode | Day close ignores tenders (DAY-01/02/03). Reprint has no tender split (RCP-06), no cashier (RCP-05). Cheque/UPI reference never captured by UI (STA-02) |
| Split tender | `fee_payment_tenders` (+ `v_fee_tender_lines` view) | `created_at` | Not shown anywhere (receipt prints "Mixed") | View exists but **no live report uses it** | DAY-01, DAY-04, RCP-06 |
| Concession / discount | `student_ledger.concession`, detail `concession`, header `concession_total`, `discount_type/value/reason` | cashier only | History "₹x off"; receipt discount line; Concession register | Concession register | No approver (CON-03). Reason not required by proc (CON-02). Allowed on refundable deposit (CON-06) |
| Extra charge | detail line `line_type='Extra'`, `ledger_id NULL` | header | Receipt line | Register head-wise | Note field dropped (STA-04). Extras-only collection blocked by controller (STA-10) |
| Over-payment → advance | header `advance_credit`, `student_advance.balance` (overwritten running balance) | header only; wallet has `updated_at` only | Receipt "Saved to advance"; settlement panel shows balance | Day close does **not** count the surplus cash (DAY-02) | Wallet has no movement ledger of its own; it can go negative (ADV-06, ADV-08); cannot be refunded (ADV-09) |
| Advance used | header `advance_used`, tender row `Advance`, wallet debit | header | Receipt "Paid from advance" | Day close counts wallet money as cash when header mode is Cash (DAY-03); register lists "Advance" as collection | Over-debit possible (ADV-04); `Advance` tender spoofable (COL-11) |
| Cancel | header `is_cancelled`, `cancel_reason`, `cancel_authorized_by`, `cancelled_by`, `cancelled_at`; ledger and wallet reversed | yes | History struck through + reason | Excluded from day/register; Cancellation register | Reprint has no cancelled flag (RCP-04). History lacks who/when (CAN-08). Allowed after refund (REF-09), after credit spent (ADV-06), after day close (CAN-12) |
| Refund | `fee_refunds` voucher (`RFD-YYYY-<global id>`), `student_ledger.refund_amount` | `refunded_by`, `refunded_at`, `authorized_by` | **Nowhere on the student screen**; no voucher reprint | Refund register; day close subtracts cash refunds | Not in history (REF-10). 0.00 vouchers possible (REF-08). Number not per school (STA-11). No void (STA-12) |
| Day close | `fee_day_close` (one row per cashier per day, **upserted**) | `closed_by`, `closed_at` | Day Close page | n/a | Re-close overwrites (DAY-06) |

---

## 3. Test catalog

Layer: **DB** = stored proc / schema, **C#** = controller/service, **UI** = view JS. Result: PASS, or
**BUG** (a check that fails because of an application bug), or STATIC (found by reading code; it
cannot run in SQL).

### COL: allocation and the collect engine

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| COL-01 | 3 months, Cash 2000 + UPI 1000 (ref) | collect 3 × 1000, tenders Cash/UPI | Receipt 3000, mode Mixed, 2 tender rows = 3000, UPI ref stored, 3 lines with ledger ids, 3 rows Paid, created_by/at set | DB | SQL COL-01a..g | PASS |
| COL-02 | Receipt number | first receipt in fixture | `RCP-2026-0001` = counter + 1 | DB | SQL COL-02 | PASS |
| COL-03 | Partial then remainder | 400 then 600 on one month | Partial / 600 left, then Paid; 2 receipts trace to the row; consecutive numbers | DB | SQL COL-03a..c | PASS |
| COL-04 | Same ledger row twice in one request | lines 700 + 700 on a 1000 due | Refused | DB | SQL **BUG COL-04** | **BUG**: accepted, the row shows 1400 paid of 1000 |
| COL-05 | Zero line rides along | line 1000 + line 0/0 | Zero line skipped, its due untouched | DB | SQL COL-05 | PASS |
| COL-06 | Nothing moves | only a 0/0 line | Refused | DB | SQL COL-06 | PASS |
| COL-07 | Rounding | amount 333.335 | Header = line = ledger = 333.34 | DB | SQL COL-07 | PASS |
| COL-08 | Absurd amount | 10^13 | Refused | DB | SQL COL-08 | PASS (numeric overflow) |
| COL-09 | Tenders short | 900 tender on 1000 | Refused | DB | SQL COL-09 | PASS |
| COL-10 | Negative tender | Cash 2000 + UPI −1000 on 1000 | Refused | DB | SQL **BUG COL-10** | **BUG**: accepted. Receipt says 1000 taken, tender lines say 2000. (The controller filters `Amount > 0` at FeeController.cs:199, but the proc does not.) |
| COL-11 | "Advance" sent as a tender mode, wallet empty | tenders `[{mode:Advance, 1000}]` | Refused | DB+C# | SQL **BUG COL-11** | **BUG**: month settled from a wallet of 0, nothing debited. The controller passes any mode through (FeeController.cs:198-205), so this can be reached by POST |
| COL-12 | Extras-only receipt for another school's student | p_student_id = school-33 student | Refused | DB | SQL **BUG COL-12** | **BUG**: school 34 issues a receipt for school 33's student |
| COL-13 | Extras-only receipt for a non-existent student | student id 2147483000 | Refused | DB | SQL **BUG COL-13** | **BUG**: receipt issued for a ghost |
| COL-14 | Wrong-school / wrong-student ledger rows | a–d variants | Refused | DB | SQL COL-14a..d | PASS |
| COL-15 | Platform scope | tenant 1 / school 0 | Refused | DB | SQL COL-15 | PASS |
| COL-16 | Extra with blank label | due + extra 50 | Header 1050; "Extra Charge" line with no ledger | DB | SQL COL-16 | PASS |
| COL-17 | Refused requests don't burn numbers | counter before/after refusals | Unchanged | DB | SQL COL-17 | PASS |
| COL-18 | Concurrency: two counters or two tabs pay the same due | two concurrent collects | The second sees the first and is refused | DB | static: fee_advance.sql:142 (no `FOR UPDATE` on the ledger read; the UPDATE then adds blindly) | **STATIC BUG** (over-collection) |
| COL-19 | Double click / retry | click Collect twice; retry after a timeout | One receipt | UI+C# | static: ManageFee.cshtml:564 (button disabled while busy: OK); no idempotency key anywhere, so a `.fail` retry after a server commit duplicates | **STATIC BUG** (retry duplicates) |
| COL-20 | Extras-only collection (lost ID card, no due) | UI: add extra, no dues ticked | Receipt for the extra | C# | static: FeeController.cs:175 rejects `Items.Count == 0` before the extras are looked at | **STATIC BUG** (extras-only impossible from the counter) |
| COL-21 | Exited student still owes | exit → collect | Collected and kept | DB | SQL REF-12 | PASS |
| COL-22 | Payment date | service always passes NULL | Receipt dated today; no back-dating from UI | C# | static: FeePaymentService.cs:414 | PASS |
| COL-23 | Allocation order | partial pay across ticked dues | Discount first, then cash, oldest due first; extras funded first | UI | static: ManageFee.cshtml buildItems (sorts by dueDate) | PASS (by reading) |

### RCP: receipts and reprint

| ID | Scenario | Steps | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| RCP-01 | Uniqueness | catalog | `UNIQUE (tenant_id, school_id, receipt_no)` | DB | SQL RCP-01 | PASS |
| RCP-02 | Gapless per school/year | after all collects | Numbers are exactly 1..counter | DB | SQL RCP-02 | PASS |
| RCP-03 | Reprint = issued | sp_fee_receipt_get | 3 lines summing to the header | DB | SQL RCP-03 | PASS |
| RCP-04 | Reprint of a cancelled receipt | header columns | Carries `is_cancelled` so the slip is stamped VOID | DB+UI | SQL **BUG RCP-04**; static fee-receipt.js (no cancel handling) | **BUG**: a cancelled receipt reprints as valid |
| RCP-05 | Reprint names the cashier | header columns | `created_by` / name | DB | SQL **BUG RCP-05** | **BUG** |
| RCP-06 | Reprint shows tender split + cheque/UPI refs | proc cursors | A tenders cursor | DB+UI | SQL **BUG RCP-06**; fee-receipt.js:185/227/256 print only header mode | **BUG**: prints "Mixed" |
| RCP-07 | Other school reprint | 23/33 asks for our receipt | "Receipt not found" | DB | SQL RCP-07 | PASS |
| RCP-08 | No session passed | fin_year NULL | Same RCP-2026 counter, no clash | DB | SQL RCP-08 | PASS |
| RCP-09 | Registration fee and fee collection share one counter | code | No duplicate numbers across the two | DB | static: sp_registration_fee_record uses the same `receipt_counters` key | PASS (by reading) |
| RCP-10 | Receipt format | Save | Only A4/A5/Thermal; anything else → A4; scoped | DB | static: sp_school_receipt_format_manage | PASS (by reading). Gated by `fees.manage`, so any cashier can change a school-wide setting (STA-07) |

### CAN: cancel / void

| ID | Scenario | Steps | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| CAN-01 | Exact reversal | receipt with cash line, cash+concession line, extra; cancel | Ledger fingerprint (paid, concession, refund, status) identical | DB | SQL CAN-01 | PASS |
| CAN-02 | Cancelled receipt kept | read header | Reason, who, when, authoriser; amounts, lines, tenders intact | DB | SQL CAN-02a/b | PASS |
| CAN-03 | Reason required | blank | Refused | DB | SQL CAN-03 | PASS |
| CAN-04 | Second cancel | again | success false; nothing reversed twice; original reason kept | DB | SQL CAN-04 | PASS |
| CAN-05 | Other school cancels | 23/33 | Not cancelled | DB | SQL CAN-05 | PASS |
| CAN-06 | Two receipts on one row, cancel the first | 400 + 300, cancel 400 | Row 300 Partial | DB | SQL CAN-06 | PASS |
| CAN-07 | History lists cancelled | history | All receipts incl. cancelled with reason | DB | SQL CAN-07 | PASS |
| CAN-08 | History shows who/when | history columns | created_by, cancelled_by, cancelled_at | DB+C#+UI | SQL **BUG CAN-08** | **BUG** |
| CAN-09 | Cancel after refund | see REF-09 | Refused | DB | SQL **BUG REF-09** | **BUG** |
| CAN-10 | Cancel after its credit was spent | see ADV-06 | Refused / wallet ≥ 0 | DB | SQL **BUG ADV-06** | **BUG** |
| CAN-11 | Number not reused | collect after cancels | New number; cancelled ones kept | DB | SQL CAN-11 | PASS |
| CAN-12 | Cancel a receipt of a closed day | close day → cancel | Refused (or close flagged) | DB | SQL **BUG CAN-12** | **BUG**: closed-day total 23383.34 vs live 22383.34, nothing flags it |
| CAN-13 | Authoriser | UI | A real identity | UI | static: ManageFee.cshtml:200 (optional pick-list text, defaults to "not specified") | **STATIC** (weak) |

### CON: concession / discount

| ID | Scenario | Steps | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| CON-01 | Sibling concession 300 flat | 3 months | Cash-only receipt; type/value/reason stored; on the waived row; in the register | DB | SQL CON-01a..c | PASS |
| CON-02 | No reason | concession 100, reason NULL | Refused | DB | SQL **BUG CON-02** | **BUG** (UI requires it, the proc does not) |
| CON-03 | Approver | schema | An approver column | DB | SQL **BUG CON-03** | **BUG** |
| CON-04 | Full waiver | 0 cash / 1000 concession | Receipt with 0 cash, 1000 waived, no tenders | DB | SQL CON-04 | PASS |
| CON-05 | Concession > due | 1500 on 1000 | Refused | DB | SQL CON-05 | PASS |
| CON-06 | Concession on a refundable deposit | deposit 1500 + 500 conc | Refused (as the admission path does) | DB+UI | SQL **BUG CON-06**; UI spreads the discount over every ticked due (ManageFee buildItems) | **BUG** |
| CON-07 | No phantom discount | type/value sent with 0 concession | Not stored | DB | SQL CON-07 | PASS |
| CON-08 | Percent rounding | UI | `Math.round` to whole rupees, capped at dues | UI | static: ManageFee.cshtml:517 | PASS (by reading) |

### ADV: advance wallet

| ID | Scenario | Steps | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| ADV-01 | Overpay → credit | 2500 for 1000 | Credit 1500 on receipt and wallet | DB | SQL ADV-01 | PASS |
| ADV-02 | Pay from wallet | adv 1000 | Mode Advance, Advance tender row, wallet 500 | DB | SQL ADV-02 | PASS |
| ADV-03 | Use > balance | 600 of 500 | Refused | DB | SQL ADV-03 | PASS |
| ADV-04 | Use > bill (no tenders) | bill 300, adv 500 | Wallet 200 or refused | DB | SQL **BUG ADV-04** | **BUG**: wallet 0, so 200 vanishes (UI caps at payable; a direct POST does not) |
| ADV-05 | Wallet + cash | adv 400 + cash 600 | Both tenders; wallet 100 | DB | SQL ADV-05 | PASS |
| ADV-06 | Cancel credit receipt after the credit was spent | cancel overpay receipt | Refused / wallet ≥ 0 | DB | SQL **BUG ADV-06** | **BUG**: wallet −1400 |
| ADV-07 | Wallet equation | sum credits − uses | = balance | DB | SQL ADV-07 | PASS |
| ADV-08 | DB guard | schema | CHECK balance ≥ 0 | DB | SQL **BUG ADV-08** | **BUG** |
| ADV-09 | Refund leftover wallet at exit | refundables | Wallet offered | DB+UI | SQL **BUG ADV-09** | **BUG**: no path at all; the money is stranded |
| ADV-10 | Wallet history | schema | A movement ledger | DB | static: `student_advance` is one overwritten balance row; the trail exists only through receipt headers | **STATIC** (weak) |

### REF: refund

| ID | Scenario | Steps | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| REF-01 | Refundables | deposit paid | Deposit first, 2000, flagged | DB | SQL REF-01 | PASS |
| REF-02 | Over-refund | 2500 of 2000 | Refused | DB | SQL REF-02 | PASS |
| REF-03 | Zero / negative / no reason | | Refused | DB | SQL REF-03a..c | PASS |
| REF-04 | Voucher trail | 1500 | Number, amount, mode, reason, who, when, authoriser, student; ledger refund_amount | DB | SQL REF-04a/b | PASS |
| REF-05 | Remainder only | 600 refused, 500 ok | Retained 0 | DB | SQL REF-05a/b | PASS |
| REF-06 | Refund ≠ new due, receipt untouched | | Paid, owing 0, receipt 2000 live | DB | SQL REF-06 | PASS |
| REF-07 | Other school / wrong student | | "Charge not found" | DB | SQL REF-07a/b | PASS |
| REF-08 | Sub-paisa refund | 0.004 | Refused | DB | SQL **BUG REF-08** | **BUG**: voucher for 0.00 created |
| REF-09 | Cancel a refunded receipt | | Refused | DB | SQL **BUG REF-09** | **BUG**: paid 0 / refunded 2000 |
| REF-10 | History shows refunds | | Receipts + refunds | DB+C#+UI | SQL **BUG REF-10** | **BUG** |
| REF-11 | Cash refund reduces expected cash | | Δ cash_refunded = 1500 | DB | SQL REF-11 | PASS |
| REF-12 | Exited student collection | | Allowed | DB | SQL REF-12 | PASS |
| REF-13 | Refund of a non-refundable head (tuition) | | Allowed but flagged | DB+UI | static: proc ignores `is_refundable`; UI only stars refundable rows | OBSERVATION (policy) |
| REF-14 | Refund numbering | | Per-school sequence | DB | static: fee_refund.sql:130 uses the global identity (first refund in school 34 was RFD-2026-0099) | **STATIC BUG** (low) |
| REF-15 | Void a wrong refund | | Reversal with trail | DB | static: no proc exists | **STATIC GAP** |
| REF-16 | Reprint a refund voucher | | Available | UI | static: no endpoint/UI | **STATIC GAP** |

### DAY: day close and register agree with the till

| ID | Scenario | Steps | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| DAY-01 | Cash part of a Mixed receipt | Cash 2000 + UPI 1000 | Δ expected cash 2000 | DB | SQL **BUG DAY-01** | **BUG**: 0 |
| DAY-02 | Overpay surplus | 2500 cash for 1000 | Δ 2500 | DB | SQL **BUG DAY-02** | **BUG**: 1000 |
| DAY-03 | Wallet part not cash | adv 400 + cash 600 | Δ 600 | DB | SQL **BUG DAY-03** | **BUG**: 1000 |
| DAY-04 | Register by true mode | register modes | No "Mixed"; Cash/UPI split | DB | SQL **BUG DAY-04** | **BUG**: `{"Cash":16383.34,"Mixed":6000,"Advance":1000}`. Wallet-funded receipts also counted as fresh collection |
| DAY-05 | Cancelled excluded | collect+cancel | Total unchanged | DB | SQL DAY-05 | PASS |
| DAY-06 | Re-close | close 100, close 200 | First count kept | DB | SQL **BUG DAY-06** | **BUG**: upsert overwrites |

### SEC: scope and permissions

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| SEC-01..04 | School 33 reads our dues / history / wallet / refundables | Nothing | DB | SQL SEC-01..04 | PASS |
| SEC-05 | Permission keys | Separate keys for cancel / refund / discount / receipt format | C# | static: FeeController.cs:171, 287, 330, 386, 411 all use `fees.manage` | **STATIC GAP** (any cashier can void, refund, discount, change the format) |
| SEC-06 | Claims-based scope | tenant/school/user from claims only | C# | static: FeeController.cs:674-676 | PASS |

### TRL: structural trail

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| TRL-01 | Nothing deletes receipts/refunds | Only `sp_school_purge` | DB | SQL TRL-01 | PASS |
| TRL-02 | No cascade erasure | No ON DELETE CASCADE on money rows | DB | SQL **BUG TRL-02** | **BUG** (low): ledger and wallet cascade from `students`; receipt lines and tenders cascade from `fee_payments` |
| TRL-03 | DB amount guards | CHECK paid + concession ≤ due, refund ≤ paid, ≥ 0 | DB | SQL **BUG TRL-03** | **BUG**: none, which is why COL-04 / REF-09 can corrupt rows |
| TRL-04 | Header = Σ lines | for every receipt | DB | SQL TRL-04 | PASS |
| TRL-05 | Ledger = live receipt lines | per student | DB | SQL TRL-05 | PASS |
| TRL-06 | Money in = tender lines | per receipt | DB | SQL TRL-06 | PASS |
| TRL-07 | Nothing written into school 33 | count unchanged | DB | SQL TRL-07 | PASS |
| TRL-08 | Fee-head rename | old receipt lines keep their printed name | DB | static: `sp_school_admin_fee_head_manage` rewrites `fee_payment_details.fee_head_name` on rename (deliberate) | OBSERVATION: conflicts with "never overwritten" |

### STA: other static findings (UI / docs)

| ID | Finding | Where | Severity |
|---|---|---|---|
| STA-02 | No cheque/UPI/card reference input. Tenders are sent as `{mode, amount}` only and `reference:''` is hard-coded, so cheque number, bank and UPI txn id are never recorded | ManageFee.cshtml:562, :565 | High |
| STA-04 | Extra-charge "Note" is collected but never sent | ManageFee.cshtml:456 vs :559 | Low |
| STA-05 | "refundable" tag never shown on a due (`dueRow(d,false)` always) | ManageFee.cshtml:419, :423 | Low |
| STA-17 | Docs claim day close / register use `v_fee_tender_lines`. The live procs do not (FeeModule.md §3.4; header of fee_payment_tenders.sql). The ManageFee header comment still says split tender/advance are "not yet persisted" | docs | Low (misleading) |
