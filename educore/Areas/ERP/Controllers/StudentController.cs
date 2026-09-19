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

        private readonly IPublicIdService _publicIds;
        private readonly IFeePaymentService _feeService;
        private readonly IAttendanceService _attendanceService;
        private readonly ITimetableService _timetableService;

        public StudentController(
            IBaseService baseService,
            IAdmissionService admissionService,
            IAdmissionWorkflowService admissionWorkflowService,
            ISchoolSettingsService schoolSettingsService,
            IPublicIdService publicIds,
            IFeePaymentService feeService,
            IAttendanceService attendanceService,
            ITimetableService timetableService,
            IWebHostEnvironment env)
        {
            _publicIds = publicIds;
            _feeService = feeService;
            _attendanceService = attendanceService;
            _timetableService = timetableService;
            _baseService = baseService;
            _admissionService = admissionService;
            _admissionWorkflowService = admissionWorkflowService;
            _schoolSettingsService = schoolSettingsService;
            _env = env;
        }

        public IActionResult StudentAttendance()
        {
            return View();
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

            await _admissionService.GetStudentListPageAsync(query, TenantId(), SchoolId(), UserId());
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

        // Sections that have active students in a class — fills the Section dropdown.
        public async Task<IActionResult> PromotionSections(string @class)
        {
            var sections = await _admissionService.GetClassSectionsAsync(@class, TenantId(), SchoolId(), UserId());
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

            var folder = Path.Combine(_env.WebRootPath, "uploads", "students", TenantId().ToString(), SchoolId().ToString());
            Directory.CreateDirectory(folder);

            var fileName = $"student_{id}_{DateTime.Now:yyyyMMddHHmmssfff}{ext}";
            var fullPath = Path.Combine(folder, fileName);
            using (var stream = new FileStream(fullPath, FileMode.Create))
            {
                await photo.CopyToAsync(stream);
            }

            var url = $"/uploads/students/{TenantId()}/{SchoolId()}/{fileName}";
            var (ok, message, photoUrl) = await _admissionService.SetStudentPhotoAsync(id, url, TenantId(), SchoolId(), UserId());

            // If the DB update failed, don't leave an orphan file behind.
            if (!ok) { try { System.IO.File.Delete(fullPath); } catch { } }

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
            return View();
        }

        // Everything the dashboard shows, in one call — the page used to build this
        // from a hardcoded array of ten students.
        //
        // Exam results are NOT here: there is still no per-student marks getter, and
        // the page says so rather than inventing numbers.
        public async Task<IActionResult> DashboardData(Guid id, int? month = null, int? year = null)
        {
            var studentId = await _publicIds.ResolveAsync(IPublicIdService.Student, id, TenantId(), SchoolId());
            if (studentId == 0) return Json(new { found = false });

            var student = await _admissionService.GetStudentByIdAsync(studentId, TenantId(), SchoolId(), UserId());
            if (student == null) return Json(new { found = false });

            var dues    = await _feeService.GetStudentDuesAsync(studentId, TenantId(), SchoolId(), UserId());
            var history = await _feeService.GetPaymentHistoryAsync(studentId, TenantId(), SchoolId(), UserId());

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

            return Json(new
            {
                found = true,
                student = new
                {
                    name      = student.StudentName,
                    roll      = student.RollNo ?? "—",
                    admNo     = student.AdmissionNo ?? "—",
                    cls       = student.ClassName,
                    sec       = student.Section ?? "—",
                    gender    = student.Gender ?? "—",
                    dob       = student.DateOfBirth?.ToString("dd MMM yyyy") ?? "—",
                    admDate   = student.AdmissionDate?.ToString("dd MMM yyyy") ?? "—",
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
                    prevSchool= student.PrevSchoolName ?? "—"
                },
                fee = new
                {
                    // Outstanding is what the ledger says, not a recomputation here —
                    // core.student_ledger stays the single source of truth for money.
                    totalDue    = dues.Sum(d => d.AmountDue),
                    totalPaid   = dues.Sum(d => d.AmountPaid),
                    concession  = dues.Sum(d => d.Concession),
                    outstanding = dues.Sum(d => d.Outstanding),
                    rows = dues.Select(d => new
                    {
                        head        = d.FeeHeadName,
                        frequency   = d.Frequency,
                        installment = d.InstallmentLabel ?? "—",
                        dueDate     = d.DueDate?.ToString("dd MMM yyyy") ?? "—",
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
                receipts = history.Select(h => new
                {
                    receiptNo = h.ReceiptNo,
                    date      = h.PaymentDate?.ToString("dd MMM yyyy") ?? "—",
                    amount    = h.Amount,
                    mode      = h.PaymentMode,
                    cancelled = h.IsCancelled      // a cancelled receipt still shows, marked
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

        public async Task<IActionResult> EditStudent(Guid id)
        {
            var studentId = await _publicIds.ResolveAsync(IPublicIdService.Student, id, TenantId(), SchoolId());
            if (studentId == 0) return RedirectToAction("StudentList");

            var model = await _admissionService.GetStudentByIdAsync(studentId, TenantId(), SchoolId(), UserId());
            if (model == null) return RedirectToAction("StudentList");

            ViewBag.StudentPublicId = id;
            await FillEditDropdownsAsync(model.ClassName);
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

            if (!ModelState.IsValid)
            {
                ViewBag.StudentPublicId = id;
                await FillEditDropdownsAsync(model.ClassName);
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
                await FillEditDropdownsAsync(model.ClassName);
                return View(model);
            }

            TempData["SuccessMessage"] = message;
            return RedirectToAction("Dashboard", new { id });
        }

        // Class list + the sections that class actually has, for the edit form.
        private async Task FillEditDropdownsAsync(string? className)
        {
            try
            {
                ViewBag.ClassList = await _baseService.GetSelectListAsync(
                    "config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString());
            }
            catch { ViewBag.ClassList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }

            ViewBag.SectionList = string.IsNullOrWhiteSpace(className)
                ? new List<string>()
                : await _admissionService.GetClassSectionsAsync(className, TenantId(), SchoolId(), UserId());
        }
    }
}
