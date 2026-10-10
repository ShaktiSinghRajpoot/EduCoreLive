> **Fix status (2026-10-10):** every row marked BUG/FAIL below has been fixed and its SQL check now passes (see `EduCoreDataAccessLayer/Database/tests/settings_subjects_teachers_periods_tests.sql` and the change log in `docs/SCALING-AND-FIXES.md`). **Update (2026-10-10, weekday schedules):** a different (shorter) Saturday is now supported: a default schedule plus an optional custom schedule per weekday (PER-34, section E below).

# Test catalog: Subject Management, Assign Class Teacher, Period Structure

**SQL suite:** `EduCoreDataAccessLayer/Database/tests/settings_subjects_teachers_periods_tests.sql`
**Last run:** `RESULT: 108 passed, 12 failed`. All 12 failures are deliberate `BUG …` checks that document wrong app behaviour.
**Fixture:** tenant 24 / school 34 / user 39, session FY 26-27 (id 14). The other school used for isolation checks is tenant 23 / school 33.

**File abbreviations used below**
- **CTL** = `educore/Areas/ERP/Controllers/SchoolSettingsController.cs`
- **V-SM / V-ACT / V-PER** = `educore/Areas/ERP/Views/SchoolSettings/{SubjectManagement,AssignClassTeacher,PeriodStructure}.cshtml`
- **SVC-SUB / SVC-CT / SVC-SS** = `EduCoreDataAccessLayer/Services/Repository/ERP/{SubjectService,ClassTeacherService,SchoolSettingsService}.cs`
- **P-SUB** = `academic.sp_school_admin_subject_manage`, **P-CT** = `core.sp_class_teacher_manage` (10-arg overload), **P-PER** = `academic.sp_school_admin_period_structure_manage`, **P-TT** = `academic.sp_school_admin_timetable_manage`, **P-SETUP** = `academic.sp_school_admin_academic_setup_manage`. The live definitions were read with `pg_get_functiondef`. `subject_management.sql`, `class_teacher_session.sql` and `period_structure.sql` match the live procs.
- **HP** = `educore/Helpers/HasPermissionAttribute.cs`

## Real-world scenario

Sunrise Public School is setting up FY 26-27, in this order:

1. **Subjects.** The admin opens Subject Management, picks **Class 7** and adds English, Hindi, Mathematics, Science, Social Science and an optional Sanskrit.
   - A clerk types "  english " and "HINDI". These should reuse the existing master subjects.
   - Later Sanskrit is dropped for Class 7, but Class 6 keeps it.
   - The admin also prepares **next session's** classes from the session picker.
2. **Class teachers.** Vinod Singh becomes class teacher of **1-A**, and then of **1-B** as well, which should only raise a warning.
   - 1-B is then handed to Shivam.
   - Someone tries to assign an inactive staff member, a driver (non-teaching staff), and a staff id from another school.
   - Vinod should pass the attendance gate for 1-A only.
3. **Bell schedule.** Period Structure gets an 8-period day: Short Break 10:00-10:15, Lunch 11:35-12:05, Diary 14:05-14:15.
   - Bad entries are attempted: overlapping, backwards, midnight-crossing and duplicate periods.
   - The timetable is filled (Monday P1 Maths for 7-A).
   - The school then **adds a 07:40 morning assembly** and **drops P8**.
   - A **shorter Saturday** is wanted.
4. **Downstream.** Someone tidies Classes & Sections and saves without changing anything. Exams, the timetable and attendance must keep working.

