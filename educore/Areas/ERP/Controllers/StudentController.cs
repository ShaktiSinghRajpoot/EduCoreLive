using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("students.view")]
    public class StudentController : Controller
    {
        private readonly IBaseService _baseService;
        private readonly IAdmissionService _admissionService;
        private readonly IAdmissionWorkflowService _admissionWorkflowService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IWebHostEnvironment _env;
        private readonly IConfiguration _config;

        private readonly IPublicIdService _publicIds;
        private readonly IFeePaymentService _feeService;
        private readonly IAttendanceService _attendanceService;
        private readonly ITimetableService _timetableService;
        private readonly IExamService _examService;
        private readonly ISubjectService _subjectService;
        private readonly IHomeworkService _homeworkService;

        public StudentController(
            IBaseService baseService,
            IAdmissionService admissionService,
            IAdmissionWorkflowService admissionWorkflowService,
            ISchoolSettingsService schoolSettingsService,
            IPublicIdService publicIds,
            IFeePaymentService feeService,
            IAttendanceService attendanceService,
            ITimetableService timetableService,
            IExamService examService,
            ISubjectService subjectService,
            IHomeworkService homeworkService,
            IWebHostEnvironment env, IConfiguration config)
        {
            _subjectService = subjectService;
            _homeworkService = homeworkService;
            _publicIds = publicIds;
            _feeService = feeService;
            _attendanceService = attendanceService;
            _timetableService = timetableService;
            _examService = examService;
            _baseService = baseService;
            _admissionService = admissionService;
            _admissionWorkflowService = admissionWorkflowService;
            _schoolSettingsService = schoolSettingsService;
            _env = env;
            _config = config;
        }

        // One StudentListModel does it all: bound filters/sort/page come in via
        // the query string; the service fills Items + TotalCount + summary tiles.
        // Tenant/school/user are sourced from CLAIMS only (never model-bound).
        public async Task<IActionResult> StudentList(StudentListModel query)
        {
            // Filter dropdowns share the same source as Admission / Enquiry.
            try { query.ClassList = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { query.ClassList = new(); }

            try { query.YearList = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString()); }
            catch { query.YearList = new(); }

            // When registration is mandatory before admission, direct admission is
            // blocked — so hide the "New Admission" shortcut and steer users through
            // the Enquiry → Registration flow instead.
            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(TenantId(), SchoolId(), UserId());
            ViewBag.RegistrationRequired = workflow.EnableRegistration && workflow.RegistrationRequiredBeforeAdmission;

            // Fee status is fee data: a teacher with students.view only must not see it,
            // filter by it, or receive it in the page.
            bool canViewFees = await HasPermissionAttribute.UserHasAsync(this, "fees.view");
            ViewBag.CanViewFees = canViewFees;
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "students.manage");
            if (!canViewFees) query.FilterFee = null;

            await _admissionService.GetStudentListPageAsync(query, TenantId(), SchoolId(), UserId());
            if (!canViewFees)
                foreach (var s in query.Items) { s.FeeStatus = ""; s.FeeDue = 0; s.AnnualTotal = 0; }
            return View(query);
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // Bulk promotion. The session (academic year) and class selectors are seeded
        // from real reference data; sections and the roster load over AJAX.
        public async Task<IActionResult> Promotion()
        {
            try { ViewBag.ClassList = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.ClassList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }

            try { ViewBag.YearList = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.YearList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }

            // "Next class" must follow teaching order (display_order), NOT the
            // dropdown order above, which is newest-class-first and would walk
            // the school downwards. Null year = the current session; the page
            // reloads the ladder from the target session once one is chosen.
            ViewBag.ClassLadder = await _admissionService.GetClassLadderDetailedAsync(TenantId(), SchoolId(), UserId());

            return View();
        }

        // Is the chosen session ready to receive students? Classes and sections
        // are per-session rows, so a new session is empty until its structure is
        // copied forward — promoting into it would strand every student on a
        // class that does not exist. The page asks before showing the confirm.
        public async Task<IActionResult> PromotionSessionCheck(string? year)
        {
            var info = await _schoolSettingsService.GetSessionStructureAsync(
                TenantId(), SchoolId(), UserId(), academicYearName: year);

            var ladder = info.IsReady
                ? await _admissionService.GetClassLadderDetailedAsync(TenantId(), SchoolId(), UserId(), year)
                : new List<ClassLadderItem>();

            return Json(new
            {
                ready          = info.IsReady,
                yearName       = info.AcademicYearName,
                classCount     = info.ClassCount,
                sectionCount   = info.SectionCount,
                canCopy        = info.CanCopy,
                sourceYearName = info.SourceYearName,
                ladder = ladder.Select(c => new { name = c.Name, order = c.Order })
            });
        }

        // Classes that exist IN ONE SESSION, in teaching order.
        //
        // The shared config.sp_dropdown_common 'Class' list is deliberately session-less:
        // it collapses every session's classes to one row per name so filters on past
        // sessions keep working. That is right for the directory, wrong here — this page
        // has to show the classes the CHOSEN session actually has, or the office picks a
        // class that session never had and the roster comes back empty with no reason.
        //
        // The class ladder is exactly that list, so reuse it rather than adding a proc.
        public async Task<IActionResult> PromotionClasses(string? year)
        {
            var ladder = await _admissionService.GetClassLadderDetailedAsync(
                TenantId(), SchoolId(), UserId(), year);

            return Json(ladder.Select(c => new { name = c.Name, order = c.Order }));
        }

        // Sections the class HAS in that session's setup — fills the Section
        // dropdowns on Promotion and Edit Student. Empty sections included, so a
        // new 5-C can be picked. Null year = the current session.
        public async Task<IActionResult> PromotionSections(string @class, string? year)
        {
            var sections = await _admissionService.GetClassSectionsAsync(@class, TenantId(), SchoolId(), UserId(), year);
            return Json(sections);
        }

        // The roster for the chosen class/section/year, with real pending dues.
        // Result % has no source yet (no exam module) — returned as null.
        public async Task<IActionResult> PromotionRoster(string @class, string? section, string? year)
        {
            if (string.IsNullOrWhiteSpace(@class)) return Json(Array.Empty<object>());

            var (items, _) = await _admissionService.GetStudentsAsync(
                TenantId(), SchoolId(), UserId(),
                pageNumber: 1, pageSize: 1000,
                filterClass: @class,
                filterSection: string.IsNullOrWhiteSpace(section) ? null : section,
                filterYear: string.IsNullOrWhiteSpace(year) ? null : year,
                filterStatus: "Active");

            var roster = items.Select(s => new
            {
                id      = s.StudentId,
                name    = s.StudentName,
                roll    = s.RollNo,
                cls     = s.ClassName,
                sec     = s.Section,
                due     = s.FeeDue
            });
            return Json(roster);
        }

        // Students who have left. Same fat-model shape as StudentList: filters and
        // paging come in on the query string, the service fills Items + tiles.
        public async Task<IActionResult> Inactive(StudentExitListModel query)
        {
            await _admissionService.GetStudentExitListAsync(query, TenantId(), SchoolId(), UserId());
            // The TC dialog opens on the school's default format (Settings > Documents).
            ViewBag.TcFormat = await _schoolSettingsService.GetTcFormatAsync(TenantId(), SchoolId(), UserId());
            return View(query);
        }

        // Mark a student as having left. Outstanding dues are reported back, not
        // blocked — the student has left either way, and the TC step checks again.
        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Exit([FromBody] StudentExitRequest request)
        {
            var result = await _admissionService.ExitStudentAsync(request, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message, outstanding = result.Outstanding });
        }

        // Upload a student photo. Saved under wwwroot/uploads/students/... (same
        // pattern as the school logo); the URL is stored on the student row and shows
        // on the directory avatar and the ID card.
        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        [RequestSizeLimit(3 * 1024 * 1024)]
        public async Task<IActionResult> UploadPhoto(Guid publicId, IFormFile? photo)
        {
            var id = await _publicIds.ResolveAsync(IPublicIdService.Student, publicId, TenantId(), SchoolId());
            if (id <= 0) return Json(new { success = false, message = "Unknown student." });
            if (photo == null || photo.Length == 0) return Json(new { success = false, message = "Choose an image." });

            var ext = Path.GetExtension(photo.FileName).ToLowerInvariant();
            string[] allowed = { ".jpg", ".jpeg", ".png", ".webp" };
            if (!allowed.Contains(ext)) return Json(new { success = false, message = "Only JPG, PNG or WEBP images are allowed." });
            if (photo.Length > 2 * 1024 * 1024) return Json(new { success = false, message = "Image must be under 2 MB." });

            var folder = UploadPaths.FolderFor(_config, _env, "students", TenantId(), SchoolId());

            // The photo being replaced, so its file can be removed afterwards.
            var oldUrl = (await _admissionService.GetStudentByIdAsync(id, TenantId(), SchoolId(), UserId()))?.PhotoUrl;

            var fileName = $"student_{id}_{Dates.Now:yyyyMMddHHmmssfff}{ext}";
            var fullPath = Path.Combine(folder, fileName);
            using (var stream = new FileStream(fullPath, FileMode.Create))
            {
                await photo.CopyToAsync(stream);
            }

            var url = UploadPaths.UrlFor("students", TenantId(), SchoolId(), fileName);
            var (ok, message, photoUrl) = await _admissionService.SetStudentPhotoAsync(id, url, TenantId(), SchoolId(), UserId());

            // If the DB update failed, don't leave an orphan file behind.
            if (!ok) { try { System.IO.File.Delete(fullPath); } catch { } }

            // Replaced photos used to pile up on disk. Delete the old file, but only
            // when its URL is in THIS school's student-photo folder; the name is
            // reduced to a bare file name so the path cannot walk anywhere else.
            var prefix = UploadPaths.UrlFor("students", TenantId(), SchoolId(), "");
            if (ok && !string.IsNullOrWhiteSpace(oldUrl)
                   && oldUrl.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                   && !string.Equals(oldUrl, url, StringComparison.OrdinalIgnoreCase))
            {
                var oldName = Path.GetFileName(oldUrl);
                if (!string.IsNullOrWhiteSpace(oldName))
                {
                    try { System.IO.File.Delete(Path.Combine(folder, oldName)); } catch { }
                }
            }

            return Json(new { success = ok, message, photoUrl });
        }

        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Reactivate([FromBody] StudentExitRequest request)
        {
            var result = await _admissionService.UndoStudentExitAsync(request.StudentId, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        // Commits the bulk promotion. The target class is worked out in the proc
        // from the school's class ladder, so it is not accepted from the page.
        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Promote([FromBody] StudentPromotionRequest request)
        {
            var result = await _admissionService.PromoteStudentsAsync(request, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success       = result.Success,
                message       = result.Message,
                promoted      = result.Promoted,
                retained      = result.Retained,
                passedOut     = result.PassedOut,
                skipped       = result.Skipped,
                skippedDetail = result.SkippedDetail
            });
        }

        // The URL carries the student's uuid. Resolving it here is what enforces the
        // tenant/school check — an unknown uuid and another school's uuid both give 0.
        public async Task<IActionResult> Dashboard(Guid id)
        {
            if (await _publicIds.ResolveAsync(IPublicIdService.Student, id, TenantId(), SchoolId()) == 0)
                return RedirectToAction("StudentList");

            ViewBag.StudentPublicId = id;   // the page's own ajax calls pass this straight back

            // Header buttons and the Fee tab follow the user's permissions.
            ViewBag.CanManage  = await HasPermissionAttribute.UserHasAsync(this, "students.manage");
            ViewBag.CanViewFees = await HasPermissionAttribute.UserHasAsync(this, "fees.view");
            ViewBag.CanCollect = await HasPermissionAttribute.UserHasAsync(this, "fees.collect");
            return View();
        }

        // Everything the dashboard shows, in one call — the page used to build this
        // from a hardcoded array of ten students.
        //
        // The Homework tab: the student's homework of the last 30 days with whether
        // they did it. Loaded only when the tab is opened.
        [HttpGet]
        public async Task<IActionResult> DashboardHomework(Guid id)
        {
            var studentId = await _publicIds.ResolveAsync(IPublicIdService.Student, id, TenantId(), SchoolId());
            if (studentId == 0) return Json(Array.Empty<object>());

            var rows = await _homeworkService.GetForStudentAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(h => new
            {
                subject = h.SubjectName, title = h.Title, details = h.Details, given = Dates.Show(h.AssignedOn),
                due = Dates.Show(h.DueOn), teacher = h.TeacherName, status = h.MyStatus
            }));
        }

        public async Task<IActionResult> DashboardData(Guid id, int? month = null, int? year = null, int? examId = null)
        {
            var studentId = await _publicIds.ResolveAsync(IPublicIdService.Student, id, TenantId(), SchoolId());
            if (studentId == 0) return Json(new { found = false });

            var student = await _admissionService.GetStudentByIdAsync(studentId, TenantId(), SchoolId(), UserId());
            if (student == null) return Json(new { found = false });

            var dues    = await _feeService.GetStudentDuesAsync(studentId, TenantId(), SchoolId(), UserId());
            var history = await _feeService.GetPaymentHistoryAsync(studentId, TenantId(), SchoolId(), UserId());
            // money handed back, listed beside the receipts (QA BUG-084)
            var refunds = await _feeService.GetRefundHistoryAsync(studentId, TenantId(), SchoolId(), UserId());
            // Whole-ledger totals. The dues list above holds only rows still owing,
            // so summing it dropped every fully paid charge from "Total Paid".
            var totals  = await _admissionService.GetStudentFeeTotalsAsync(studentId, TenantId(), SchoolId(), UserId());

            // Fee figures go only to users who may see fees (a Teacher opens this
            // page too). The page hides the Fee tab when fee comes back null.
            bool canViewFees = await HasPermissionAttribute.UserHasAsync(this, "fees.view");

            // month/year null on the first load: the page picks a month from the list
            // that comes back and asks again, so we do not guess which one it wants.
            var att = await _attendanceService.GetStudentAttendanceAsync(
                studentId, TenantId(), SchoolId(), UserId(), student.AcademicYear, month, year);

            // The student's timetable IS their section's. Resolve class+section to a
            // section id through the setup, which already lists them for this session —
            // a student whose section has no timetable simply gets an empty week.
            var setup = await _timetableService.GetSetupAsync(TenantId(), SchoolId(), UserId());
            var mySection = setup.Sections.FirstOrDefault(x =>
                string.Equals(x.ClassName, student.ClassName, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(x.SectionName ?? "", student.Section ?? "", StringComparison.OrdinalIgnoreCase));

            var grid = mySection == null
                ? new TimetableGrid()
                : await _timetableService.GetGridAsync(mySection.SectionId, TenantId(), SchoolId(), UserId());

            // Exams whose RESULTS are published only, and absences are excluded from the
            // totals — see core.sp_exam_result_student. examId null = their latest one.
            var exam = await _examService.GetStudentResultAsync(
                studentId, TenantId(), SchoolId(), UserId(), examId);

            // Subjects the class studies (Subject Management, current session). Only
            // when the class name is unambiguous -- streams can share a class name.
            var classMatches = (await _subjectService.GetClassesAsync(TenantId(), SchoolId(), UserId()))
                .Where(c => string.Equals(c.ClassName, student.ClassName, StringComparison.OrdinalIgnoreCase))
                .ToList();
            int? classSubjects = classMatches.Count == 1 ? classMatches[0].SubjectCount : null;

            // Age in completed years on the school's today, from the DOB.
            int? age = null;
            var dob = Dates.Parse(student.DateOfBirth);
            if (dob.HasValue)
            {
                var today = Dates.Now.Date;
                int years = today.Year - dob.Value.Year;
                if (dob.Value.Date > today.AddYears(-years)) years--;
                if (years >= 0) age = years;
            }

            return Json(new
            {
                found = true,
                student = new
                {
                    // A left student is shown read-only: the page hides Edit and
                    // says when and why they left.
                    isActive  = student.IsActive,
                    status    = string.IsNullOrWhiteSpace(student.Status) ? (student.IsActive ? "Active" : "Left") : student.Status,
                    leftOn    = string.IsNullOrWhiteSpace(student.DateOfLeaving) ? null : Dates.Show(student.DateOfLeaving, "dd MMM yyyy"),
                    leftWhy   = student.LeavingReason,
                    photo     = student.PhotoUrl,
                    name      = student.StudentName,
                    roll      = student.RollNo ?? "—",
                    admNo     = student.AdmissionNo ?? "—",
                    cls       = student.ClassName,
                    sec       = student.Section ?? "—",
                    gender    = student.Gender ?? "—",
                    dob       = string.IsNullOrWhiteSpace(student.DateOfBirth) ? "—" : Dates.Show(student.DateOfBirth, "dd MMM yyyy"),
                    age,
                    subjects  = classSubjects,
                    admDate   = string.IsNullOrWhiteSpace(student.AdmissionDate) ? "—" : Dates.Show(student.AdmissionDate, "dd MMM yyyy"),
                    year      = student.AcademicYear,
                    guardian  = student.GuardianName ?? "—",
                    mother    = student.MotherName ?? "—",
                    mobile    = student.MobileNumber ?? "—",
                    altMobile = student.AlternateMobile ?? "—",
                    address   = student.Address ?? "—",
                    blood     = student.BloodGroup ?? "—",
                    religion  = student.Religion ?? "—",
                    category  = student.Category ?? "—",
                    nation    = student.Nationality ?? "—",
                    idProof   = student.IdProofNo ?? "—",
                    prevSchool= student.PrevSchoolName ?? "—",
                    prevBoard = student.PrevBoard ?? "—",
                    prevClass = student.PrevClass ?? "—",
                    prevTc    = student.PrevTcNo ?? "—",
                    motherTongue = student.MotherTongue ?? "—",
                    apaar     = student.ApaarId ?? "—",
                    udise     = student.UdiseStudentId ?? "—",
                    fatherOcc  = student.FatherOccupation ?? "—",
                    fatherQual = student.FatherQualification ?? "—",
                    fatherEmail = student.FatherEmail ?? "—",
                    motherOcc  = student.MotherOccupation ?? "—",
                    motherQual = student.MotherQualification ?? "—",
                    motherEmail = student.MotherEmail ?? "—",
                    income    = student.AnnualIncome
                },
                fee = !canViewFees ? null : (object)new
                {
                    // Outstanding is what the ledger says, not a recomputation here —
                    // core.student_ledger stays the single source of truth for money.
                    totalDue    = totals.TotalDue,
                    totalPaid   = totals.TotalPaid,
                    concession  = totals.TotalConcession,
                    refunded    = totals.TotalRefunded,
                    closed      = totals.TotalClosed,
                    advance     = totals.AdvanceBalance,
                    outstanding = totals.Outstanding,
                    rows = dues.Select(d => new
                    {
                        head        = d.FeeHeadName,
                        frequency   = d.Frequency,
                        installment = d.InstallmentLabel ?? "—",
                        dueDate     = string.IsNullOrWhiteSpace(d.DueDate) ? "—" : Dates.Show(d.DueDate, "dd MMM yyyy"),
                        due         = d.AmountDue,
                        paid        = d.AmountPaid,
                        outstanding = d.Outstanding
                    })
                },
                attendance = new
                {
                    // A day nobody marked is not an absence, so the percentage is over
                    // days this student's class actually held a register.
                    schoolDays = att.SchoolDays,
                    present    = att.Present,
                    absent     = att.Absent,
                    leave      = att.LeaveDays,
                    percent    = att.Percent,
                    months     = att.Months.Select(m => new { m.Month, m.Year, m.SchoolDays, m.Present }),
                    days       = att.Days
                },
                timetable = new
                {
                    // null section = this class/section has no timetable setup at all,
                    // which the page reports differently from "set up but empty".
                    hasSection = mySection != null,
                    periods = setup.Periods.Select(pd => new
                    {
                        seq   = pd.PeriodSeq,
                        label = pd.Label,
                        type  = pd.PeriodType,       // break/lunch rows are not subjects
                        start = pd.StartTime,
                        end   = pd.EndTime
                    }),
                    days = setup.Days.Select(dy => new { dow = dy.DayOfWeek, label = dy.DayLabel }),
                    entries = grid.Entries.Select(e => new
                    {
                        dow     = e.DayOfWeek,
                        seq     = e.PeriodSeq,
                        subject = e.SubjectName,
                        teacher = e.StaffName
                    })
                },
                exams = new
                {
                    options = exam.Exams.Select(e => new
                    {
                        id   = e.ExamId,
                        name = e.ExamName,
                        type = e.ExamType ?? "",
                        date = string.IsNullOrWhiteSpace(e.StartDate) ? "" : Dates.Show(e.StartDate, "dd MMM yyyy")
                    }),
                    subjects = exam.Subjects.Select(x => new
                    {
                        subject  = x.Subject,
                        obtained = x.Obtained,     // null when absent
                        max      = x.MaxMarks,
                        pass     = x.PassMarks,
                        absent   = x.IsAbsent,
                        passed   = x.Passed,       // null = cannot say, not "failed"
                        percent  = x.Percent,
                        grade    = x.Grade         // from the school's grade scale
                    }),
                    subjectCount = exam.SubjectCount,
                    obtained     = exam.Obtained,
                    total        = exam.Total,
                    percent      = exam.Percent,
                    absentCount  = exam.AbsentCount,
                    failedCount  = exam.FailedCount,
                    // Null when absent from every paper (no percentage, so no grade or rank).
                    grade        = exam.Grade,
                    classRank    = exam.ClassRank,
                    classSize    = exam.ClassSize,
                    sectionRank  = exam.SectionRank,
                    sectionSize  = exam.SectionSize
                },
                receipts = !canViewFees ? null : (object)history.Select(h => new
                {
                    receiptNo = h.ReceiptNo,
                    date      = string.IsNullOrWhiteSpace(h.PaymentDate) ? "—" : Dates.Show(h.PaymentDate, "dd MMM yyyy"),
                    amount    = h.Amount,
                    mode      = h.PaymentMode,
                    collectedBy = h.CollectedBy,   // the payer is not recorded; the cashier is
                    cancelled = h.IsCancelled      // a cancelled receipt still shows, marked
                }),
                refunds = !canViewFees ? null : (object)refunds.Select(r => new
                {
                    refundNo = r.RefundNo,
                    date     = Dates.Show(r.RefundDate),
                    amount   = r.Amount,
                    mode     = r.Mode,
                    against  = r.Against,
                    by       = r.RefundedBy
                })
            });
        }

        // A student's session-by-session timeline. core.students only holds their
        // present position, so this comes from core.student_enrolment.
        public async Task<IActionResult> EnrolmentHistory(Guid id)
        {
            var studentId = await _publicIds.ResolveAsync(IPublicIdService.Student, id, TenantId(), SchoolId());
            if (studentId == 0) return Json(Array.Empty<object>());

            var items = await _admissionService.GetEnrolmentHistoryAsync(
                studentId, TenantId(), SchoolId(), UserId());

            return Json(items.Select(e => new
            {
                year      = e.AcademicYear,
                cls       = e.ClassName,
                sec       = e.Section,
                roll      = e.RollNo,
                status    = e.Status,
                isCurrent = e.IsCurrent
            }));
        }

        // Everything that changed the student's place or money outside a receipt:
        // admission, concession, exit / reactivate, promotion (with the dues
        // carried), class changes, bus assignments, closed dues and refunds.
        public async Task<IActionResult> History(Guid id)
        {
            var studentId = await _publicIds.ResolveAsync(IPublicIdService.Student, id, TenantId(), SchoolId());
            if (studentId == 0) return Json(Array.Empty<object>());

            var items = await _admissionService.GetStudentHistoryAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(items.Select(h => new
            {
                when   = h.HappenedAt,
                action = h.Action,
                detail = h.Detail,
                amount = h.Amount,
                by     = h.DoneBy
            }));
        }

        public async Task<IActionResult> EditStudent(Guid id)
        {
            var studentId = await _publicIds.ResolveAsync(IPublicIdService.Student, id, TenantId(), SchoolId());
            if (studentId == 0) return RedirectToAction("StudentList");

            var model = await _admissionService.GetStudentByIdAsync(studentId, TenantId(), SchoolId(), UserId());
            if (model == null) return RedirectToAction("StudentList");

            // A student who has left is a closed record: view it, do not edit it.
            if (!model.IsActive)
            {
                TempData["ErrorMessage"] = "This student has left. Re-admit them from Inactive Students to edit the record.";
                return RedirectToAction("Dashboard", new { id });
            }

            ViewBag.StudentPublicId = id;
            await FillEditDropdownsAsync(model.ClassName, model.AcademicYear);
            return View(model);
        }

        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> EditStudent(Guid id, AdmissionModel model)
        {
            var studentId = await _publicIds.ResolveAsync(IPublicIdService.Student, id, TenantId(), SchoolId());
            if (studentId == 0) return RedirectToAction("StudentList");

            // The id comes from the URL, never from the posted form — otherwise the
            // form could name a different student than the one the URL authorised.
            model.StudentId = studentId;

            var stored = await _admissionService.GetStudentByIdAsync(studentId, TenantId(), SchoolId(), UserId());
            if (stored == null) return RedirectToAction("StudentList");
            if (!stored.IsActive)
            {
                TempData["ErrorMessage"] = "This student has left. Re-admit them from Inactive Students to edit the record.";
                return RedirectToAction("Dashboard", new { id });
            }

            // The read-only fields are not posted (they have no name); put them
            // back so a refused save re-renders with them filled in.
            model.AdmissionNo   = stored.AdmissionNo;
            model.AdmissionDate = stored.AdmissionDate;
            model.AcademicYear  = stored.AcademicYear;
            model.PhotoUrl      = stored.PhotoUrl;

            // Same rules as admission (AdmissionController.SaveAdmission). The
            // proc checks them too; this keeps the message on the form.
            var mobile = model.MobileNumber?.Trim();
            if (string.IsNullOrWhiteSpace(mobile))
                ModelState.AddModelError(nameof(model.MobileNumber), "Mobile number is required.");
            else if (!System.Text.RegularExpressions.Regex.IsMatch(mobile, @"^\d{10}$"))
                ModelState.AddModelError(nameof(model.MobileNumber), "Mobile number must be 10 digits.");
            if (!string.IsNullOrWhiteSpace(model.AlternateMobile) &&
                !System.Text.RegularExpressions.Regex.IsMatch(model.AlternateMobile.Trim(), @"^\d{10}$"))
                ModelState.AddModelError(nameof(model.AlternateMobile), "Alternate mobile must be 10 digits.");
            if (!string.IsNullOrWhiteSpace(model.IdProofNo) &&
                !System.Text.RegularExpressions.Regex.IsMatch(model.IdProofNo.Trim(), @"^\d{12}$"))
                ModelState.AddModelError(nameof(model.IdProofNo), "Aadhaar number must be 12 digits.");
            var dob = Dates.Norm(model.DateOfBirth);
            if (string.IsNullOrWhiteSpace(model.DateOfBirth))
                ModelState.AddModelError(nameof(model.DateOfBirth), "Date of birth is required.");
            else if (dob == null)
                ModelState.AddModelError(nameof(model.DateOfBirth), "Date of birth is not a valid date.");
            else if (string.CompareOrdinal(dob, Dates.Today) > 0)
                ModelState.AddModelError(nameof(model.DateOfBirth), "Date of birth cannot be in the future.");
            else if (!string.IsNullOrWhiteSpace(stored.AdmissionDate) &&
                     string.CompareOrdinal(dob, Dates.Norm(stored.AdmissionDate) ?? "") > 0)
                ModelState.AddModelError(nameof(model.DateOfBirth), "Date of birth cannot be after the admission date.");
            model.DateOfBirth = dob ?? model.DateOfBirth;

            if (!ModelState.IsValid)
            {
                ViewBag.StudentPublicId = id;
                await FillEditDropdownsAsync(model.ClassName, stored.AcademicYear);
                return View(model);
            }

            var (ok, message) = await _admissionService.UpdateStudentAsync(
                model, TenantId(), SchoolId(), UserId());

            if (!ok)
            {
                // Business rules come back as the proc's own wording (unknown class,
                // not this school's student) — show it on the form, not a toast that
                // disappears while they are still reading the field it refers to.
                ModelState.AddModelError(string.Empty, message);
                ViewBag.StudentPublicId = id;
                await FillEditDropdownsAsync(model.ClassName, stored.AcademicYear);
                return View(model);
            }

            TempData["SuccessMessage"] = message;
            return RedirectToAction("Dashboard", new { id });
        }

        // Class list + the sections that class has in the student's session.
        private async Task FillEditDropdownsAsync(string? className, string? academicYear)
        {
            try
            {
                ViewBag.ClassList = await _baseService.GetSelectListAsync(
                    "config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString());
            }
            catch { ViewBag.ClassList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }

            ViewBag.SectionList = string.IsNullOrWhiteSpace(className)
                ? new List<string>()
                : await _admissionService.GetClassSectionsAsync(className, TenantId(), SchoolId(), UserId(), academicYear);
        }
    }
}
