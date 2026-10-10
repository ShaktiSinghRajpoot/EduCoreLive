> **Fix status (2026-10-10, Phase 2):** every bug below is fixed except ATT-08 (the class-teacher gate ignores an inactive teacher; that proc, `core.sp_class_teacher_manage` in `class_teacher_session.sql`, belongs to the settings area). The approved business defaults are recorded in the BD table. The SQL suite now asserts the correct behaviour: `RESULT: 137 passed, 1 failed (1 of them BUG checks)`, and the one failure is ATT-B8. Scripts changed, in apply order: `school_calendar.sql`, `academics_edit_history.sql` (new), `student_attendance.sql`, `attendance_student.sql`, `attendance_report.sql`, `exam_marks.sql`, `exam_result_student.sql`, `exam_schedule.sql`, `timetable.sql`. Change log: `docs/SCALING-AND-FIXES.md`.

# Test catalog: Daily academics: attendance, exams, timetable, calendar, Smart Bell

**SQL suite:** `EduCoreDataAccessLayer/Database/tests/academics_attendance_exams_tests.sql`
**Last run (2026-10-10, before the fixes):** `RESULT: 85 passed, 35 failed (35 of them BUG checks)`. **After the fixes:** `RESULT: 137 passed, 1 failed` (ATT-B8, see the banner). The suite runs in one transaction and rolls back. No `ZZ` rows were left behind afterwards (checked: students, subjects, exams, calendar, periods, sections, timetable, attendance, weekly offs, back-date setting).
**Fixture:** tenant 24 / school 34 / user 39, session FY 26-27 (id 14). Classes 6 (421), 7 (422), 8 (423). The suite adds a 7-B section inside the transaction. Teachers: Vinod (staff 23 / user 45), Shivam (26 / 47), inactive teaching Shakti (32 / 51). The other school used for isolation checks is tenant 23 / school 33.
**Not repeated here** (already in `attendance_exam_tests.sql` / `settings_subjects_teachers_periods_tests.sql`): future date, plain Sunday, back-date lock, empty register, single-row re-save, marks range/negative, finalise lock + reopen, draft exam hidden from results, absent excluded from totals, break slot not bookable, same-teacher-same-slot clash, period edits vs timetable, subject unmapping clears bookings, IsTeacher across schools.

**File abbreviations used below**
- **CTL-ATT** = `educore/Areas/ERP/Controllers/AttendanceController.cs`, **CTL-EX** = `.../ExamController.cs`, **CTL-SS** = `.../SchoolSettingsController.cs`, **CTL-ST** = `.../StudentController.cs`
- **V-ATT / V-RPT** = `educore/Areas/ERP/Views/Attendance/{StudentAttendance,AttendanceReport}.cshtml`
- **V-STATT** = `educore/Areas/ERP/Views/Student/StudentAttendance.cshtml`
- **V-ME / V-CE** = `educore/Areas/ERP/Views/Exam/{MarkEntry,CreateExam}.cshtml`
- **V-TT / V-CAL / V-BELL / V-SM** = `educore/Areas/ERP/Views/SchoolSettings/{Timetable,SchoolCalendar,SmartBell,SubjectManagement}.cshtml`
- **SVC-ATT / SVC-EX / SVC-CAL / SVC-TT** = `EduCoreDataAccessLayer/Services/Repository/ERP/{Attendance,Exam,SchoolCalendar,Timetable}Service.cs`
- **P-SAVE** = `core.sp_attendance_save`, **P-ROST** = `core.sp_attendance_roster`, **P-STU** = `core.sp_attendance_student`, **P-REG** = `core.sp_attendance_month_register`, **P-CT** = `core.sp_class_teacher_manage` (10-arg), **P-EX** = `academic.sp_school_admin_exam_manage`, **P-MK** = `academic.sp_school_admin_exam_marks_manage`, **P-RES** = `core.sp_exam_result_student`, **P-TT** = `academic.sp_school_admin_timetable_manage`, **P-CAL** = `academic.sp_school_admin_calendar_manage`. Line numbers for procs are lines of `pg_get_functiondef` output; the live definitions were read with it.
- **Root cause R1:** `dates_as_text.sql` changed `school_calendar.calendar_date` and `exam_subjects.exam_date` to `varchar(10)`. `to_char(varchar, text)` does not exist, so every statement that still calls `to_char()` on those columns now fails at plan time. A full scan of the live procs finds exactly three such calls: P-CAL:25, P-EX:455 and P-EX:480.

## Real-world scenario

Sunrise Public School, FY 26-27:

1. **Calendar.**
   - The office declares a local-festival holiday, a PTM half day closing at 11:30, a Saturday weekly off, and a compensatory working Sunday.
   - The Smart Bell and the attendance register should agree on every one of these days.
2. **Attendance.**
   - Vinod is class teacher of 7-A. He marks four registers in August and later corrects a mistake: Bhavna was not absent on day 1.
   - Chhavi joins 7-A on day 3. Dev is moved from 7-A to 7-B after day 2. Eshan leaves the school (Transfer) on day 2.
   - Vinod also tries to mark a 7-B student, and an inactive teacher who is still on 7-B's record tries the gate.
3. **Exams.**
   - A Half Yearly runs for classes 6, 7 and 8. Maths is in all three classes, but class 6's paper is out of 80. Class 7 sits it in section A only.
   - The Maths sheet gets full marks, a half mark, a blank, an absentee with marks typed in, an over-max value, "abc", a student who left, a class-6 student, and a student from another school.
   - The sheet is finalised, reopened by the admin, and a mark is changed from 100 to 90.
   - Later a paper is removed from a datesheet after its marks were entered.
4. **Timetable.**
   - 7-A Monday P1 is Vinod in room ZZ-101. Shivam is then booked into ZZ-101 for 8-A in the same period.
   - Someone books a Sunday, a subject the class does not study, another school's subject or teacher, and an inactive teacher.
   - Monday is copied across the week while Vinod is busy on Tuesday P1.