## A. Subject Management (SUB)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SUB-01 | Page loads current session by default | GET /SubjectManagement | Picker on current session, class list for it | Controller | static: CTL:528-539, 544-557 | PASS |
| SUB-02 | Class list = active classes of session with counts | GetClasses | 11 classes, counts per class | Proc | SQL SUB-A1..A4 | PASS |
| SUB-03 | No classes in session | session with 0 classes | Helpful empty state ("add classes first") | UI-JS | static: V-SM:73-90 shows "0 classes" and blank list, no guidance | FAIL (minor UX) |
| SUB-04 | Session badge CURRENT / NOT CURRENT | switch picker | Badge reflects session; page reloads with ?academicYearId | UI-JS | static: V-SM:51-57, 490-494 | PASS |
| SUB-05 | Click class loads its subjects with loader | click "Nursurry" | Loader, pills rendered, suggestions | UI-JS | static: V-SM:354-390 | PASS |
| SUB-06 | **Click a numerically named class ("1".."8")** | click class "7" | Subjects load | UI-JS | static: V-SM:357 `$item.data('class')` - jQuery 3.7.1 `getData` turns "7" into the number 7. `getSuggestions(7)` then calls `className.toLowerCase()` (V-SM:189), which throws a TypeError inside `.done`. Pills never render, and the `.always` loader-hide registered after `.done` can be skipped | **BUG** |
| SUB-07 | Load failure | ClassSubjects 500 | Error toast, panel reset | UI-JS | static: V-SM:382-388 | PASS |
| SUB-08 | Cached reload of a class | click A, B, A | A served from cache | UI-JS | static: V-SM:360 | PASS |
| SUB-09 | Add via suggestion chip | click "Sanskrit" chip | Pill added, chip shows tick | UI-JS | static: V-SM:393-396, 307-325 | PASS |
| SUB-10 | Suggestions by class name | "Nursery", "6", "XI Science", "Commerce" | Relevant lists | UI-JS | static: V-SM:188-207 (Roman numerals like "VI" fall back to the default list) | PASS |
| SUB-11 | Add via button / Enter | type "Computer" + Enter | Pill added, input cleared | UI-JS | static: V-SM:399-409 | PASS |
| SUB-12 | Add blank | empty / spaces + Add | "Please enter a subject name." | UI-JS | static: V-SM:400-401 | PASS |
| SUB-13 | Duplicate in UI (case-insensitive) | add "english" when "English" exists | "already added" toast | UI-JS | static: V-SM:414-416 | PASS |
| SUB-14 | Max length 80 in UI | 81 chars | Input blocks at 80 | UI-JS | static: V-SM:133 `maxlength="80"` | PASS |
| SUB-15 | Remove pill | click x on "Hindi" | Pill removed, dirty badge | UI-JS | static: V-SM:424-430 | PASS |
| SUB-16 | Remove pill named "123" / "true" | subject "123" | Removed | UI-JS | static: V-SM:425 `.data('subject')` turns the value into a number or boolean, so `x !== s` never matches and the pill cannot be removed | **BUG** (low) |
| SUB-17 | **Subject name containing a quote** | save `x" onmouseover="alert(1)` | Shown as text | UI-JS | static: V-SM:282-284. `$('<div>').text().html()` does not escape `"`, so the name breaks out of `data-subject="…"` and becomes a live attribute. The proc stores the name verbatim (SQL SUB-A17), so this is stored XSS for every later viewer. Should use `EC.esc` | **BUG** |
| SUB-18 | Dirty badge | add / remove | "Unsaved changes" shown | UI-JS | static: V-SM:273-279 | PASS |
| SUB-19 | Switch class with unsaved edits | edit 7, click 6, back to 7 | Warn, or keep the dirty state | UI-JS | static: V-SM:331. `originalSnap` is reset to the unsaved cache, so the edits look saved and Discard cannot revert them. `mirrorToLocalStorage` (V-SM:471-478) also pushes unsaved lists into localStorage | **BUG** (low) |
| SUB-20 | Discard | edit, Discard | Back to snapshot | UI-JS | static: V-SM:433-438 (the toast uses the 'error' style) | PASS |
| SUB-21 | Save happy path | 6 subjects, Save | success toast, count badge | Proc+UI | SQL SUB-A5, A6; static V-SM:441-467 | PASS |
| SUB-22 | New names go into the master | Mathematics, Social Science new | 2 master rows added | Proc | SQL SUB-A7 | PASS |
| SUB-23 | Case / padding reuse the master row | "  english ", "HINDI" | No new master row, master spelling kept | Proc | SQL SUB-A8, A9 | PASS |
| SUB-24 | Idempotent re-save | save the same list twice | Still 6 mapping rows | Proc | SQL SUB-A10 | PASS |
| SUB-25 | Reorder | move Mathematics first | display_order follows the list | Proc | SQL SUB-A11 | PASS |
| SUB-26 | Remove optional subject | drop Sanskrit | Unmapped from Class 7; master and Class 6 keep it | Proc | SQL SUB-A12..A14 | PASS |
| SUB-27 | Blank / whitespace entries via API | `["Maths","","  ","English"]` | Skipped, count 2 | Proc+Service | SQL SUB-A15, A16; SVC-SUB:71-74 | PASS |
| SUB-28 | Special characters | `&`, Devanagari, apostrophe, `/`, quotes | Round-trip exactly | Proc | SQL SUB-A17 | PASS |
| SUB-29 | Duplicates inside one list via API | `Maths`, `maths`, ` MATHS ` | 1 mapping row, count 1 | Proc | SQL SUB-A18 PASS. SQL **SUB-A19 FAIL**: the proc reports count 3 because `v_ord` counts the loop, not the rows (proc line 109, 132) | **BUG** (low) |
| SUB-30 | Empty list clears the class | Save with no pills | Class has 0 subjects (no confirm) | Proc / UI | SQL SUB-A20, A21; static V-SM:441-453 has no confirm | PASS (no confirm is a UX risk) |
| SUB-31 | Over-long name via API | 81 chars | Friendly refusal | Proc / Service | SQL SUB-A22: refused, but with the raw "value too long for type character varying(80)" (SVC-SUB:97 passes it through) | PASS (raw message) |
| SUB-32 | Exactly 80 chars | 80 chars | Accepted | Proc | SQL SUB-A23 | PASS |
| SUB-33 | No class id | classId 0 / null | "Pick a class first." | Service+Proc | SVC-SUB:67-68; SQL SUB-A24 | PASS |
| SUB-34 | Deleted / non-existent class | deleted id, 999999 | Refused | Proc | SQL SUB-A25, A26 | PASS |
| SUB-35 | Unknown operation | 'Nope' | Refused | Proc | SQL SUB-A27 | PASS |
| SUB-36 | **Save on a non-current session** | session picker = next session, class "ZZ VI", Save | Subjects stored for that session and read back | Controller+Service+Proc | SQL SUB-A29 PASS (explicit year). **SUB-A30 / A31 FAIL**: V-SM:452 posts no academicYearId, the `ClassSubjectsDto` (CTL:569-573) has none, SVC-SUB:76-78 leaves `p_academic_year_id` NULL, and P-SUB:17 falls back to the current year. The rows land under the current session with a next-session class id, and the page reads back nothing | **BUG** (high) |
| SUB-37 | Save to an inactive (is_active=false) class | API | Refused (the list hides it) | Proc | static: P-SUB:82-87 checks only is_deleted | FAIL (low) |
| SUB-38 | Class search | type "kg" | Filters, shows "n of m" | UI-JS | static: V-SM:498-514 | PASS |
| SUB-39 | Search with no match | "zzz" | "No class matches" | UI-JS | static: V-SM:512 | PASS |
| SUB-40 | Pagination | - | N/A, no pagination on this page | UI-JS | static: V-SM | N/A |
| SUB-41 | Antiforgery on save | POST without token | 400 | Controller | static: CTL:576, V-SM:451 | PASS |
| SUB-42 | View-only role saves | role with academics.view only | 403, Save hidden | Controller / UI | static: CTL:577 gives 403. The Save button is still shown (V-SM:167) and the user gets "You do not have permission" from EC.ajaxError | PASS (button not hidden) |
| SUB-43 | Anonymous user | not logged in | Challenge / redirect | Controller | static: HP:36-39 (the class has no [Authorize], CTL:15 is commented out; HasPermission covers every action) | PASS |
| SUB-44 | SUPER_ADMIN (tenant 1) | platform login | Refused | Service+Proc | SVC-SUB:25, 65, 104; SQL SC-E1, E2 | PASS |
| SUB-45 | Cross-school read / write | other school uses our class id, or we use theirs | Nothing returned, writes refused | Proc | SQL SC-E8..E11 | PASS |
| SUB-46 | Timetable dropdown follows class subjects | after save | 7-A dropdown = Class 7 subjects | Proc (downstream) | SQL DS-D1 | PASS |
| SUB-47 | Exams require the mapping | after save | Exam proc accepts mapped subjects, refuses others | Proc (downstream) | SQL DS-D8; static exam proc line 361-367 | PASS |
| SUB-48 | Remove a subject still booked in the timetable | unmap Maths while 7-A has Maths periods | Refuse, or warn and clear the bookings | Proc (downstream) | SQL **DS-D7 FAIL**: 2 stale bookings stay, and the timetable modal no longer offers that subject | **BUG** (low) |
| SUB-49 | CreateExam / MarkEntry localStorage mirror | Save | localStorage key updated | UI-JS | static: V-SM:215, 471-478 (stale per-browser copy, see SUB-19) | PASS (fragile) |
| SUB-50 | Service errors are logged | proc RAISE | Warning logged with SqlState | Service | static: SVC-SUB:94-98 has no ILogger, so the error is swallowed with no log (breaks the CLAUDE.md convention) | FAIL (low) |
| SUB-51 | Internal whitespace | "Social  Science" vs "Social Science" | Same subject | Proc | static: P-SUB:93 only trims the ends, so these become two master subjects | FAIL (low) |

