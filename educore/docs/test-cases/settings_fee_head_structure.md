# Test catalog: Fee Head Master and Fee Structure

Pages: `/ERP/SchoolSettings/FeeHead` and `/ERP/SchoolSettings/FeeStructure`.
SQL suite: `EduCoreDataAccessLayer/Database/tests/settings_fee_head_structure_tests.sql`. A cell like `SQL B9` names a check in that suite. `settings C4` means `settings_tests.sql`.
First run (2026-10-10, local DB, rolled back): **171 passed, 12 failed**. All 12 failures were app bugs.

**Update (same day):** every row marked BUG below has since been fixed. FH-48 is only partly changed: a same name at another collection point, or with a different refundable flag, is now refused. The suite now asserts the corrected behaviour and gained the checks B13-B14, E13, I15b-c and J7b-c. Latest run: **190 passed, 0 failed**. The Result column below still shows the state before the fixes.

Abbreviations used in the citations:
- View FH = `educore/Areas/ERP/Views/SchoolSettings/FeeHead.cshtml`
- View FS = `.../FeeStructure.cshtml`
- Ctl = `educore/Areas/ERP/Controllers/SchoolSettingsController.cs`
- Svc = `EduCoreDataAccessLayer/Services/Repository/ERP/SchoolSettingsService.cs`
- AdmCtl = `educore/Areas/ERP/Controllers/AdmissionController.cs`
- Procs: `core.sp_school_admin_fee_head_manage`, `core.sp_fee_head_list`, `core.sp_fee_head_delete_cascade` (+ `fn_fee_head_delete_guard`), `core.sp_school_admin_fee_structure_manage`. Each was checked against the live DB with `pg_get_functiondef`.

## Real-world scenario

**Sunrise Public School** (tenant 24 / school 34, session `FY 26-27`, Apr 2026 to Mar 2027):

1. **Creating the heads.** The accountant creates these heads:
   - Tuition: Monthly, 2,500
   - Admission Fee: One Time, Admission point, 15,000
   - Caution Money: One Time, Admission point, refundable, 5,000
   - Transport: Monthly, Optional
   - Annual Charges: Quarterly, 1,800
   - Activity: Half Yearly, Optional Services, 3,000
   - Exam Fee: Yearly, 2,000
   - Registration: Registration point, 500

   They also try bad input: blank, negative, huge and 3-decimal amounts, unknown cycles, duplicate names, padded names and renames.
2. **First structure.** They build the class structure for Nursery: all heads ticked except Transport and Registration, for an annual estimate of 65,200. They copy it to LKG and to next session.
3. **Admissions.** Students join on 1 April, on 1 September, and on 1 September under a "charge from session start" policy. Ledgers are generated from the structure.
4. **Mid-year revision.** A parent pays April tuition. The school then raises tuition to 2,800 and later 3,000, and drops and re-adds Activity.
5. **Head changes.** The accountant changes a head's default amount, then its billing cycle, then renames "Tuition" to "Tuition Fee". Another school also has receipts under the same name.
6. **Deactivating and deleting.** Heads are deactivated and re-activated. Heads are deleted:
   - with only unpaid dues
   - with a payment against them
   - with only a concession against them
   - with a refund against them
   - after their receipt has been cancelled
7. **Isolation.** A second school, and the platform tenant, try to read and write all of the above.

## Fee Head Master (FH)