## A. School calendar + Smart Bell (CAL / BELL)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| CAL-01 | **School Calendar page loads** | GET SchoolCalendarData → GetCalendar | Entries + weekly offs for the year | Proc | SQL CAL-A1. P-CAL:25 `to_char(calendar_date,…)` on varchar → `function to_char(character varying, unknown) does not exist` (R1). SVC-CAL:33 has no catch, so the action returns 500. V-CAL:42 only toasts "Could not load the calendar." The page shows no holidays and no weekly offs at all. Saving still works blind | FIXED (to_char ::date cast, hotfix_2026_10_10.sql + school_calendar.sql) |
| CAL-02 | Declare a holiday | SaveEntry holiday, "ZZ Local Festival" | Saved | Proc | SQL CAL-A2 | PASS |
| CAL-03 | Bell sees the holiday | GetDayStatus(holiday) | day_type holiday, is_working false, title | Proc | SQL CAL-A3 | PASS |
| CAL-04 | Half day without closing time | half_day, no time | Refused | Proc | SQL CAL-A4 | PASS |
| CAL-05 | Half day closing 11:30 | half_day 11:30 | Working day, half_day_end 11:30 | Proc | SQL CAL-A5 | PASS |
| CAL-06 | Unknown day type | "vacation" | Refused | Proc | SQL CAL-A6 | PASS |
| CAL-07 | Re-save the same date | half day → holiday with blank title | One row; title "Holiday"; closing time dropped | Proc | SQL CAL-A7, A8 | PASS |
| CAL-08 | Saturday weekly off | SaveWeeklyOff "0,6" | Saturday reads weekly_off | Proc | SQL CAL-A9 | PASS |
| CAL-09 | Compensatory working Sunday | SaveEntry working on Sunday | Sunday reads working | Proc | SQL CAL-A10 | PASS |
| CAL-10 | Half-day closing time vs bell schedule | half day ending 07:00 (before P1) or 23:00 | Warn or refuse when it is outside school hours | Proc | static: P-CAL:112-114 only checks that it is not NULL | FIXED (closing time must fall inside the period structure; SQL CAL-G0, G0b) |
| CAL-11 | Delete another school's entry by id | DeleteEntry id from tenant 23 scope | Not deleted | Proc | SQL ISO-H5 | PASS |
| CAL-12 | Delete reports what it did | DeleteEntry with an id that matches nothing | "not found" | Proc | static: P-CAL:134-140 always returns "Entry removed." | FIXED ("That calendar entry was not found."; SQL ISO-H5) |
| CAL-13 | Holiday ranges (Diwali week) | 5 consecutive days | One action | UI/Proc | P-CAL `SaveRange` / `DeleteRange`; V-CAL "Date range" dialog | BUILT (section J; SQL WDS-F*) |
| BELL-01 | Day status defaults to today on the school's clock | GetDayStatus(NULL) | today (Asia/Kolkata) | Proc | SQL BELL-A11 | PASS |
| BELL-02 | Half day clamps the periods | half_day_end 11:30 | Periods starting ≥ 11:30 dropped; a spanning period ends at 11:30 | UI-JS | static: V-BELL:155-168 `buildPeriods` | PASS |
| BELL-03 | Holiday / weekly off is silent | holiday | "School holiday" card, no ring | UI-JS | static: V-BELL tick() 305-312 | PASS |
| BELL-04 | Re-sync picks up a newly declared holiday | declare holiday while kiosk open | Re-sync every 5 min, at midnight, and when the tab wakes | UI-JS | static: V-BELL:126-131, sync() | PASS |
| BELL-05 | Half day announcement | half day end boundary | "Today is a half day…" | UI-JS | static: V-BELL announceEn/Hi | PASS |
| BELL-06 | Bell and register agree | holiday / weekly off / working Sunday | The bell is silent on days attendance refuses, and rings on days attendance accepts | Cross | SQL ATT-B1..B3 show the register ignores the calendar | FIXED (register follows the calendar; SQL ATT-B1..B3) |

