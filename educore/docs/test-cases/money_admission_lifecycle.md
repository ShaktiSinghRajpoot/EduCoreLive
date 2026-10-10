# Test cases: money across admission and the student lifecycle

**Rule under test:** any time money is charged, taken, discounted, refunded, cancelled, reversed or dropped, the system keeps a lasting record of who did it, when, how much, the mode, the receipt number, the student and the fee head. Nothing is quietly hard-deleted or overwritten. The record shows up somewhere in the UI, and it matches the fee reports and Day Close.

- **SQL suite:** `EduCoreDataAccessLayer/Database/tests/money_admission_lifecycle_tests.sql`. It uses tenant 24 / school 34 / user 39, with 23/33 as the cross-school fixture. Everything runs in one transaction and is rolled back.
- **Phase 1 run (2026-10-10):** 51 passed, 26 failed, all 26 being BUG checks. **Phase 2 run (after the fixes, same day):** `RESULT: 102 passed, 0 failed`. No test rows leaked.
- **Live procedures:** each one was confirmed with `pg_get_functiondef` before writing a check. Script line numbers are listed only so you know which file to edit.
- **No duplication:** this suite does not repeat checks in `admission_fee_tests`, `admission_validation_tests`, `promotion_tests`, `transport_tc_tests`, `money_trail_tests` or `workflow_billing_tests`.
- **How to read a result:** every check states the correct behaviour. In phase 1 the failing ones were named `BUG …`; they have been renamed now that they pass (see §0 for the new IDs). Rows marked *static* were checked by reading the code. They can't be run from SQL because they live in C# or JS.

---

## 0. Phase 2: what was fixed and where

Apply the procs in this order: `student_money_lifecycle.sql` (new) → `student_master_fields.sql` → `transport_module.sql` → `student_exit.sql` → `student_promotion.sql` → `student_update.sql` → `transfer_certificate.sql` → `student_list.sql`.

**The core idea:** a due is never hard-deleted. When it stops applying (the student left, the bus was removed, the route or class changed), its unpaid part is **closed**. The row stays. `amount_due` drops to whatever has been settled, and the closed part is kept in `closed_amount`, together with the reason, who closed it and when. Because the row survives, every existing outstanding formula reads 0 for it, receipt lines always resolve, and the close can be undone exactly.