## B. Assign Class Teacher (ACT)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| ACT-01 | Page + session picker | GET /AssignClassTeacher | Current session selected | Controller | static: CTL:942-947 | PASS |
| ACT-02 | Grid = all live sections of the session | Grid | 14 sections | Proc | SQL ACT-B1, B2 | PASS |
| ACT-03 | Summary cards | load | Sections / Assigned / Unassigned / Conflicts | UI-JS | static: V-ACT:184-191 | PASS |
| ACT-04 | Pool lists active teachers | Teachers | Vinod listed | Proc | SQL ACT-B3 | PASS |
| ACT-05 | Pool hides inactive and other-school staff | - | Hidden | Proc | SQL ACT-B4, B5 | PASS |
| ACT-06 | **Pool should list teaching staff only** | Teachers | Non-Teaching / Support excluded | Proc | SQL **ACT-B6 FAIL**: 3 non-teaching staff are listed (P-CT 'Teachers', no staff_type filter). The ClassSection coordinator list does filter Teaching (CTL:625-626) | **BUG** (medium) |
| ACT-07 | Assign a teacher | select Vinod for 1-A | Saved, toast, updated_by stamped | Proc+UI | SQL ACT-B8..B10; static V-ACT:275-289 | PASS |
| ACT-08 | One teacher, two sections | Vinod to 1-B too | Allowed, load 2, warning row, Conflicts card +1 | Proc+UI | SQL ACT-B11..B13; static V-ACT:229, 243, 186 | PASS (warning only, by design) |
| ACT-09 | Idempotent re-assign | same teacher again | No change | Proc | SQL ACT-B14 | PASS |
| ACT-10 | Reassign | 1-B to Shivam | Vinod's load back to 1 | Proc | SQL ACT-B15 | PASS |
| ACT-11 | Clear | "— Unassigned —" (0) / null | NULL stored, "cleared" message | Proc+UI | SQL ACT-B22, B23; static V-ACT:269 | PASS |
| ACT-12 | Attendance gate | Vinod on 1-A | true; case and padding ignored | Proc (downstream) | SQL ACT-B16, B17; AttendanceController.cs:33-39 | PASS |
| ACT-13 | Gate denies others / after a change | other teacher, old teacher | false | Proc | SQL ACT-B18..B20, B24 | PASS |
| ACT-14 | Gate with no section | section NULL | false | Proc | SQL ACT-B21 | PASS |
| ACT-15 | Deleted / missing section | ids 155, 999999 | "Section not found." | Proc | SQL ACT-B25, B26 | PASS |
| ACT-16 | **Other school's staff id** | staffId = school 33's staff | Refused | Proc | SQL **ACT-B27 FAIL**: accepted. P-CT 'Assign' never checks staff scope, and `class_teacher_staff_id` has no FK. The grid then shows teacher_id with a NULL name | **BUG** (high: cross-tenant reference) |
| ACT-17 | **Non-existent staff id** | 999999 | Refused | Proc | SQL **ACT-B28 FAIL**: accepted | **BUG** (medium) |
| ACT-18 | **Inactive staff** | Kailash (inactive) | Refused | Proc | SQL **ACT-B29 FAIL**: accepted | **BUG** (medium) |
| ACT-19 | Section already assigned to staff who is now inactive | grid load | The dropdown shows the real teacher, or flags them | UI-JS | static: V-ACT:172 ignores `teacherName` from the grid. The select (V-ACT:197-200) has no option for a staff member outside the pool, so it shows "— Unassigned —" while the status says "Assigned" | **BUG** (low) |
| ACT-20 | Save fails | proc RAISE / 403 | Revert + error toast | UI-JS | static: V-ACT:286; 403 shows a generic "Something went wrong." (V-ACT:272) instead of EC.ajaxError | PASS (generic message) |
| ACT-21 | Auto-balance | click | Confirm first; uses teachers only | UI-JS | static: V-ACT:303-327. No confirm, and it fills every empty section from the pool, which includes non-teaching staff (ACT-06). It fires N parallel POSTs | **BUG** (medium, via ACT-06) |
| ACT-22 | Auto-balance with none empty / no teachers | - | Info / error toast | UI-JS | static: V-ACT:305-306 | PASS |
| ACT-23 | Unassigned-only toggle / card | click | Filters | UI-JS | static: V-ACT:293-302 | PASS |
| ACT-24 | Search class / section / teacher | "vinod" | Filters rows | UI-JS | static: V-ACT:218-221 | PASS |
| ACT-25 | Class filter | pick "5" | Only class 5 | UI-JS | static: V-ACT:154-160, 214 | PASS |
| ACT-26 | Empty session (no sections) | new session | "No sections, add them in Classes & Sections" | UI-JS | static: V-ACT:107-111 says "Try a different search or filter", which is misleading | FAIL (minor UX) |
| ACT-27 | Load failure | grid 500 | Toast, subtitle updated | UI-JS | static: V-ACT:180 shows the toast, but the subtitle stays "Loading…" | PASS (minor) |
| ACT-28 | XSS in names | staff / section names with `<` | Escaped | UI-JS | static: V-ACT:200, 238-249 use EC.esc | PASS |
| ACT-29 | Malformed / empty JSON body | POST `null` | 400 / friendly JSON | Controller | static: CTL:974 dereferences `dto.SectionId` without `?.`, so a null body throws a NullReferenceException (500) | **BUG** (low) |
| ACT-30 | Antiforgery | POST without token | 400 | Controller | static: CTL:970, V-ACT:129, 268 | PASS |
| ACT-31 | Permission | academics.view only | Grid OK, assign 403 | Controller | static: CTL:951, 960, 971 | PASS |
| ACT-32 | Platform scope | tenant 1 / school 0 | Refused | Service+Proc | SVC-CT:163, 191, 205; SQL SC-E5..E7 | PASS |
| ACT-33 | Cross-school section / session / gate | assign to their section, their session id, their gate | Refused / empty / false | Proc | SQL SC-E12..E15 | PASS |
| ACT-34 | Classes & Sections re-save keeps class teacher | unchanged structure saved | Teacher restored | Proc (downstream) | SQL DS-D10 | PASS |
| ACT-35 | Two classes with the same name (different stream) | grid | Separate groups | UI-JS | static: V-ACT:171 groups by className only, so they would merge | FAIL (low, depends on class-name uniqueness) |
| ACT-36 | Service error logging | RAISE | Logged | Service | static: SVC-CT:219-222 has no logger | FAIL (low) |