## B. Attendance: calendar, gate, statuses (ATT)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| ATT-01 | **Register on a declared holiday** | save on the festival day | Refused, like the bell | Proc | SQL ATT-B1. P-SAVE never reads `academic.school_calendar`; it only blocks Sunday | FIXED (SQL ATT-B1) |
| ATT-02 | **Register on a configured weekly off (Saturday)** | weekly off 0,6; save on Saturday | Refused | Proc | SQL ATT-B2. P-SAVE:20-22 hard-codes `DOW = 0` and ignores `school_calendar_settings` | FIXED (SQL ATT-B2) |
| ATT-03 | **Register on a declared working Sunday** | working entry on Sunday; save | Accepted | Proc | SQL ATT-B3: "Attendance is not marked on Sundays." A school with a Friday weekly off cannot mark Sundays at all | FIXED (SQL ATT-B3) |
| ATT-04 | Half day | save on the PTM day | Accepted, counted as a school day | Proc | SQL ATT-B4 | PASS |
| ATT-05 | Class teacher passes the gate | Vinod, 7-A | true | Proc | SQL ATT-B5 | PASS |
| ATT-06 | Class teacher of 7-A, other section | Vinod, 7-B | false | Proc | SQL ATT-B6 | PASS |
| ATT-07 | Non-class-teacher | Shivam, 7-A | false; Save returns "only for your assigned class-section" | Proc+CTL | SQL ATT-B7; static CTL-ATT:96-97 | PASS |
| ATT-08 | **Inactive (left) teacher still recorded as class teacher** | staff is_active = false | Gate false | Proc | SQL ATT-B8. P-CT IsTeacher joins `core.staff` but never checks `is_active`/`is_deleted` (nor `c.is_deleted`) | BUG (Low), NOT FIXED: gate lives in core.sp_class_teacher_manage (class_teacher_session.sql), outside this area (SQL BUG ATT-B8) |
| ATT-09 | **7-A teacher posts a 7-B student id** | POST Save {class:"7", section:"A", items:[7-B student]} | Refused | CTL+Proc | SQL ATT-B9 (saved 1). CTL-ATT:96 gates on the request's class/section text only. P-SAVE has no class/section parameter and accepts any student of the school (P-SAVE:39-53). A class teacher, or anyone holding attendance.manage, can rewrite any section's register | FIXED (class-section passed to the proc and checked against the register; SQL ATT-B9, ISO-H4) |
| ATT-10 | Admin marks any section | school admin | Allowed | CTL | static: CTL-ATT:33-39 | PASS |
| ATT-11 | **Unknown status** | status "present" (lowercase) / "Holiday" | Refused | Proc | SQL ATT-B10: success, saved=0. P-SAVE:51 silently filters, and "Attendance saved for 0 student(s)" is shown as a success | FIXED (refused; SQL ATT-B10) |
| ATT-12 | Late | status Late | Stored as Late, counts present | Proc | SQL ATT-B11; P-STU/P-REG map Late → P | PASS |
| ATT-13 | Row snapshots class-section of the day | save 8-A student | class_name/section on row = 8-A | Proc | SQL ATT-B12 | PASS |
| ATT-14 | Page cannot show Leave / Late | a day with a Leave mark | Shown as Leave, kept on re-save | UI-JS | static: V-ATT:245 maps every non-"absent" status to present, and V-ATT:287 re-posts it as Present. Opening and re-saving a day silently turns Leave/Late into Present | FIXED (Late/Leave shown as a tag and re-posted as stored) |
| ATT-15 | Unmarked day looks marked | open a past day nobody marked | Clear "not marked yet" state | CTL+UI | static: CTL-ATT:81 sends "present" for unmarked rows; V-ATT shows all-green. The "Not confirmed" hint (V-ATT:159-166) is the only cue | FIXED ("not marked yet" hint; roster sends status "" + marked flag) |
| ATT-16 | Student name escaped | name with `<img onerror>` | Escaped | UI-JS | static: V-ATT:209 concatenates `s.name` raw (stored XSS). FRONTEND-CONVENTIONS requires `EC.esc` | FIXED (EC.esc on name, initials, parent, phone) |
| ATT-17 | Date picker on the school clock | 00:00-05:30 IST | Today = IST today | UI-JS | static: V-ATT:169 `toISOString()` is UTC, so before 05:30 the default date and `max` are yesterday | FIXED (date from the server, ViewBag.Today) |
| ATT-18 | Roster load failure | Roster 500 | Error row in the list | UI-JS | static: V-ATT:250 only toasts and leaves the previous class's list on screen (FRONTEND-CONVENTIONS "EC.listEmpty on every path") | FIXED (EC.listEmpty on empty and failed loads) |
| ATT-19 | **Orphan mock page** | GET /ERP/Student/StudentAttendance | Not reachable, or wired | UI | static: CTL-ST:52-55 serves V-STATT, which has 12 hard-coded fake students (V-STATT:131-144). Save only toasts "Attendance saved" with a `// TODO: POST` (V-STATT:253-254); nothing is stored. It is not in the menu but answers to anyone with students.view | FIXED (mock page, action and stylesheet removed) |