| Bug (phase-1 ID) | Fix (file:line) | New check(s) |
|---|---|---|
| LIFE-PROMO-BILL | `student_promotion.sql:487`: Promote/Retain bill the target class's recurring structure for the new session (`fn_class_fee_plan` + `fn_student_bill_plan`, once per session) and re-bill a kept bus route. PassOut closes later dues (`:481`). | G0, G3, G3b, G4, G5, G6, G7 |
| ADM-MSG | `AdmissionController.cs:361-446` (feeFailed / feeMessage / transportMessage); `Create.cshtml:1015-1016` holds the page with a dialog until a receipt or bus failure is read; a balance still due is shown in the toast | static |
| TRN-SCOPE / TRN-09 | `transport_module.sql:397`: the student must belong to this school and be active | E7 |
| LIFE-EXIT-DUES / -BUS / -TC | `student_exit.sql:42` `fn_student_leave_money`: closes dues after the leaving date ('Left on …', who, when) and ends the bus | F0, F5, F5b, F5c, F6, F6c, F7 |
| LIFE-WALLET-REFUND | collection agent (wallet refund voucher) | F16 |
| LIFE-TC-WALLET | `transfer_certificate.sql:264` | F15 |
| FEE-CANCEL-REFUNDED | collection agent (`fee_receipt_cancel.sql`) | D5 |
| FEE-DUPLINE | collection agent (`fee_advance.sql`) | C14 |
| TRN-ORPHAN / TRN-REMOVE | `transport_module.sql:436, 476, 496`: CLOSE, never DELETE; a part-paid month is topped up to the new fare | E3, E3b, E4, E4b, E5, E5b, E6b |
| TRN-SESSION | `transport_module.sql:429` clamps to the session's real end date; both controllers stop counting months (`TransportController.cs:167`) | E0 |
| ADM-SD | `AdmissionController.cs:572-603`: the fallback deposit uses the real head's id and name, and the concession skip list comes from the same fee list. The ledger now carries `fee_head_id`. | D0, D1 |
| ADM-PLAN / -NEG / -DUPHEAD | `AdmissionController.cs:250, 576` builds the plan and totals on the server; `student_master_fields.sql:224` refuses negative amounts and duplicate heads | A11, A12, A13 (+ static) |
| LIFE-LIST / -EXPORT / -DASH | `student_list.sql:65-72`, `student_master_fields.sql:493-500`, `sp_student_fee_totals` → `StudentController.cs:289` | C15, C16, C17 |
| ADM-41 / ADM-12 | `AdmissionController.cs:628` (QuoteAdmission: real instalments) and `:819` (proportional spread); `Create.cshtml:667, 738` | static |
| LIFE-UNDO / -UNDO-TC | `student_exit.sql:219` (refused with a live TC), `:227` (audit row), `fn_student_return_money` (exact restore of the dues and the bus) | F8, F11, F11b, F11c, F11d, F12 |
| LIFE-CLASS\* | `student_update.sql:110, 120` (session / section checks), `:152` (enrolment), `:182` (close + re-bill from next month when a structure exists), `:199` (audit) | H1–H8 |
| LIFE-TC-VOID | `transfer_certificate.sql:379` | F9 |
| ADM-TRN | `AdmissionController.cs:446` | static |
| LIFE-PROMO-VISIBLE | `sp_student_history_get` → `StudentController.History` → Dashboard "Activity & Money History" card | G8, D4b, F6c |
| ADM-42 | `AdmissionController.cs:370`: a concession over the cap is not posted; the message says it is awaiting approval | static |
| Risk: concurrent duplicate admission | `student_master_fields.sql:251` (transaction-scoped advisory lock) | static (B1/B2 for the serial case) |
| Risk: one enquiry admitted twice | `student_master_fields.sql:242` (`FOR UPDATE` + refuse) | enquiry suites |
| Risk: three separate transactions | **Not fixed.** `PgExec` has no shared transaction across services. The failures are now reported (ADM-MSG). | — |
| Risk: money collected with `students.manage` only | **Not changed here.** The coordinator owns `[HasPermission]`. | — |

---

## 1. Real-world scenario

*Aarav is admitted to Class 3-A on 10 Oct, in the middle of the FY 26-27 session (Apr–Mar). He takes the school bus.*

1. **Admission.** The class plan has a one-time Admission Fee of 5,000, monthly Tuition of 1,000 and a refundable Security Deposit of 2,000. The ledger should hold one Admission row, one Deposit row and Tuition for **Oct–Mar (6 rows)**. That works (A1–A9). The Security Deposit row is the controller's fallback line, named "Security Deposit". No fee head has that name, so the Refund screen shows it as **not refundable**, and an admission concession can be applied to it (**ADM-SD**).
2. **Pays part at the desk.** The parent pays 4,000 of the 7,000 due now, by UPI. The receipt, the line items, Day Close, the Collection Register and Payment History all record it correctly (C1–C9). If the receipt step fails, though, the page still says only "Admission … saved." The failure message and the "₹3,000 still due" line never reach the screen (**ADM-MSG**).
3. **Bus.** He is assigned to the Far stop (900 a month) at admission. If that step fails, nobody is told (**ADM-TRN**). If a clerk later assigns him from the Transport page with a 12-month count, the bus is billed into the next session (**TRN-SESSION**).
4. **Changes route** to the Near stop in November. Paid months are kept and unpaid months are re-billed at the new fare (E1–E3). But November's bus fee had been paid by mistake and that receipt was cancelled, so the November row had nothing paid against it. The route change hard-deleted that row, and the cancelled receipt now points at a ledger row that no longer exists (**TRN-ORPHAN**).
5. **Promoted to Class 4** in April. His unpaid balance carries over and is recorded (G1), and his advance wallet balance comes with him (G2). But **no Class 4 fees are created at all** (**LIFE-PROMO-BILL**), and the promotion history that records carried dues isn't visible anywhere in the UI (**LIFE-PROMO-VISIBLE**).
6. **Leaves mid-year.** The exit keeps every receipt and ledger row (F1–F4). But tuition and bus fees for every month after the leaving date stay on his ledger (**LIFE-EXIT-DUES**), and the bus assignment stays active (**LIFE-EXIT-BUS**). As a result, a family that has paid in full up to the leaving date is **refused a TC** (**LIFE-EXIT-TC**). The office's only way through is to post a fake "concession" for months he never attended.
7. **Deposit refund.** The refund voucher records the amount, mode, reason, authoriser, who issued it and when. It appears on the Refund Register and in Day Close (D2–D4). If the original receipt is cancelled after the refund, though, the same 2,000 is reversed a second time (**FEE-CANCEL-REFUNDED**). If he had overpaid into the advance wallet, there is **no way to refund that balance** (**LIFE-WALLET-REFUND**), and the TC is issued anyway with the balance still held (**LIFE-TC-WALLET**).
8. **Office mistakes.** "Reactivate" erases the exit date, the reason and who recorded it, and leaves nothing behind (**LIFE-UNDO**). It works even when a live TC exists (**LIFE-UNDO-TC**). A TC can be voided without a reason (**LIFE-TC-VOID**).

