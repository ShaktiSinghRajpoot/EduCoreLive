# Test cases: Academic Years + Classes & Sections

Pages: `/ERP/SchoolSettings/AcademicYears`, `/ERP/SchoolSettings/ClassSection`
SQL suite: `EduCoreDataAccessLayer/Database/tests/settings_years_classes_tests.sql`
First run (before fixes): RESULT: 139 passed, 23 failed. **After fixes: RESULT: 177 passed, 0 failed** (every BUG row below is now FIXED; see "Fix status" at the end). Result column keeps the original finding.

Stack read:
- Views: `educore/Areas/ERP/Views/SchoolSettings/AcademicYears.cshtml`, `ClassSection.cshtml`
- Controller: `educore/Areas/ERP/Controllers/SchoolSettingsController.cs` (ClassSection 590-787, AcademicYear 791-880, DTOs 1305-1362)
- Service: `EduCoreDataAccessLayer/Services/Repository/ERP/SchoolSettingsService.cs` (setup 262-400, clone 402-473, years 593-690)
- Procs, checked against the live local DB with `pg_get_functiondef`:
  - `academic.sp_school_admin_academic_year_manage`. The latest script is **`fee_charge_from_per_year.sql`**; `academic_year_manage.sql` is out of date and has no charge-from guard.
  - `academic.sp_school_admin_academic_setup_manage` (`academic_class_section_fields.sql`)
  - `academic.sp_academic_year_clone` and `sp_academic_year_structure_info` (`academic_session_rollover.sql`)
  - `config.sp_dropdown_common('AcademicYear')`
- Table facts that matter:
  - `academic_years.start_date` / `end_date` are `varchar(10) NOT NULL` with `CHECK (end_date > start_date)`.
  - `uq_academic_year (tenant, school, name)` is **not partial**, so it also covers deleted rows.
  - `academic_year_name` is `varchar(20)`.
  - Classes and sections have case-insensitive partial unique indexes.
  - `class_subjects` and `exam_subjects` link to a class by `academic_class_id`, and `timetable` links by `academic_class_section_id`.
  - Students, enrolment and fee structures store the year, class and section **by name**.

---

## The real-world scenario

Sunrise Public School (tenant 24, school 34) gets ready for session **ZZ 2040-41**:

1. **New session.** The admin opens Academic Years and clicks *New Academic Year*. They enter the name ZZ 2040-41, dates 01-Apr-2040 to 31-Mar-2041, and set "Charge recurring fees from" to session start. One typo is to leave the end date blank, and another is to enter a 21-character name. A colleague also tries to create "ZZ Overlap", which runs Oct 2040 to Sep 2041.
2. **Current session.** They click *Set current* on ZZ 2040-41 and later switch back to FY 26-27. Meanwhile a second admin has a stale tab open and clicks *Set current* on a year that was just deleted.
3. **Build the classes.** On Classes & Sections they choose ZZ 2040-41 and build the class ladder:
   - Nursery, LKG, UKG, I to X, and XII Science (PCM).
   - XI split by stream into "XI Science (PCM)" and "XI Commerce", both at rank 14.
   - Sections A/B/C with 40 seats and a room each.
   - A coordinator linked from the staff list for Nursery, and free-text "Mrs. Rao" for Class I.
4. **Adjust the classes.**
   - Rename section II-C to "Rose".
   - Remove the unused class UKG.
   - Admit a child into IV-A, then try to rename IV-A, remove IV-A, rename class IV and remove class IV.
   - Remove the empty section IV-C.
   - Move class IV to rank 70 and put IV-A in the "Hall" room.
5. **Downstream pages.** Subjects, exams and the timetable were already set up for FY 26-27, and the admin presses Save on Classes & Sections without changing anything.
6. **Copy forward.** They create session ZZ 2027-28, accept the banner "Copy from FY 26-27", then add a class that exists only in the copy.
7. **Rename and delete.** They rename a session that has a child in it, remove its class and delete it. Then they delete a session by mistake and type it in again. Finally they delete the current session.

---

## A. Academic Years page