| ID | Scenario | Steps / input | Expected result | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| FH-01 | Open the page with `fees.view` | GET FeeHead | Page renders: grid, tiles, form | Controller | static Ctl:240 `[HasPermission("fees.view")]` | PASS |
| FH-02 | Open the page without `fees.view` | User whose role lacks the key | 403 | Controller | static Helpers/HasPermissionAttribute.cs:50-51 | PASS |
| FH-03 | Open the page signed out | No auth cookie | Redirect to login | Controller | static HasPermissionAttribute.cs:37-41 | PASS |
| FH-04 | Save / Delete / Toggle without `fees.manage` | POST as a view-only role | 403 | Controller | static Ctl:267, 319, 338 | PASS |
| FH-05 | Save / Delete / Toggle without an antiforgery token | Crafted POST | 400 | Controller | static Ctl:266, 318, 337; View FH:136, 453 | PASS |
| FH-06 | Edit lookup is read-only | GET GetFeeHeadById | Needs `fees.view`, returns JSON | Controller | static Ctl:301-315 | PASS |
| FH-07 | Admin role bypass and multi-role focus | School admin; user focused on one role | Admin always allowed; focused role decides for others | Controller | static PermissionService.cs:56-84 | PASS |
| FH-08 | Permission keys exist in the catalogue | — | `fees.view` and `fees.manage` present | Proc/DB | SQL K22 | PASS |
| FH-09 | Create Tuition, Monthly, 2,500, Mandatory, Academic, Recurring | Fill form, Save | Row created. Every field stored. Active, not deleted, created_by = user | Proc | SQL A1, A2-A2i | PASS |
| FH-10 | Edit button fills every field | Click edit on a row | Name, cycle, amount, type radio, group, point and refundable all load; title becomes "Edit Fee Head"; Cancel Edit shown | UI-JS + Proc | SQL A3; static View FH:542-567 | PASS |
| FH-11 | One head per cycle and per collection point | Create the 8 Sunrise heads | All accepted; master list returns all 8 | Proc | SQL A4, A5, A6, A8 | PASS |
| FH-12 | Refundable deposit (Caution Money) | Admission point + Refundable on | Both flags round-trip; "Refundable" badge shown | Proc + UI | SQL A7; settings C5; static View FH:391-394 | PASS |
| FH-13 | Edit in place | Transport 1,200 to 1,300, Optional to Mandatory | Same id; values updated; updated_by and updated_at stamped | Proc | SQL A9, A9b | PASS |
| FH-14 | Zero amount (free diary) | Amount 0 | Accepted | Proc | SQL A10 | PASS |
| FH-15 | Amount in paise | 1234.56 | Stored exactly | Proc | SQL A11 | PASS |
| FH-16 | Third decimal place | 99.999 | Browser blocks it (step 0.01); a crafted post is rounded to 100.00 | UI + Proc | SQL A12; static View FH:182 | PASS |
| FH-17 | Blank amount | Amount empty | Saved as 0, not NULL | Controller + Proc | SQL A13; static FeeHead.cs:25 (non-nullable decimal) | PASS |
| FH-18 | Very large amount | 9,999,999,999.99 / 10,000,000,000 | First accepted. Second refused (no silent clip). The raw "numeric field overflow" text is shown in the toast | Proc + Svc | SQL A14, A15; static Svc:881-886 | PASS |
| FH-19 | Negative amount | -0.01 | `min=0` hint in browser; proc refuses with a sentence | UI + Proc | SQL B2; static View FH:181 | PASS |
| FH-20 | Blank name | "" / NULL | JS toast; controller check; proc refuses | UI-JS + Ctl + Proc | SQL B1; settings C1; static View FH:521-526, Ctl:274-278 | PASS |
| FH-21 | Name of only spaces | "   " | JS trim, controller IsNullOrWhiteSpace, and proc trim all reject | UI-JS + Ctl + Proc | static View FH:517, Ctl:274; settings C1 | PASS |
| FH-22 | Name length | 80 chars / 81 chars | 80 accepted (form maxlength 80); 81 refused | UI + Proc | SQL A16, A17; static View FH:148 | PASS |
| FH-23 | No billing cycle | Cycle not chosen / blank / NULL | JS toast; controller; proc refuse | UI-JS + Ctl + Proc | SQL B4, B5; static View FH:528-533, Ctl:280-284 | PASS |
| FH-24 | Unknown cycle (crafted post) | "Weekly" | Refused | Proc | SQL B3 | PASS |
| FH-25 | Cycle in odd case or with spaces (crafted post / legacy data) | `" monthly "` | Stored as canonical "Monthly" | Proc | SQL B9: **stored as " monthly "** | BUG |
| FH-26 | No fee type | Radio not chosen / NULL | JS toast; controller; proc refuse | UI-JS + Ctl + Proc | SQL B7; static View FH:535-539, Ctl:286-290 | PASS |
| FH-27 | Unknown fee type (crafted post) | "Compulsory" | Refused. Only Mandatory and Optional drive the tiles and the pre-ticks | Proc | SQL B10: **accepted** | BUG |
| FH-28 | Unknown collection point | "Counter" | Refused | Proc | SQL B6 | PASS |
| FH-29 | NULL point or group | Crafted post | Defaults to Recurring / Academic (group is for reporting only, so it is not validated) | Proc | SQL B11 | PASS |
| FH-30 | Edit an id that does not exist | id 999999 | "Fee head not found."; no insert | Proc | SQL B12 | PASS |
| FH-31 | A refused save leaves nothing behind | Bad inputs B1-B7 | Row count unchanged | Proc | SQL B8 | PASS |
| FH-32 | Create a name that already exists, in a different case | "zz tuition" | One head, original casing kept. This is an upsert by design; the message does not say an existing head was overwritten | Proc | SQL C1, C2; settings C4 | PASS |
| FH-33 | Create a duplicate with padding | "  ZZ Lab Fee  " | Same head | Proc | settings C4c | PASS |
| FH-34 | Rename onto another head's name | Transport renamed to "ZZ Tuition" | Refused with "already exists"; Transport unchanged | Proc | SQL C3, C4 | PASS |
| FH-35 | Rename onto a case or space variant of another head | "  ZZ TUITION " | Refused | Proc | SQL C5 | PASS |
| FH-36 | Head changes its own casing | "ZZ TRANSPORT" | Allowed | Proc | SQL C6 | PASS |
| FH-37 | Rename with padding | "   ZZ Bus Fee   " | Stored trimmed | Proc | SQL C7 | PASS |
| FH-38 | Re-save unchanged values twice | Save, Save | Idempotent: one row, OK | Proc | SQL C8 | PASS |
| FH-39 | Double-click Save | Two fast clicks | Second click disabled by the global guard | UI-JS | static Views/Shared/Sections/_Scripts.cshtml:80-92 | PASS |
| FH-40 | Rename a head that is already billed and paid ("Tution" fixed to "Tuition") | Rename after admissions and a receipt | Ledger, frozen plan, structure lines and this school's receipt lines all carry the new name; message gives the row count | Proc | SQL I16-I20 | PASS |
| FH-41 | Rename must not touch other schools | Another school has a receipt line with the same name | Their receipt line is unchanged | Proc | SQL I21: **school 33's receipt line renamed**. The proc's `UPDATE core.fee_payment_details ... WHERE fee_head_name = v_old_name` has no tenant or school filter | BUG |
| FH-42 | Deactivate a head (proc) | Toggle | is_active false; message says "inactive — stays on past records" | Proc | SQL D1 | PASS |
| FH-43 | Deactivate or re-activate from the page | Look for a toggle; look at an inactive row | Status visible and a toggle button present | UI | static View FH:372-467: **no toggle button and no Active/Inactive badge anywhere**. `ToggleFeeHeadStatus` (Ctl:336-353) cannot be reached from the UI, and an inactive head looks identical to an active one | BUG |
| FH-44 | Inactive head still visible to master readers | GetFeeHead / grid / by id | Returned with is_active = false | Proc | SQL D2, D3, D4 | PASS |
| FH-45 | Re-activate | Toggle again | Active; message "active again" | Proc | SQL D5 | PASS |
| FH-46 | Toggle an unknown id | 999999 | "Fee head not found." | Proc | SQL D6 | PASS |
| FH-47 | Edit an inactive head | Change its amount | Stays inactive | Proc | SQL D7 | PASS |
| FH-48 | Create form with an inactive head's name | Type "ZZ Bus Fee" while it is inactive | Revives it (upsert by design). Risk: no warning to the user | Proc | SQL D8 | PASS |
| FH-49 | Inactive head not offered for a new structure | Open Fee Structure | Head not listed | Controller | static Ctl:409 `.Where(fh => fh.IsActive)` | PASS |
| FH-50 | Inactive head not charged on admission | Admission fee preview | Filtered out | Controller | static AdmCtl:486-489 (`d.IsActive`) | PASS |
| FH-51 | Search the grid | "zz " | Case-insensitive; total_count is the full set | Proc | SQL E1 | PASS |
| FH-52 | Paging | Size 3, page 2, page 99, page 0 / size 0 | 3 rows with full total; rows 4-6; empty; clamped to 1/10 | Proc | SQL E2-E5; static ListModelBase.cs:19-29 | PASS |
| FH-53 | Page past the end | URL `?Page=99` | Tiles and "Showing" still show the real totals | Svc + View | static Svc:788-793 reads the counts from the first row, so 0 rows gives 0 / 0 / 0 tiles and "No fee heads… Try changing search" | BUG |
| FH-54 | Filter by cycle | "monthly" (any case) | Only that cycle; dropdown keeps the choice | Proc + View | SQL E6; static View FH:330-337 | PASS |
| FH-55 | Sort | Amount desc / name desc / junk column | Largest first / Z-A / falls back to name (no injection) | Proc | SQL E7, E8, E9 | PASS |
| FH-56 | Tiles across pages | Page size 2 | Mandatory/Optional count the whole filtered set | Proc | SQL E10 | PASS |
| FH-57 | Search with no match | "no such head" | No rows; empty state shown | Proc + View | SQL E11; static View FH:358-370 | PASS |
| FH-58 | Pasted search with surrounding spaces | " zz tuition " | Trimmed; finds Tuition | Proc | SQL E12: **0 rows**. Proc tests `TRIM(p_search)=''` but matches the untrimmed text | BUG |
| FH-59 | Search for "%" or "_" | "%" | Treated literally | Proc | static sp_fee_head_list: `ILIKE '%'\|\|p_search\|\|'%'` is not escaped, so "%" matches everything (cosmetic) | BUG |
| FH-60 | Page-size selector | Pick 25 | Grid re-queries; size clamped 1-200 | UI + Model | static View FH:474; ListModelBase.cs:25-29 | PASS |
| FH-61 | State after Save or Delete | Filter "Monthly", page 2, then delete | Return to the same filter and page | Controller | static Ctl:299, 333, 352: `RedirectToAction(nameof(FeeHead))` drops search, filter and page. A failed save also loses the typed form (UX) | BUG |
| FH-62 | Cancel Edit | Click Cancel Edit | Form reset; FeeHeadId 0 so the next save creates | UI-JS | static View FH:503-514, 570-572 | PASS |
| FH-63 | Edit lookup fails (403 / 500 / network) | Click edit | Error toast | UI-JS | static View FH:545: `$.get` has no error handler, so nothing happens | BUG |
| FH-64 | Delete confirm | Click trash | Confirm dialog naming the head | UI-JS | static View FH:449-451 + site.js:256 | PASS |
| FH-65 | Confirm explains the cascade | Delete a head on every class structure | Dialog warns that unpaid dues, plans and structure lines will be removed and empty structures retired | UI | static View FH:449: "Delete this fee head?" only; the impact appears only afterwards | BUG |
| FH-66 | Delete a head with only unpaid dues (Activity) | Delete | Dues, plan rows and structure lines removed; structure rollups recomputed; head soft-deleted; message gives the counts | Proc | SQL J1-J6; settings C6-C7 | PASS |
| FH-67 | Delete a class's only head | Delete | Structure retired, not left at 0 | Proc | SQL J7 | PASS |
| FH-68 | Delete a head with a payment (Tuition Fee, April paid) | Delete | Refused. Message points to "inactive". Nothing touched | Proc | SQL J8-J12 | PASS |
| FH-69 | Delete a head with only a concession / only a refund | Delete | Refused | Proc | SQL J13, J14 | PASS |
| FH-70 | Delete after the only receipt is cancelled | Collect, cancel, delete | Refused before the cancel, allowed after; cancelled receipt lines kept | Proc | SQL J15, J16, J17 | PASS |
| FH-71 | Delete twice / unknown id / id 0 | — | Not found / not found / refused | Proc | SQL J18, J19, J20 | PASS |
| FH-72 | A deleted head is gone everywhere | Toggle, grid, by id, edit | Not found / absent | Proc | SQL J21-J25 | PASS |
| FH-73 | Name re-use after delete | Recreate "Admission Fee"; rename onto "Activity" | New id; rename allowed | Proc | SQL J26, J27 | PASS |
| FH-74 | Refusal says "mark it inactive" | Delete a paid head from the page | User can follow the advice | UI | static: no toggle in the UI (see FH-43) | BUG |
| FH-75 | Cache invalidated after a write | Save / Delete / Toggle, then open Fee Structure / Admission | Fresh list immediately | Svc | static Svc:892, 928, 954 `_cache.Remove(FeeHeadsKey)` | PASS |
| FH-76 | Cache is per tenant | Two schools | Separate keys | Svc | static Svc:39 `AppCache.Key("feeheads", tenantId, schoolId)` | PASS |
| FH-77 | "Not collected" / "Not charged" badges | Registration fee or security deposit switched off in Workflow | Badge on the head | Ctl + View | static Ctl:258-262; View FH:400-413 | PASS |
| FH-78 | HTML in a head name | Name `<img src=x onerror=alert(1)>` | Rendered as text everywhere | UI | Grid OK: Razor encodes View FH:385. **Flash toast is not encoded**: the proc message `"<name>" saved.` goes through TempData into toastr, whose `escapeHtml` defaults to false (_Scripts.cshtml:61-69, 113-121) | BUG |
| FH-79 | Platform or school-0 scope | tenant 1 / school 0 on every operation | Refused by the service guard and the proc | Svc + Proc | SQL K1-K6; settings E2; static Svc:851, 898, 936 | PASS |
| FH-80 | Another school uses our ids | Read, edit, toggle, delete our head | Not found; our row unchanged | Proc | SQL K11-K16; settings E3 | PASS |
| FH-81 | Same name in two schools | "ZZ Tuition Fee" in both | Two independent heads | Proc | SQL K21 | PASS |
| FH-82 | Proc business errors show as a message, not a 500 | Duplicate rename, negative amount | Toast with the proc sentence; Warning logged with SqlState | Svc | static Svc:877-887, 912-922 | PASS |