---

## 2. Money trail map

| Action that moves or charges money | Tables written | Where the UI shows it | Report / reconciliation that shows it | Gap |
|---|---|---|---|---|
| Admission builds the fee plan and ledger (`sp_admission_manage` SaveAdmission) | `students` (pay_today/annual/concession totals), `student_fee_plan`, `student_ledger`, `student_enrolment`, `admission_audit` | Student Dashboard fee table; Fee counter dues | Defaulters (outstanding) | `admission_audit` is never read. The amounts in the plan come from the browser (ADM-PLAN/NEG/DUPHEAD). |
| Cash or concession taken at admission (`sp_fee_payment_collect`, called from `AdmissionController.SaveAdmission`) | `fee_payments`, `fee_payment_details`, (`fee_payment_tenders` only for split tender), `student_ledger` | Receipt modal (only on success); Payment History; Dashboard receipts | Day Close, Collection Register (by mode / by head), Concessions register | Failure and balance messages never shown (ADM-MSG). A zero-cash concession-only receipt counts in Day Close `receipt_count`. |
| Unpaid registration balance carried onto the student | `student_ledger` ('Registration' row), `admission_audit` | Fee counter dues | Defaulters | none |
| Registration receipt re-pointed to the student | `fee_payments.student_id` | Payment History | Collection Register | none |
| Transport assignment (`sp_transport_assign_manage` SaveAssignment) | `student_transport` (new row; old row soft-deleted), `student_ledger` ('Transport Fee'); unpaid future rows **hard-deleted** | Transport → Assign (current assignment only) | Defaulters / Collection by head | No history of deleted charges. The old assignment is never shown. Cross-school assignment is possible. Billing can run past session end. A part-paid month keeps the old fare. |
| Transport removal (RemoveAssignment) | `student_transport` soft-delete; unpaid rows from the current month on **hard-deleted** | none (no history) | none | Part-paid future months stay owed (TRN-REMOVE). Cancelled-receipt lines are orphaned (TRN-ORPHAN). No reason recorded. |
| Receipt cancel (`sp_fee_receipt_cancel`) | `fee_payments` (is_cancelled, reason, authoriser, who, when), ledger reversed, wallet reversed | Payment History (struck through), Dashboard 'CANCELLED' | Concessions & Cancellations register; excluded from Day Close | Allowed after a refund (FEE-CANCEL-REFUNDED) |
| Refund / deposit return (`sp_fee_refund_record`) | `fee_refunds` (RFD no, amount, mode, reason, authoriser, refunded_by, refunded_at), `student_ledger.refund_amount` | Fee → Payment History refund action | Refund Register; Day Close `cash_refunded` | Not on the Student Dashboard. The refundable flag is looked up by fee-head **name** (ADM-SD). |
| Advance wallet credit / use | `fee_payments.advance_credit/used`, `fee_payment_tenders` 'Advance', `student_advance` | Fee counter wallet badge; receipt | none of its own | **No way to pay it out** (LIFE-WALLET-REFUND); TC ignores it |
| Exit (`sp_student_exit` Exit) | `students` (status, date_of_leaving, reason, exit_recorded_by/at), `student_enrolment` status | Inactive list (outstanding column) | Defaulters still lists the leaver, including future months | Future dues and the bus assignment are not closed (LIFE-EXIT-*) |
| Reactivate (`sp_student_exit` Undo) | `students` exit columns **set to NULL** | none | none | Exit history destroyed (LIFE-UNDO); allowed with a live TC (LIFE-UNDO-TC) |
| TC issue / void (`sp_tc_manage`) | `tc_register` (outstanding_at_issue always written as 0, void reason optional) | TC Register | none | Void with no reason (LIFE-TC-VOID). Wallet balance not checked (LIFE-TC-WALLET). |
| Promotion (`sp_student_promote`) | `students`, `student_enrolment`, `student_promotion_history` (dues_carried) | Enrolment history timeline (no money in it) | none | No new-session ledger (LIFE-PROMO-BILL); history never read (LIFE-PROMO-VISIBLE) |
| Class change (`sp_student_update`) | `students.class_name/section` overwritten | Dashboard | none | No re-billing, no audit, enrolment not updated (LIFE-CLASS*) |