| ID | Scenario | Steps / input | Expected result | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| AY-01 | Create a session | name `ZZ 2040-41`, 2040-04-01..2041-03-31, SessionStart, not current | Created, id returned; list shows name, ISO dates, SessionStart, not current, 0 classes, 0 students; still exactly one current | Proc | SQL AY-01, AY-01b..i | PASS |
| AY-02 | NULL name | name NULL | "Academic year name is required." | Proc | SQL AY-02 | PASS |
| AY-03 | Whitespace name | `'   '` | Refused, name required | Proc | SQL AY-03 | PASS |
| AY-03u | Whitespace name in UI | type spaces, click Save | Toast "Academic year name is required.", no POST | UI-JS | static: AcademicYears.cshtml:234-235 | PASS |
| AY-03c | Whitespace name in controller | POST `{name:"  "}` | `success:false`, name required | Controller | static: SchoolSettingsController.cs:815-816 | PASS |
| AY-04 | Padded name | `'   ZZ Trim   '` | Stored `ZZ Trim` | Proc + Controller | SQL AY-04; static: SchoolSettingsController.cs:821 (`Trim()`) | PASS |
| AY-05 | 21-character name | `ZZ 2040-2041 Session1` | Refused with a readable "max 20 characters" message | Proc | SQL AY-05 (refused), AY-05b (message is raw "value too long for type character varying(20)") | **BUG** |
| AY-05u | Name maxlength in UI | type 25 characters | Input stops at 20 | UI-JS | static: AcademicYears.cshtml:122 (no `maxlength`); controller has no length check (815-829) | **BUG** |
| AY-06 | Exactly 20 characters | `ZZ 2048-2049 Session` | Accepted | Proc | SQL AY-06 | PASS |
| AY-07 | Special characters and unicode | `ZZ <b>&"'x</b>`, `ZZ सत्र 2056` | Stored verbatim; rendered HTML-encoded | Proc + View | SQL AY-07, AY-07b; static: AcademicYears.cshtml:69,84 (Razor-encoded), EC.confirm escapes name site.js:156 | PASS |
| AY-08 | No dates | start and end blank | Refused with a readable "dates are required" message | Proc | SQL AY-08 (refused), AY-08b (raw "null value in column start_date ... violates not-null constraint") | **BUG** |
| AY-08u | Dates required in UI | leave dates blank, Save | Client blocks with a message | UI-JS | static: AcademicYears.cshtml:236-240 (dates optional; `startDate:start\|\|null` is sent) | **BUG** |
| AY-09 | Start date but no end | start only | Refused, readable | Proc | SQL AY-09, AY-09b (raw NOT NULL text) | **BUG** |
| AY-09c | Invalid date string by hand-made POST | `startDate:"31-31-2040"` | Refused as an invalid date | Controller | static: SchoolSettingsController.cs:822-823 (`Dates.Norm` turns it into null, which then hits the raw NOT NULL error) | **BUG** (same root as AY-08) |
| AY-10 | End before start | 2041-04-01..2040-03-31 | "End date cannot be before start date." | Proc + UI | SQL AY-10, AY-10b; static: AcademicYears.cshtml:238 | PASS |
| AY-11 | One-day session (end = start) | 2045-04-01..2045-04-01 | Refused with a readable message | Proc + UI | SQL AY-11 (refused only by CHECK), AY-11b (raw "violates check constraint chk_academic_year_dates"); UI allows it: AcademicYears.cshtml:238 tests `end < start` only; proc fee_charge_from_per_year.sql:122 same | **BUG** |
| AY-12 | Duplicate name | `ZZ 2040-41` again | Refused, "already exists" | Proc | SQL AY-12 | PASS |
| AY-13 | Duplicate, different case | `zz 2040-41` | Refused | Proc | SQL AY-13 | PASS |
| AY-14 | Duplicate with padding | `'  ZZ 2040-41 '` | Refused | Proc | SQL AY-14 | PASS |
| AY-15 | Same name in another school | school 33 creates `ZZ 2040-41` | Allowed | Proc | SQL AY-15 | PASS |
| AY-16 | Unknown charge-fees-from | `Garbage` | Stored AdmissionMonth | Proc + Controller | SQL AY-16; static: SchoolSettingsController.cs:827-828 | PASS |
| AY-17 | NULL charge-fees-from | NULL | AdmissionMonth | Proc | SQL AY-17 | PASS |
| AY-18 | Overlapping session | `ZZ Overlap` 2040-10-01..2041-09-30 | Refused: overlaps ZZ 2040-41 | Proc | SQL AY-18 (accepted) | **BUG** |
| AY-19 | Identical dates to another session | `ZZ Same Dates` 2040-04-01..2041-03-31 | Refused | Proc | SQL AY-19 (accepted) | **BUG** |
| AY-20 | Back-to-back session | 2041-04-01..2042-03-31 | Accepted (no overlap) | Proc | SQL AY-20 | PASS |
| AY-21 | Set current | *Set current* on ZZ 2040-41 | It becomes the only current session | Proc | SQL AY-21, AY-21b | PASS |
| AY-22 | Set current twice | repeat | Still exactly one current | Proc | SQL AY-22 | PASS |
| AY-23 | Set current does not touch other schools | after AY-21 | School 33's current session unchanged | Proc | SQL AY-23 | PASS |
| AY-24 | Switch back | *Set current* on FY 26-27 | FY 26-27 current | Proc | SQL AY-24 | PASS |
| AY-25 | Set current with id 0 | id 0 | "Select an academic year." | Proc | SQL AY-25 | PASS |
| AY-26 | Set current from a stale tab (year deleted) | id 999999 | Refused; current session kept | Proc | SQL AY-26 (accepted: **school left with 0 current sessions**); fee_charge_from_per_year.sql:216-226 clears every flag, then updates nothing | **BUG** |
| AY-27 | Set current on another school's year id | id of school 33's year | Refused; our current session kept | Proc | SQL AY-27 (same: 0 current); AY-27b the other school's rows untouched (PASS) | **BUG** |
| AY-28 | Create a session with "Set as current" ticked | `ZZ 2064-65`, current = true | Flag moves to the new session | Proc | SQL AY-28 | PASS |
| AY-29 | Edit a non-current session, box unticked | resave ZZ 2040-41 | Current session unchanged | Proc | SQL AY-29 | PASS |
| AY-30 | Edit THE current session and untick "Set as current" | resave current year, is_current = false | Refused, or the session stays current (a school must always have one) | Proc | SQL AY-30 (0 current); fee_charge_from_per_year.sql:196 `is_current = COALESCE(p_is_current, is_current)`, and the service always sends a bool | **BUG** |
| AY-31 | Edit with current ticked | resave FY 26-27, current = true | It becomes the only current session | Proc | SQL AY-31 | PASS |
| AY-32 | Edit name, dates and charge-from | on an empty session | All saved, in place | Proc | SQL AY-32, AY-32b | PASS |
| AY-33 | Re-save unchanged | same payload | Same id, one row | Proc | SQL AY-33 | PASS |
| AY-34 | Rename onto another session's name | `FY 26-27` (any case) | Refused | Proc | SQL AY-34 | PASS |
| AY-35 | Case-only rename of itself | `zz 2064-2065` | Allowed | Proc | SQL AY-35 | PASS |
| AY-36 | Edit an id that no longer exists | id 999999 | Refused ("session not found") | Proc | SQL AY-36 (returns success with id NULL; UI toasts "Academic year saved.") | **BUG** |
| AY-37 | Same, with current ticked | id 999999, current = true | Current session kept | Proc | SQL AY-37 (all current flags cleared first: 0 current) | **BUG** |
| AY-38 | Edit another school's year id | our scope, school 33's id | Their row not changed | Proc | SQL AY-38 | PASS |
| AY-39 | Charge-from change after admissions | FY 26-27 has a student; flip the value | Refused with an explanation | Proc | SQL AY-39 | PASS |
| AY-39b | Date fix on a session with students | same charge-from, end + 1 day | Allowed | Proc | SQL AY-39b | PASS |
| AY-39c | Charge-from change on an empty session | ZZ 2040-41 | Allowed | Proc | SQL AY-39c | PASS |
| AY-39u | Charge-from locked in the modal when students > 0 | Edit a year with students | Select disabled, "Locked: N students" note | UI-JS | static: AcademicYears.cshtml:208,216-226 | PASS |
| AY-39p | Charge-from on a past session whose students have been promoted | students' `core.students.academic_year` is now the next session | Still locked (fee plans for that session exist) | Proc + UI | static: fee_charge_from_per_year.sql:155-163 counts `core.students` (current position only), so the count is 0 and the change is allowed; the UI lock uses the same count (AcademicYears.cshtml:87 `data-students`) | **BUG** (low) |
| AY-40 | List order | several sessions | Newest start date first | Proc | SQL AY-40 | PASS |
| AY-41 | Unknown operation | `BogusOp` | Refused | Proc | SQL AY-41 | PASS |
| AY-42 | Students counted per session | admit a child into `ZZ Rename` | Count = 1 | Proc | SQL AY-42 | PASS |
| AY-43 | Rename a session that has students | `ZZ Rename` to `ZZ Renamed` | Students stay attached, or the rename is refused while students, fees or enrolment reference the name | Proc | SQL AY-43 (count becomes 0; the child still says "ZZ Rename"; students, enrolment, fee structures and attendance are keyed by name and nothing cascades) | **BUG** |
| AY-44 | After the rename, remove that child's class | Classes page save `[]` | Refused (child enrolled) | Proc | SQL AY-44 (accepted; the guard compares by the new name) | **BUG** |
| AY-45 | After the rename, delete the session | Delete | Refused | Proc | SQL AY-45 (deleted with a child still in it) | **BUG** |
| AY-46 | Delete an empty session | Delete, then confirm | Soft-deleted (is_deleted, inactive, not current), gone from the list | Proc | SQL AY-46, AY-46b | PASS |
| AY-46u | Delete asks for confirmation | click trash | EC.confirm with the session name; Cancel does nothing | UI-JS | static: AcademicYears.cshtml:262-265 | PASS |
| AY-47 | Delete twice | same id again | Harmless | Proc | SQL AY-47 | PASS |
| AY-48 | Re-create a deleted session's name | delete `ZZ Delete Me`, then add it again | Allowed (the proc's duplicate check skips deleted rows) | Proc | SQL AY-48 (raw "duplicate key value violates unique constraint uq_academic_year": the constraint is not partial) | **BUG** |
| AY-49 | Delete a session with classes and students | FY 26-27 | Refused, with counts | Proc | SQL AY-49 | PASS |
| AY-50 | Delete a session with classes only | | Refused | Proc | SQL AY-50 | PASS |
| AY-51 | Delete with no id | NULL | "Select an academic year." | Proc | SQL AY-51 | PASS |
| AY-52 | Delete an unknown id | 999999 | Refused | Proc | SQL AY-52 (reports "Academic year deleted.") | **BUG** (low) |
| AY-53 | Delete another school's year | school 33's id | Their row untouched | Proc | SQL AY-53 | PASS |
| AY-54 | Delete the current session | empty current session | Refused (switch the current session first) | Proc + UI | SQL AY-54 (deleted: 0 current); the UI shows the trash button on the current row too (AcademicYears.cshtml:88) | **BUG** |
| AY-55 | New session shows in the shared year dropdown | after AY-01 | Listed | Proc | SQL AY-55 | PASS |
| AY-56 | Dropdown marks the current session | | `IsSelected` on the current session | Proc | SQL AY-56 | PASS |
| AY-57 | Current session listed first | | First row = current | Proc | SQL AY-57 | PASS |
| AY-58 | Deleted session not in the dropdown | | Not listed | Proc | SQL AY-58 | PASS |
| AY-59 | Other school's sessions not in the dropdown | | Not listed | Proc | SQL AY-59 | PASS |
| AY-60..64 | Platform or missing school scope | tenant 1 / school 0 on Save, List, SetCurrent, Delete | "Invalid school admin scope." | Proc + Service | SQL AY-60..64; static: SchoolSettingsService.cs:598,624,640,654 guards | PASS |
| AY-65 | Our list never shows another school's session | | 0 foreign rows | Proc | SQL AY-65 | PASS |
| AY-66 | Their list never shows ours | | 0 | Proc | SQL AY-66 | PASS |
| AY-67 | Cache invalidation | Save, SetCurrent or Delete | `dropdowns:basicprofile` key removed (tenant/school scoped) | Service | static: SchoolSettingsService.cs:633,647,661; key SchoolSettingsService.cs:40 | PASS |
| AY-68 | Cache not touched on a refused write | proc RAISE | No removal needed (nothing changed) | Service | static: removal happens after the proc returns (633); an exception skips it | PASS |
| AY-69 | Antiforgery | POST without the token | 400 | Controller + UI | static: token AcademicYears.cshtml:160, header :185; `[ValidateAntiForgeryToken]` SchoolSettingsController.cs:807,843,863 | PASS |
| AY-70 | Permissions | user without `settings.view` / `settings.manage` | GET returns 403; POSTs return 403; anonymous gets a login challenge | Controller | static: SchoolSettingsController.cs:793,808,844,864; HasPermissionAttribute.cs:36-50 | PASS |
| AY-71 | Ids come from claims, not the body | body carries no tenant/school | Scope = claims | Controller | static: SchoolSettingsController.cs:811-813 | PASS |
| AY-72 | Proc RAISE shown to the user | duplicate name | Toast shows the proc message | Controller + UI | static: SchoolSettingsController.cs:836-839; AcademicYears.cshtml:248 | PASS |
| AY-73 | HTTP failure (403/500/network) | | Toast via EC.ajaxError, modal stays open | UI-JS | static: AcademicYears.cshtml:250,259,271 | PASS |
| AY-74 | Double-click Save | two quick clicks on a new year | One request; button busy | UI-JS | static: AcademicYears.cshtml:233-251 (no EC.buttonBusy or disable; the second POST meets the duplicate check or a raw unique-constraint race) | **BUG** (low) |
| AY-75 | Edit modal pre-fill | click Edit | Name, ISO dates, current switch and charge-from filled in | UI-JS | static: AcademicYears.cshtml:84-87,201-209 (StartDate is ISO text; the column is varchar) | PASS |
| AY-76 | Add modal reset after an edit | Edit, Cancel, then New | Empty form, AdmissionMonth, title "New Academic Year" | UI-JS | static: AcademicYears.cshtml:191-199 | PASS |
| AY-77 | Summary cards and empty state | 0 years / some years | "No academic years yet" shows only when the list is empty; cards show total and current (or "—") | View | static: AcademicYears.cshtml:39,45,57,93-97 | PASS |
| AY-78 | "Set current" hidden on the current row | | Button not rendered for the current session | View | static: AcademicYears.cshtml:80-83 | PASS |
| AY-79 | Success reloads the list | Save, Set current or Delete succeeds | Toast, then reload after 0.5-0.6 s | UI-JS | static: AcademicYears.cshtml:247,256,268 | PASS |
| AY-80 | Search / pagination | | None on this page (short list) | — | static: n/a | N/A |

