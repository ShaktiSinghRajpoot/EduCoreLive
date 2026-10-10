# Test catalog: money history in Enquiry and Registration

Pages: `/ERP/Enquiry/EnquiryCRM` (register modal, delete), `/ERP/Registration/Index` (walk-in, collect fee, cancel, reprint).
SQL suite: `EduCoreDataAccessLayer/Database/tests/money_enquiry_registration_tests.sql`. A cell like `SQL A7` names a check in that suite. `SQL BUG REG-05` is a check named after the correct behaviour that fails because of an app bug.
First run (2026-10-10, local DB, tenant 24 / school 34, rolled back, no leaked rows): **69 passed, 27 failed**. All 27 failures are app bugs (named `BUG ...`). No test was weakened to pass.

**Update (same day, after the fixes):** all 27 failures are fixed. The suite now asserts the corrected behaviour, uses no `BUG` names, and checks expected refusals against their message. Latest run: **109 passed, 0 failed**. The Result column below still shows the state before the fixes. What changed:
- **Paid is derived.** `core.fn_registration_fee_is_paid` (in `registration_fee_partial.sql`) decides "paid", and every screen reads it. `fn_registration_fee_settled` also counts money paid on the carried `Registration` ledger row after admission. The stored `registration_fee_paid` is now only a cache. The `MarkFeePaid` operation and the browser's paid tick are gone.
- **`sp_registration_fee_record` refuses** collection on a deleted, admitted, withdrawn or unregistered enquiry. It also refuses a discount without a reason, an unknown payment mode (modes are normalised to Cash / UPI / Card / Cheque / Bank Transfer) and a future-dated receipt. It locks the enquiry row (`FOR UPDATE`) and stores the discount value.
- **Receipt context** returns the cash as `this_receipt` and the discount as `this_discount`. It is computed as of the receipt, so a receipt cancelled later still counts for the slips printed while it was live.
- **Registrations list** returns every receipt plus fee / settled / balance. It shows a "Part paid" badge and a receipts dialog with Print and Cancel; Cancel uses the existing `/ERP/Fee/CancelReceipt`. The withdrawal note shows whenever any money was taken.
- **DeleteEnquiry** refuses admitted enquiries and enquiries with any receipt, writes a `Deleted` history row, and reports failure honestly. The CRM hides Delete for those rows.
- **`sp_enquiry_register`** ignores the paid tick, locks the row, and answers a replay without writing a second history row.
- **Fixed by other owners:** REG-03c (cancel clears the cache), REG-05/06 (discount in the Concessions report and on the receipt), REG-15 (double admission), REG-17 (head name), REG-18 (post-admission cancel becomes a due).

**The rule under test:** wherever money is taken, waived, discounted, marked paid, cancelled or carried, there must be a durable record of who, when, how much, mode, receipt number, for which enquiry or student, and for which fee head. That record must never be silently deleted or overwritten. It must be visible in the UI and must agree with the Collection Register, the Concessions and Cancellations report, and Day Close.

Abbreviations:
- EnqCtl = `educore/Areas/ERP/Controllers/EnquiryController.cs`
- RegCtl = `educore/Areas/ERP/Controllers/RegistrationController.cs`
- RegView = `educore/Areas/ERP/Views/Registration/Index.cshtml`
- CrmView = `educore/Areas/ERP/Views/Enquiry/EnquiryCRM.cshtml`
- RowAct = `educore/Areas/ERP/Views/Enquiry/_EnquiryRowActions.cshtml`
- FeeSvc = `EduCoreDataAccessLayer/Services/Repository/ERP/FeePaymentService.cs`
- EnqSvc = `.../EnquiryService.cs`
- SetSvc = `.../SchoolSettingsService.cs`
- Scripts are in `EduCoreDataAccessLayer/Database/`. Every proc below was checked against the live DB with `pg_get_functiondef`. The scripts that hold the live versions are:
  - `registration_fee_partial.sql`: `sp_registration_fee_record`, `fn_registration_fee_settled`, `sp_registration_fee_summary`, `sp_registration_receipt_context`
  - `registration_manage.sql`: `sp_registration_manage`
  - `enquiry_registration.sql`: `sp_enquiry_register`
  - `enquiry_crm_manage.sql`
  - `fee_receipt_cancel.sql`
  - `fee_reports.sql`: Collection Register
  - `fee_concession_cancel_report.sql`
  - `fee_day_close.sql`
  - `fee_advance.sql`: `sp_fee_receipt_get`
  - `student_master_fields.sql`: `sp_admission_manage`, which carries the registration balance

