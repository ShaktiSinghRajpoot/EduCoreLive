# Test cases: student records, transport (non-money), TC and ID card documents

**Scope:** what the office types, searches and prints: a child's record, the directory, photos, the promotion screen, routes, stops and vehicles, the Transfer Certificate and the ID card. The money side of admission, exit, promotion, bus billing and TC dues is in `money_admission_lifecycle.md` and is not repeated here.

- **SQL suite:** `EduCoreDataAccessLayer/Database/tests/students_transport_documents_tests.sql`. It uses tenant 24 / school 34 / user 39, with 23/33 as the cross-school fixture. Everything runs in one transaction and is rolled back. When an accepted bad write would spoil the fixture for later checks, the test undoes it with a private `__undo__` exception after recording the result.
- **Phase 1 run (2026-10-10):** `RESULT: 69 passed, 28 failed`. All 28 failures are `BUG …` checks; no failure comes from the test's own logic. After the rollback, no `ZZ-STD-*` student, `ZZ` route or vehicle, `ZZ NEXT` session, TC or audit row was left behind, and the school-34 TC counter is unchanged.
- **Phase 2 run (after the fixes, same day):** `RESULT: 120 passed, 0 failed`. The 28 `BUG` checks keep their ids without the prefix, and 23 checks were added (Aadhaar, admission roll, legacy rows, photo audit, TC print / void / uuid, leaver view, capacity, vehicle switch-off, fare snapshot, soft delete). Rows marked BUG / GAP below are FIXED unless §0 says otherwise.
- **Live procedures:** each was confirmed with `pg_get_functiondef` before its check was written: `sp_student_update`, `sp_student_set_photo`, `sp_student_list`, `sp_admission_manage` (GetStudents / GetStudentById), `sp_class_active_sections`, `sp_class_ladder`, `sp_student_promote`, `sp_student_enrolment_history`, `sp_student_history_get`, `sp_transport_route_manage`, `sp_transport_vehicle_manage`, `sp_transport_assign_manage`, `sp_transport_routes_dropdown`, `sp_tc_manage`, `sp_id_card_students`, `sp_id_card_sections`, `fn_public_id_to_id`.
- **No duplication:** nothing here repeats `promotion_tests`, `transport_tc_tests` or `money_admission_lifecycle_tests`. Where an area is already covered, the row says so.
- **How to read it:** every check states the correct behaviour. `BUG` means the application is wrong. *static* rows were checked by reading the code (C#, Razor, JS); they can't be reached from SQL. `INFO` rows record behaviour that is waiting on a business decision (§4).

---

## 0. Phase 2: what was fixed and where

Apply in this order (all safe to re-run):

1. `transport_module.sql`
2. `transfer_certificate.sql`
3. `student_update.sql`
4. `student_photo.sql`
5. `student_list.sql`
6. `student_master_fields.sql`
7. `student_exit.sql`

Apply `transport_module.sql` after `hotfix_2026_10_10.sql`, and never re-run that hotfix: it holds an older `sp_transport_assign_manage`.

| Bug | Fix | Check |
|---|---|---|
| TRN-GETASSIGN | `transport_module.sql:550` (alias `rt`, from the hotfix) | E15a |
| TC-ISSUE-PRINT | `transfer_certificate.sql:334` returns `public_id`; `TcController.cs:39`; `Inactive.cshtml:427` opens `Print?id=<uuid>&print=1` | F1 (TC-ISSUE-PRINT) |
| TC-VOID-PRINT | `transfer_certificate.sql:357`; `Tc/Print.cshtml:172` (VOID stamp, no print button) | F6 |
| TC-GET-PRINT | `TcController.cs:53` (GET uses `Get`, never counts) and `:69` `MarkPrinted` (POST, `students.manage`); `Tc/Print.cshtml:177, 245` (NOT AN ORIGINAL until the button counts it; `?print=1` runs once and is removed from the URL) | F12d |
| TC-VOID-VISIBLE | `transfer_certificate.sql:385`; `Tc/Register.cshtml:85` | F12c |
| TC-DAYS / -NEG / -APPDATE | `transfer_certificate.sql:281-289` | F8–F10 |
| PRO-PICK | `Promotion.cshtml:583, 600` (one `unpicked` map; desktop and mobile boxes mirror) | static |
| PRO-RADIO | `Promotion.cshtml:495-499, 558` (mobile radios `ocm<id>`) | static |
| PRO-ROSTER | `student_master_fields.sql:557` | D9 |
| PRO-SECTIONS | `student_update.sql:328` `sp_class_setup_sections` (new); `StudentController.cs:142`; `Promotion.cshtml` and `EditStudent.cshtml` pass the session | D0, D0b |
| STU-EDIT-DROP | `EditStudent.cshtml:303` (status card → link to Mark as left); email, WhatsApp, caste and remarks removed; photo uploads at once (`:431`) | static |
| STU-EDIT-PHOTO / -RERENDER | `EditStudent.cshtml:33`; `StudentController.cs:536` | static |
| STU-DOB-FUTURE / -ADM / STU-MOBILE / STU-GENDER / STU-AADHAAR | `student_update.sql:151-173`; `StudentController.cs:547` onwards | A2–A4, A8, A10c |
| STU-DUP-EDIT / STU-ROLL-DUP | `student_update.sql:188, 202` | A6, A7 |
| STU-AADHAAR-ADM / STU-ROLL-ADM | `student_master_fields.sql:279, 291` | A10e, A10f |
| STU-AUDIT | `student_update.sql:266` (`StudentEdited`, old → new; Aadhaar masked) | A10, A10b |
| STU-ENROL-ROLL | `student_update.sql:258` | A11 |
| STU-SEARCH-SPACE / -WILDCARD | `student_list.sql:39`; also GetStudents, `student_exit.sql`, TC List (strpos) | B5, B6 |
| STU-SORT-CLASS | `student_list.sql:135` (`class_order` = setup `display_order`) | B8 |
| STU-EXPORT-FEE / -CSVINJ | `StudentList.cshtml:446, 458`; `AdmissionController.cs:490` | static |
| STU-XSS-DASH / STU-DASH-FAKE | `Dashboard.cshtml:453` (`ic`), `ps`, fee and doc rows escaped; `:729` real address and contact; real status | static |
| STU-LEFT-VIEW | `student_master_fields.sql:574` (GetStudentById includes leavers); `StudentController.cs:335, 505`; `Inactive.cshtml` links the name; `Dashboard.cshtml:371` read-only banner | F12f |
| PHO-08 / PHO-12 | `StudentController.cs:216, 234`; `student_photo.sql:55, 65` | C4 |
| TRN-DUP-ROUTE / TRN-NEG-FARE | `transport_module.sql:184, 192` | E2, E3 |
| TRN-DEL-STOP / TRN-DEL-ROUTE | `transport_module.sql:257, 280` (an empty route is soft-deleted and its buses detached) | E6, E19, E20 |
| TRN-INACTIVE-ROUTE / -STOP | `transport_module.sql:597` | E7, E8 |
| TRN-CAPACITY (approved) | `transport_module.sql:113, 607` (seats = active buses' capacity; no capacity set = unlimited); riders / seats on Routes and Assign | E5, E5b, E5c |
| TRN-SOLD (approved) | `transport_module.sql:459` (last active bus of a ridden route) | E12, E12b–d |
| Fare change (approved) | Riders keep their snapshotted fare; `Routes.cshtml` and `Assign.cshtml` say so | E6c |
| TRN-DUP-VEH / TRN-CAP-NEG / TRN-VEH-SCOPE | `transport_module.sql:385, 389, 397`; GetVehicles joins only this school's live routes (`:355`) | E9–E11b |
| TRN-SCOPE-MSG | `transport_module.sql:204, 273, 303` (and Vehicle not found) | E17 |
| TRN-XSS-ASSIGN | `Assign.cshtml:63, 91` onwards (`EC.esc` everywhere) | static |
| TRN-09 | `Routes.cshtml:136`, `Vehicles.cshtml:103` (busy, fail handlers, capacity ≥ 1) | static |
| SEC-20 | `AdmissionController.cs:48, 458` (no routes offered, no bus assigned or billed when Transport is off) | static |
| IDC-NOTE / -MISSING-LIST / -BROKEN-IMG / -YEAR-STALE | `IdCard/Print.cshtml:78, 110, 136` (missing list on screen, no auto-print while any are missing); `IdCardController.cs:58` `PhotoCheck`; `IdCard/Index.cshtml:101, 137` | static |
| Admission/Dashboard mock | View and CSS deleted; `AdmissionController.cs:92` redirects to the student list | static |
| D4 TC number year | **Kept** (restarts 1 January, by decision; commented in `transfer_certificate.sql`) | — |
| PHO-07 content sniffing | **Not changed**: extension allow-list + `nosniff` header kept as sufficient | — |

---

## 1. Real-world scenario

1. **Correcting a record.** The office fixes Pihu's DOB, re-types the parent mobile with stray spaces and adds her Aadhaar. All three are saved correctly and the mobile is trimmed (A1). However:
   - The same form also accepts a DOB in the future, a DOB after the admission date, and the mobile `98AB5`. Admission refuses all three, but the edit path has no server-side check (STU-DOB-FUTURE, STU-DOB-ADM, STU-MOBILE).
   - Nothing records **who changed the DOB or the mobile, or what the old values were**. Only class and section changes are audited (STU-AUDIT).
   - On the Edit page, the e-mail, WhatsApp, caste, remarks, **student status ("Left", "Transfer" with a required reason)** and the photo picker are all thrown away on save, while the page still says "Student updated successfully" (STU-EDIT-DROP).
2. **Photo.** An upload from the directory works. The file name is built on the server, so there is no path traversal, and size and extension are checked (C1–C3, PHO-*). Replaced files are never deleted from disk, and the Edit page never shows the existing photo.
3. **Directory search.** Search by name in any case, by admission number in lower case, by part of the mobile, and with padding all work (B1–B4). A double space between names finds nothing, `%` lists everyone, and "sort by class" puts class 2 before LKG (B5, B6, B8). The **CSV export ignores the Fee filter**, so "Pending only" exports everyone, and it does not neutralise `=`/`+`/`@` at the start of a cell (STU-EXPORT-*).
4. **Promotion, Class 5 at session end, two retained.** The procedure handles it correctly: 2 promoted, 2 retained, the 5-B child skipped with a reason, another school's id skipped, a double submit refused, and the history card shows who did it (D1–D10). On the screen, though:
   - **Unticking a student does not exclude them.** `picked()` also reads the hidden mobile-layout checkbox, which is still ticked (PRO-PICK).
   - The desktop Promote/Retain/Pass-out toggles share radio names with the hidden mobile copies, so the desktop selection never shows as selected (PRO-RADIO).
   - Reloading the roster after the run lists all four moved children again (PRO-ROSTER).
   - An empty section (5-C) is never offered as a target, either here or on Edit Student (PRO-SECTIONS).
5. **Bus route with 3 stops and a vehicle at capacity.** Saving the route and its stops works (E1). A 2-seat bus takes a third child without any warning; capacity is neither checked nor shown anywhere (E5, §4). **The Assign page cannot show any student's current bus.** `GetForStudent` raises `record "r" is not assigned yet` on every call, so the "Currently assigned / Remove Transport" panel never appears (TRN-GETASSIGN). The office can also:
   - delete the route while children ride it (TRN-DEL-ROUTE);
   - drop the stop they board at (TRN-DEL-STOP);
   - assign a child to a switched-off route or a removed stop (TRN-INACTIVE-*);
   - create the same route or vehicle twice (TRN-DUP-*);
   - enter negative fares or capacities (TRN-NEG-FARE, TRN-CAP-NEG).

   **Stored XSS:** the Assign page builds its dropdowns from names without escaping them (TRN-XSS-ASSIGN).
6. **Vehicle sold (switched off) while assigned.** The status changes, the riders stay on the route, and nobody is warned (E12, §4).
7. **TC in Board format, then voided.** Issue keeps every Board field, numbers run on without gaps, a re-issue takes a fresh number, and the void records why, who and when (F1–F7). However:
   - **"Issue & Print" opens a 404.** The page passes the integer `tcId` where `Tc/Print` expects the public uuid (TC-ISSUE-PRINT).
   - **A voided certificate still prints as a clean original.** The procedure serves it, and the print template has no VOID stamp (TC-VOID-PRINT).
   - Days present > working days, negative days, and an application date in the future are all accepted (TC-DAYS*, TC-APPDATE).
   - The void reason is never shown in the Register (TC-VOID-VISIBLE).
8. **ID cards for 7-A with a missing photo.** The sheet holds the right children in numeric roll order (1, 2, 10). The missing photo prints a placeholder, and leavers and other schools are excluded (G1–G8). The sheet still carries a stale "photos are blank until upload is enabled" banner, and nothing lists which children have no photo before printing (IDC-*).

---

## 2. Test catalog

Layer: **DB** = stored procedure, **C#** = controller/service, **JS** = view script, **Razor** = server-rendered view.

### STU: student record and directory

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| STU-01 | Correct DOB, mobile, Aadhaar | DOB 2016-06-06, mobile `'  9876543210 '`, Aadhaar 12 digits | Stored; mobile trimmed | DB | SQL A1, A1b, A1c | PASS |
| STU-02 | Future DOB on edit | DOB today+30 | Refused (admission refuses it) | DB+C# | SQL `BUG STU-DOB-FUTURE`; static `StudentController.cs:488-505` has no check (compare `AdmissionController.cs:221-240`); `sp_student_update` line 77 takes any date | BUG |
| STU-03 | DOB after admission date | admitted 2026-04-15, DOB 2026-05-01 | Refused | DB | SQL `BUG STU-DOB-ADM` | BUG |
| STU-04 | Bad mobile on edit | `98AB5` | Refused (10 digits) | DB+C# | SQL `BUG STU-MOBILE`; client `pattern` only (`EditStudent.cshtml:225`) | BUG |
| STU-05 | Blank name | `'   '` | Refused | DB | SQL A5 | PASS |
| STU-06 | Padded name | `'  ZZ Edit Kid  '` | Stored trimmed | DB | SQL A5b | PASS |
| STU-07 | Edit one child into another's identity | name `zz  TWIN`, same DOB and mobile as an active student | Refused, like admission's duplicate guard | DB | SQL `BUG STU-DUP-EDIT` | BUG |
| STU-08 | Duplicate roll no in a section | roll 4 already held in 5-A | Refused (attendance and ID cards key on it) | DB | SQL `BUG STU-ROLL-DUP` (see §4 D5) | BUG |
| STU-09 | Gender outside the list | `Boy` | Refused (drops out of the Male/Female tiles) | DB | SQL `BUG STU-GENDER` | BUG (low) |
| STU-10 | Markup in a name | `<img src=x onerror=alert(1)>` as guardian | Stored verbatim; every renderer escapes | DB | SQL A9 (stored); rendering: STU-XSS-* | PASS (DB) |
| STU-11 | Who changed the DOB / mobile | after STU-01 | An audit row with old → new and the user | DB | SQL `BUG STU-AUDIT` (0 rows; only `updated_by` is overwritten) | BUG |
| STU-12 | Roll change reaches enrolment | roll 3 → 13 | `student_enrolment.roll_no` = 13 (Enrolment History, next promotion) | DB | SQL `BUG STU-ENROL-ROLL` (still 3); `sp_student_update` line 97 updates enrolment only on a class/section move | BUG |
| STU-13 | Section change | 5-A → 5-B | Enrolment follows; `SectionChanged` audit | DB | SQL A12, A12b | PASS |
| STU-14 | Section the class lacks | 5-Z | Refused | DB | SQL A13 | PASS |
| STU-15 | Class change re-bills | — | covered by `money_admission_lifecycle` H1–H8 | — | existing | n/a |
| STU-16 | Cross-school edit / platform scope | — | covered by `money_admission_lifecycle` I4, I6 | — | existing | n/a |
| STU-EDIT-DROP | Fields on the Edit form that are never saved | change Email, WhatsApp, Caste, Remarks, Status → "Left" + reason, pick a photo | Saved, or not offered | Razor+C# | static: `EditStudent.cshtml:238, 243, 306, 323, 88/343-376, 398` post fields that `sp_student_update` has no parameter for (`AdmissionService.cs:548-571`). `PhotoFile` is posted multipart and ignored by `StudentController.EditStudent` (`:488`). Success is still reported. | BUG |
| STU-EDIT-PHOTO | Existing photo on Edit | student with a photo | Shown | Razor | static: `EditStudent.cshtml:38` hard-codes `photo = ""` | BUG (low) |
| STU-EDIT-RERENDER | Refused save re-renders the form | e.g. bad section | Locked fields still filled | C# | static: `StudentController.cs:507-515` re-renders the *posted* model, which carries no AdmissionNo / AdmissionDate / AcademicYear (readonly inputs have no `name`) | BUG (low) |
| STU-EDIT-MODELSTATE | Non-nullable `AcademicYear` not posted | — | Edit still saves | C# | verified with a scratch MVC probe that binds the exact form fields: `ModelState.IsValid = true` | PASS |
| STU-17 | Search by name, any case | `zz MEERA` | 1 row | DB | SQL B1 | PASS |
| STU-18 | Search by admission no | `zz-std-04` | 1 row | DB | SQL B2 | PASS |
| STU-19 | Search by part of the mobile | `00000041` | 1 row | DB | SQL B3 | PASS |
| STU-20 | Padded search | `'   zz meera devi   '` | 1 row | DB | SQL B4 | PASS |
| STU-21 | Double space in the search | `zz meera  devi` | 1 row | DB | SQL `BUG STU-SEARCH-SPACE` | BUG (low) |
| STU-22 | `%` / `_` typed into search | `%` | Treated literally | DB | SQL `BUG STU-SEARCH-WILDCARD` (7 of 7 returned); `sp_student_list` lines 60-63, also `sp_admission_manage` GetStudents, `sp_student_exit_list`, `sp_tc_manage` List | BUG (low) |
| STU-23 | Numeric class filter | `5` | Only class 5 | DB | SQL B7 | PASS |
| STU-24 | Sort by class | LKG and 2 | Teaching order (LKG first) | DB | SQL `BUG STU-SORT-CLASS`; `sp_student_list` lines 92-93 sort by `class_name` text, so "10" also comes before "2" | BUG (low) |
| STU-25 | Paging | page 2, size 1 | 2nd row; stable total | DB | SQL B9 | PASS |
| STU-26 | Page size abuse | `?PageSize=100000` | Capped | C# | static `ListModelBase.cs:28` (1–200) | PASS |
| STU-27 | Tenant isolation of the directory | 23/33 lists | none of ours | DB | SQL B10 | PASS |
| STU-EXPORT-FEE | CSV export under a Fee filter | Fee = Pending, export | Same rows as on screen | JS | static: `StudentList.cshtml:440-444` sends search, class, gender and year, but not `FilterFee`; `GetStudentsData` has no fee parameter (`AdmissionController.cs:472-475`) | BUG |
| STU-EXPORT-CSVINJ | Formula injection | name `=HYPERLINK(...)` | Cell neutralised (prefix `'`) | JS | static: `StudentList.cshtml:454` only doubles quotes | BUG (low) |
| STU-XSS-DASH | Name / guardian / DOB / fee head rendered on the Student Dashboard | guardian from STU-10 | Escaped | JS | static: `Dashboard.cshtml:435-437` `ic()` and `:724-728` `ps()` put values into `innerHTML` raw (Overview quick info, Academic placement, Profile tab incl. Full Name); `:669, 679-683` fee head, mode, receipt raw. The guardian payload runs when the dashboard opens. | BUG |
| STU-XSS-OTHER | Same payload elsewhere | directory, Promotion, Edit, History, ID card, TC | Escaped | Razor/JS | static: Razor `@` encodes (`StudentList`, `IdCard/Print`, `Tc/Print`, `Tc/Register`); Promotion uses `EC.esc` (`:525-545`); Edit uses `textContent`; History / Enrolment use `EC.esc` (`Dashboard.cshtml:772-800`); `JsonSerializer` escapes `<` in `EditStudent.cshtml:473` | PASS |
| STU-DASH-FAKE | Profile tab address / contact / status | any student | Real values | JS | static: `Dashboard.cshtml:711` hard-codes `'Village Mathura, UP – 281001'` for every student; `:716` shows `s.phone`, which is never set (`undefined`); `:341` status is always `'Active'`. The API already returns `address` and `mobile` (`StudentController.cs:329-331`). | BUG |
| STU-DATA-NUMERIC | Numeric names through jQuery `.data()` | class "5", vehicle "007" | No type surprises | JS | static: every `.data('name'/'no')` lands in `.text()`, `.val()` or `EC.confirm({name})` (`StudentList.cshtml:474, 525`, `Inactive.cshtml:332, 371`, `Routes.cshtml:105`, `Vehicles.cshtml:96`). jQuery keeps "007" as a string; "5" becomes 5 and prints the same. Class names reach no `.data()` call. | PASS |
| STU-LEFT-VIEW | Open a left student's record | from anywhere | Dashboard / history viewable | C#/DB | static: `GetStudentById` filters `is_active = TRUE` (`sp_admission_manage` GetStudentById), so `Dashboard` / `EditStudent` redirect to the list for a leaver | GAP |
| STU-PERM | Writes need `students.manage` + antiforgery | — | — | C# | static `StudentController.cs:189-248, 485-487` | PASS |

### PHO: student photo

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| PHO-01 | Set photo | url | Stored | DB | SQL C1 | PASS |
| PHO-02 | Replace photo | new url | Points at the new file | DB | SQL C2 | PASS |
| PHO-03 | Cross-school set | 23/33 | Refused; unchanged | DB | SQL C3, C3b | PASS |
| PHO-04 | Extension allow-list | `.gif`, `.svg`, `.html` | Refused | C# | static `StudentController.cs:211-213` (jpg/jpeg/png/webp) | PASS |
| PHO-05 | Size | > 2 MB | Refused | C# | static `:204` (3 MB request cap) and `:214` (2 MB) | PASS |
| PHO-06 | Path traversal in the file name | `../../x.jpg` | Ignored | C# | static `:218` builds the name `student_{id}_{timestamp}{ext}`; only the extension comes from the client | PASS |
| PHO-07 | Content does not match the extension | HTML renamed `.jpg` | Refused or harmless | C# | static: no magic-byte check; served with `X-Content-Type-Options: nosniff` (`Program.cs:262`), so it never renders as HTML | RISK (low) |
| PHO-08 | Old file after a replace | — | Deleted | C# | static `:216-229` deletes only on DB failure; replaced files pile up | BUG (low) |
| PHO-09 | DB update fails | — | No orphan file | C# | static `:229` | PASS |
| PHO-10 | Uploading another school's student | foreign uuid | "Unknown student." | C# | static `:207-208` (`fn_public_id_to_id` is scoped) | PASS |
| PHO-11 | HEIC / huge camera shot | — | Compressed to JPEG | JS | static `site.js:385-414` (falls back to the original file on a decode error) | PASS |
| PHO-12 | Photo change audited | — | Who / when | DB | static: `sp_student_set_photo` writes only `updated_by` | GAP |

### PRO: promotion (UI and roster side; money is in the lifecycle suite)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| PRO-01 | Class 5: 2 promote, 2 retain | outcomes per student, section "keep" | 2 / 2 promoted / retained | DB | SQL D1, D2, D3 | PASS |
| PRO-02 | Keep-section into a class without it | 5-B → 6 (only A) | Skipped with a reason | DB | SQL D1b, D4 | PASS |
| PRO-03 | Explicit target section | 5-B, target A | 6-A | DB | SQL D6 | PASS |
| PRO-04 | Another school's id in the payload | `studentId` of school 33 | Skipped "(not found)"; untouched | DB | SQL D1b, D5 | PASS |
| PRO-05 | Double submit | same payload again | Nobody promoted twice | DB | SQL D7 | PASS |
| PRO-06 | Enrolment trail | retained child | old `Retained`, new `Active` + current | DB | SQL D8 | PASS |
| PRO-07 | History card shows the run and who | — | `Promotion: Retain` + user | DB | SQL D10 | PASS |
| PRO-08 | Cross-school history / enrolment | 23/33 | Nothing | DB | SQL D11, D12 | PASS |
| PRO-ROSTER | Roster reloaded after a run | class 5, source session | Moved children not listed | DB | SQL `BUG PRO-ROSTER` (all 4 listed again; each comes back "skipped (not in …)" on the next commit). `sp_admission_manage` GetStudents joins the source enrolment row but ignores its status (`Promoted` / `Retained`). | BUG |
| PRO-SECTIONS | Target section list (and Edit Student section list) | class 5 set up with A, B, C; C empty | A, B, C offered | DB | SQL `BUG PRO-SECTIONS` (A, B only). `sp_class_active_sections` reads sections from **students**, not from the setup, and ignores the session. Used by `PromotionSections` → `Promotion.cshtml:356, 412-416` and `EditStudent.cshtml:478-491`. | BUG |
| PRO-PICK | Untick one student before committing | untick on desktop | That student is not promoted | JS | static: `Promotion.cshtml:584-587` `picked()` iterates every `.pr-pick`, including the hidden mobile copy (`:542`) that is still ticked, so the unticked child is still sent. The counts never drop either. | BUG |
| PRO-RADIO | Outcome toggle shows the choice | click Retain on desktop | Retain highlighted | JS | static: `Promotion.cshtml:492-495` gives desktop and mobile radios the same `name="oc<id>"` with no `<form>`, so they form one group. The hidden mobile radio, inserted last, takes the checked state (HTML radio-group rule), and the desktop toggle never shows a selection. The row tint still changes. | BUG |
| PRO-09 | Final class defaults to Pass Out; missing target class blocks | — | — | JS | static `Promotion.cshtml:321-341, 437-441, 735-752` | PASS |
| PRO-10 | Session not set up | empty target | Review disabled with a reason | JS+DB | static `:654-692`; DB covered by `promotion_tests` A | PASS |
| PRO-11 | Unticked "promote with dues" warns before commit | — | count shown | JS | static `:762-767` | PASS |
| PRO-12 | Pass-out / skip a class / demote | — | covered by `promotion_tests` C, D | — | existing | n/a |

### TRN: transport (routes, stops, vehicles, assignment UI); billing is in the lifecycle suite

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| TRN-01 | Route with 3 stops | A 500, B 700, C 900 | Saved in entry order | DB | SQL E1 | PASS |
| TRN-DUP-ROUTE | Same route twice | `'  zz route NORTH '` | Refused | DB | SQL `BUG TRN-DUP-ROUTE`; `sp_transport_route_manage` SaveRoute has no check, stores the name untrimmed, and the Save button has no busy state (`Routes.cshtml:228-238`) | BUG |
| TRN-NEG-FARE | Negative stop fare | −100 | Refused | DB | SQL `BUG TRN-NEG-FARE` (the input's `min=0` is client-only) | BUG |
| TRN-02 | Vehicle on the route | capacity 2 | Saved | DB | SQL E4 | PASS |
| TRN-CAPACITY | Third rider on a 2-seat route | assign 3 | **Business decision** (§4 D1) | DB | SQL E5 INFO: accepted silently; capacity is not compared anywhere and not shown on Assign | INFO |
| TRN-DEL-STOP | Drop a stop children board at | save route without Stop C | Refused, or stop kept | DB | SQL `BUG TRN-DEL-STOP`; SaveRoute deactivates any stop not in the list (`sp_transport_route_manage` lines 80-82) | BUG |
| TRN-03 | Inactive route hidden on Assign | toggle off | Not in the dropdown | DB | SQL E7 | PASS |
| TRN-INACTIVE-ROUTE | Assign to an inactive route (API / stale page) | toggle off, assign | Refused | DB | SQL `BUG TRN-INACTIVE-ROUTE`; SaveAssignment's stop lookup ignores `rt.is_active` / `is_deleted` (`sp_transport_assign_manage` lines 51-55) | BUG |
| TRN-04 | Stop left out of a save | — | Deactivated | DB | SQL E8 | PASS |
| TRN-INACTIVE-STOP | Assign to a removed stop | old stop id | Refused | DB | SQL `BUG TRN-INACTIVE-STOP`; same lookup ignores `s.is_active`. The child is billed at the dead stop's fare. | BUG |
| TRN-DUP-VEH | Same vehicle number twice | `' zz-bus-01 '` | Refused | DB | SQL `BUG TRN-DUP-VEH` | BUG |
| TRN-CAP-NEG | Negative capacity | −5 | Refused | DB | SQL `BUG TRN-CAP-NEG` | BUG |
| TRN-VEH-SCOPE | Vehicle pointed at another school's route | `routeId` of school 33 | Refused | DB | SQL `BUG TRN-VEH-SCOPE`; SaveVehicle never checks the route's school, and GetVehicles then shows that school's route name (cross-tenant read) | BUG |
| TRN-SOLD | Bus switched off while its route has riders | toggle | **Business decision** (§4 D2) | DB | SQL E12 INFO: inactive, 3 riders still on the route, no warning | INFO |
| TRN-05 | Delete vehicle | — | Leaves the list | DB | SQL E13 | PASS |
| TRN-GETASSIGN | Assign page shows the current bus | pick a student who rides | "Currently assigned …" with Remove | DB | SQL `BUG TRN-GETASSIGN`: **every call raises** `record "r" is not assigned yet`. The live proc declares `r record` and also aliases `transport_routes r` in GetForStudent (`transport_module.sql:370` vs `:379-381`). `TransportService.GetAssignmentAsync` (`:240-257`) does not catch, so `TransportController.GetAssignment` returns 500, `#curAssign` never shows, and **Remove Transport is unreachable from the UI**. Introduced today in `7a05384`. | BUG (high) |
| TRN-06 | Cross-school stops / assignment read | 23/33 | Nothing | DB | SQL E14, E15 (E15 is vacuous until TRN-GETASSIGN is fixed) | PASS |
| TRN-07 | Cross-school rename / delete our route | 23/33 | Unchanged | DB | SQL E16, E17 | PASS |
| TRN-SCOPE-MSG | …and the caller is told it failed | — | success = false | DB | SQL `BUG TRN-SCOPE-MSG` (Delete / Toggle / Save of a foreign id answer "Route deleted." / "Vehicle saved." for a no-op) | BUG (low) |
| TRN-DEL-ROUTE | Delete a route children ride | 3 riders | Refused | DB | SQL `BUG TRN-DEL-ROUTE`; the riders stay active and billed on a deleted route | BUG |
| TRN-XSS-ASSIGN | Names on the Assign page | student / route / stop / class name with markup | Escaped | JS | static: `Assign.cshtml:61` (`fill`: sessions, classes, sections), `:73` (student name, adm no), `:86` (route name), `:90` (stop name) concatenate raw into `.html()` | BUG |
| TRN-08 | Routes / Vehicles pages | names with markup | Escaped | Razor | static: `@` encoding (`Routes.cshtml:35, 157`, `Vehicles.cshtml:34, 293`); `stopRow` escapes `"` (`Routes.cshtml:206`) | PASS |
| TRN-09 | Double-click Save on Vehicles / Routes | — | One record | JS | static: no `EC.buttonBusy`, no `.fail` (`Vehicles.cshtml:350-355`, `Routes.cshtml:228-238`). With no duplicate check, this creates two. | BUG (low) |
| TRN-10 | Permissions / module gate | — | `transport.view` / `.manage` + module | C# | static `TransportController.cs:11-12, 61-176` | PASS |
| TRN-11 | Billing, route change, removal, session clamp | — | covered by `money_admission_lifecycle` E0–E7 and `transport_tc_tests` B, C | — | existing | n/a |

### TC: Transfer Certificate (document side); the dues gate is in the lifecycle suite

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| TC-01 | Board format with all Board fields | exam result, subjects, fees-upto, 120/110 days, activities, application date | All stored; reason defaults to the exit reason | DB | SQL F1 | PASS |
| TC-02 | Number shape | — | `TC-YYYY-NNNN` | DB | SQL F2 | PASS |
| TC-03 | Consecutive numbers | two issues | +1, no gap | DB | SQL F3 | PASS |
| TC-04 | Void reason whitespace | `'    '` | Refused | DB | SQL F4 | PASS |
| TC-05 | Void trail | reason | why / who / when stored | DB | SQL F5 | PASS |
| TC-VOID-PRINT | Print a voided TC | `Print` op / old link | Refused, or stamped VOID | DB+Razor | SQL `BUG TC-VOID-PRINT`; `sp_tc_manage` Print never checks `is_void`; `Tc/Print.cshtml:146-149` stamps only DUPLICATE. A TC voided before its first print comes out as a clean **original**. The Register hides the button (`Register.cshtml:95`), but the uuid link still works. | BUG (high) |
| TC-06 | Re-issue after void | — | New number; voided one retired | DB | SQL F7 | PASS |
| TC-DAYS | Present > working | 250 / 200 | Refused | DB | SQL `BUG TC-DAYS` | BUG |
| TC-DAYS-NEG | Negative days | −5 / −1 | Refused | DB | SQL `BUG TC-DAYS-NEG` | BUG |
| TC-APPDATE | Application date after the issue date | today+20 | Refused | DB | SQL `BUG TC-APPDATE` | BUG (low) |
| TC-07 | "Withdrawn" student | — | No TC | DB | SQL F11 | PASS |
| TC-08 | Register search | TC no in lower case; name | Found; live and void both listed | DB | SQL F12, F12b | PASS |
| TC-09 | Cross-school list / print / void | 23/33 | Nothing; print count untouched | DB | SQL F13, F14, F14b, F15 | PASS |
| TC-ISSUE-PRINT | "Issue & Print" | issue from Inactive | Opens the certificate | JS+C# | static: `Inactive.cshtml:410` opens `Tc/Print?id=<integer tcId>`, but `TcController.Print(Guid id)` (`TcController.cs:45-48`) cannot bind an int, so it gets `Guid.Empty` → `NotFound()`. `Issue` returns no public id (`TcController.cs:39`). | BUG (high) |
| TC-VOID-VISIBLE | Why was TC-2026-0001 voided? | Register | Reason / who / when shown | DB+Razor | static: `sp_tc_manage` List does not select `void_reason`, `voided_by` or `voided_at`; `Register.cshtml:81-84` shows only "Void". The prompt promises "kept for audit". | GAP |
| TC-GET-PRINT | Print is a GET that writes | refresh / prefetch / a `students.view` user opening the link | Original not used up by a view | C# | static: `TcController.cs:43-52` → `print_count + 1` under `students.view`; a page refresh turns the original into "DUPLICATE" | RISK |
| TC-10 | Snapshot, one live TC, dues gate, wallet gate | — | covered by `transport_tc_tests` D/E, `money_admission_lifecycle` F | — | existing | n/a |
| TC-11 | Format fallback | `Preview?format=xyz` | Basic | C# | static `TcController.cs:110` | PASS |

### IDC: ID cards

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| IDC-01 | 7-A class set | 3 children, 6 leavers in 7-A | 3 cards, no leavers | DB | SQL G1 | PASS |
| IDC-02 | Roll order | rolls 10, 2, 1 | 1, 2, 10 | DB | SQL G2 | PASS |
| IDC-03 | Missing photo | 2 of 3 without | `photo_url` NULL → "PHOTO" placeholder | DB+Razor | SQL G3; static `IdCard/Print.cshtml:94-101` | PASS |
| IDC-04 | Section case | `a` | matches A | DB | SQL G4 | PASS |
| IDC-05 | Unknown year | — | Empty sheet with a note | DB+Razor | SQL G5; static `Print.cshtml:75-78` | PASS |
| IDC-06 | Sections list | class 7 | A | DB | SQL G6 | PASS |
| IDC-07 | Single card with photo | — | Photo shown | DB | SQL G7 | PASS |
| IDC-08 | Cross-school card | 23/33 | Nothing | DB | SQL G8 | PASS |
| IDC-NOTE | Banner on the print sheet | — | Correct | Razor | static: `IdCard/Print.cshtml:73` always says "Photos are blank … until student-photo upload is enabled", which is no longer true | BUG (low) |
| IDC-MISSING-LIST | Which children have no photo? | before printing 7-A | Count / list shown | Razor | static: nothing on `IdCard/Index` or the sheet counts missing photos | GAP |
| IDC-YEAR-STALE | Change Year after picking Class | — | Sections reload | JS | static: `IdCard/Index.cshtml:98-111` reloads sections only on class change | BUG (low) |
| IDC-BROKEN-IMG | Photo file deleted from disk | — | Placeholder | Razor | static: `<img>` has no `onerror` (`Print.cshtml:96`) | BUG (low) |

### SCP: scope and leaks

| ID | Scenario | Expected | How verified | Result |
|---|---|---|---|---|
| SCP-01 | Every id parameter in this area (student, route, stop, vehicle, TC, photo, history, card) | Scoped to tenant + school | SQL B10, C3, D5, D11, D12, E14–E17, F13–F15, G8; static: uuid resolution in `fn_public_id_to_id` | PASS, except TRN-VEH-SCOPE |
| SCP-02 | Nothing created leaked to another school | 0 | SQL H1–H5 | PASS |
| SCP-03 | Nothing left after the run | 0 rows | post-run query (students, routes, vehicles, session, TC, audit, counter) | PASS |

---

## 3. Bugs by severity

| Sev | ID | Where to change |
|---|---|---|
| High | TRN-GETASSIGN: Assign page can't show or remove any bus | `transport_module.sql` (rename the `r record` variable at `:370` or the `r` alias at `:379-381`) |
| High | TC-ISSUE-PRINT: "Issue & Print" opens a 404 | `TcController.Issue` (return the TC's public id) + `Inactive.cshtml:410` |
| High | TC-VOID-PRINT: a voided TC prints as clean / original | `transfer_certificate.sql` (Print: refuse or flag void) + `Tc/Print.cshtml` (VOID stamp) |
| High | PRO-PICK: unticked students are still promoted | `Promotion.cshtml:584-587` (read only the visible list, or one checkbox per student) |
| Medium | STU-EDIT-DROP: status / email / remarks / photo silently discarded | `EditStudent.cshtml` (remove or wire the fields); status belongs to the Exit flow |
| Medium | STU-XSS-DASH, TRN-XSS-ASSIGN: stored XSS | `Dashboard.cshtml` (`ic`, `ps`, fee rows) and `Assign.cshtml` (use `EC.esc`) |
| Medium | STU-DASH-FAKE: hard-coded address on every profile | `Dashboard.cshtml:711, 716, 341` |
| Medium | STU-DOB-FUTURE / -ADM / STU-MOBILE: edit accepts what admission refuses | `student_update.sql` (+ the same checks in `StudentController.EditStudent`) |
| Medium | STU-AUDIT: no trail of DOB / mobile / name edits | `student_update.sql` (write an `admission_audit` row with old → new) |
| Medium | TRN-DEL-ROUTE, TRN-DEL-STOP, TRN-INACTIVE-ROUTE / -STOP | `transport_module.sql` |
| Medium | PRO-ROSTER, PRO-SECTIONS | `student_master_fields.sql` (GetStudents: exclude closed source enrolment), `sp_class_active_sections` (read the session's setup) |
| Medium | STU-EXPORT-FEE | `StudentList.cshtml:440` + `AdmissionController.GetStudentsData` |
| Medium | TRN-VEH-SCOPE | `transport_module.sql` SaveVehicle |
| Medium | PRO-RADIO | `Promotion.cshtml:492-495` (distinct names for the mobile copy) |
| Low | STU-DUP-EDIT, STU-ROLL-DUP, STU-GENDER, STU-ENROL-ROLL, STU-SEARCH-*, STU-SORT-CLASS, STU-EXPORT-CSVINJ, STU-EDIT-PHOTO, STU-EDIT-RERENDER, PHO-08, TRN-DUP-ROUTE / -VEH, TRN-NEG-FARE, TRN-CAP-NEG, TRN-SCOPE-MSG, TRN-09, TC-DAYS / -NEG / TC-APPDATE, IDC-NOTE / -YEAR-STALE / -BROKEN-IMG | as listed in §2 |

---

## 4. Business decisions needed

| # | Question | Today |
|---|---|---|
| D1 | **Vehicle capacity.** When a route's active buses are full, should Assign refuse, warn, or allow? And should the Assign page show seats left? | Capacity is stored and never read. |
| D2 | **Bus sold / switched off with riders.** Block, warn, or require reassigning the route's children first? | Allowed silently. |
| D3 | **Fare change on a stop.** Should riders already assigned move to the new fare from next month? | The fare is snapshotted at assignment; editing a stop never touches existing riders. |
| D4 | **TC number year.** The counter resets on 1 January (calendar year), not at the session start. | `TC-2026-0001` restarts in January, in the middle of a session. |
| D5 | **Roll number uniqueness.** Unique within class + section + session? (STU-ROLL-DUP assumes yes.) | Not enforced anywhere. |
| D6 | **"Aadhaar" field.** The Edit form forces 12 digits, but the column is `id_proof_no` ("Aadhaar / birth-cert no") and admission accepts any text. Is it Aadhaar only, or any ID proof? | Client-side pattern only. |
| D7 | **Viewing a student who has left.** Should the Dashboard (fees, receipts, history) stay reachable after an exit? | Redirects to the list (STU-LEFT-VIEW). |
| D8 | **Edit-form status.** Should status changes stay on the Exit / Reactivate flow (recommended), with the status block removed from Edit Student? | The block is shown and silently ignored. |
| D9 | **Deleting a route.** If it has had riders this session, refuse outright or require an end date / migration? | Deleted. |

---

## 5. Live bus tracking (added 2026-10-11)

**Feature:** the driver's phone browser shares the bus's position during a trip; staff watch the
buses on a map and replay past trips; parents follow their route's bus through a share link with
no login. Script `EduCoreDataAccessLayer/Database/transport_live_tracking.sql` (apply it, then
`school_purge.sql`). Suite `tests/transport_live_tracking_tests.sql`, fixture 24/34 (driver = staff
21 / user 43, other staff = staff 23 / user 45), cross-school 23/33/38.
**Run (2026-10-11): `RESULT: 75 passed, 0 failed`.**

**Pages:** `/ERP/MyBus` (driver, no permission key: being the bus's assigned driver is the
permission; menu item "My Bus" shows only for drivers), `/ERP/Transport/LiveTracking` and
`/ERP/Transport/TripHistory` (`transport.view`, hidden and refused when Transport is switched off),
share links on `/ERP/Transport/Routes` (`transport.manage`), public `/BusTrack/{token}`.

| ID | Scenario | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|
| GPS-01 | Who sees "My Bus" | Only the bus(es) whose `driver_staff_id` is the user's staff row; a non-staff user, or the driver under another school's scope, sees none | DB | SQL A1–A4 | PASS |
| GPS-02 | Start trip by anyone but the driver | Refused (other staff, school admin, another school, platform scope, inactive staff, switched-off bus) | DB | SQL B1–B7 | PASS |
| GPS-03 | Start trip | Trip keeps bus, route and driver (snapshots for history) | DB | SQL B8 | PASS |
| GPS-04 | One running trip per vehicle | A second start resumes the same trip; the unique index refuses a second running row | DB | SQL B9, B10 | PASS |
| GPS-05 | Good point | Saved; becomes the trip's latest position | DB | SQL C1 | PASS |
| GPS-06 | Point from anyone but the bus's current driver | Refused (other staff, another school, a driver taken off the bus mid-trip) | DB | SQL C2, C3, C16 | PASS |
| GPS-07 | Bad position | lat > 90, lng < -180, (0,0), missing lat: refused | DB+C# | SQL C4–C7; NaN / 1e308 become NULL in the service and are refused (smoke test) | PASS |
| GPS-08 | Accuracy | Negative or worse than 2 km: refused | DB | SQL C8, C9 | PASS |
| GPS-09 | Timestamp | More than 2 min in the future, or older than the trip: refused | DB | SQL C10, C11 | PASS |
| GPS-10 | Min interval | A point < 5 s after the last one, or out of order, is dropped (accepted = false), not an error | DB | SQL C12, C13 | PASS |
| GPS-11 | Junk speed / heading | Stored empty, point kept | DB | SQL C14 | PASS |
| GPS-12 | Live list | Running trips of this school only, with position, age, driver; not another school's; not idle buses; platform scope refused | DB | SQL D1–D4 | PASS |
| GPS-13 | Stale trip | Nothing received for 30 min: closed (`Stale`, ended at the last point) on the next read or write; takes no more points; a new start closes a stale trip on the same bus; 29 min is still running | DB | SQL E1–E5 | PASS |
| GPS-14 | End trip | Only the driver; twice is harmless; no points after; leaves the live list | DB | SQL F1–F6 | PASS |
| GPS-15 | Share link create | Only the sha256 hash is stored | DB | SQL G1, G2 | PASS |
| GPS-16 | Public read, no trip | Route name, "not on a trip" | DB | SQL G3 | PASS |
| GPS-17 | Public read during a trip | That route's bus only (not another route's running bus); row has only route name, trip id, vehicle no., position, age | DB | SQL G4, G5; smoke test: driver name absent from page and JSON | PASS |
| GPS-18 | Regenerate / revoke | Old link stops at once; one live link per route; revoking twice says so | DB | SQL G6, G7, G13, G14 | PASS |
| GPS-19 | Cross-school link changes | Another school can neither create nor revoke a link to our route | DB | SQL G8, G9 | PASS |
| GPS-20 | Unknown / garbage / malformed token | Nothing returned; malformed never reaches the DB (C# format check) | DB+C# | SQL G10, G11; smoke test `{"valid":false}` | PASS |
| GPS-21 | Module off / route deleted | The public link shows nothing | DB | SQL G12, G15 | PASS |
| GPS-22 | History | Lists trips with start, end, reason, driver, bus, route, point count; vehicle and date filters; path in time order; another school sees neither list nor path | DB | SQL H1–H7 | PASS |
| GPS-23 | 30-day retention | A trip start deletes points older than 30 days and ended trips started > 30 days ago (all schools); recent points kept | DB | SQL I1–I4 | PASS |
| GPS-24 | School purge | Deletes points, trips and share links, before what they reference (H12 in `platform_access_security_tests` also covers it) | DB | SQL J1, J2 | PASS |
| GPS-25 | Tenant isolation | Trips and points carry their own school only | DB | SQL J3 | PASS |
| GPS-26 | Public page rate limit | `bustrack` policy, 60 requests / minute / IP, then 429 | C# | smoke test: 70 rapid calls -> 17 x 429 | PASS |
| GPS-27 | Antiforgery on driver posts | Missing token -> 400 | C# | smoke test | PASS |
| GPS-28 | Public page caching | `Cache-Control: no-store`, `X-Robots-Tag: noindex` | C# | smoke test | PASS |
| GPS-29 | Escaping | Vehicle no., route, driver go through `EC.esc` on the map, list, history and parent page | JS | static | PASS |

**Limitations (by design, documented):** a browser page cannot share location from the background,
so the driver must keep My Bus open with the screen on (the page asks for a screen wake lock where
the browser supports it, and says so). Location needs HTTPS (or localhost). The share link is shown
once; to give it out again the office makes a new one, which stops the old one.