## C. Attendance over a month: joiner, mover, leaver, edits (ATT)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| ATT-20 | Not-yet-admitted student on day 1 | Chhavi admitted day 3, posted on day 1 | Skipped | Proc | SQL ATT-C1 | PASS (now refused with the student named; SQL ATT-C0) |
| ATT-21 | Day-1 roster excludes her | roster day 1 | Not listed | Proc | SQL ATT-C2 | PASS |
| ATT-22 | **Student who has left, marked after leaving** | Eshan left day 2; mark day 3 | Refused / skipped | Proc | SQL ATT-C3 (saved 1). P-SAVE joins `core.students` without `is_active` or `date_of_leaving` | FIXED (SQL ATT-C3) |
| ATT-23 | **Back-dated roster for a day the leaver was still here** | roster for day 1 after the exit | Lists him so the day can be corrected | Proc | SQL ATT-C4. P-ROST filters `is_active = TRUE` (today's state), not his enrolment on that date | FIXED (SQL ATT-C4, C4b, C4c) |
| ATT-24 | Joiner present on both her days | P-STU | present 2 | Proc | SQL ATT-C5 | PASS |
| ATT-25 | **Joiner's school days count from admission** | P-STU | 2 days, 100% | Proc | SQL ATT-C6, C7: 4 days, 50%. P-STU "held" counts every register of the class in the session, including days before admission. The same applies to V-RPT:61 (`p/schoolDays`) | FIXED (SQL ATT-C6, C7, C10b) |
| ATT-26 | **Section changer's %** | Dev: 2 days in 7-A + 1 in 7-B, present all | ≤ 100% (3/3) | Proc | SQL ATT-C8: 150%. P-STU counts "held" for the current section only, but counts his own rows from both sections | FIXED (SQL ATT-C8) |
| ATT-27 | 7-A month register | P-REG August | 4 school days, Bhavna 4 marks | Proc | SQL ATT-C9, C10 | PASS |
| ATT-28 | **Month register keeps a student who left during it** | P-REG August after Eshan's exit | Eshan listed with his 2 days | Proc | SQL ATT-C11. P-REG roster = current active students. A past month's printed register loses rows retroactively, and the class average changes | FIXED (SQL ATT-C11) |
| ATT-29 | 7-B register days | P-REG 7-B August | 1 day | Proc | SQL ATT-C12 | PASS |
| ATT-30 | **7-B register shows only 7-B marks** | Dev in 7-B register | 1 mark (day 3) | Proc | SQL ATT-C13: 3 marks, so 300% against 1 school day. P-REG filters marks by the student's current class, not `a.class_name/section` | FIXED (SQL ATT-C13, C13b) |
| ATT-31 | Correction keeps one row | Absent → Present by Vinod | 1 row | Proc | SQL ATT-C14 | PASS |
| ATT-32 | Who marked / who corrected | after correction | marked_by 39, updated_by 45 | Proc | SQL ATT-C15 | PASS |
| ATT-33 | **What it was before (audit)** | after correction | Old status "Absent" retained with who/when | Proc/DB | SQL ATT-C16: no history table. A second edit also overwrites the first editor | FIXED (core.student_attendance_history; SQL ATT-C16) |
| ATT-34 | **Unchanged mark re-stamped** | page re-posts whole roster; Shivam saves | updated_by unchanged for untouched rows | Proc | SQL ATT-C17: updated_by=47 on an unchanged row. P-SAVE ON CONFLICT updates unconditionally, and V-ATT:286-288 always posts the whole roster, so "changed by" means "last pressed Save" | FIXED (unchanged rows are not rewritten; SQL ATT-C17, C17b) |
| ATT-35 | Totals after correction | Bhavna | 3 P, 0 A, 1 L of 4 = 75% | Proc | SQL ATT-C18 | PASS |
| ATT-36 | Month-picker figures agree with summary | P-STU p_months | Same denominator as summary | Proc | static: P-STU months cursor uses the student's own row count as `school_days`, while the summary uses class registers. A partially marked day shows 100% in the month list | FIXED (month list uses the same denominator as the summary) |
| ATT-37 | Report holidays | Report month with a calendar holiday | Holiday column shaded | UI-JS | static: V-RPT:163, 239 shade Sundays only, and ignore the calendar and weekly offs | FIXED (proc returns calendar days off; report shades them) |
| ATT-38 | Report CSV | name starting "=" | Neutralised | UI-JS | static: V-RPT:311 writes names raw (CSV formula injection) | FIXED (formula-looking cells prefixed with a quote) |

## D. Exam create / schedule (EXM)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| EXM-01 | **Create any exam** | SaveExam, one class, one paper | "Exam saved as draft." | Proc | SQL EXM-D1: `function to_char(character varying, unknown) does not exist` at P-EX:455 (R1). The clash query is planned on every save, so **no exam can be created or edited**. SVC-EX:193-197 shows the raw Postgres text as the page message | FIXED (SQL EXM-D1, E20) |
| EXM-02 | Blank name | "   " | Refused | Proc | SQL EXM-D2 | PASS |
| EXM-03 | End before start | | Refused | Proc | SQL EXM-D3 | PASS |
| EXM-04 | No class | items [] | Refused | Proc | SQL EXM-D4 | PASS |
| EXM-05 | Subject the class does not study | ZZ Art for class 7 | Refused ("Check Subject Management") | Proc | SQL EXM-D5 | PASS |
| EXM-06 | Another school's subject | tenant-23 subject id | Refused | Proc | SQL EXM-D6 | PASS |
| EXM-07 | Another school's class | tenant-23 class id | Refused | Proc | SQL EXM-D7 | PASS |
| EXM-08 | Pass > max | 60/50 | Refused | Proc | SQL EXM-D8 | PASS |
| EXM-09 | Max 0 | 0 | Refused | Proc | SQL EXM-D9 | PASS |
| EXM-10 | Paper outside exam dates | +9 days | Refused | Proc | SQL EXM-D10 | PASS |
| EXM-11 | Finish before start | 11:00-10:00 | Refused | Proc | SQL EXM-D11 | PASS |
| EXM-12 | Class with no papers | subjects [] | Refused | Proc | SQL EXM-D12 | PASS |
| EXM-13 | **Two papers same class same time** | Maths 09-11, Science 10-12 same day | Friendly clash message | Proc | SQL EXM-D13: the R1 crash instead. P-EX:480 (clash against other exams) has the same defect | FIXED (SQL EXM-D13) |
| EXM-14 | 7-A and 7-B papers in one slot | exam X 7-A only, exam Z 7-B only | Not a clash | Proc | SQL EXM-D14 | PASS |
| EXM-15 | Whole-class paper overlapping 7-A's | exam W whole class 7 | Datesheet flags clash | Proc | SQL EXM-D15 | PASS |
| EXM-16 | Duplicate name (any case) | "zz half yearly" | Refused | Proc | SQL EXM-D16 | PASS |
| EXM-17 | Unknown status | "Closed" | Refused | Proc | SQL EXM-D17 | PASS |
| EXM-18 | Publish with no papers | | Refused | Proc | SQL EXM-D18 | PASS |
| EXM-19 | Multi-class exam (6, 7, 8) | items for 3 classes | One exam, 3 datesheets | Proc | static: P-EX:327-435 loops classes; can only be exercised after EXM-01 is fixed (fixture inserted rows the way the proc stores them) | PASS (SaveExam works again; SQL EXM-E20 edits a 3-class exam) |
| EXM-20 | **Removing a paper that already has marks** | edit exam, untick Science | Refuse, or warn and archive the marks | Proc | static: P-EX:407-410 deletes `exam_subjects` with no check on `exam_marks`. The marks stay orphaned and then inflate results (EXM-36) | FIXED (refused; SQL EXM-E18) |
| EXM-21 | **Lowering max marks below entered marks** | max 100 → 50 with a 90 on the sheet | Refused | Proc | static: P-EX:391-397 updates max_marks unconditionally. Results can then exceed 100% | FIXED (refused; SQL EXM-E19) |
| EXM-22 | Paper on a holiday / Sunday | examDate = declared holiday | Warn | Proc | static: P-EX never reads the calendar | FIXED (papers on holidays / weekly offs refused; SQL EXM-D19, D20) |
| EXM-23 | Subjects come from Subject Management, not localStorage | open CreateExam / MarkEntry | Server lists | UI | static: V-CE:239 uses Exam/Subjects (CTL-EX:89-94 → SubjectService); V-ME:206-210 is all server endpoints. The gap is closed. V-SM:215, 476-485 still mirrors subjects into localStorage for these pages: dead code with a stale comment, and unguarded `localStorage` (throws in a blocked-storage browser after a successful save) | PASS (gap closed); dead localStorage mirror REMOVED |
| EXM-24 | Section chooser lists real sections | ClassSections | Sections with students | Proc | static: P-EX:114-130 | PASS |

## E. Marks entry (EXM)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| EXM-25 | Sheet sections follow the exam | class 7 targets A | Only "A" offered | Proc | SQL EXM-E1 | PASS |
| EXM-26 | Over max by a fraction | 100.01 / 100 | Refused | Proc | SQL EXM-E2 | PASS |
| EXM-27 | Non-numeric | "abc" | Refused | Proc | SQL EXM-E3 (raw "invalid input syntax for type numeric" reaches the page via SVC-EX catch) | PASS (message raw) |
| EXM-28 | Student who left | Eshan (enrolment Left) | Refused | Proc | SQL EXM-E4 | PASS |
| EXM-29 | Other class's student | class-6 student on 7-A sheet | Refused | Proc | SQL EXM-E5 | PASS |
| EXM-30 | Other school's student | | Refused | Proc | SQL EXM-E6 | PASS |
| EXM-31 | Student moved to 7-B | Dev on 7-A sheet / on 7-B sheet | Refused on 7-A, listed on 7-B | Proc | SQL EXM-E7a, E16 (sp_student_update moves the enrolment row) | PASS |
| EXM-32 | Full marks, half mark, blank | 100, 33.5, "" | Stored 100.00, 33.50, NULL | Proc | SQL EXM-E7..E9 (numeric(6,2): 33.555 would silently round to 33.56) | PASS |
| EXM-33 | Absent with marks typed | absent + 60 | Absent, marks NULL | Proc | SQL EXM-E10 | PASS |
| EXM-34 | **Finalise turns blanks into Absent** | blank draft row, then Finalize | Blank → Absent, as the dialog promises (V-ME:187) | Proc | SQL EXM-E11: stays NULL and not absent. P-MK:226-236 only adds students with no row at all. V-ME:567-569 re-sends a cleared mark as a NULL row, so this happens through the UI. P-RES then counts that paper's max with 0 obtained | FIXED (SQL EXM-E11, E14b) |
| EXM-35 | Reopen records who | admin reopens | reopened_by = admin | Proc | SQL EXM-E12; CTL-EX:395 admin-only | PASS |
| EXM-36 | Who entered / who changed a mark | 100 → 90 by Vinod | created_by 39, updated_by 45 | Proc | SQL EXM-E13 | PASS |
| EXM-37 | **What the mark was before (audit)** | 100 → 90 | Old value retained | Proc/DB | SQL EXM-E14: no history. `finalized_by`/`reopened_by` also keep only the latest | FIXED (academic.exam_marks_history; SQL EXM-E14, E14c) |
| EXM-38 | **Marks for a section the exam does not cover** | exam = 7-A only; POST 7-B sheet | Refused | Proc | SQL EXM-E15 (saved 1). P-MK checks that the class is on the exam (P-MK:45-49) but not `exam_class_sections` | FIXED (SQL EXM-E15) |
| EXM-39 | **Marks against a Draft exam** | POST SaveMarks for a Draft exam | Refused | Proc | SQL EXM-E17 (saved 1). Only the page hides drafts (CTL-EX:282); P-MK never reads `exams.status` | FIXED (SQL EXM-E17) |
| EXM-40 | Re-entry after the exam is Published | edit marks of a Published exam, sheet not finalised | Business rule | Proc | static: allowed, because "Published" means the datesheet is published. Only finalising a sheet locks it | BY DESIGN: marks stay editable until the RESULTS are published, then locked (RES-15) |
| EXM-41 | Teacher without exams.manage | sheet read-only | Inputs locked | UI+CTL | static: V-ME:432-434; CTL-EX:373 | PASS |
| EXM-42 | Any teacher with exams.manage can enter any class's marks | subject teacher of 6 edits 8 | Restrict to the teacher's classes/subjects | CTL | static: no subject-teacher check anywhere in CTL-EX/P-MK | BY DESIGN (BD-08: stays exams.manage) |

## F. Results (EXM)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| EXM-43 | **Multi-class exam: each paper once** | Aarav (7): Maths 90/100 + Science 50/100 | 2 subjects, 140/200, 70% | Proc | SQL EXM-F1..F3: 4 subjects, total 380, 84.2%. P-RES:72-73 and 97-98 join `exam_subjects` on (exam, subject) **without `academic_class_id`**, so Maths matches the class 6, 7 and 8 rows. Every multi-class exam with a shared subject shows wrong totals on the student dashboard | FIXED (SQL EXM-F1..F3) |
| EXM-44 | **Different max per class** | Gita (6): 60/80 | 75% | Proc | SQL EXM-F4: 3 subjects, 180/280, 64.3% (same join) | FIXED (SQL EXM-F4) |
| EXM-45 | Baseline before a paper is removed | Bhavna 30 + 40 of 200 | 35% | Proc | SQL EXM-F5 | PASS |
| EXM-46 | **Marks of a removed paper** | Science dropped from datesheet | 30/100 = 30% | Proc | SQL EXM-F6: 70/100 = 70%. P-RES LEFT JOINs the missing paper: obtained still counts and max is NULL. Results can exceed 100% | FIXED (SQL EXM-F6) |
| EXM-47 | Exam back to Draft | SetStatus Draft | Hidden from results | Proc | SQL EXM-F7 | PASS |
| EXM-48 | Grade per subject / overall | | Grade from a grading scale | — | static: no grading table, column or proc anywhere. The only "Grade/Class Rank" is mock JS in `Views/Admission/Dashboard.cshtml:152, 272, 323` (`rank:rand(1,40)`) | BUILT (RES-01..06, RES-16, RES-20) |
| EXM-49 | Class rank | | Rank within section/class | — | static: not implemented | BUILT (RES-17..19) |
| EXM-50 | Class-wise result sheet / report card | | Printable result | — | static: only the per-student dashboard (CTL-ST DashboardData → P-RES) exists | BUILT: Exam/ResultSheet, printable + CSV (RES-21, RES-29, RES-30) |
| EXM-51 | Partial results visible | Published exam, sheets still draft | Results visible only when final | Proc | static: P-RES:25 filters `status='Published'` (datesheet) only, so draft marks show on the dashboard | FIXED: results show only once published, which needs every sheet finalised (RES-09, RES-11) |

## G. Timetable (TT)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| TT-01 | **Another school's subject** | SaveCell subject id of tenant 23 | Refused | Proc | SQL TT-G1. P-TT:165-208 never checks subject scope; the FK only checks existence | FIXED (SQL TT-G1) |
| TT-02 | **Subject the class does not study** | ZZ Art for 7-A | Refused | Proc | SQL TT-G2. The dropdown filters it (P-TT:129-136), but the POST is not checked | FIXED (SQL TT-G2) |
| TT-03 | **Another school's teacher** | staff id of tenant 23 | Refused | Proc | SQL TT-G3 (no FK on staff_id) | FIXED (SQL TT-G3) |
| TT-04 | **Inactive teacher** | staff 32 | Refused | Proc | SQL TT-G4 | FIXED (SQL TT-G4) |
| TT-05 | **Teacher picker = teaching staff** | GetSetup teachers | Teaching only | Proc | SQL TT-G5: 3 non-teaching staff listed. P-TT:59-64 has no staff_type filter, unlike the class-teacher pool | FIXED (SQL TT-G5) |
| TT-06 | **Lesson on the weekly off** | day 0 (Sunday) | Refused | Proc | SQL TT-G6. The grid has no Sunday column, but the POST is accepted | FIXED (SQL TT-G6) |
| TT-07 | Day 7 | | Refused | DB | SQL TT-G7 (`chk_timetable_dow`, raw message) | PASS |
| TT-08 | Book Monday P1 | 7-A Vinod ZZ-101 | Saved | Proc | SQL TT-G8 | PASS |
| TT-09 | Re-save same slot | | Not a self-clash | Proc | SQL TT-G9 | PASS |
| TT-10 | **Room double-booking** | 8-A Shivam, ZZ-101, same slot | Refused | Proc | SQL TT-G10. The room clash exists only in the page (V-TT:179-192, 404-415 "courtesy"); P-TT gates the teacher only | FIXED (SQL TT-G10) |
| TT-11 | Same teacher, different day | Vinod 8-A Tue P1 | Saved | Proc | SQL TT-G11 | PASS |
| TT-12 | Copy Day | copy Monday (2 lessons) | 9 copied, 1 skipped (teacher busy) | Proc | SQL TT-G12 | PASS |
| TT-13 | Copy Day skips weekly off | | No Sunday rows | Proc | SQL TT-G13 | PASS |
| TT-14 | Copy Day does not double-book | Vinod Tue P1 | Still one booking | Proc | SQL TT-G14 | PASS |
| TT-15 | Copy Day room clashes | copied lesson's room busy elsewhere | Skipped like a teacher clash | Proc | static: P-TT:272-283 checks the teacher only | FIXED (Copy Day skips a busy room too) |
| TT-16 | Teacher view | Vinod | Both sections | Proc | SQL TT-G15; P-TT GetTeacherGrid | PASS |
| TT-17 | Half-day effect on timetable | PTM half day | Lessons after 11:30 shown as not held | UI | static: only the bell clamps (V-BELL:155-168); timetable and attendance are unaware | BY DESIGN (BD-10: a half day affects the bell only) |
| TT-18 | Escaping | subject/teacher/room with HTML | Escaped | UI-JS | static: V-TT:324-358 use EC.esc | PASS |

## H. Scope and isolation (ISO)

| ID | Scenario | Expected | How verified | Result |
|---|---|---|---|---|
| ISO-01 | Other school reads our student's attendance | Nothing | SQL ISO-H1 | PASS |
| ISO-02 | Other school's register lists our student | No | SQL ISO-H2 | PASS |
| ISO-03 | Other school marks our student | 0 saved | SQL ISO-H3 | PASS |
| ISO-04 | We mark their student | 0 saved | SQL ISO-H4 | PASS |
| ISO-05 | They delete our holiday by id | Kept | SQL ISO-H5 | PASS |
| ISO-06 | Our holiday affects them | No | SQL ISO-H6 | PASS |
| ISO-07 | Read their exam | Nothing | SQL ISO-H7 | PASS |
| ISO-08 | Change their exam status | Not found | SQL ISO-H8 | PASS |
| ISO-09 | Delete their exam | Not found | SQL ISO-H9 | PASS |
| ISO-10 | Edit their exam via SaveExam | Not found | SQL ISO-H10, H11 | PASS |
| ISO-11 | They enter marks on our exam | Not found | SQL ISO-H12 | PASS |
| ISO-12 | They reopen our sheet | Not found | SQL ISO-H13 | PASS |
| ISO-13 | They read our student's results | Nothing | SQL ISO-H14 | PASS |
| ISO-14 | **Exam list given their session id** | No name leak | SQL ISO-H15: returns their session name "2027-2028". P-EX:72-74 (and 110-112, 224-226) read `academic_years` by id with no tenant filter. Exams themselves do not leak | FIXED (SQL ISO-H15) |
| ISO-15 | They clear/copy on our section | Our grid unchanged | SQL ISO-H16 | PASS |
| ISO-16 | They read our grid | Nothing | SQL ISO-H17 | PASS |
| ISO-17 | They book our section | Refused | SQL ISO-H18 | PASS |
| ISO-18 | Platform scope (tenant 1 / school 0) on attendance, calendar, marks | Refused | SQL ISO-H19..H21 | PASS |
| ISO-19 | Permissions | attendance.view/manage, exams.view/manage, academics.view/manage, RequiresModule(Exams), ValidateAntiForgeryToken on every POST | static: CTL-ATT:12, 87-88; CTL-EX:12-13, 157-158, 166-167, 206-207, 373-374, 389-390; CTL-SS:1121-1148, 1257-1260, 1358-1389 | PASS |
| ISO-20 | Error logging convention | Services that catch log first | static: SVC-ATT, SVC-EX, SVC-CAL, SVC-TT catch `PostgresException` without an `ILogger` (CLAUDE.md "Error logging convention") | FIXED (ILogger + Warning in all four services) |

## I. Results: grade scale, publish step, grades, rank, result sheet (RES)

Added 2026-10-10 with the results feature (BD-02, BD-03). **SQL suite:** `EduCoreDataAccessLayer/Database/tests/exam_results_publish_tests.sql` (own fixture: class 8, sections A/B, six ZZ RS students, one exam with Maths /100 and Science /50). **Last run:** `RESULT: 81 passed, 0 failed`. Procs: `exam_results_publish.sql` (**P-GS** = `academic.sp_school_admin_grade_scale_manage`, **P-RP** = `academic.sp_school_admin_exam_results_manage`, `fn_exam_class_result`, `fn_exam_pending_sheets`, `fn_grade_for_percent`). Pages: `Exam/GradeScale`, `Exam/ResultSheet` (Examinations menu).

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| RES-01 | No scale saved | GetScale | CBSE 8-point default: A1 91-100 ... E 0-32, flagged default | Proc | SQL A1 | PASS |
| RES-02 | Grade mapping | 91, 90.5, 33, 32.99, 100, 0, NULL | A1, A2, D, E, A1, E, none (between two whole-number bands = lower band) | Proc | SQL A2..A8 | PASS |
| RES-03 | Invalid scales | empty, blank label, duplicate label (any case), overlap, gap, not from 0, not to 100, min > max, > 100, non-numeric | Refused with a message naming the band | Proc | SQL A9..A18 | PASS |
| RES-04 | Custom scale | 5 bands A/B/C/D/F | Saved; GetScale returns 5, not default; grades follow it | Proc | SQL A19..A21b | PASS |
| RES-05 | Refused save | invalid scale after a valid one | Previous scale kept | Proc | SQL A23 | PASS |
| RES-06 | Reset | ResetDefault | CBSE default again | Proc | SQL A25 | PASS |
| RES-07 | Publish with a draft datesheet | PublishResults on a Draft exam | Refused | Proc | SQL B1 | PASS |
| RES-08 | Result status of a new exam | GetStatus | Unpublished; expected sheets = papers x sections with students (4), all pending | Proc | SQL B2 | PASS |
| RES-09 | **Publish while sheets are not finalised** | none / 3 of 4 finalised | Refused, with the count and the first pending sheet | Proc | SQL B3, B6, B7 | PASS |
| RES-10 | Marks while results unpublished | SaveMarks drafts | Accepted | Proc | SQL B4 | PASS |
| RES-11 | **Draft marks hidden from parents** | Published datesheet, results unpublished | Student dashboard shows nothing (also not as "latest exam") | Proc | SQL B5, B5b | PASS (closes EXM-51) |
| RES-12 | Finalise turns blank into Absent | r4 never marked | Absent | Proc | SQL B8 | PASS |
| RES-13 | Publish | all finalised | Published, by/at stamped, log row Publish | Proc | SQL B10..B12 | PASS |
| RES-14 | Publish twice | | Refused | Proc | SQL B13 | PASS |
| RES-15 | **Marks locked once published** | SaveMarks, ReopenSheet, SaveExam edit, SetStatus Draft | All refused ("Unpublish the results first"); mark unchanged; GetSheet reports results_published so Marks Entry locks the grid | Proc+UI | SQL C1..C6; V-ME `pubChip` / `locked()` | PASS (closes EXM-40) |
| RES-16 | Overall percentage and grade | 130/150 | 86.7% (dashboard, 1 dp), grade A2 (from the 2-dp %) | Proc | SQL D1..D3 | PASS |
| RES-17 | **Rank with ties** | two students 86.67%, next 83.33% | 1, 1, 3 by class; section rank separately (2 of 3 in A) | Proc | SQL D4..D7, D15 | PASS |
| RES-18 | Absent paper | Science absent | Out of the total (45/100 = 45%, C2), still ranked | Proc | SQL D8 | PASS |
| RES-19 | Absent from every paper | | No %, no grade, no rank (not counted in class size) | Proc | SQL D10 | PASS |
| RES-20 | Subject grade | 90/100, 40/50, absent | A2, B1 (out of its own max), none | Proc | SQL D11..D13 | PASS |
| RES-21 | Class result sheet | whole class / section "b" | 6 students x 2 papers; section filter keeps the class rank | Proc | SQL D14..D16 | PASS |
| RES-22 | Grades are not stored | change the scale after publishing | The next read shows the new grade | Proc | SQL D17 | PASS |
| RES-23 | Unpublish | blank reason / other school / with reason / twice | Refused / not found / done and logged (reason, who, when) / refused | Proc | SQL E1..E5, E7 | PASS |
| RES-24 | Hidden again after unpublish | | Dashboard shows nothing | Proc | SQL E6 | PASS |
| RES-25 | Correction cycle | unpublish, reopen, edit, finalise, republish | Mark edit history kept (40 -> 45); ranks recomputed (sole rank 1, then 2) | Proc | SQL E8..E11 | PASS |
| RES-26 | Marks of a removed paper | paper deleted behind the procs' back | Do not count | Proc | SQL E12 | PASS |
| RES-27 | Tenant isolation | other school: class sheet, status, student result, result function, grade scale; platform scope | Not found / nothing / own scale only / refused | Proc | SQL A22, A24, B9, E2, F1..F6 | PASS |
| RES-28 | Permissions | publish, unpublish, grade scale save/reset need exams.manage; pages need exams.view | `[HasPermission("exams.manage")]` + `ValidateAntiForgeryToken` on every POST | CTL | static: CTL-EX SaveGradeScale, ResetGradeScale, PublishResults, UnpublishResults | PASS |
| RES-29 | CSV export | a name starting with = + - @ tab | Prefixed with `'` and quoted, so a spreadsheet keeps it as text | CTL | static: CTL-EX `Csv()` | PASS |
| RES-30 | Print | Result Sheet print button | Selectors and status panel hidden; table only | UI | static: Results.css `@media print` | PASS (not browser-tested) |
| RES-31 | School purge | | grade_scale and exam_result_log deleted | Proc | SQL platform_access_security_tests H12 | PASS |

**Rules recorded with the feature:** a grade band runs from its min % up to the next band's min %; the grade is worked from the percentage rounded to 2 dp; rank uses the same 2-dp percentage over the whole class (the section column is the rank inside the section); absent papers are out of the total (today's rule), so a student absent from a paper is ranked on the papers they sat.