## Fee Structure (FS)

| ID | Scenario | Steps / input | Expected result | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| FS-01 | Access rules | GET with `fees.view`; Save/Delete need `fees.manage` + token | Enforced | Controller | static Ctl:358-360, 433-435, 461-464, 502-505; View FS:47 | PASS |
| FS-02 | Default session | Open the page | Current session preselected | Ctl + DB | static Ctl:366-367 + `config.sp_dropdown_common` ORDER BY is_current DESC | PASS |
| FS-03 | Class list follows the chosen session | Switch session in the dropdown | Classes reload for that session | UI + Ctl | static Ctl:371-374 loads the first year's classes only; View FS:666 just recomputes the summary | BUG |
| FS-04 | No classes configured | New school | Warning with a link; Save disabled | View | static View FS:118-127, 299 | PASS |
| FS-05 | No active fee heads | All heads inactive or deleted | A message pointing to Fee Head Master | View | static View FS:207-218, 299: Save is disabled but the Fee Heads card is just empty | BUG |
| FS-06 | Heads grouped by cycle; empty groups hidden | Mixed cycles | Five group headings, only the non-empty ones | View | static View FS:207-218 | PASS |
| FS-07 | Head saved with a non-canonical cycle (see FH-25) | " monthly " head exists | Shown and saved | View + Ctl | static View FS:218/228: never rendered, which leaves a gap in the `FeeHeads[i]` indexes (View FS:237), so MVC binding stops there and drops every later head on Save | BUG |
| FS-08 | Mandatory heads pre-ticked; Select Mandatory button | Open; click the button | Mandatory heads ticked, optional ones unticked | UI-JS | static View FS:250, 668-676 | PASS |
| FS-09 | Amount defaults to the head's default | Open | Amount input = default amount | View | static View FS:275; Ctl:425 | PASS |
| FS-10 | Live summary and annual formula | Tick heads, type amounts | One Time + Monthly x12 + Quarterly x4 + Half Yearly x2 + Yearly | UI-JS | static View FS:567-626 | PASS |
| FS-11 | Summary shows Quarterly and Half-Yearly rows | Quarterly head ticked | Visible line items | View | static View FS:346-359: only One Time / Monthly / Yearly rows exist; Quarterly and Half Yearly appear only inside the annual total | BUG |
| FS-12 | Save with nothing chosen | No session / class / head | JS toast; server re-checks | UI-JS + Ctl | static View FS:773-790; Ctl:469-487 | PASS |
| FS-13 | Save Nursery: Tuition 2,500, Annual Charges Q 1,800, Activity H 3,000, Exam Y 2,000, Admission 15,000, Caution 5,000 | Save | Every rollup correct; annual 65,200; active; created_by | Proc | SQL F1-F2g | PASS |
| FS-14 | Lines read back | Edit / admission read | 6 lines with head id, name, cycle, amount; listed with head count and sorted names | Proc | SQL F3-F8 | PASS |
| FS-15 | Several classes in one save | Tick 2 classes | One structure each; message lists the classes saved; a partial failure says where it stopped | Proc + Svc | SQL F9; static Svc:1293-1330 | PASS |
| FS-16 | Copy to next session | Same class, "2027-28" | Separate record; this session untouched (UI path: Edit, change session, Save) | Proc + UI | SQL F10; static View FS:684 | PASS |
| FS-17 | Zero-amount head on a structure | Free Diary 0 | Counted as a head | Proc | SQL F11 | PASS |
| FS-18 | Saving over existing classes | Tick classes that already have structures | Warning boxes before Save; existing structures updated | UI-JS | static View FS:537-565, 792-796 | PASS |
| FS-19 | Re-save identical | Save twice | Same id, no extra rows, one header | Proc | SQL G1, G2 | PASS |
| FS-20 | Mid-year revision | Tuition 2,800, Activity dropped | Rollups recomputed; dropped line soft-deleted and hidden; head count 5; audit stamps | Proc | SQL G3-G7 | PASS |
| FS-21 | Re-add a dropped head | Activity back at 3,200 | Same detail row revived with the new amount | Proc | SQL G8 | PASS |
| FS-22 | Editing one class leaves the others alone | Edit Nursery | LKG unchanged | Proc | SQL G9 | PASS |
| FS-23 | Inactive head on a saved structure | Deactivate Exam Fee | Stays on the structure (admission filters it by flag) | Proc | SQL G10 | PASS |
| FS-24 | Edit a structure holding an inactive head | Edit, then Update | Inactive head kept | UI + Ctl | static Ctl:409 lists active heads only and View FS:725-735 ticks only rendered rows, so Update silently drops the inactive head | BUG |
| FS-25 | Delete a structure (proc) | DeleteFeeStructure | Header and lines soft-deleted; not listed; not offered to admission; second delete "not found" | Proc | SQL G11-G15 | PASS |
| FS-26 | Delete a structure (UI / service) | — | Button exists; failure reported | UI + Svc | static View FS:482-489 has only an Edit button. Svc:1335-1355 returns 1 whenever any row comes back, so the "not found" result shows as "Fee structure deleted." (Ctl:513-514) | BUG |
| FS-27 | Save a deleted class again | Save | Revived with the same id | Proc | SQL G16 | PASS |
| FS-28 | No lines | NULL / [] | Refused | Proc | SQL H1, H2 | PASS |
| FS-29 | Negative amount (crafted post; the input has only `min=0`) | -500 | Refused like the head master | Proc | SQL H3: **accepted, annual -6,000**, and it would go into the ledger | BUG |
| FS-30 | Blank / NULL class (crafted `SelectedClasses=`) | "" / NULL | Refused | Ctl + Proc | SQL H4: **"" accepted** (Ctl:475 checks only Count); H5 NULL refused | BUG |
| FS-31 | Blank session | "   " | Refused | Ctl + Proc | Ctl:469 blocks it at the controller; SQL H6: proc accepts it | BUG |
| FS-32 | Another school's head id in the post | feeHeadId of school 33 | Refused | Proc | SQL H7: **accepted** | BUG |
| FS-33 | Deleted head id in the post | — | Refused | Proc | SQL H8: **accepted** | BUG |
| FS-34 | Name and cycle in the hidden inputs are edited | feeHeadId = Tuition, name "Hacked Name", cycle "Weekly" | Name and cycle taken from the master | Proc | SQL H9: **stored as posted**. Unknown cycles fall into the "yearly" bucket | BUG |
| FS-35 | Same head twice in one save | Duplicate line | Refused atomically (raw PG text) | Proc | SQL H10, H11 | PASS |
| FS-36 | Line without a head id | — | Refused | Proc | SQL H12 | PASS |
| FS-37 | Rollups match the stored lines | 2500.555 | Annual = 12 x the stored 2500.56 | Proc | SQL H13: **30006.66 vs 30006.72** (rollups use the unrounded input) | BUG |
| FS-38 | Annual total overflows | 999,999,999/month | Refused | Proc | SQL H14 | PASS |
| FS-39 | Admission on 1 April from the structure | Admit | 12 monthly, 4 quarterly ("Apr 2026 - Jun 2026"), 2 half-yearly, 1 yearly, one-time "Admission"; total billed = structure annual | Proc | SQL I1-I6 | PASS |
| FS-40 | Admission on 1 September | Admit | 7 months; quarters snap to Jul / Oct / Jan; 2 halves | Proc | SQL I7, I8 | PASS |
| FS-41 | "Charge fees from" = SessionStart | Admit on 1 September | 12 months | Proc | SQL I9 | PASS |
| FS-42 | Revision after a payment | Pay April, raise tuition to 3,000 | Admitted students' ledger and frozen plan unchanged; payment intact; next admission offered 3,000 | Proc | SQL I10-I13 | PASS |
| FS-43 | Head default amount changed | 9,999 on the master | Saved structures unchanged | Proc | SQL I14 | PASS |
| FS-44 | Head billing cycle changed | Annual Charges Quarterly to Half Yearly | Saved structures follow, or the user is warned | Proc | SQL I15: **structure still "Quarterly"**. The page files the head under Half Yearly while admission keeps billing quarterly (AdmCtl:494 uses `d.Frequency`) until each class is re-saved | BUG |
| FS-45 | Edit button | Click edit on a saved row | Single-class edit mode; saved heads ticked with saved amounts; button reads "Update Structure" | UI-JS + Ctl | static View FS:678-753; Ctl:433-459 | PASS |
| FS-46 | Edit-mode locks | Select All / Clear / tick a second class | Blocked or single-select | UI-JS | static View FS:628-662 | PASS |
| FS-47 | Exit edit mode | Click Exit | Normal mode; classes cleared | UI-JS | static View FS:755-766 | PASS |
| FS-48 | Structure of a class that has been removed | Class renamed in setup | Hidden from the list; edit refuses with a clear toast | Ctl + UI | static Ctl:383-399; View FS:694-699 | PASS |
| FS-49 | Search Saved Structures with numeric class names ("1".."8", as in school 34) | Type in "Search class..." | Filters rows | UI-JS | static View FS:803: jQuery `.data('class')` turns "5" into the number 5, so `(5 \|\| '').toLowerCase()` throws TypeError and the search does nothing | BUG |
| FS-50 | Search by head name | "Exam" | Rows containing it | UI-JS | static View FS:804-808 (works only when no class name is numeric, see FS-49) | PASS |
| FS-51 | Reset button | Click Reset (also in edit mode) | Summary and edit mode reset | UI-JS | static View FS:294 is a plain `type="reset"`: no `updateSummary()`, edit mode stays, hidden IsEditMode stays "true" | BUG |
| FS-52 | HTML in a head or class name | Head `<img src=x onerror=alert(1)>` | Shown as text | UI-JS | static View FS:579, 601: names are put into `.html()` without `EC.esc`. Mandatory heads are pre-ticked and `updateSummary()` runs on load (812), so it fires on every page open | BUG |
| FS-53 | "No fee heads" badge on a saved row | Structure with 0 heads | Red badge | View | static View FS:448-453 | PASS |
| FS-54 | Recurring column | Monthly + quarterly + half | /mo, /qtr, /half-yr lines | View | static View FS:463-468 | PASS |
| FS-55 | Created By / Updated By columns | Saved row | Names | View | static View FS:478-479 print the raw user id (`int`, e.g. "39") | BUG |
| FS-56 | Platform or school-0 scope | tenant 1 / school 0 on save, list, delete | Refused | Svc + Proc | SQL K7-K10; static Svc:966, 1266, 1337 | PASS |
| FS-57 | Another school against our structures | Read lines, list, delete | Nothing returned; delete "not found" | Proc | SQL K17, K18, K19 | PASS |
| FS-58 | Same class and session name in another school | Other school saves "Nursurry / FY 26-27" | Independent | Proc | SQL K20 | PASS |
| FS-59 | Admission reads collection point, refundable and active from the master | Admission form | Lines enriched from the cached heads | Svc | static Svc:1053-1071 | PASS |
| FS-60 | Refundable deposit excluded from the admission discount | Concession at admission | Caution Money skipped | Ctl | static AdmCtl:352-357 | PASS |
| FS-61 | Registration-point heads not charged at admission | Registration head on the structure | Excluded | Ctl | static AdmCtl:486-489 | PASS |
| FS-62 | Deleting a head recomputes or retires structures | See FH-66, FH-67 | Rollups correct; empty structure retired | Proc | SQL J4, J5, J7 | PASS |
| FS-63 | Edit lookup needs class and session | Missing parameter | `success:false` message | Ctl | static Ctl:441-442 | PASS |
| FS-64 | Double-click Save | — | Guarded | UI-JS | static _Scripts.cshtml:80-92 | PASS |

**Totals:** FH has 82 cases (PASS 70, BUG 12). FS has 64 cases (PASS 46, BUG 18). Overall 146 cases.
