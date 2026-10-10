> **Fix status (2026-10-10):** every row marked BUG/FAIL below has been fixed and its SQL check now passes (see `EduCoreDataAccessLayer/Database/tests/settings_profile_docs_workflow_tests.sql` and the change log in `docs/SCALING-AND-FIXES.md`). Left as-is (observations, not bugs): landline numbers are rejected by the mobile-only phone rule, text fields are not trimmed, and there is no "remove logo" button.

# Test catalog: Basic Profile, Documents & Formats, Admission Workflow

SQL suite: `EduCoreDataAccessLayer/Database/tests/settings_profile_docs_workflow_tests.sql`
Final run: **RESULT: 106 passed, 10 failed** (all 10 failures are real app bugs, listed at the end).

Abbreviations: `SSC` = `educore/Areas/ERP/Controllers/SchoolSettingsController.cs`, `AWC` = `educore/Areas/ERP/Controllers/AdmissionWorkflowController.cs`,
`BP.cshtml` = `educore/Areas/ERP/Views/SchoolSettings/BasicProfile.cshtml`, `DOC.cshtml` = `.../SchoolSettings/Documents.cshtml`,
`WF.cshtml` = `educore/Areas/ERP/Views/AdmissionWorkflow/WorkflowSettings.cshtml`, `SMM` = `EduCoreDataAccessLayer/Models/SchoolManageModel.cs`,
`SSS` = `EduCoreDataAccessLayer/Services/Repository/ERP/SchoolSettingsService.cs`, `AWS` = `.../Repository/ERP/AdmissionWorkflowService.cs`,
`bp.sql` = `EduCoreDataAccessLayer/Database/sp_school_admin_basic_profile_manage.sql` (matches the live DB definition).

## Real-world scenario

**Roman Public School (tenant 24, school 34) gets ready for session FY 26-27.**

1. The school admin opens **Basic Profile**. School code, name, board and type are read-only (Super Admin owns them). She fills in display name, website, registration and affiliation numbers, established year, address (State, then District, then City, plus Pincode), contact person, official phone, alternate phone and email. She uploads the logo from her phone (a 5 MB photo, compressed in the browser). She saves. The name, address and logo now print on every receipt, TC and ID card.
2. Later the school moves from Gurugram (Haryana) to Delhi. She changes the State and leaves District blank. A State Board school would have its State locked to the board's state.
3. On **Documents & Formats** she previews and saves an A5 fee receipt, the Board-format TC (for CBSE transfers) and Landscape ID cards. Fee receipts on every screen and the ID-card print page then use these. The TC issue dialog should open on Board.
4. On **Admission Workflow** she turns Registration on and makes it mandatory before admission. She turns on a registration fee (Rs 500), auto-numbering with prefix `SPS/`, collect-fee-at-admission and a Rs 5,000 security deposit. Transport and Inventory are off because the school has no buses and no store.
5. Downstream: walk-in admission is now blocked until the enquiry is registered. Registration numbers come out as SPS/0001, SPS/0002 and so on. The registration fee and the refundable deposit are charged. The Transport and Inventory menus disappear and their URLs are refused.

## A. Basic Profile (BP)