## J. Calendar date ranges + per-day bell schedules (WDS)

Added 2026-10-10 with the weekday-schedules feature. **SQL suite:** `EduCoreDataAccessLayer/Database/tests/weekday_schedules_tests.sql` (fixture 24 / 34 / 39, other school 23 / 33). **Last run:** `RESULT: 97 passed, 0 failed`. The period-structure half is catalogued in `settings_subjects_teachers_periods.md` section E. Procs: P-CAL (`school_calendar.sql`: new `SaveRange`, `DeleteRange`; SaveEntry and SaveRange share one code path), P-TT (`timetable.sql`), `academic.fn_day_periods` (`period_structure.sql`). Page: School Calendar "Date range" button (Dated Entries header).

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| RNG-01 | Holiday over a week | Mon 14 - Sun 20 Sep, a half day already on Wed 16 | 5 entries created; Wed kept as the half day; Sunday (weekly off) skipped; the message names both | Proc | SQL WDS-F1..F6 | PASS |
| RNG-02 | Day type over the range | fn_school_day_type 14..21 | holiday x4, half_day, holiday, weekly_off, working | Proc | SQL WDS-F7 | PASS |
| RNG-03 | Attendance inside the range | register on Tue 15 | Refused (school holiday) | Proc | SQL WDS-F8 | PASS |
| RNG-04 | Leave / payroll days | fn_school_working_days 14..20 | 0.5 (the half day) | Proc | SQL WDS-F9 | PASS |
| RNG-05 | Exam paper inside the range | paper on Thu 17 | Refused (school is closed) | Proc | SQL WDS-F10 | PASS |
| RNG-06 | Bad ranges | same range again, to < from, > 1 year, no first date, unknown type | Refused with a message ("Nothing was added ...") | Proc | SQL WDS-F11..F15 | PASS |
| RNG-07 | Half-day range vs each day's hours | Fri-Sat half day 12:30, Saturday's own schedule ends 10:55 | Refused naming Saturday; nothing written (atomic); Friday alone accepted | Proc | SQL WDS-F16..F18 | PASS |
| RNG-08 | Working-day range over a weekly off | Sunday 27 | Created; the day reads working | Proc | SQL WDS-F19 | PASS |
| RNG-09 | Delete a range | 14..20 | 6 entries removed, days back on the weekly pattern, entries outside kept; empty range / backwards refused | Proc | SQL WDS-F20..F24 | PASS |
| RNG-10 | Isolation / scope | other school deletes or adds in our dates; tenant 1 | Our entries untouched, theirs separate; platform refused | Proc | SQL WDS-G6..G9, G12 | PASS |
| RNG-11 | Page | Date range dialog: from/to, type, name, closing time; Add range / Remove entries in range (EC.confirm) | Toast shows the proc's message (what was skipped) | UI-JS | static: V-CAL; inline JS checked with `new Function` | PASS (not browser-tested) |
| TT-19 | Timetable follows each day's schedule | short Saturday | Grid shows Saturday's own periods; booking checks that day's schedule; Copy Day maps by label and reports skipped labels | Proc+UI | SQL WDS-D*, WDS-E*; static V-TT | PASS |
| BELL-07 | Smart Bell on a short Saturday | Saturday has its own schedule | Rings Saturday's periods; a half day still cuts it short | CTL | static: CTL-SS BuildBellStateAsync passes today's weekday | PASS |