---

## 3. Test catalog

Layer: **DB** = stored procedure, **C#** = controller/service, **JS** = view script.

### A. Ledger generated from the fee plan

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| ADM-01 | Mid-session monthly | Admit 10 Oct with Monthly 1000, AdmissionMonth policy | Oct–Mar = 6 rows | DB | SQL A1, A2 | PASS |
| ADM-02 | Nothing billed after session end | same | 0 rows after 2027-03-31 | DB | SQL A3 | PASS |
| ADM-03 | Quarterly joiner | Quarterly 600 | Starts on the session quarter boundary (Oct), 2 rows | DB | SQL A4 | PASS |
| ADM-04 | Half-yearly joiner | Half Yearly 2000 | 1 row (Oct–Mar) | DB | SQL A5 | PASS |
| ADM-05 | Yearly / one-time | Yearly 3000, One Time 5000 | One 'Annual' row, one 'Admission' row | DB | SQL A6, A7 | PASS |
| ADM-06 | Fresh ledger | — | paid 0, concession 0, status Pending | DB | SQL A8 | PASS |
| ADM-07 | Plan frozen and audited | — | 5 `student_fee_plan` rows; `AdmissionCreated` audit row with the user | DB | SQL A9, A10 | PASS |
| ADM-08 | Negative amount in plan | amount −5000 | Refused | DB | SQL `BUG ADM-NEG` | FIXED (§0) |
| ADM-09 | Same head twice | Admission Fee ×2 | Billed once / refused | DB | SQL `BUG ADM-DUPHEAD` | FIXED (§0) |
| ADM-10 | Head the school never configured | 'ZZ Head Nobody Configured', 99,999 | Refused (or re-priced from the structure) | DB+C# | SQL `BUG ADM-PLAN`; static `AdmissionController.cs:678-690` (amounts read from `LedgerPreviewJson`) | FIXED (§0) |
| ADM-11 | Charge-from SessionStart vs AdmissionMonth | — | covered by `workflow_billing_tests` | — | existing suite | n/a |
| ADM-12 | "Estimated annual" and annual concession assume 12 months | Mid-year joiner billed 6 months | Estimate and %-discount use the months actually billed | JS | static `Create.cshtml:733-736, 747` | FIXED (§0) |