## C. Period Structure (PER)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| PER-01 | Page seeds the saved schedule | GET | JSON seed, cards, glance bar | Controller+UI | static: CTL:1065-1084, V-PER:156-163 | PASS |
| PER-02 | Empty school | no rows | Empty timeline, "0 periods" | Proc+UI | SQL PER-C1; static V-PER:233 (no "add your first period" prompt) | PASS |
| PER-03 | Save an 8-period day with break, lunch and diary | 11 slots unsorted, "LUNCH", padded label, no type | Stored in clock order, seq 1..11, trimmed, lower-case, default class | Proc | SQL PER-C2..C6 | PASS |
| PER-04 | Idempotent re-save | save twice | 11 rows | Proc | SQL PER-C7 | PASS |
| PER-05 | Empty schedule | Save with 0 | Refused ("stops the bell") | UI / Ctl / Proc | static V-PER:304, CTL:1174; SQL PER-C8, C9 | PASS |
| PER-06 | More than 60 periods | 61 items | Refused | Controller | static: CTL:1176-1177 (the proc has no cap) | PASS |
| PER-07 | Blank label | "   " | Refused | UI / Ctl / Proc | V-PER:279; CTL:1183; SQL PER-C10, C11 | PASS |
| PER-08 | Label > 50 | 51 chars | Refused | UI / Ctl / Proc | V-PER:129 maxlength; CTL:1185; SQL PER-C23 (the proc gives the raw "value too long") | PASS |
| PER-09 | Label exactly 50 | 50 chars | Accepted | Proc | SQL PER-C28 | PASS |
| PER-10 | Missing start / end | blank time | Refused | UI / Ctl / Proc | V-PER:280; CTL:1192-1195; SQL PER-C12, C13 | PASS |
| PER-11 | Backwards period | 08:40-08:00 | Refused | UI / Ctl / Proc | V-PER:281-284; CTL:1196; SQL PER-C14 | PASS |
| PER-12 | Zero length | 08:00-08:00 | Refused | Proc | SQL PER-C15 | PASS |
| PER-13 | Crosses midnight | 23:30-00:15 | Refused | Proc | SQL PER-C16 | PASS |
| PER-14 | Overlap | P1 08:00-08:45, P2 08:40 | Refused | UI / Ctl / Proc | V-PER:175-182; CTL:1217-1225; SQL PER-C17 | PASS |
| PER-15 | Overlap posted in reverse order | reversed array | Still refused | Ctl / Proc | CTL:1216 sorts first; SQL PER-C18 | PASS |
| PER-16 | Break nested inside a period | Lunch inside P5 | Refused | Proc | SQL PER-C19 | PASS |
| PER-17 | Back-to-back periods | P1 ends 08:40, P2 starts 08:40 | Accepted | Proc | SQL PER-C28 | PASS |
| PER-18 | Duplicate label | two "P1" | Refused | UI / Ctl / Proc | V-PER:285-286; CTL:1189; SQL PER-C20 | PASS |
| PER-19 | Duplicate by case / padding | "Break" vs " break " | Refused | Proc | SQL PER-C21 | PASS |
| PER-20 | Unknown type | "sports" | Refused | Ctl / Proc | CTL:1202; SQL PER-C22 | PASS |
| PER-21 | Impossible clock time | "25:00" | Refused | Ctl / Proc | CTL:1149-1159 `TryReadClockTime`; SQL PER-C24 (raw cast message at proc level) | PASS |
| PER-22 | Non-array payload | `{}` | Refused | Proc | SQL PER-C25 | PASS |
| PER-23 | Unknown operation | 'Nope' | Refused | Proc | SQL PER-C26 | PASS |
| PER-24 | Refused save is atomic | any refusal | Old schedule intact | Proc | SQL PER-C27 | PASS |
| PER-25 | Edit a period | P3 ends 09:55 | Stored | Proc+UI | SQL PER-C29; static V-PER:287-290 | PASS |
| PER-26 | Delete a period | remove Diary (confirm) | Deleted on Save | Proc+UI | SQL PER-C30, C31; static V-PER:251-259 (EC.confirm) | PASS |
| PER-27 | Add modal resets fields | Add | Blank form, type=class | UI-JS | static: V-PER:262-273 | PASS |
| PER-28 | Up / down reorder buttons | move P2 above P1 | Meaningful reorder | UI-JS | static: V-PER:245-250. The server re-sorts by start time (P-PER line 186-188, 233), so a move is never saved. Moving creates a fake "overlaps" warning that blocks Save (V-PER:303) | **BUG** (low) |
| PER-29 | Cards + glance bar + total | after edits | Correct counts, start / end, total duration | UI-JS | static: V-PER:184-202 | PASS |
| PER-30 | Legend covers every type | assembly / diary | Legend lists all 5 | UI-JS | static: V-PER:74-77 lists only Class / Break / Lunch (the CSS has all 5) | FAIL (cosmetic) |
| PER-31 | Leave with unsaved changes | edit, navigate away | Warn | UI-JS | static: no beforeunload in V-PER | FAIL (low) |
| PER-32 | Save button double-click | 2 clicks | One save / busy state | UI-JS | static: V-PER:302-319 has no EC.buttonBusy (harmless, because replace-all is idempotent) | PASS (minor) |
| PER-33 | XSS in label | `<b>` label | Escaped | UI-JS | static: V-PER:198, 213 EC.esc; the seed goes through System.Text.Json, which escapes `<` | PASS |
| PER-34 | **Shorter Saturday** | Saturday ends 12:30 | Per-day schedule | Proc / UI | Default schedule + optional custom schedule per weekday (`period_structure.day_of_week`, NULL = default). Page: day selector with Use default / Custom schedule / Copy from default | BUILT (section E; SQL WDS-B*) |
| PER-35 | Permission | academics.view only | Page OK, Save 403 | Controller | static: CTL:1064, 1163 | PASS |
| PER-36 | Antiforgery | no token | 400 | Controller | static: CTL:1162, V-PER:305-311 | PASS |
| PER-37 | Platform scope | tenant 1 / school 0 | Refused | Service+Proc | SVC-SS:479, 512; SQL SC-E3, E4 | PASS |
| PER-38 | Cross-school isolation | our saves | The other school's 5-row schedule untouched | Proc | SQL SC-E16, E17 | PASS |
| PER-39 | Smart Bell reads the same schedule | after save | Kiosk shows the new periods | Controller (downstream) | static: CTL:1110-1133 | PASS |
| PER-40 | Timetable books only class periods | book Short Break | Refused | Proc (downstream) | SQL DS-D3 | PASS |
| PER-41 | Teacher clash in the timetable | same teacher, same slot, 8-A | Refused | Proc (downstream) | SQL DS-D4 | PASS |
| PER-42 | **Add an assembly after the timetable is filled** | insert Assembly 07:40 before P1 | Monday Maths stays on P1 | Proc (downstream) | SQL **DS-D5 FAIL**: P-PER renumbers seq by clock order (line 233), but timetable rows are keyed by `period_seq`, so every booking shifts one period (Maths now sits on "Assembly"). The page gives no warning | **BUG** (high) |
| PER-43 | **Remove a period that has bookings** | drop P8 | Refuse / warn / clear bookings | Proc (downstream) | SQL **DS-D6 FAIL**: the booking is orphaned on a seq that is no longer a teaching period | **BUG** (high, same root cause) |