**Rules recorded with the feature:** SaveRange never overwrites a date that already has an entry (SaveEntry still replaces one date); holiday and half-day ranges skip weekly offs, a working-day range does not (that is how a weekly off is opened); a half day's closing time is checked against that date's own bell schedule; ranges are capped at one year.

## Business decisions (BD), with the user-approved defaults

| ID | Question | Decision |
|---|---|---|
| BD-01 | Should the register follow the School Calendar (holidays, weekly offs, working Sundays)? This report assumes **yes** (ATT-01..03). | APPROVED: yes. Declared holidays and weekly offs are refused, declared working days allowed, no hard-coded Sunday. |
| BD-02 | When are results visible? The exam's "Published" currently means the datesheet is published, so draft (un-finalised) marks show on the student dashboard, and marks stay editable after publishing. Should there be a separate "Publish results" step that also locks sheets? | APPROVED: no result-publish step for now (future feature). **Built 2026-10-10:** a separate results status; publish needs every sheet finalised and locks marks; unpublish needs a reason and is logged (section I). |
| BD-03 | Grades and rank: which grading scale (CBSE 9-point, %, per school)? Rank per section or class, with ties? | APPROVED: future feature. The only grade/rank values are mock JS in `Views/Admission/Dashboard.cshtml` (Admission area); flagged to that page's owner. **Built 2026-10-10:** per-school grade scale (CBSE 8-point default), rank by overall % in class and section, ties share a rank (section I). The Admission dashboard mock is still not wired up. |
| BD-04 | Is "Leave" an absence for attendance %? | APPROVED: Leave is not present, and is reported separately. Late is present but stays Late. |
| BD-05 | Should a month register show everyone enrolled during that month (leavers, section movers) for the days they were there? This report assumes **yes** (ATT-28/30). | APPROVED: yes, leavers and movers stay, with marks only on the days they belonged. |
| BD-06 | Audit depth for attendance and marks: full history (old → new, who, when) or last-change only? This report assumes **history is required** (ATT-33, EXM-37). | APPROVED: full history (old, new, who, when), written only on a real change. |
| BD-07 | May exam papers be scheduled on holidays/Sundays? | APPROVED: refused, with a clear message. |
| BD-08 | Should mark entry be limited to the teacher who teaches that subject/section? | APPROVED: stays exams.manage. |
| BD-09 | May non-teaching staff appear in the timetable (e.g. a librarian for a library period)? | APPROVED: active teaching staff only. |
| BD-10 | On a half day, are periods after closing "not held" for timetable/attendance purposes? | APPROVED: bell only; a normal attendance day; timetable unchanged. |
| BD-11 | Unpublishing or deleting an exam whose sheets are finalised: allow, warn, or refuse? | APPROVED: an exam with finalised sheets cannot be deleted (SQL EXM-E11b); it can be unpublished. |

## Totals

- Calendar ranges + per-day schedules (section J): **97** SQL checks in `weekday_schedules_tests.sql`, all PASS; 13 catalog rows.
- Results feature (section I): **81** SQL checks in `exam_results_publish_tests.sql`, all PASS; 31 catalog rows.
- SQL checks: **138** after the fixes (137 PASS, 1 BUG: ATT-B8). Before the fixes: 120 checks (85 PASS, 35 BUG).
- Catalog rows: 146 test rows plus 11 business decisions. Real bugs: the dates-as-text root cause (R1), which breaks the calendar page and exam create/edit (3 checks), and the result-join bug (Critical). The full list with severity is in the final report.