## B. Classes & Sections page

| ID | Scenario | Steps / input | Expected result | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| CS-01 | Build the full ladder | 16 classes x A/B/C | Saves; 16 classes / 48 sections; Academic Years page shows 16 classes | Proc | SQL CS-01, CS-01b, CS-01c | PASS |
| CS-02 | Rank becomes display order; streams share a rank | XI PCM and XI Commerce both 14 | Stored as posted | Proc | SQL CS-02 | PASS |
| CS-03 | Classes listed in rank order | | Nursery..X, then XI Commerce, XI Science (PCM), XII | Proc + UI | SQL CS-03; static: ClassSection.cshtml:350 (sort by rank) | PASS |
| CS-04 | Stream round-trips | `com` | `com` | Proc | SQL CS-04 | PASS |
| CS-04c | Unknown stream by hand-made POST | `stream:"x<script>"` | Refused | Controller | static: SchoolSettingsController.cs:729-730 (allowlist) | PASS |
| CS-05 | Coordinator linked from staff | staff 23, typed text differs | Staff id kept; name taken from the staff row | Proc | SQL CS-05 | PASS |
| CS-06 | Free-text coordinator | `Mrs. Rao`, no id | Kept | Proc | SQL CS-06 | PASS |
| CS-07 | Coordinator from another school | staff 33 | Id and name both dropped | Proc | SQL CS-07 | PASS |
| CS-07u | Coordinator dropdown | | Only this school's Teaching staff | Controller | static: SchoolSettingsController.cs:627-634 | PASS |
| CS-08 | Section order follows the posted order | C, A, B | 1, 2, 3 | Proc | SQL CS-08 | PASS |
| CS-09 | Capacity and room; blanks become NULL | 35/III-C, null/null, 45/`'  '` | As posted; blank room becomes NULL | Proc | SQL CS-09 | PASS |
| CS-10 | Names trimmed | `'  IV  '`, `' A '` | `IV`, `A` | Proc + Controller | SQL CS-10; static: SchoolSettingsController.cs:716,740 | PASS |
| CS-11 | Blank class name | `'   '` | Not saved (proc skips it); controller refuses | Proc + Controller | SQL CS-11; static: SchoolSettingsController.cs:717-718 | PASS |
| CS-11u | Blank class name in UI | | Toast "Class name is required." | UI-JS | static: ClassSection.cshtml:482-483 | PASS |
| CS-12 | Blank section name | | Not saved; controller refuses | Proc + Controller | SQL CS-12; static: SchoolSettingsController.cs:741-742 | PASS |
| CS-12u | Blank section in UI | | "Section name is required." | UI-JS | static: ClassSection.cshtml:545-546 | PASS |
| CS-13 | Duplicate class name (any case) | `Nursery` + `nursery` | Refused | Proc + Controller + UI | SQL CS-13 (unique index); static: controller 721-722, JS 493-499 | PASS |
| CS-14 | Duplicate section in a class (any case) | `A` + `a` | Refused | Proc + Controller + UI | SQL CS-14; static: controller 746-747, JS 550-551 | PASS |
| CS-15 | Same section name in different classes | A everywhere | Allowed | Proc | SQL CS-15 | PASS |
| CS-16 | Class name 51 characters | | Refused | Proc + Controller + UI | SQL CS-16; static: controller 719-720, JS maxlength 153 and length check after the suffix 492 | PASS |
| CS-17 | Section name 21 characters | | Refused | Proc + Controller + UI | SQL CS-17; static: controller 742-743, JS maxlength 214 | PASS |
| CS-18 | Room 51 characters | | Refused | Proc + Controller + UI | SQL CS-18; static: controller 752-753, JS maxlength 222 | PASS |
| CS-19 | Coordinator 151 characters | | Refused | Proc + Controller | SQL CS-19; static: controller 733-734 | PASS |
| CS-20 | Maximum lengths and capacity 5000 | 50/20/50/150, 5000 | Accepted | Proc | SQL CS-20 | PASS |
| CS-21 | Special characters | `Rose – "Red" & <Lily>`, `O'Hara`, room `<b>1</b>` | Stored verbatim; rendered escaped | Proc + UI | SQL CS-21; static: ClassSection.cshtml:367,373,374,396,397 (EC.esc), seed JSON via JsonSerializer (249) | PASS |
| CS-22 | Negative capacity | -5 | Refused at every layer | Proc + Controller + UI | SQL CS-22 (proc and table accept -5: no CHECK); controller refuses (748); JS refuses negatives (548) | **BUG** (low, defence in depth) |
| CS-22u | Capacity 0 or blank in UI | 0 | Message says "1 and 5000" | UI-JS | static: ClassSection.cshtml:547-548 (0/blank accepted and stored as "no capacity" via `cap\|\|null` at 284; the message is inconsistent) | PASS (cosmetic note) |
| CS-22c | Capacity below current strength | edit IV-A to cap 0 < strength | Refused | UI-JS | static: ClassSection.cshtml:556 (only when cap is set) | PASS |
| CS-23 | Payload not an array | `{"not":"an array"}` | Refused | Proc | SQL CS-23 | PASS |
| CS-24 | Malformed JSON | | Refused | Proc | SQL CS-24 | PASS |
| CS-25 | Re-save unchanged | post the current structure back | Every field identical; 16 live classes | Proc | SQL CS-25, CS-25b | PASS |
| CS-26 | Class teacher survives a save | teacher set on I-A, then save another change | Teacher still on I-A | Proc | SQL CS-26 | PASS |
| CS-26u | Class teacher read-only here | Edit section | Shown greyed out, "Assigned on Assign Class Teacher page" | UI-JS | static: ClassSection.cshtml:225-227,539 | PASS |
| CS-27 | Rename an empty section | II-C to Rose | Saved | Proc | SQL CS-27 | PASS |
| CS-28 | Remove an unused class | UKG | Gone; nothing else changed | Proc | SQL CS-28, CS-28b | PASS |
| CS-28u | Delete class asks for confirmation; blocked client-side when it has students | | EC.confirm; toast "Cannot delete — N students" | UI-JS | static: ClassSection.cshtml:515-527 | PASS |
| CS-29 | Live strength | admit a child into IV-A | IV-A strength 1; the session counts 1 student | Proc | SQL CS-29, CS-29b | PASS |
| CS-30 | Remove a section with a child | IV-A | Refused, readable | Proc | SQL CS-30 | PASS |
| CS-31 | Rename a section with a child | IV-A to Alpha | Refused | Proc | SQL CS-31 | PASS |
| CS-32 | Rename a class with a child | IV to Class 4 | Refused | Proc | SQL CS-32 | PASS |
| CS-33 | Case-only class rename with a child | IV to iv | Refused | Proc | SQL CS-33 | PASS |
| CS-34 | Remove a whole class with a child | IV | Refused | Proc | SQL CS-34 | PASS |
| CS-35 | Refusals change nothing | | IV-A still there | Proc | SQL CS-35 | PASS |
| CS-35u | UI resyncs after a refusal | server says no | Toast with the proc message, then reload | UI-JS + Controller | static: ClassSection.cshtml:298-301; SchoolSettingsController.cs:780-783 | PASS |
| CS-36 | Remove an empty section next to the child's | IV-C | Allowed | Proc | SQL CS-36 | PASS |
| CS-37 | Change rank and room of a class with a child | rank 70, room Hall | Allowed | Proc | SQL CS-37 | PASS |
| CS-38 | A child who Left does not block | enrolment status Left | Section can be removed | Proc | SQL CS-38 | PASS |
| CS-39 | Save into another school's session | school 33's year id | Refused; nothing written | Proc | SQL CS-39, CS-39b | PASS |
| CS-40 | Two saves in one transaction | call the proc twice in one tx | Both work | Proc | SQL CS-40 ("relation _ct_snap already exists": academic_class_section_fields.sql:196 creates a temp table ON COMMIT DROP); latent only, because the app runs one proc per transaction | **BUG** (low) |
| CS-41 | Read another school's session | | Nothing returned | Proc | SQL CS-41 | PASS |
| CS-42 | Save into a deleted session | delete a year, then post classes to it | Refused | Proc | SQL CS-42 (accepted: the year lookup at academic_class_section_fields.sql:143 has no `is_deleted` filter) | **BUG** (low) |
| CS-43 | No session | year 0 | "Please select academic year." | Proc + Controller + UI | SQL CS-43; static: controller 705-706, JS 278 | PASS |
| CS-44 | Unchanged re-save of the live session | FY 26-27 | Visible structure identical | Proc | SQL CS-44 | PASS |
| CS-45 | Subject mapping survives a save | press Save with no changes | Class subjects stay mapped | Proc | SQL CS-45 (**49 to 0**: every save soft-deletes all classes and re-inserts them with new ids; `class_subjects.academic_class_id` keeps pointing at the dead rows) | **BUG** (high) |
| CS-46 | Exam papers survive a save | same | Exam subjects stay on their class | Proc | SQL CS-46 (**144 to 0**) | **BUG** (high) |
| CS-47 | Timetable survives a save | same | Timetable slots stay on their section | Proc | SQL CS-47 (**1 to 0**; `timetable.academic_class_section_id` points at a deleted section and the grid reads empty) | **BUG** (high) |
| CS-48 | Enrolled children still match a class and section | after the save | 0 orphans (name-keyed) | Proc | SQL CS-48 | PASS |
| CS-49 | Structure info for a new session | ZZ 2027-28 | 0 classes / 0 sections | Proc | SQL CS-49 | PASS |
| CS-50 | Copy source = closest earlier session with classes | | FY 26-27 offered | Proc | SQL CS-50 | PASS |
| CS-51 | Structure info counts | FY 26-27 | Matches live counts | Proc | SQL CS-51 | PASS |
| CS-52 | A later session is never the source | | ZZ 2040-41 not offered for FY 26-27 | Proc | SQL CS-52 | PASS |
| CS-53 | Copy reports counts | Copy from FY 26-27 | "Copied 11 classes and 14 sections ..." | Proc | SQL CS-53 | PASS |
| CS-54 | Copy is faithful | | Names, ranks, streams, coordinators, capacity, rooms, order all equal | Proc | SQL CS-54 | PASS |
| CS-55 | Class teachers not copied | | 0 in the new session | Proc | SQL CS-55 | PASS |
| CS-56 | Copy into a session that has classes | repeat the copy | Refused | Proc | SQL CS-56 | PASS |
| CS-57 | Copy independent of the source | add a class to the copy | Source unchanged | Proc | SQL CS-57 | PASS |
| CS-58 | Banner disappears once classes exist | | `class_count > 0`, so CanCopySetup is false | Proc + Controller | SQL CS-58; static: SchoolSettingsController.cs:646 | PASS |
| CS-58u | Copy button busy and error handling | | Busy while copying; reset and toast on failure; reload on success | UI-JS | static: ClassSection.cshtml:307-335 | PASS |
| CS-59 | Copy onto itself | | Refused | Proc | SQL CS-59 | PASS |
| CS-60 | Copy with a missing source | 0 | Refused | Proc + Controller | SQL CS-60; static: controller 664-665 | PASS |
| CS-61 | Copy from an empty session | | Refused | Proc | SQL CS-61 | PASS |
| CS-62 | Copy FROM another school | | Refused | Proc | SQL CS-62 | PASS |
| CS-63 | Copy INTO another school | | Refused; nothing written | Proc | SQL CS-63, CS-63b | PASS |
| CS-64 | Structure info for another school's session | | Empty | Proc | SQL CS-64 | PASS |
| CS-65..68 | Platform or missing school scope on save, read, copy and info | tenant 1 / school 0 | Refused / no row | Proc + Service | SQL CS-65..68; static: SchoolSettingsService.cs:264,366,408,438 | PASS |
| CS-69 | No foreign class row on our sessions | | 0 | Proc | SQL CS-69 | PASS |
| CS-70 | Year switcher | change the dropdown | Navigates with `?academicYearId=` | UI-JS | static: ClassSection.cshtml:601-605 | PASS |
| CS-71 | Default session | no query string | Current session (or the first one) | Controller | static: SchoolSettingsController.cs:598-603 | PASS |
| CS-72 | CURRENT / NOT CURRENT badge | view a past session | "NOT CURRENT" | View | static: ClassSection.cshtml:87-93 | PASS |
| CS-73 | Search | "section b", "x", no match | Filters by class name or "Section X"; auto-expands matches; empty state when nothing matches | UI-JS | static: ClassSection.cshtml:349-361,412-413 | PASS |
| CS-74 | Empty-session state | session with no classes and nothing to copy | Says "no classes yet, add one" | UI | static: ClassSection.cshtml:124-128 (always says "No classes found — Try a different search") | **BUG** (cosmetic) |
| CS-75 | Expand / collapse all | | Toggles every class and the label | UI-JS | static: ClassSection.cshtml:593-599 | PASS |
| CS-76 | New class gets section A | Add Class | Section A, capacity 40 | UI-JS | static: ClassSection.cshtml:505-510 | PASS |
| CS-77 | Stream suffix on add | Class 11 + PCM | Preview "Saved as: Class 11 Science (PCM)"; not doubled if already typed | UI-JS | static: ClassSection.cshtml:464-477,491 | PASS |
| CS-78 | Rank validation | rank 0 / blank / 1000 | 1000 refused; 0 or blank refused | UI-JS + Controller | static: JS 484 turns 0/blank into "next rank" silently; controller 723 accepts 0 although its message says 1-999 | **BUG** (low) |
| CS-79 | Rename a class with no students | edit IV to Class 4 (no admissions yet, fee structure already set) | Fee structure and class teacher follow, or the rename warns | UI-JS + Proc | static: ClassSection.cshtml:500-502 allows renaming a saved class (the comment at 459-463 says renaming orphans name-keyed data); `core.school_fee_structures` keys on class_name; the teacher snapshot matches on the old name (academic_class_section_fields.sql _ct_snap restore) | **BUG** (medium) |
| CS-80 | Shared room warning | same room twice | Warning toast; still saves | UI-JS | static: ClassSection.cshtml:552-553,563,569-577 | PASS |
| CS-81 | Save is optimistic; the request fails (403/500/network) | | UI rolls back or reloads | UI-JS | static: ClassSection.cshtml:303 (`.fail` only toasts; local DATA keeps the unsaved change until a manual refresh) | **BUG** (low) |
| CS-82 | Fast consecutive edits | two saves in flight | Serialised (each is replace-all) | UI-JS | static: ClassSection.cshtml:277-304 (no in-flight guard; out-of-order completion can persist the older snapshot) | **BUG** (low) |
| CS-83 | Server returns success:false without a message | proc returns no row | Meaningful message | Controller | static: SchoolSettingsController.cs:786 (`{success = result > 0}` has no message, so the generic "Save failed.") | **BUG** (low) |
| CS-84 | Antiforgery on save and copy | | Token header; `[ValidateAntiForgeryToken]` | Controller + UI | static: ClassSection.cshtml:239,292,318; controller 657,697 | PASS |
| CS-85 | Permissions | without `academics.view` / `academics.manage` | 403 | Controller | static: SchoolSettingsController.cs:590,656,698 | PASS |
| CS-86 | URL-tampered `academicYearId` from another school | `?academicYearId=11` | Empty structure; save refused | Controller + Proc | SQL CS-39/CS-41; static: controller 605 (scoped proc) | PASS |
| CS-87 | Hand-made POST with two classes of the same name | | Refused with an explanation | Controller | static: SchoolSettingsController.cs:721-722 | PASS |
| CS-88 | No cache to invalidate | | Classes are not cached (only fee heads, basic-profile dropdowns and formats) | Service | static: SchoolSettingsService.cs:39-40, 360-400 (no `_cache`) | PASS |
| CS-89 | Pagination | | None (one session's classes on one page) | — | n/a | N/A |

---

## Bugs found (by severity)

**High**
1. **Every Classes & Sections save detaches subjects, exam papers and the timetable.**
   - Where: `academic_class_section_fields.sql:207-224`, live `sp_school_admin_academic_setup_manage` (SaveAcademicSetup).
   - What happens: the save soft-deletes all classes and sections for the year and re-inserts them with new ids.
     - `class_subjects` and `exam_subjects` (by `academic_class_id`) and `timetable` (by `academic_class_section_id`) keep pointing at the dead rows.
     - An unchanged Save on the live session took class subjects from 49 to 0, exam subjects from 144 to 0, and timetable slots from 1 to 0 (CS-45/46/47).
     - Any edit on the page (a room, a new section) does the same.
     - School 33 already shows the damage: all 135 of its `class_subjects` rows point at deleted classes.
   - Should: update rows that match by name in place (or carry these child rows over, as `_ct_snap` does for class teachers).
2. **Setting the current session to an id that isn't this school's live session leaves the school with no current session, and reports success.**
   - Where: `fee_charge_from_per_year.sql:216-226`.
   - What happens: it clears every flag first and then updates nothing (AY-26, AY-27). A stale tab after a delete is enough to trigger it.
   - Should: check that the id exists in this school (and is not deleted) before clearing.
3. **Renaming a session detaches everything keyed by its name.**
   - Where: `fee_charge_from_per_year.sql:192-204`.
   - What happens:
     - Students, enrolment, fee structures and attendance all hold the session name, and nothing cascades the change.
     - After a rename the session shows 0 students (AY-43).
     - The Classes page then lets you remove the child's class (AY-44), and the session itself can be deleted with the child still in it (AY-45).
   - Should: cascade the name change, or refuse the rename once anything references the session.

**Medium**
4. **Overlapping sessions are accepted** (AY-18, AY-19), in both the proc and the UI.
5. **A school can end up with no current session in two other ways.**
   - Editing the current session with the switch off (AY-30, `fee_charge_from_per_year.sql:196`).
   - Deleting the current session (AY-54, delete branch 232-265; the trash button also shows on the current row at `AcademicYears.cshtml:88`).
6. **Editing an unknown or deleted id reports "saved".**
   - With "current" ticked it also clears the current flag (AY-36, AY-37).
   - `fee_charge_from_per_year.sql:176-204`: the UPDATE matches 0 rows and the proc still returns success.
7. **A deleted session's name can't be reused.**
   - What happens: the user sees a raw unique-constraint error (AY-48).
   - Why: `uq_academic_year` covers deleted rows, but the proc's duplicate check skips them.
8. **Renaming a saved class (no students) orphans name-keyed fee structures and drops its class teacher** (CS-79, `ClassSection.cshtml:500-502`).

**Low**
9. **Raw database messages shown to the user** (the controller passes `ex.MessageText` through):
   - blank or missing dates (AY-08/09; the UI doesn't require dates, `AcademicYears.cshtml:236-240`)
   - end = start (AY-11, `AcademicYears.cshtml:238` and proc :122 only test `<`)
   - a name over 20 characters (AY-05; no maxlength at `AcademicYears.cshtml:122`, no controller check)
10. **Delete with an unknown id reports "Academic year deleted."** (AY-52).
11. **Classes can be saved into a deleted session** (CS-42, `academic_class_section_fields.sql:143`).
12. **Capacity has no DB-level range check**; -5 is stored if the controller is bypassed (CS-22).
13. **`_ct_snap` temp table** makes the setup proc fail if it is called twice in one transaction (CS-40). This is latent.
14. **Charge-from guard counts only `core.students`.** The lock disappears for a past session whose students were promoted (AY-39p).
15. **UI gaps on the two pages:**
   - Year Save has no busy/double-click guard (AY-74).
   - Class/section saves are optimistic: no reload when the request fails (CS-81), and no in-flight guard (CS-82).
   - The controller returns no message when the proc returns no row (CS-83).
   - Rank 0 is accepted by the controller despite its "1-999" message, and silently replaced by the next rank in JS (CS-78).
   - The empty-session copy says "Try a different search" (CS-74).

Counts: 182 catalogue rows (86 AY, 96 CS; a few rows group sub-cases such as AY-60..64 and CS-65..68). 71 rows cite static code evidence, and 34 rows are marked BUG. The SQL suite has 162 checks: 139 pass and 23 fail.


---

## Fix status (2026-10-10)

All bugs above are fixed. Procedures are in `EduCoreDataAccessLayer/Database/academic_year_class_section_fixes.sql` (applied locally). Re-run: settings_years_classes_tests.sql **177/177**, settings_subjects_teachers_periods_tests.sql **121/121**.

| Bug | Fix |
|---|---|
| 1 Save detaches subjects/exams/timetable | Setup proc updates in place by originalName, then by name; only removed rows soft-deleted (CS-45/46/47, CS-79/80) |
| 2 Set current on unknown id | Existence check before clearing flags (AY-26/27) |
| 3 Session rename detaches students | Rename refused while `academic.fn_academic_year_name_usage` finds any use (AY-43..43d) |
| 4 Overlap | Proc refuses overlapping dates (AY-18/18b/19) |
| 5 No current session (untick / delete) | Proc refuses; UI disables the switch on the current session and hides its delete button |
| 6 Edit unknown id says saved | Existence check (AY-36/37) |
| 7 Deleted name not reusable | `uq_academic_year` replaced by partial `ux_academic_years_name` (AY-48) |
| 8 Class rename | Id kept, name carried into fee structures, teacher kept (CS-79..80c) |
| 9 Raw DB messages | Proc + controller + JS validate name length, dates required, end > start (AY-05b/08b/09b/11b) |
| 10 Delete unknown id | Refused (AY-52) |
| 11 Save into deleted session | Refused (CS-42) |
| 12 Capacity | Proc refuses outside 1..5000 (CS-22/22b) |
| 13 _ct_snap | Temp table removed (CS-40) |
| 14 Charge-from lock after promotion | Counts enrolment too (AY-39d/e) |
| 15 UI gaps | Year Save busy; class saves serialised + reload on failure; controller message on result 0; rank must be 1..999 (controller + JS); empty-session text |