## Real-world scenario

**Sunrise Public School** (session `FY 26-27`, registration fee Rs 500, set on a Registration-point fee head):

1. **Enquiry.** Mrs. Sharma walks in for her son Aarav (Nursery). The counsellor saves an enquiry and logs two follow-up calls. Status goes New, then Interested.
2. **Registration with a part payment.** She registers Aarav from the CRM. She pays **Rs 300 cash** today and gets receipt RCP-2026-0001, with "200 outstanding" printed on it. Two days later she pays **Rs 200 by UPI** from the Registrations list (Collect Registration Fee) and gets RCP-2026-0002.
3. **Reprint.** She has lost the first slip and asks for a reprint.
4. **Discount.** A sibling family gets Rs 100 off (Fixed, reason "Sibling discount") and pays 400. A staff ward gets a 100% waiver.
5. **Mistake.** A cashier records 500 against the wrong child and cancels that receipt with reason and authoriser. The cashier collects again.
6. **Withdrawal and comeback.** A family withdraws (Cancel Registration, reason "Changed Mind"). The fee is non-refundable. A month later they come back and are registered again.
7. **Delete.** A counsellor deletes an enquiry that already has a paid receipt.
8. **Admission.** Aarav's twin enquiry (300 of 500 paid) is admitted. The unpaid 200 becomes a ledger due and is later paid at the fee counter. A cheque behind the 300 then bounces, so that receipt is cancelled after admission.
9. **End of day.** The cashier opens Day Close, the Collection Register, and the Concessions and Cancellations report.

## Money trail map

| Action (UI) | Code path | Tables written | Visible in UI | Report |
|---|---|---|---|---|
| Register + collect fee (CRM modal / Register Walk-in) | EnqCtl `RegisterEnquiry` / `RegisterWalkin` → `RegisterCoreAsync` (EnqCtl:403-492) → `sp_enquiry_register`, then `sp_registration_fee_record` | `core.enquiries` (registration_number/date, **registration_fee_paid**, registration_fee_amount frozen); `core.enquiry_status_history`; `core.receipt_counters`; `core.fee_payments` (payment_type='Registration', enquiry_id, student_id NULL, amount=cash, discount_amount/type/reason, created_by, payment_date) | Receipt popup right away (`EcReceipt.show`). Registrations list: Fee badge + **newest** receipt only. | Collection Register (receipts / by mode / head "Registration Fee"); Day Close (per cashier); discounts **not** in the Concessions report (REG-05) |
| Collect remaining fee (Registrations list) | RegCtl `MarkFeePaid` (RegCtl:130-177) → `sp_registration_manage('MarkFeePaid')` (**sets flag TRUE first**, separate transaction) → `sp_registration_fee_record` | as above | as above | as above |
| Fee summary in collect dialog | RegCtl `FeeSummary` → `sp_registration_fee_summary` | none (read) | Collect dialog | n/a |
| Reprint receipt | `/ERP/Fee/GetReceipt` → `sp_fee_receipt_get` + `sp_registration_receipt_context` | none | Receipt popup; registration block "fee / received earlier / paid on this receipt / balance" | n/a |
| Cancel a registration receipt | Only `ManageFee` → Payment History (**student only**, so possible only after admission) → `sp_fee_receipt_cancel` | `fee_payments.is_cancelled`, cancel_reason, cancel_authorized_by, cancelled_by, cancelled_at (the receipt is kept). The flag is **not** recomputed (REG-03). | Struck-through in the student's Payment History | Cancellations tab; Day Close cancelled_count; removed from the Collection Register |
| Cancel registration (withdrawal) | RegCtl `Cancel` → `sp_registration_manage('Cancel')` | `enquiries.status`='Not Interested', lost_reason; history row "(fee retained, non-refundable)". Receipts untouched. | Registrations list badge "Withdrawn"; receipt still reprintable | Receipts stay in the Collection Register |
| Delete enquiry | EnqCtl `DeleteEnquiry` → `crm_manage('DeleteEnquiry')` | `enquiries.is_active=FALSE` only (soft delete, **no history row**, no guard) | Enquiry and its receipt disappear from the CRM **and** the Registrations list | Receipts stay in the Collection Register, with the name resolved from the hidden enquiry |
| Admission from enquiry | AdmissionController Save → `sp_admission_manage('SaveAdmission', p_enquiry_id)` | `fee_payments.student_id` re-pointed to the new student (enquiry_id kept); unpaid balance → `core.student_ledger` row (head = `fn_registration_fee_head_name`, label 'Registration'); `admission_audit` 'RegistrationBalanceCarried' + 'ConvertedFromEnquiry' | Student Payment History shows the registration receipts; carried due at the fee counter | Carried due paid at the counter is reported under the **head name**, while enquiry receipts are reported as the literal "Registration Fee" (REG-17) |