## D. Cross-page downstream (DS)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| DS-01 | **Re-save Classes & Sections unchanged** | Save on the ClassSection page | Subjects, timetable and class teacher survive | Proc (P-SETUP) | SQL DS-D9 (new ids), DS-D10 PASS (class teacher restored). **DS-D11 FAIL**: Class 6's 9 subjects vanish, because class_subjects is keyed on the old academic_class_id. **DS-D12 FAIL**: 7-A's timetable is left on the soft-deleted section id | **BUG** (high) |
| DS-02 | Exam setup after DS-01 | create exam for Class 6 | Subjects available | Proc | Follows from DS-D11: exam proc line 361-367 refuses "not a subject of 6" | **BUG** (via DS-01) |
| DS-03 | Attendance by class teacher after DS-01 | Vinod marks 7-A | Allowed | Proc | Follows from DS-D10: the gate matches on class and section names | PASS |

## E. Weekday schedules (WDS), built 2026-10-10

**SQL suite:** `EduCoreDataAccessLayer/Database/tests/weekday_schedules_tests.sql` (same fixture: tenant 24 / school 34 / user 39; other school 23 / 33). **Last run:** `RESULT: 97 passed, 0 failed`. Scripts: `period_structure.sql` (column `day_of_week`, `academic.fn_day_periods`, 7-argument P-PER with `GetAllSchedules` and `UseDefault`), `timetable.sql`, `school_calendar.sql`. Calendar-range checks (WDS-F*) are listed in `academics_attendance_exams.md` section J.