### B. Atomicity, double submit, admission numbers

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| ADM-20 | Same form posted twice | identical name/DOB/mobile | Second refused; billed once | DB | SQL B1, B2 | PASS |
| ADM-21 | Concurrent double submit | two requests at once | Only one student | DB | static: the duplicate check is a `COUNT(*)` with no lock or unique key (`sp_admission_manage`, `student_master_fields.sql`). The button is disabled (`Create.cshtml:982`), which is the only defence against a race. | RISK |
| ADM-22 | Auto admission numbers | two blank numbers | Consecutive and distinct (DB counter) | DB | SQL B3 | PASS |
| ADM-23 | Refused admission leaves nothing | future date + plan | No student / plan / ledger / audit | DB | SQL B4 | PASS |
| ADM-24 | Typed number collides (case-insensitive) | 'zz-mal-a1' | Refused; nobody billed | DB | SQL B5 | PASS |
| ADM-25 | Admission saved but payment fails | collect raises | User is told the money was **not** recorded | C#+JS | static: `AdmissionController.cs:384-387` builds `feeMessage`, but `Create.cshtml:992-1009` never reads `res.feeMessage` and shows "Admission … saved." | FIXED (§0) |
| ADM-26 | Part payment: balance shown after save | pay 4000 of 7000 | "₹3,000 still due" shown | JS | static: the same ignored `feeMessage` (`AdmissionController.cs:379-382`). The hint before submit exists (`Create.cshtml:813-823`). | FIXED (§0) |
| ADM-27 | Student and money in separate transactions | — | Atomic, or the failure clearly reported | C# | static: three separate calls at `AdmissionController.cs:316, 363, 402` | RISK (made worse by ADM-MSG) |
| ADM-28 | Transport fails at admission | bad stop | Error reported | C# | static: `AdmissionController.cs:402-405` discards the `(ok,msg)` result | FIXED (§0) |
| ADM-29 | Overpay at admission | amount > due now | Refused | C#+JS | static `AdmissionController.cs:252-253`, `Create.cshtml:959`. The cap uses the client's `payToday`. | PASS (client-trusted) |

### C. Money taken at admission

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| ADM-30 | Receipt completeness | 3000 UPI, ref UPI-REF-77 | Student, amount, mode, ref, cashier, date, RCP-no | DB | SQL C1 | PASS |
| ADM-31 | Itemised line | — | Line names the head and ledger row | DB | SQL C2 | PASS |
| ADM-32 | Remaining due visible | 5000 − 3000 | 2000 in dues and on Defaulters | DB | SQL C3, C4 | PASS |
| ADM-33 | Day Close | — | School total +3000; cash +0 (UPI); UPI shown in the mode split | DB | SQL C5–C7 | PASS |
| ADM-34 | Collection Register / Payment History | — | Receipt listed | DB | SQL C8, C9 | PASS |
| ADM-35 | Concession-only receipt | 0 cash, 500 concession, reason | Receipt amount 0, concession 500, reason stored; Concessions register lists it; collection unchanged | DB | SQL C10–C12 | PASS |
| ADM-36 | Cash + concession settle together | — | 1500 left | DB | SQL C13 | PASS |
| ADM-37 | Same ledger id twice in one collect | 2 × 1500 on a 1500 balance | Refused | DB | SQL `BUG FEE-DUPLINE` (row ends up 1500 over-settled) | FIXED (§0) |
| ADM-38 | Student list CSV Fee Due | 600 cash + 400 concession | Due 0, Paid | DB | SQL `BUG LIFE-EXPORT` (shows 400 / Partial) | FIXED (§0) |
| ADM-39 | Student Directory Fee Due | same | Due 0, Paid | DB | SQL `BUG LIFE-LIST`; script `student_list.sql:71` | FIXED (§0) |
| ADM-40 | Student Dashboard Total Fee / Paid / Concession | fully paid row | Totals include settled rows | C# | SQL `BUG LIFE-DASH`; static `StudentController.cs:285, 340-342` (sums `sp_student_dues_get`, which returns only unsettled rows) | FIXED (§0) |
| ADM-41 | Annual concession at admission | "Apply to: Estimated Annual" | Spread over the year's dues | C#+JS | static: the client sends the annual discount as `calculatedAmount` (`Create.cshtml:747,793`). `AllocateAdmissionPayment` (`AdmissionController.cs:764-772`) writes it all off against the admission charges and the earliest months, and the cash then spills into tuition. `stillDue` (`:379`) goes negative. | FIXED (§0) |
| ADM-42 | Concession above the approval cap | > 100,000 | Held until approved | C# | static: the proc sets `Pending Approval`, but the controller posts the concession to the ledger immediately (`AdmissionController.cs:338-372`) | FIXED (§0) |
| ADM-43 | Concession stored on the student vs applied | concession > dues | Same figure in both places | C#/DB | static: `students.concession_amount` is the client figure; the ledger gets the capped amount | RISK |