## Test cases

Layers: UI-JS, Ctl (controller or C# service), Proc. "SQL X" means a check in the suite. "static" means verified by reading the code.

### Enquiry and follow-ups (no money moves; covered by `enquiry_registration_tests.sql` A-C, not repeated)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| ENQ-01 | Edit keeps registration and money fields | Edit a registered enquiry from the CRM | Status, registration number, date, flag and fee kept | Ctl | static EnqCtl:194-204 (copies existing values back) | PASS |
| ENQ-02 | Edit of an admitted enquiry | POST SaveEnquiry for an admitted enquiry | Refused | Ctl | static EnqCtl:187-192 | PASS (the proc itself does not guard) |
| ENQ-03 | Direct status change to Registration Done / Admission Confirmed | UpdateStatus / LogFollowup | Refused (action-driven) | Ctl | static EnqCtl:249, 297 | PASS |
| ENQ-04 | Withdrawn lead shows "Register" | CRM row for a Not Interested lead | Register reachable (so re-registration is a normal path) | UI | static RowAct:34 + `IsTerminal` = Admission Confirmed only (EnquiryModel.cs:201) | PASS (it feeds REG-04) |

### Registration fee: taking money

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| REG-A1 | Part payment | 300 Cash of fee 500 | Accepted; receipt 300; balance 200 returned; message says outstanding | Proc | SQL A1-A3 | PASS |
| REG-A2 | Flag on part payment | after 300 of 500 | `registration_fee_paid` FALSE | Proc | SQL A4 | PASS |
| REG-A3 | Agreed fee frozen | first receipt with fee 500 | `registration_fee_amount`=500 | Proc | SQL A5 | PASS |
| REG-A4 | Full audit on receipt | inspect row | created_by, created_at, mode, amount, type, enquiry, date | Proc | SQL A6 | PASS |
| REG-A5 | Over-collection | 201 when 200 owed | Refused with the amount owed | Proc | SQL A7 | PASS |
| REG-A6 | No number burned by a refusal | next receipt after a refusal | Consecutive | Proc | SQL A8, G19 | PASS |
| REG-A7 | Second instalment by UPI with reference | 200 UPI, ref | Balance 0, flag TRUE, mode/ref kept, both receipts live | Proc | SQL A9-A12 | PASS |
| REG-A8 | Fee raised after settlement | 100 more with fee 600 | Refused, frozen fee wins | Proc | SQL A13 | PASS |
| REG-A9 | Receipt snapshot per receipt | context for each receipt | 0/300/200, then 300/200/0 | Proc | SQL A14-A15 | PASS |
| REG-A10 | Reprint | `sp_fee_receipt_get` | Enquiry name and id | Proc | SQL A16 | PASS |
| REG-A11 | Reports agree | Register receipts, mode, head; Day Close cash/total | +300 Cash, +200 UPI, +500 head, Day Close +300 / +500 | Proc | SQL A17-A22 | PASS |
| REG-12 | Every receipt reprintable before admission | two part-payment receipts | Both reachable from the Registrations list (the only reprint place before admission) | Proc + UI | SQL BUG REG-12; registration_manage.sql:62-72 (`LIMIT 1`), RegView:417 | **BUG** |
| REG-24 | Concurrent collect (two cashiers / two tabs) | two MarkFeePaid at once on a part-paid fee | One succeeds, the other is refused | Proc | static registration_fee_partial.sql:153-178. Nothing locks the enquiry: the only UPDATE matches no rows once the fee is frozen, so both sessions read the same `v_settled` and both insert. The first payment is protected only by accident. The UI busy-button stops one user's double click, not two sessions. | **BUG** (not run: needs two sessions) |
| REG-22 | Fee only on a registered enquiry | pay on an unregistered enquiry | Refused | Proc | SQL BUG REG-22 | **BUG** (low, API-only) |
| REG-20 | Payment mode validated | mode `cash` / unknown | Refused; Day Close counts only exact `'Cash'` | Proc | SQL BUG REG-20 | **BUG** (low; the UI sends fixed values) |
| REG-21 | Future-dated receipt | p_payment_date = today+30 | Refused | Proc | SQL BUG REG-21 | **BUG** (low; the service always sends NULL) |
| REG-G | Validation | negative, zero, negative discount, platform tenant | Refused | Proc | SQL G10-G13 | PASS |

### Discounts and waivers

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| REG-B1 | 400 cash + 100 Fixed discount | reason "Sibling discount" | Settles 500; type/amount/reason stored; receipt amount = cash 400 | Proc | SQL B1-B3 | PASS |
| REG-B2 | Register shows discount | Collection Register | discount_total 100 | Proc | SQL B4 | PASS |
| REG-05 | Discount in Concessions report | Concessions tab | Listed with reason | Proc | SQL BUG REG-05; fee_concession_cancel_report.sql:38 filters `concession_total > 0`, but the registration proc writes `discount_amount` only | **BUG** |
| REG-06 | Printed receipt shows the discount | GetReceipt | Discount line, -100 | Proc + JS | SQL BUG REG-06; fee_advance.sql:353 header has no `discount_amount`; fee-receipt.js:81 prints only `concession > 0` | **BUG** |
| REG-07 | "Paid on this receipt" | context for the 400 + 100 receipt | 400 (cash) | Proc + JS | SQL BUG REG-07; registration_fee_partial.sql:297 uses amount+discount; fee-receipt.js:115 | **BUG** |
| REG-08 | Discount needs a reason (proc) | discount, NULL reason | Refused | Proc | SQL BUG REG-08 (the controller checks at EnqCtl:414; the proc does not) | **BUG** (low) |
| REG-08b | Percentage value recorded | 20% discount | `discount_value`=20 | Proc | static: the proc has no `p_discount_value`, so `discount_value` stays 0 | **BUG** (low) |
| REG-B9 | 100% waiver | 0 cash, 500 discount | 0-cash receipt with 500 discount, flag TRUE | Proc | SQL B9 | PASS |

### The "fee paid" flag

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| REG-01 | Marked paid without money | MarkFeePaid op with no receipt following | Never flagged paid without a live receipt | Proc + Ctl | SQL BUG REG-01; registration_manage.sql:136-148; RegCtl:137 runs it **before** the payment | **BUG (High)** |
| REG-01b | Payment refused after MarkFeePaid | MarkFeePaid, then collect refused | Flag = (balance = 0) | Proc + Ctl | SQL BUG REG-01b; RegCtl:171 returns failure but the flag stays TRUE | **BUG** |
| REG-23 | Flat fee-head setup (no class-wise structure) | Registrations → Collect | Fee taken with a receipt | Ctl | static RegCtl:150 and 202 use `GetCollectionPointTotalAsync` (class-wise only, SetSvc:1119). The register modal uses the **Resolved** total (EnqCtl:437, 503), which falls back to the head default. With flat heads `regFee`=0, so MarkFeePaid flips the flag, issues **no receipt**, and returns success. | **BUG (High)** |
| REG-02 | Client-trusted flag on Register | `p_registration_fee_paid`=TRUE, no payment (fee lookup 0, or workflow fee disabled) | Not flagged paid | Proc + Ctl | SQL BUG REG-02; enquiry_registration.sql:104; EnqCtl:423 passes the client value; EnqCtl:432/441 can skip the payment | **BUG (High)** |
| REG-03 | Cancel the only paying receipt | sp_fee_receipt_cancel | Flag FALSE, list says Pending | Proc | SQL BUG REG-03, REG-03b; fee_receipt_cancel.sql never touches `enquiries` | **BUG** |
| REG-04 | Re-register a paid enquiry | Register again with the fee box unticked | Flag stays TRUE (balance 0) | Proc | SQL BUG REG-04; enquiry_registration.sql:104 overwrites with FALSE | **BUG** |
| REG-16 | Carried due paid at the counter | after admission, pay the ledger due | Registration shows settled | Proc | SQL BUG REG-16; `fn_registration_fee_settled` counts only enquiry receipts | **BUG** (medium) |

### Cancelling a receipt

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| REG-C4 | Cancel with reason + authoriser | | Cancelled, row kept, who/when/why stored, balance back to 500 | Proc | SQL C4-C6 | PASS |
| REG-C7 | Reports after cancel | | Out of the Register; in the Cancellations tab; Day Close cancelled +1 | Proc | SQL C7-C9 | PASS |
| REG-C10 | Re-collect | | New number, never reused | Proc | SQL C10 | PASS |
| REG-C11 | Double cancel / blank reason | | Refused | Proc | SQL C11-C12 | PASS |
| REG-25 | Void a mistaken receipt **before admission** | wrong-child receipt on an enquiry | Some UI can cancel it | UI | static: CancelReceipt is reachable only from `Fee/ManageFee.cshtml` Payment History, which is keyed by student_id. A pre-admission registration receipt has no student, so it **cannot be voided from any screen**. | **BUG** (medium) |
| REG-26 | Old receipt snapshot after an earlier receipt is cancelled | | The printed "received earlier / balance" stays as issued | Proc | static registration_fee_partial.sql:297 recomputes from **live** receipts with `payment_id <` | **BUG** (low) |

### Withdrawal and re-registration

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| REG-D1 | Withdraw a paid registration | Cancel, reason "Changed Mind" | Not Interested + reason; history row "fee retained"; receipt live; number kept; still listed and reprintable | Proc | SQL D1-D5 | PASS |
| REG-11 | Collect on a withdrawn registration | part-paid, withdrawn, then collect 200 | Refused (the UI hides the button, the proc does not refuse) | Proc | SQL BUG REG-11 | **BUG** (low) |
| REG-D8 | Re-register | revive + Register | Same number, no new money, a second charge refused | Proc | SQL D8-D10 | PASS |
| REG-13 | Replayed Register (double click / retry) | Register an already-registered enquiry | No duplicate "Registration Done → Registration Done" history row | Proc | SQL BUG REG-13 | **BUG** (low) |
| REG-D11 | Cancel note for a part-paid registration | open the Cancel modal | "Fee retained" note shown when any money was taken | UI | static RegView:602 shows the note only when `registrationFeePaid` (i.e. fully paid) | **BUG** (low) |

### Deleting an enquiry

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| REG-09 | Delete enquiry with a paid receipt | DeleteEnquiry | Refused (or at least kept visible) | Proc + UI | SQL BUG REG-09; enquiry_crm_manage.sql:349 has no guard; RowAct:67 always shows Delete; CrmView confirm says "cannot be undone" | **BUG (High)** |
| REG-E2 | Receipt survives | | Not hard-deleted; still in the Register | Proc | SQL E2-E3 | PASS |
| REG-09b | Receipt still reprintable | | Registrations list still shows it | Proc | SQL BUG REG-09b (list filters `is_active`) | **BUG** |
| REG-09c | Delete is audited | | History row who/when | Proc | SQL BUG REG-09c | **BUG** |
| REG-09d | Delete an admitted enquiry | | Refused | Proc + UI | SQL BUG REG-09d | **BUG** |
| REG-10 | Collect on a deleted enquiry | part-paid, deleted, collect | Refused | Proc | SQL BUG REG-10 (`sp_registration_fee_record` has no `is_active` check) | **BUG** |
| REG-E6 | Register a deleted enquiry | | Refused | Proc | SQL E6 | PASS |
| REG-19 | Cross-school delete message | other school deletes our id | Enquiry untouched **and** failure reported | Proc + Ctl | SQL G7 PASS; SQL BUG REG-19 (the proc always returns success=1; EnqSvc:460 shows "Enquiry deleted.") | **BUG** (low) |

### Admission downstream

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| REG-F1 | Admit a part-paid enquiry | 300 of 500 paid | Student created; receipt re-pointed to the student with enquiry kept; 200 carried as a ledger due under the head name; audited; receipt in the student Payment History | Proc | SQL F1-F5 | PASS |
| REG-14 | Double charge after admission | collect 200 on the enquiry after admission | Refused (200 is already a ledger due) | Proc + Ctl | SQL BUG REG-14; registration_fee_partial.sql has no `admission_id` check; RegCtl `MarkFeePaid` has none either | **BUG (High)** |
| REG-15 | Same enquiry admitted twice | second SaveAdmission with the same `p_enquiry_id` (different name) | Refused | Proc | SQL BUG REG-15; student_master_fields.sql:452 carries the balance again, giving a **second 200 due**; no guard on `enquiries.admission_id` | **BUG (High)** |
| REG-F9 | Carried due collected at the counter | sp_fee_payment_collect | Ledger Paid | Proc | SQL F9 | PASS |
| REG-17 | One fee, one head name | Register head split | Same head for enquiry receipts and the carried due | Proc | SQL BUG REG-17; fee_reports.sql:99 uses the literal "Registration Fee", but the carry uses `fn_registration_fee_head_name` | **BUG** (low) |
| REG-18 | Registration receipt cancelled after admission | cheque bounce, cancel 300 | 300 becomes collectible (ledger due) | Proc | SQL BUG REG-18; the reversed money sits only on the enquiry balance, which nothing chases after admission | **BUG** (medium) |
| REG-F14 | Fully paid, then admitted | | Nothing carried | Proc | SQL F14 | PASS |

### Scope, permissions, numbering

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| REG-G1 | Cross-school money and read | school 33 on our enquiry/receipt: pay, summary, reprint, context, MarkFeePaid, Cancel, Register list | All refused or empty | Proc | SQL G1-G6, G9 | PASS |
| REG-G18 | Receipt numbers | registration + counter receipts | Unique, gap-free, one shared RCP-YYYY sequence | Proc | SQL G18-G19 | PASS |
| REG-27 | Permission to take money | user with `registration.manage` but no `fees.*` | Collecting money needs a fee permission | Ctl | static: RegCtl:113/128 MarkFeePaid needs only `registration.manage`, and EnqCtl:316 RegisterEnquiry only `enquiry.manage`. The read-only `FeeSummary` needs `fees.view` (RegCtl:185), and the reprint `/ERP/Fee/GetReceipt` needs `fees.view`. So a clerk can take money but cannot see the balance or reprint. This is inverted. | **BUG** (medium) |
| REG-28 | Tenant guard | tenant 1 / school 0 | Refused before the DB call | Ctl + Proc | static FeeSvc:61, `RegistrationService` RunActionAsync; SQL G10 | PASS |