| ID | Scenario | Expected | How verified | Result |
|---|---|---|---|---|
| WDS-01 | Migration | The existing schedule is the default (day_of_week NULL); every weekday runs on it; re-running the script changes nothing; the old 6-argument positional call still saves the default | SQL WDS-A1..A6 | PASS |
| WDS-02 | Save a short Saturday | Stored as Saturday's own rows; GetPeriodStructure(6) returns them, (1) and (no day) return the default; GetAllSchedules returns default first, then each custom day | SQL WDS-B1..B7 | PASS |
| WDS-03 | Rules per schedule | Overlap, duplicate label (case/padding), unknown type, backwards, empty: refused, nothing changed | SQL WDS-B8..B13 | PASS |
| WDS-04 | Weekly off / bad day | A schedule for a weekly off (Sunday) or day 7 refused | SQL WDS-B14, B15 | PASS |
| WDS-05 | Edit the default | Saturday's own schedule untouched | SQL WDS-B16, B17 | PASS |
| WDS-06 | Use default | Needs a day; drops the day's rows; harmless on a day without its own | SQL WDS-B18..B22 | PASS |
| WDS-07 | **Lessons follow per day** | Saturday renumbered: Saturday lessons follow by label, Monday does not move; default renumbered: Monday follows, Saturday does not | SQL WDS-C1..C7 | PASS |
| WDS-08 | Booked period protection per day | Removing / un-teaching a booked Saturday period refused (message names the day); the default may drop a period only a custom day teaches; Saturday cannot go back to a default lacking its booked period | SQL WDS-C8..C13 | PASS |
| WDS-09 | Back to the default | Lessons move to the default's period of the same name; no lesson left on a missing period | SQL WDS-C14..C17 | PASS |
| WDS-10 | Book against the day's schedule | A slot only the default has, or Saturday's break, refused on Saturday; GetSetup lists each day's own periods; teacher clash per day | SQL WDS-D1..D8 | PASS |
| WDS-11 | Copy Day across schedules | Lessons go to the same label; a day without it skips and the message names it ("Sat P5, Sat P7"); short day copied to long days | SQL WDS-E1..E8 | PASS |
| WDS-12 | Isolation / scope | Other school's schedules, Use default, booking; platform scope refused | SQL WDS-G1..G5, G10, G11 | PASS |
| WDS-13 | Period Structure page | Day selector (Default + weekdays that are not weekly offs), Custom badge, Use default (confirm, immediate), Custom schedule (starts as a copy of the default), Copy from default, Save posts `day` | static: V-PER; inline JS checked with `new Function` | PASS (not browser-tested) |
| WDS-14 | Timetable page | Rows = every label any day has; a day without the period shows "—"; a day whose time differs shows it in the cell; stats count each day's own teaching periods | static: V-TT; inline JS checked | PASS (not browser-tested) |
| WDS-15 | Smart Bell | Rings by today's schedule (`GetPeriodStructure(today's weekday)`); half day still clamps it | static: CTL BuildBellStateAsync | PASS |

## Totals

- **Catalog:** 133 cases (SUB 51, ACT 36, PER 43, DS 3).
- **SQL suite:** 120 checks, 108 pass and 12 fail. All 12 failures are documented bugs.