### D. Security deposit and refund trail

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| DEP-01 | Fallback "Security Deposit" line is refundable | Refundable head is called "ZZ Caution"; the plan line is "Security Deposit" | Refund screen shows it as refundable; concession skips it | DB+C# | SQL `BUG ADM-SD`; static `AdmissionController.cs:514-533` (fixed name), `:352-357` (skip list built from the structure only), `fee_refund.sql:64` (flag looked up by name) | FIXED (§0) |
| DEP-02 | Refund voucher completeness | 2000 Cash, reason, authoriser | RFD no, amount, mode, reason, authoriser, who, when, ledger, student | DB | SQL D2 | PASS |
| DEP-03 | Refund on the register and in Day Close | — | Listed; `cash_refunded` ≥ 2000 | DB | SQL D3, D4 | PASS |
| DEP-04 | Cancel a receipt after its money was refunded | cancel RCP after RFD | Refused | DB | SQL `BUG FEE-CANCEL-REFUNDED` (paid 0, refunded 2000); `fee_receipt_cancel.sql:64` | FIXED (§0) |
| DEP-05 | Refund more than retained / twice | — | Refused | DB | covered by `admission_fee_tests` C3, `money_trail` 10.x | n/a |
| DEP-06 | Refund visible on the student's page | — | Dashboard shows refunds | C# | static: dashboard receipts list only (`StudentController.cs:415-421`) | GAP |