| ID | Scenario | Steps / input | Expected result | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| BP-01 | Page load for school admin | GET /ERP/SchoolSettings/BasicProfile | Profile of the claim's school is shown | Controller | static: SSC:44-58 | PASS |
| BP-02 | View permission | User without settings.view | 403 | Controller | static: SSC:45, HasPermissionAttribute.cs:49-50 | PASS |
| BP-03 | Save permission | POST without settings.manage | 403 | Controller | static: SSC:63 | PASS |
| BP-04 | Unauthenticated | Anonymous GET/POST | Challenge (redirect to login) | Controller | static: HasPermissionAttribute.cs:36-40 | PASS |
| BP-05 | CSRF | POST without antiforgery token | 400 | Controller | static: SSC:62, BP.cshtml:20 | PASS |
| BP-06 | Platform/tenant-1 user | Claims tenant 1 | Service returns null, sent to AccessDenied | Controller | static: SSS:46, SSC:54; SQL A4 | PASS |
| BP-07 | School id 0 refused by proc | Get with school 0 | "Invalid school admin scope." | Proc | SQL A5 | PASS |
| BP-08 | Get returns exactly one row | Get for 24/34 | 1 row, our school | Proc | SQL A1, A2 | PASS |
| BP-09 | Cross-tenant read | Get with tenant 24, school 33 | No row | Proc | SQL A3 | PASS |
| BP-10 | Unknown operation | op='DeleteBasicProfile' | Refused | Proc | SQL A6 | PASS |
| BP-11 | Read-only identity fields | School code, name, board, type | Rendered readonly; proc never writes board/type | UI / Proc | static: BP.cshtml:141-154; SQL B15, B16 | PASS |
| BP-12 | Board cannot be changed by crafted post | p_board_id=2, p_school_type_id=99 | Board/type unchanged | Proc | SQL B15, B16 | PASS |
| BP-13 | Save success message | Valid post | TempData "Basic profile updated successfully.", redirect (PRG) | Controller | static: SSC:139-142, _Scripts.cshtml:105-106 | PASS |
| BP-14 | Save returns school id | Valid save | Cursor success=TRUE, school_id=34 | Proc | SQL B1 | PASS |
| BP-15 | Display name round-trip | "ZZ Roman Public School" | Stored and read back | Proc | SQL B2 | PASS |
| BP-16 | Display name cleared | Empty field | NULL stored (optional) | Proc | SQL B19 | PASS |
| BP-17 | Display name > 200 | 201 chars | Server StringLength(200) error; DB refuses too | Controller / Proc | static: SMM:15; SQL C17 | PASS |
| BP-18 | Registration number round-trip | "REG/HR/2001/77" | Stored with slashes | Proc | SQL B3 | PASS |
| BP-19 | Registration number > 100 | 101 chars | Refused | Controller / Proc | static: SMM:45; SQL C16 | PASS |
| BP-20 | Affiliation number round-trip | "530123" | Stored | Proc | SQL B4 | PASS |
| BP-21 | Affiliation number > 100 | 101 chars | StringLength(100) error | Controller | static: SMM:48 | PASS |
| BP-22 | Established year round-trip | 1995 | Stored | Proc | SQL B5 | PASS |
| BP-23 | Established year lower bound | 1800 accepted, 1799 refused | As stated | Proc | SQL C12, C10 | PASS |
| BP-24 | Established year upper bound | 2100 accepted, 2101 refused | As stated | Proc | SQL C13, C11 | PASS |
| BP-25 | Established year in the future | 2050 | Rejected (a school cannot be founded next year) | UI-JS / Controller | static: BP.cshtml:408-411 rejects it (max = current year), but SMM:51 accepts up to 2100, so a crafted post stores 2050 | FAIL (low) |
| BP-26 | Established year non-numeric | "abcd" | Model binding error is shown | Controller | static: int? binding plus BP.cshtml:327-335 toast | PASS |
| BP-27 | Website with scheme | "https://romanpublic.edu.in" | Accepted | Proc | SQL B6 | PASS |
| BP-28 | Website without scheme | "romanpublic.edu.in" or "www.school.com" | Accepted by both layers, or rejected by both | UI-JS / Controller | static: BP.cshtml:404-407 client regex makes the scheme optional and passes it, but SMM:54 `[Url]` requires http(s)/ftp, so the save fails with "Enter valid website URL." | BUG |
| BP-29 | Website exactly 200 / 201 chars | Boundary | 200 accepted, 201 refused | Proc | SQL C15, C14 | PASS |
| BP-30 | Website cleared | Empty | NULL stored | Proc | SQL B19 | PASS |
| BP-31 | Address line 1 required (client) | Blank | "Address Line 1 is required." inline, submit blocked | UI-JS | static: BP.cshtml:396, site.js:525-534 | PASS |
| BP-32 | Address line 1 whitespace only | "   " | Rejected (client trims; [Required] rejects whitespace) | UI-JS / Controller | static: site.js:505, SMM:60 | PASS |
| BP-33 | Address line 1 NULL at DB | NULL | NOT NULL violation | Proc | SQL C1 | PASS |
| BP-34 | Address line 1 > 250 | 251 chars | Refused | Controller / Proc | static: SMM:61; SQL C18 | PASS |
| BP-35 | Special chars and Unicode in address | `Plot #12, 'A' Block, नई सड़क` | Round-trips exactly | Proc | SQL B7 | PASS |
| BP-36 | Address line 2 (hidden) preserved | Hidden field posts old value | Old value kept | UI / Proc | static: BP.cshtml:222; SQL B8 | PASS |
| BP-37 | State required | No state selected | "State is required." | UI-JS / Controller | static: BP.cshtml:397, SMM:78/88 | PASS |
| BP-38 | State NULL at DB | NULL | NOT NULL violation | Proc | SQL C3 | PASS |
| BP-39 | Non-existent state id | state_id=999999 | FK violation | Proc | SQL C22 | PASS |
| BP-40 | City required | Blank | "City is required." | UI-JS / Controller / Proc | static: BP.cshtml:398; SQL C2 | PASS |
| BP-41 | City format | "Hubballi-Dharwad", "Y.S.R. Kadapa" accepted; "Sector 5" refused (digits) | As stated | Controller | static: SMM:72 | PASS |
| BP-42 | City > 100 | 101 chars | Refused (input maxlength 100 as well) | UI / Proc | static: _StateDistrictCity.cshtml (maxlength=100); SQL C21 | PASS |
| BP-43 | District optional, text and ids round-trip | Gurugram / 199 | Stored | Proc | SQL B9, B10 | PASS |
| BP-44 | State changed, district left blank | Haryana/Gurugram, then Delhi with no district | District id cleared (or in the new state) | Proc | SQL D1: state_id=32 but district_id=199 (Gurugram, Haryana) is kept by `COALESCE` at bp.sql:268 | BUG |
| BP-45 | District cleared | District set to "Select District" | Text and id both cleared | Proc | SQL D2: text becomes NULL but district_id 199 stays, so the reload pre-selects the old district again | BUG |
| BP-46 | State Board lock: state forced | Board 3 (State Board, UP), post Haryana | State forced to UP (26) | Proc | SQL D3 | PASS |
| BP-47 | State Board lock: foreign district dropped | Post district 199 (Haryana) under the UP lock | district_id NULL | Proc | SQL D4: bp.sql:169 nulls p_district_id, then bp.sql:268 COALESCE brings back the stored 199 | BUG |
| BP-48 | State Board lock: own-state district kept | District 660 (Kushinagar, UP) | Kept | Proc | SQL D5 | PASS |
| BP-49 | Lock flagged to the UI | Get on a State Board school | board_requires_state=TRUE, "State Board (Uttar Pradesh)" | Proc / UI | SQL D6; static: BP.cshtml:244-247 | PASS |
| BP-50 | National board: state free | CBSE, Delhi | Delhi stored | Proc | SQL D7 | PASS |
| BP-51 | State lock after a validation error | State Board school submits an invalid phone | Page re-renders with the State still locked | Controller | static: SSC:117-121 returns View(model) built from the post. BoardRequiresState, TenantName and StatusName are not posted (BP.cshtml:22-27), so the lock disappears and the sidebar shows "Tenant not available" / "Status -" | BUG (low) |
| BP-52 | Pincode required | Blank | "Pincode is required." | UI-JS / Proc | static: BP.cshtml:399; SQL C4 | PASS |
| BP-53 | Pincode format | 5 digits, a letter, 7 digits | Refused | UI-JS / Controller / Proc | static: site.js:481, SMM:94; SQL C5, C6, C7 | PASS |
| BP-54 | Pincode starting with 0 | "012345" | Refused by client and controller (DB check would allow it) | UI-JS / Controller | static: site.js:481, SMM:94 | PASS |
| BP-55 | Contact name required | Blank / NULL | Refused | UI-JS / Controller / Proc | static: BP.cshtml:400; SQL C8 | PASS |
| BP-56 | Contact name > 150 | 151 chars | Refused | Proc | SQL C19 | PASS |
| BP-57 | Contact name format | "9839073643" typed as a name | Accepted (no format rule). The fixture row actually holds a phone number as the contact name | Controller | static: SMM:99-101 | Observation |
| BP-58 | Designation (hidden) preserved | Old value posted back | Kept | UI / Proc | static: BP.cshtml:282; SQL B12 | PASS |
| BP-59 | Official phone required | Blank / NULL | Refused | UI-JS / Proc | static: BP.cshtml:401; SQL C9 | PASS |
| BP-60 | Official phone format | "5123456789", "98765" | Refused (must match ^[6-9]\d{9}$) | UI-JS / Controller | static: site.js:479, SMM:111 | PASS |
| BP-61 | Official landline | "0124-2345678" | A school's official number is often a landline; it is rejected | UI-JS / Controller | static: SMM:111 (mobile-only regex) | Observation |
| BP-62 | Alternate phone optional / format | Blank ok; "123" refused | As stated | UI-JS / Controller | static: BP.cshtml:402, SMM:114 | PASS |
| BP-63 | Email optional / format / length | Blank ok; "a@b" refused; 151 chars refused | As stated | UI-JS / Controller / Proc | static: site.js:480, SMM:106; SQL C20 | PASS |
| BP-64 | Email, phones round-trip | Values saved | Read back | Proc | SQL B13 | PASS |
| BP-65 | Leading/trailing spaces | " Anita " | Nothing trims (client trims only to validate; proc stores as posted) | Controller / Proc | static: site.js:505, bp.sql UPDATE | Observation |
| BP-66 | Logo: no file picked | Save without a logo | Existing logo kept | Proc | SQL B14 (COALESCE bp.sql:200) | PASS |
| BP-67 | Logo: new file | Upload PNG | New URL replaces the old one | Controller / Proc | static: SSC:122-126; SQL B18 | PASS |
| BP-68 | Logo: phone photo 5 MB | JPEG 5 MB | Compressed to <=600px in the browser, posted, accepted | UI-JS | static: BP.cshtml:374-389, site.js:385-434 | PASS |
| BP-69 | Logo: non-image file | PDF | "Please choose an image file." | UI-JS | static: BP.cshtml:365-369 | PASS |
| BP-70 | Logo: > 2 MB after compression | Huge PNG | "Logo image must be less than 2 MB." (client and server) | UI-JS / Controller | static: BP.cshtml:375-379, SSC:110-113 | PASS |
| BP-71 | Logo: GIF / HEIC / SVG not shrunk | Small GIF | Friendly "Only JPG, PNG or WEBP" | Controller | static: SSC:102-108 (content-type check) | PASS |
| BP-72 | Logo: JPEG with a .jfif extension (Windows default) or no extension, already small | content-type image/jpeg, name photo.jfif | Friendly validation message | Controller | static: site.js:430 posts the original when compression saves nothing, SSC:102 accepts image/jpeg, then SSC:149 **throws InvalidOperationException**, an unhandled 500 | BUG |
| BP-73 | Logo: remove logo | Want no logo | No way to remove one; COALESCE keeps the old URL | UI / Proc | static: BP.cshtml:34-38, bp.sql:200 | Observation (feature gap) |
| BP-74 | Logo preview | Pick a file | Preview updates, toast shows the size saving | UI-JS | static: BP.cshtml:385-388 | PASS |
| BP-75 | Server validation messages shown | Invalid post | Each ModelState error toasted (Razor-encoded) | UI-JS | static: BP.cshtml:327-335 | PASS |
| BP-76 | Reset button | Click Reset | Reloads the page from DB (discards edits) | UI | static: BP.cshtml:304-305 | PASS |
| BP-77 | Live validation | Blur/fix field | Error shows on blur, clears on fix, submit blocked with toast | UI-JS | static: site.js:525-546 | PASS |
| BP-78 | Fields removed from validation | SchoolName/Board/Type/Admin not posted | ModelState entries removed so save is not blocked | Controller | static: SSC:74-99 | PASS |
| BP-79 | Unposted settings not wiped | SMS/email flags, academic year, formats | Untouched by profile save | Proc | SQL B17 (proc never writes school_settings) | PASS |
| BP-80 | Re-save idempotent | Save 3 times | One profile, address and contact row | Proc | SQL B20 | PASS |
| BP-81 | Refused save leaves data intact | Bad pincode etc. | Previous values intact | Proc | SQL C23 | PASS |
| BP-82 | DB error on save | Unforeseen proc error | Friendly message | Controller | static: SSC:129 has no try/catch, so a PostgresException becomes a 500 (the CLAUDE.md logging convention is not followed) | FAIL (low) |
| BP-83 | Platform scope write | Save with 1/0 | Refused | Proc | SQL C24 | PASS |
| BP-84 | Tenant/school mismatch write | Save with tenant 24, school 33 (tenant 23's school) | Refused, nothing written | Proc | SQL I1: 3 rows created under (24,33), success returned | BUG (low, defence in depth) |
| BP-85 | Concurrency | Two admins save at once | Last write wins, one row each (ON CONFLICT) | Proc | SQL B20; static: bp.sql ON CONFLICT | PASS |
| BP-86 | Downstream: letterhead | Receipt / TC / ID card / Documents preview use name, address, logo | Read via GetBasicProfileAsync | Downstream | static: FeeController.cs:635, TcController.cs:88, IdCardController.cs:89, DOC.cshtml:168-179, SchoolIdentityViewComponent.cs:29 | PASS |

## B. Documents & Formats (DOC)

| ID | Scenario | Steps / input | Expected result | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| DOC-01 | Page load | GET /ERP/SchoolSettings/Documents | Three cards with the saved choice checked | Controller / UI | static: SSC:187-205, DOC.cshtml:48,93,138 | PASS |
| DOC-02 | View permission | No settings.view | 403 | Controller | static: SSC:188 | PASS |
| DOC-03 | Tenant-1 user | Claims tenant 1 | AccessDenied | Controller | static: SSC:198 | PASS |
| DOC-04 | Receipt A5 save + read | Save A5 | Get returns A5 | Proc | SQL E1 | PASS |
| DOC-05 | Receipt Thermal | Save Thermal | Stored | Proc | SQL E2 | PASS |
| DOC-06 | Receipt unknown value | "Letter" | Coerced to A4 (service and proc), reported "saved" | Proc / Service | SQL E3; static: SSS:1122 | PASS (silent coercion noted) |
| DOC-07 | Receipt wrong case | "a5" | Not stored as is (coerced to A4) | Proc | SQL E4 | PASS |
| DOC-08 | Receipt blank | Empty | Controller: "Choose a format."; proc default A4 | Controller / Proc | static: FeeController.cs:415-416; SQL E5 | PASS |
| DOC-09 | Receipt no radio chosen | None checked | "Choose a format." toast | UI-JS | static: DOC.cshtml:186-187 | PASS |
| DOC-10 | Receipt save permission | User with settings.manage but not fees.manage | Can save the format on a Settings page | Controller | static: FeeController.cs:411 requires fees.manage, so a 403 comes back and DOC.cshtml:202 shows "Something went wrong." | BUG (low) |
| DOC-11 | Receipt preview | Click Preview | EcReceipt.preview with this school's letterhead and absolute logo URL | UI-JS | static: DOC.cshtml:168-183 | PASS |
| DOC-12 | Receipt busy button | Double click Save | Button busy until done | UI-JS | static: DOC.cshtml:190,203 | PASS |
| DOC-13 | Receipt downstream | Any receipt print | Uses saved format (cached, cache busted on save) | Downstream | static: FeeController.cs:602, SSS:1135 | PASS |
| DOC-14 | TC Board save + read | Save Board | Get returns Board | Proc | SQL E6 | PASS |
| DOC-15 | TC unknown value | "Standard" | Coerced to Basic | Proc | SQL E7 | PASS |
| DOC-16 | TC save permission + CSRF | settings.manage + token | Enforced | Controller | static: SSC:210-213, DOC.cshtml:223 | PASS |
| DOC-17 | TC preview | Click Preview | New tab, sample TC in chosen format | UI-JS / Controller | static: DOC.cshtml:208-211, TcController.cs:60-63,110 | PASS |
| DOC-18 | TC preview permission | Settings-only user | Preview opens | Controller | static: TcController.cs:13 needs students.view, so the new tab shows 403 | FAIL (low) |
| DOC-19 | TC default used when issuing | Save Board, then Issue TC | Issue dialog opens on Board ("The default format for a new TC") | Downstream | static: Student/Inactive.cshtml:373 always resets to 'Basic'. GetTcFormatAsync is read only by the Documents page itself (SSC:201), so the setting has no effect | BUG |
| DOC-20 | ID card Landscape save + read | Save Landscape | Get returns it | Proc | SQL E8 | PASS |
| DOC-21 | ID card junk value | "&lt;script&gt;" | Coerced to Portrait | Proc | SQL E9 | PASS |
| DOC-22 | ID card preview | Click Preview | New tab with sample cards | UI-JS / Controller | static: DOC.cshtml:235-238, IdCardController.cs:81-95 | PASS (needs students.view, same as DOC-18) |
| DOC-23 | ID card downstream | Students → ID Cards | Default layout pre-selected | Downstream | static: IdCardController.cs:44, IdCard/Index.cshtml:9 | PASS |
| DOC-24 | Formats independent | Save TC only | Receipt and ID card unchanged | Proc | SQL E10 | PASS |
| DOC-25 | Other settings untouched | Format saves | enable_sms etc. intact | Proc | SQL E11 | PASS |
| DOC-26 | No settings row yet | New school | Get empty (service default), first save creates 1 row, others at defaults | Proc | SQL E12, E13, E14 | PASS |
| DOC-27 | Re-save idempotent | Save twice | One row | Proc | SQL E13 | PASS |
| DOC-28 | Scope guards | 1/0, school 0, tenant-1 read | Refused | Proc | SQL E15, E16, E17 | PASS |
| DOC-29 | Cross-school isolation | Our saves | Other school's formats unchanged | Proc | SQL E18 | PASS |
| DOC-30 | Tenant/school mismatch write | Save with (24, 33) | Refused | Proc | SQL I2: row created | BUG (low) |
| DOC-31 | Cache scoped per tenant | Two schools | Cache key includes tenant+school | Service | static: SSS:1093,1140,1187 | PASS |
| DOC-32 | Layout | Area view sets Layout explicitly | Theme loads | UI | static: DOC.cshtml:8 | PASS |

## C. Admission Workflow (WF)

| ID | Scenario | Steps / input | Expected result | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| WF-01 | Page load | GET /ERP/AdmissionWorkflow/WorkflowSettings | Saved settings shown | Controller | static: AWC:29-41 | PASS |
| WF-02 | View permission | No admission_workflow.view | 403 (class-level) | Controller | static: AWC:13 | PASS |
| WF-03 | Save permission + CSRF | No admission_workflow.manage / no token | 403 / 400 | Controller | static: AWC:44-46 | PASS |
| WF-04 | Never-saved school | First visit | Defaults: reg off, auto-number on, prefix REG-, modules on | Service / Proc | SQL F1; static: AWS:29-32, AWC model defaults | PASS |
| WF-05 | Full round-trip | Reg on/required/fee, auto, "SPS/", collect, deposit, T off, E on, I off, P on | All read back | Proc | SQL F2–F6 | PASS |
| WF-06 | Registration off clears children | Crafted post with required/fee on | Stored FALSE (controller, service and proc) | Controller / Proc | static: AWC:54-58, AWS:102-104; SQL F7 | PASS |
| WF-07 | Prefix survives registration off | Turn reg off | Prefix/auto kept for later | Proc | SQL F8 | PASS |
| WF-08 | Children greyed when off | Uncheck Enable Registration | Child block disabled (pointer-events none) | UI-JS | static: WF.cshtml:289-291, WorkflowSettings.css:54 | PASS (keyboard can still toggle; the server normalises) |
| WF-09 | Prefix shown only with auto-number | Toggle auto | #prefixWrap toggles | UI-JS | static: WF.cshtml:294 | PASS |
| WF-10 | Prefix blank | "    " | REG- | Service / Proc | static: AWS:105; SQL F9 | PASS |
| WF-11 | Prefix padded with special chars | "  SPS/26-27/  " | "SPS/26-27/" | Proc | SQL F10 | PASS |
| WF-12 | Prefix 20 chars | Boundary | Accepted | UI / Proc | static: WF.cshtml:96 maxlength=20; SQL F11 | PASS |
| WF-13 | Prefix 21 chars (crafted) | 21 chars | Refused with a clear message | Proc / Service | SQL F12 (proc refuses); static: AWS:138-144 swallows it and the UI says only "Unable to save admission workflow settings." | PASS (generic message) |
| WF-14 | One row per school | Many saves | 1 row | Proc | SQL F13 | PASS |
| WF-15 | Soft-deleted row revived | is_deleted=TRUE, then save | Row live again | Proc | SQL F14 | PASS |
| WF-16 | Scope guards | 1/0 save, school 0 read | Refused | Proc / Service | SQL F15, F16; static: AWS:31,94 | PASS |
| WF-17 | Unknown operation | "ResetWorkflow" | Refused | Proc | SQL F17 | PASS |
| WF-18 | Cross-school isolation | Our saves | School 33's workflow unchanged | Proc | SQL F18 | PASS |
| WF-19 | Tenant/school mismatch write | Save with (24, 33) | Refused | Proc | SQL I3: row created | BUG (low) |
| WF-20 | Get failure | DB unavailable on GET | Error shown | Service | static: AWS:80-87 returns defaults silently; a Save then overwrites the real settings with defaults | Observation (low) |
| WF-21 | Live journey preview | Toggle reg/fee/required | Chips update (Registration + Fee (required)) | UI-JS | static: WF.cshtml:307-325 | PASS |
| WF-22 | Save message | Submit | TempData success/failure toast, PRG redirect | Controller | static: AWC:62-67 | PASS |
| WF-23 | Cancel | Click Cancel | Reload from DB | UI | static: WF.cshtml:261-262 | PASS |
| WF-24 | Charge-from moved | Row links to Academic Years | Link present, no field posted | UI | static: WF.cshtml:193-208 | PASS |
| WF-25 | Reg fee: amount <= 0 | 0 / blank / -5 | "Enter an amount greater than 0." (client and server) | UI-JS / Controller | static: WF.cshtml:357, AWC:84-85 | PASS |
| WF-26 | Reg fee: create | "Registration Fee", 500 | Registration-point, non-refundable, One Time head | Controller / Proc | SQL H3 | PASS |
| WF-27 | Reg fee: edit amount | 750 | Same head updated, never duplicated | Controller / Proc | SQL H4; static: AWC:91,96 | PASS |
| WF-28 | Deposit: create | "Security Deposit", 5000 | Refundable Admission-point head | Controller / Proc | SQL H5 | PASS |
| WF-29 | **Deposit named like an existing head** | No deposit head yet; type "Admission Fee" | New head, or refused; the real Admission Fee stays untouched | Controller | SQL H1: AWC:96 sends id 0, the proc upserts by name, and the school's Admission Fee becomes a refundable deposit | BUG (high) |
| WF-30 | **Reg fee named like an existing head** | No reg head yet; type "Tution Fee" | Tuition untouched | Controller | SQL H2: Tution Fee turned into a Registration-point One Time head (stops billing monthly) | BUG (high) |
| WF-31 | Rename onto another head | Existing reg head renamed to "Lab Fee" | "A fee head named ... already exists." | Proc | SQL H6 | PASS |
| WF-32 | Fee name > 80 | 81 chars (input maxlength=80) | Refused | UI / Proc | static: WF.cshtml:115; SQL H7 | PASS |
| WF-33 | Amount overflow | 1e10 | Refused (numeric(12,2)), message returned | Proc / Service | SQL H8; static: SSS:870-876 | PASS |
| WF-34 | Negative amount (crafted) | -1 | Refused | Controller / Proc | static: AWC:84; SQL H9 | PASS |
| WF-35 | Card on an inactive head | Head switched off in Fee Head master, amount set on card | Head chargeable again (card shows "Current: Rs 900 — editing updates it") | Controller / Proc | SQL H10: stays inactive, and GetCollectionPointResolvedTotalAsync (SSS:1255-1260) skips inactive heads, so registration charges 0 | BUG (low) |
| WF-36 | Remove fee | Click trash, confirm | Head deleted (cascade; refused if money collected) | UI-JS / Controller / Proc | static: WF.cshtml:373-387, AWC:126-149; SQL H11 | PASS |
| WF-37 | Remove only this page's heads | Crafted id of another head | "That is not one of the fee heads managed on this page." | Controller | static: AWC:130-134 | PASS |
| WF-38 | Remove: other school | Delete our head with (23,33) | Not deleted | Proc | SQL H12 | PASS |
| WF-39 | Fee card permission | User with admission_workflow.manage but not fees.manage | Clear refusal | Controller | static: AWC:79,121 require fees.manage; the 403 shows as "Something went wrong." (WF.cshtml:366) | FAIL (low) |
| WF-40 | Fee cards prefilled | Existing heads | Name/amount filled, hint "Current: Rs …" | UI-JS | static: WF.cshtml:333-352, AWC:154-160 | PASS |
| WF-41 | Fee wrap visibility | Fee/deposit toggles off | Amount block hidden | UI-JS | static: WF.cshtml:296-298 | PASS |
| WF-42 | Downstream: registration mandatory | Walk-in admission while required | Redirect to CRM; POST also blocked | Downstream | static: AdmissionController.cs:95-100, 259-266 | PASS |
| WF-43 | Downstream: enquiry not registered | Convert an unregistered enquiry | Blocked; "Registration Done" required | Downstream | static: AdmissionController.cs:69-75,109; SQL G4 | PASS |
| WF-44 | Downstream: registration disabled | Register endpoint | "Registration is not enabled for this school." | Downstream | static: EnquiryController.cs:328-330, 355-357 | PASS |
| WF-45 | Downstream: auto-number uses prefix | Register with SPS/ | SPS/0001, then SPS/0002 | Downstream / Proc | SQL G1, G2 | PASS |
| WF-46 | Downstream: re-register keeps number | Register again with another prefix | Same number, sequence not burned | Proc | SQL G3 | PASS |
| WF-47 | Downstream: manual mode needs number | Auto off, no number | Refused (controller and proc) | Controller / Proc | static: EnquiryController.cs:410-411; SQL G5 | PASS |
| WF-48 | Downstream: manual number trimmed | "  MAN-001 " | "MAN-001" | Proc | SQL G6 | PASS |
| WF-49 | Downstream: duplicate manual number | Two enquiries both "MAN-001" | Second refused | Proc | SQL G7: both accepted (no uniqueness check in sp_enquiry_register, no unique index on core.enquiries) | BUG (medium) |
| WF-50 | Downstream: registration fee charged only when enabled | Fee off | No receipt recorded | Downstream | static: EnquiryController.cs:432 | PASS |
| WF-51 | Downstream: collect fee at admission off | Cashier ticks Collect | Payment amount forced to 0 | Downstream | static: AdmissionController.cs:336-337 | PASS |
| WF-52 | Downstream: deposit only when enabled | Deposit toggle off | Refundable Admission heads hidden from admission fees | Downstream | static: AdmissionController.cs:489-492, 510-518 | PASS |
| WF-53 | Downstream: module toggles hide menu | Transport/Exams/Inventory/Payroll off | Menu groups hidden | Downstream | static: _VerticalMenu.cshtml:29-34 | PASS |
| WF-54 | Downstream: module toggles block URLs | Typed URL to /ERP/Transport | Redirect/JSON refusal | Downstream | static: RequiresModuleAttribute.cs:52-85 on Transport/Exam/Inventory/Payroll/Leave controllers | PASS |
| WF-55 | Downstream: registration page when off | Registration disabled, open /ERP/Registration | Hidden from menu; the page itself still opens | Downstream | static: RegistrationController.cs:12-13,41 (no EnableRegistration guard) | Observation |
| WF-56 | Permission keys exist | settings.*, admission_workflow.*, fees.manage | All present and active | DB | SQL I4 | PASS |

**Totals:** 174 catalog cases (BP 86, DOC 32, WF 56): 149 PASS, 15 BUG, 4 FAIL (low), 6 Observation. SQL suite: 116 checks.

## Bugs found

1. **High: Inline fee card silently repurposes an existing fee head.** AWC:91-104 sends `FeeHeadId = 0` when the school has no Registration or Security head yet, using whatever name the admin typed. `core.sp_school_admin_fee_head_manage` upserts by name on id 0. Typing "Admission Fee" as the deposit name turns the real Admission Fee into a refundable deposit (SQL H1). Typing "Tution Fee" for the registration fee turns tuition into a one-time Registration charge, so monthly tuition stops (SQL H2). Expected: refuse a name that belongs to a head of a different kind, or create a separate head.
2. **Medium: The district id outlives its state and its text.** bp.sql:268 `district_id = COALESCE(EXCLUDED.district_id, …)`. (a) Change the state and leave the district blank, and the old state's district id stays, an impossible pair (SQL D1). (b) Clear the district, and the text goes NULL but the id stays, so the page re-selects it (D2). (c) The State Board lock nulls a foreign district at bp.sql:169, but the COALESCE restores it, defeating the lock's own rule (D4). Expected: when state_id changes or district text is NULL, set district_id from the parameter (NULL), not COALESCE.
3. **Medium: The saved TC default format has no effect.** Student/Inactive.cshtml:373 always resets the issue dialog to 'Basic'. Nothing outside the Documents page reads GetTcFormatAsync. Expected: pre-select the saved format.
4. **Medium: Duplicate manual registration numbers are accepted** when auto-numbering is off (`core.sp_enquiry_register`, no uniqueness check or index; SQL G7). Expected: refuse a number already issued in the school.
5. **Medium: A website without a scheme passes the page but fails the save.** BP.cshtml:404-407 allows `school.com` / `www.school.com`, but SMM:54 `[Url]` demands http(s). The user gets "Enter valid website URL." after submitting a value the page said was fine.
6. **Medium: A logo with an unexpected extension crashes with a 500.** SSC:149 throws InvalidOperationException (for example a small `.jfif` JPEG, which site.js:430 posts unchanged because compression saved nothing). The content-type check at SSC:102 passes it. Expected: add a ModelState error like the other logo checks.
7. **Low: The procs do not check that the school belongs to the tenant.** Basic profile, receipt/TC/ID format and workflow saves with (tenant 24, school 33) write rows and report success (SQL I1-I3). The tables have no FK to core.schools. Ids come from claims, so this is defence in depth.
8. **Low: Saving an amount on an inactive fee head does not reactivate it** (SQL H10). The card shows the amount as current, but registration charges 0.
9. **Low: A validation error re-render loses unposted display state.** SSC:117-121: the State Board state lock disappears, and the sidebar shows "Tenant not available" / "Status -".
10. **Low: Permission mismatches on single pages give a generic "Something went wrong."** The receipt-format save needs fees.manage (FeeController.cs:411) on a Settings page. The workflow fee cards need fees.manage (AWC:79,121). TC/ID previews need students.view (TcController.cs:13, IdCardController.cs:14).
11. **Low: The established-year rules disagree.** The client caps the year at the current year, but the server accepts up to 2100 (SMM:51).
12. **Low: SaveBasicProfile has no try/catch** (SSC:129). A proc error is an unlogged 500, against the CLAUDE.md error-logging convention.