### E. Transport

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| TRN-01 | Month count past session end | SaveAssignment with 12 months from Oct | Clamped to session end | DB+C# | SQL `BUG TRN-SESSION` (6 months after Mar); static `TransportController.cs:251-268` and `AdmissionController.cs:721-738` assume Apr–Mar and parse the year from the session **name** | FIXED (§0) |
| TRN-02 | Paid month survives route change | — | Kept | DB | SQL E1 | PASS |
| TRN-03 | Old assignment kept | — | Old row with 900 fare kept (soft) | DB | SQL E2 | PASS (but no UI shows it) |
| TRN-04 | Re-billing at the new fare | — | Unpaid later months at 600 | DB | SQL E3 | PASS |
| TRN-05 | Cancelled receipt orphaned | pay Nov, cancel, change route | Receipt line still resolves | DB | SQL `BUG TRN-ORPHAN`; `transport_module.sql:396, 441` (hard `DELETE`). `fee_payment_details.ledger_id` has no FK. | FIXED (§0) |
| TRN-06 | Part-paid future month after removal | 300 of 900 paid for Dec, then removed in Oct | Nothing owed for months not ridden (credit or refund the 300) | DB | SQL `BUG TRN-REMOVE` (600 still owed). The part-paid month also keeps the old fare after a route change. | FIXED (§0) |
| TRN-07 | Removal ends the assignment | — | No active row | DB | SQL E6 | PASS |
| TRN-08 | Cross-school student | our route, student of school 33 | Refused | DB | SQL `BUG TRN-SCOPE` (2 ledger rows written under tenant 24 for school 33's student). The proc never checks the student. | FIXED (§0) |
| TRN-09 | Transport assigned to a student who has left | — | Refused | DB | static: no `is_active` check in SaveAssignment | FIXED (§0) |
| TRN-10 | Reason / history of removal | — | Who, when, why visible | DB/UI | static: only `updated_by`; `GetForStudent` returns the active row only | GAP |

### F. Exit, reactivate, TC

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| LIFE-01 | Exit keeps money records | — | No ledger row or receipt deleted | DB | SQL F1, F2 | PASS |
| LIFE-02 | Exit reports outstanding | — | Equals the ledger | DB | SQL F3 | PASS |
| LIFE-03 | Exit records who, when, why | — | Stored | DB | SQL F4 | PASS |
| LIFE-04 | Dues after the leaving date | leave 10 Oct | Nov–Mar tuition and bus no longer owed (waived with a record) | DB | SQL `BUG LIFE-EXIT-DUES` (6200) | FIXED (§0) |
| LIFE-05 | Bus after exit | — | Assignment ended | DB | SQL `BUG LIFE-EXIT-BUS` | FIXED (§0) |
| LIFE-06 | TC for a leaver paid up to the leaving date | — | Issued | DB | SQL `BUG LIFE-EXIT-TC` ("Clear pending dues of 6,200") | FIXED (§0) |
| LIFE-07 | Reactivate keeps the exit on record | Exit, then Undo | An audit row, or the exit details kept | DB | SQL `BUG LIFE-UNDO`; `student_exit.sql:107` | FIXED (§0) |
| LIFE-08 | Overpayment goes to the wallet | 1500 for 1000 | Wallet 500 | DB | SQL F7 | PASS |
| LIFE-09 | TC with the family's credit still held | wallet 500 | TC withheld, or a refund prompted | DB | SQL `BUG LIFE-TC-WALLET` | FIXED (§0) |
| LIFE-10 | Refund path for the wallet | — | A voucher can pay it out | DB | SQL `BUG LIFE-WALLET-REFUND` (only collect, cancel and purge write `student_advance`) | FIXED (§0) |
| LIFE-11 | Reactivate with a live TC | — | Refused (void the TC first) | DB | SQL `BUG LIFE-UNDO-TC` | FIXED (§0) |
| LIFE-12 | TC void reason | reason NULL | Refused | DB | SQL `BUG LIFE-TC-VOID`; `transfer_certificate.sql:364` | FIXED (§0) |
| LIFE-13 | `tc_register.outstanding_at_issue` | — | Real value | DB | static: always written as 0 (correct only because of the gate) | INFO |
| LIFE-14 | Exited student on Defaulters | — | Listed with real dues only | DB | static: `sp_fee_defaulters_get` has no `is_active` filter, and the future months from LIFE-04 show up | follows LIFE-04 |

### G. Promotion

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| LIFE-20 | Dues carried recorded | 5000 owing | `promotion_history.dues_carried` = 5000 | DB | SQL G1 | PASS |
| LIFE-21 | Wallet survives | 250 | 250 | DB | SQL G2 | PASS |
| LIFE-22 | New session billed | promote 3 → 4 | Class-4 plan ledger for the target session | DB | SQL `BUG LIFE-PROMO-BILL` (0 dues). Only `sp_admission_manage` ever creates tuition rows, and transport isn't re-billed either. | FIXED (§0) |
| LIFE-23 | Promotion history visible | — | UI shows it | DB/UI | SQL `BUG LIFE-PROMO-VISIBLE` (no proc reads it; `admission_audit` likewise) | FIXED (§0) |
| LIFE-24 | Carry off with dues | — | covered by `promotion_tests` E | — | existing | n/a |

### H. Class change (EditStudent)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| LIFE-30 | Ledger after class change | 3 → 4 | Fee difference re-billed, or at least flagged | DB | SQL H1 (shows the ledger unchanged); static `student_update.sql:91` | GAP |
| LIFE-31 | Enrolment follows class change | — | `student_enrolment` says 4 | DB | SQL `BUG LIFE-CLASS` (session-filtered lists show the old class) | FIXED (§0) |
| LIFE-32 | Class change recorded | — | Audit row | DB | SQL `BUG LIFE-CLASS-AUDIT` | FIXED (§0) |
| LIFE-33 | Class only in another session | 'ZZ Next Only' | Refused | DB | SQL `BUG LIFE-CLASS-SESSION` | FIXED (§0) |

### I. Scope and permissions

| ID | Scenario | Expected | How verified | Result |
|---|---|---|---|---|
| SCP-01 | Another school exits our student | Refused | SQL I1 | PASS |
| SCP-02 | Another school refunds our fee | No refund | SQL I2 | PASS |
| SCP-03 | Another school collects against our ledger | Refused | SQL I3 | PASS |
| SCP-04 | Another school edits our student | Refused | SQL I4 | PASS |
| SCP-05 | Another school cancels our receipt | No cancel | SQL I5 | PASS |
| SCP-06 | Platform scope admits | Refused | SQL I6 | PASS |
| SCP-07 | Nothing lands in another school | 0 | SQL I7 | PASS |
| SCP-08 | Transport cross-school | Refused | SQL `BUG TRN-SCOPE` | FIXED (§0) |
| SCP-09 | Permissions | Writes need `.manage` + antiforgery | static: `AdmissionController.cs:185-186`, `StudentController.cs:189-248`, `TcController.cs:34,75`, `TransportController.cs:154,173`. The fee preview and routes are `students.view`. | PASS |
| SCP-10 | Admission collects money under `students.manage` only | Collection requires a fee permission | static `AdmissionController.cs:185` — no fee permission checked | RISK |
