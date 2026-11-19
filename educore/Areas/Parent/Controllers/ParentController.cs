using System.Globalization;
using educore.Areas.Parent.Models;
using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace educore.Areas.Parent.Controllers
{
    /// <summary>
    /// The parent pages (Phase 1, view only). Rules that must hold:
    ///   - The child comes ONLY from the parent's own linked list, read again on every
    ///     request (core.sp_parent_children). Any other id is 404, never 500 (PT-09/10).
    ///     An empty list (number removed, blocked, Parent App taken away, school
    ///     inactive) signs the parent out at once (PT-12, PT-20).
    ///   - Every read uses the child's own tenant and school ids.
    ///   - A screen whose module is not in the plan, or that the school turned off for
    ///     parents, is refused here as well as hidden (PT-21/22): ParentScreens.Refusal.
    ///   - Reused staff services are called with actionUserId 0 (a parent has no user);
    ///     the procs they call check tenant/school only. Nothing from them reaches the
    ///     page unfiltered: staff names on receipts, cancel reasons, other children.
    /// </summary>
    [Area("Parent")]
    [Authorize(AuthenticationSchemes = ParentAuth.Scheme, Policy = ParentAuth.Policy)]
    public class ParentController : Controller
    {
        private const int NoUser = 0;

        private readonly IParentService _parents;
        private readonly IFeePaymentService _fees;
        private readonly IAttendanceService _attendance;
        private readonly IExamService _exams;
        private readonly IHomeworkService _homework;
        private readonly ITimetableService _timetable;
        private readonly ISchoolCalendarService _calendar;
        private readonly ISchoolSettingsService _settings;
        private readonly IConfiguration _config;
        private readonly IWebHostEnvironment _env;
        private readonly ILogger<ParentController> _logger;

        private List<ParentChild> _children = new();

        public ParentController(IParentService parents, IFeePaymentService fees, IAttendanceService attendance,
                                IExamService exams, IHomeworkService homework, ITimetableService timetable,
                                ISchoolCalendarService calendar, ISchoolSettingsService settings,
                                IConfiguration config, IWebHostEnvironment env, ILogger<ParentController> logger)
        {
            _parents = parents;
            _fees = fees;
            _attendance = attendance;
            _exams = exams;
            _homework = homework;
            _timetable = timetable;
            _calendar = calendar;
            _settings = settings;
            _config = config;
            _env = env;
            _logger = logger;
        }

        private string Mobile => ParentAuth.Mobile(User);

        // Runs before every action: who may this parent see right now?
        public override async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
        {
            _children = await _parents.GetChildrenAsync(Mobile);
            if (_children.Count == 0)
            {
                await HttpContext.SignOutAsync(ParentAuth.Scheme);
                TempData["ParentMessage"] = "You have been signed out: parent access is no longer available for this number. Please contact the school.";
                context.Result = RedirectToAction("Login", "ParentAccount");
                return;
            }
            ViewBag.Children = _children;
            await next();
        }

        /// <summary>The child asked for, from the parent's own list; the first child when none is asked for.</summary>
        private ParentChild? Pick(int? c) =>
            c is int id ? _children.FirstOrDefault(x => x.StudentId == id) : _children.FirstOrDefault();

        /// <summary>Null when the screen may open; otherwise the 404 / refusal to return.</summary>
        private IActionResult? Gate(ParentChild? child, string screen)
        {
            if (child == null)
            {
                Response.StatusCode = StatusCodes.Status404NotFound;
                return View("Refused", "This page was not found.");
            }
            ViewBag.Child = child;
            ViewBag.Screen = screen;

            var refusal = ParentScreens.Refusal(child, screen);
            if (refusal == null) return null;

            Response.StatusCode = StatusCodes.Status403Forbidden;
            return View("Refused", refusal);
        }

        [HttpGet("parent")]
        [HttpGet("parent/home")]
        public IActionResult Home(int? c)
        {
            var child = Pick(c);
            return Gate(child, "home") ?? View(child);
        }

        [HttpGet("parent/attendance")]
        public async Task<IActionResult> Attendance(int? c, int? m, int? y)
        {
            var child = Pick(c);
            var refused = Gate(child, "attendance");
            if (refused != null) return refused;

            var now = Dates.Now;
            int month = m is >= 1 and <= 12 ? m.Value : now.Month;
            int year  = y is >= 2000 and <= 2100 ? y.Value : now.Year;

            // The same proc as the student's Attendance tab and the register (BUG-037).
            var summary = await _attendance.GetStudentAttendanceAsync(child!.StudentId, child.TenantId, child.SchoolId,
                                                                      NoUser, child.AcademicYear, month, year);
            var page = new ParentAttendancePage { Month = month, Year = year, Summary = summary };
            if (month == now.Month && year == now.Year && summary.Days.TryGetValue(now.Day, out var mark))
                page.TodayMark = mark;

            var from = new DateTime(year, month, 1);
            var cal = await _calendar.GetCalendarAsync(from, from.AddMonths(1).AddDays(-1), child.TenantId, child.SchoolId, NoUser);
            page.WeeklyOffDays = cal.WeeklyOffDays;
            foreach (var e in cal.Entries.Where(e => e.DayType == "holiday"))
                if (DateTime.TryParseExact(e.Date, Dates.Iso, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
                    page.Holidays[d.Day] = e.Title;

            return View(page);
        }

        [HttpGet("parent/fees")]
        public async Task<IActionResult> Fees(int? c)
        {
            var child = Pick(c);
            var refused = Gate(child, "fees");
            if (refused != null) return refused;

            // The same open ledger lines Collect Fees uses (core.sp_student_dues_get),
            // older sessions' unpaid lines included.
            var dues = await _fees.GetStudentDuesAsync(child!.StudentId, child.TenantId, child.SchoolId, NoUser);
            string today = Dates.Today;
            var page = new ParentFeesPage();

            foreach (var d in dues.Where(d => d.Outstanding > 0))
            {
                bool dueNow = string.IsNullOrWhiteSpace(d.DueDate) || string.CompareOrdinal(d.DueDate, today) <= 0;
                if (dueNow) page.DueNow += d.Outstanding; else page.Later += d.Outstanding;

                string? old = !string.IsNullOrWhiteSpace(d.CarriedFrom) ? d.CarriedFrom
                            : (!string.IsNullOrWhiteSpace(d.AcademicYear) && !string.IsNullOrWhiteSpace(child.AcademicYear)
                               && string.CompareOrdinal(d.AcademicYear, child.AcademicYear) < 0) ? d.AcademicYear : null;

                var date = Dates.Parse(d.DueDate);
                string label = date == null ? "No due date" : date.Value.ToString("MMM yyyy", CultureInfo.InvariantCulture);
                var group = page.Months.FirstOrDefault(x => x.Label == label);
                if (group == null)
                {
                    group = new ParentFeeMonth { Label = label };
                    page.Months.Add(group);
                }
                group.Lines.Add(new ParentFeeLine
                {
                    Head        = string.IsNullOrWhiteSpace(d.InstallmentLabel) ? d.FeeHeadName : $"{d.FeeHeadName} – {d.InstallmentLabel}",
                    DueDate     = d.DueDate,
                    Outstanding = d.Outstanding,
                    Overdue     = !string.IsNullOrWhiteSpace(d.DueDate) && string.CompareOrdinal(d.DueDate, today) < 0,
                    OldSession  = old == null ? null : $"Dues of {old}"
                });
            }
            return View(page);
        }

        [HttpGet("parent/receipts")]
        public async Task<IActionResult> Receipts(int? c)
        {
            var child = Pick(c);
            var refused = Gate(child, "receipts");
            if (refused != null) return refused;

            var history = await _fees.GetPaymentHistoryAsync(child!.StudentId, child.TenantId, child.SchoolId, NoUser);
            var rows = history.Select(h => new ParentReceiptRow
            {
                ReceiptNo   = h.ReceiptNo,
                Date        = h.PaymentDate,
                Amount      = h.Amount,
                Mode        = h.PaymentMode,
                IsCancelled = h.IsCancelled
            }).ToList();
            return View(rows);
        }

        [HttpGet("parent/receipt")]
        public async Task<IActionResult> Receipt(int? c, string? no)
        {
            var child = Pick(c);
            var refused = Gate(child, "receipts");
            if (refused != null) return refused;

            FeeReceipt? receipt = null;
            if (!string.IsNullOrWhiteSpace(no))
            {
                try { receipt = await _fees.GetReceiptAsync(no, child!.TenantId, child.SchoolId, NoUser); }
                catch (Exception ex) { _logger.LogWarning(ex, "Parent receipt {ReceiptNo} not read", no); }
            }
            // Another child's receipt (or none) is simply not found.
            if (receipt == null || receipt.StudentId != child!.StudentId)
            {
                Response.StatusCode = StatusCodes.Status404NotFound;
                return View("Refused", "This receipt was not found.");
            }

            await LogViewAsync(child, "RECEIPT_VIEW", receipt.ReceiptNo);
            return View(new ParentReceiptPage { School = await HeaderAsync(child), Receipt = receipt });
        }

        [HttpGet("parent/results")]
        public async Task<IActionResult> Results(int? c, int? exam)
        {
            var child = Pick(c);
            var refused = Gate(child, "results");
            if (refused != null) return refused;
            return View(await ResultAsync(child!, exam));
        }

        [HttpGet("parent/report-card")]
        public async Task<IActionResult> ReportCard(int? c, int? exam)
        {
            var child = Pick(c);
            var refused = Gate(child, "results");
            if (refused != null) return refused;

            var page = await ResultAsync(child!, exam);
            if (page.ExamId == 0)
            {
                Response.StatusCode = StatusCodes.Status404NotFound;
                return View("Refused", "No published result was found.");
            }
            page.School = await HeaderAsync(child!);
            await LogViewAsync(child!, "REPORT_CARD_VIEW", page.ExamName);
            return View(page);
        }

        // Published exams only: core.sp_exam_result_student never returns an exam whose
        // results are not published (PT-18), even when its id is asked for.
        private async Task<ParentResultsPage> ResultAsync(ParentChild child, int? exam)
        {
            var result = await _exams.GetStudentResultAsync(child.StudentId, child.TenantId, child.SchoolId, NoUser, exam);
            var page = new ParentResultsPage { Result = result };
            bool hasMarks = result.Subjects.Count > 0;
            var shown = exam is int id ? result.Exams.FirstOrDefault(e => e.ExamId == id) : result.Exams.FirstOrDefault();
            if (shown != null && hasMarks)
            {
                page.ExamId = shown.ExamId;
                page.ExamName = shown.ExamName;
            }
            return page;
        }

        [HttpGet("parent/homework")]
        public async Task<IActionResult> Homework(int? c)
        {
            var child = Pick(c);
            var refused = Gate(child, "homework");
            if (refused != null) return refused;

            var list = await _homework.GetForStudentAsync(child!.StudentId, child.TenantId, child.SchoolId, NoUser);
            return View(list);
        }

        [HttpGet("parent/timetable")]
        public async Task<IActionResult> Timetable(int? c)
        {
            var child = Pick(c);
            var refused = Gate(child, "timetable");
            if (refused != null) return refused;

            var page = new ParentTimetablePage();
            if (child!.SectionId > 0)
            {
                var grid = await _timetable.GetGridAsync(child.SectionId, child.TenantId, child.SchoolId, NoUser);
                page.Entries = grid.Entries;   // only this section's slots; the other lists are not used
                var setup = await _timetable.GetSetupAsync(child.TenantId, child.SchoolId, NoUser);
                page.Periods = setup.Periods;
            }
            return View(page);
        }

        [HttpGet("parent/notices")]
        public async Task<IActionResult> Notices(int? c)
        {
            var child = Pick(c);
            var refused = Gate(child, "notices");
            if (refused != null) return refused;

            var page = new ParentNoticesPage
            {
                Notices = await _parents.GetNoticesAsync(child!.TenantId, child.SchoolId, child.ClassName)
            };
            var from = Dates.Now.Date;
            var to = from.AddDays(60);
            page.Events = await _calendar.GetEventsAsync(from.ToString(Dates.Iso), to.ToString(Dates.Iso),
                                                         child.TenantId, child.SchoolId, NoUser);
            // Exams appear on the school calendar too; parents see only published ones of
            // the child's own class (ForWhom holds the exam's classes).
            page.Events = page.Events.Where(e => e.Kind != "Exam"
                || (e.Status == "Published"
                    && (string.IsNullOrWhiteSpace(e.ForWhom)
                        || e.ForWhom.Split(',').Any(x => string.Equals(x.Trim(), child.ClassName, StringComparison.OrdinalIgnoreCase)))))
                .ToList();
            var cal = await _calendar.GetCalendarAsync(from, to, child.TenantId, child.SchoolId, NoUser);
            page.Holidays = cal.Entries.Where(e => e.DayType != "working").OrderBy(e => e.Date).ToList();
            return View(page);
        }

        /// <summary>The child's photo. /uploads is for signed-in staff only, so the parent gets it from here.</summary>
        [HttpGet("parent/photo")]
        public IActionResult Photo(int? c)
        {
            var child = Pick(c);
            if (child == null || string.IsNullOrWhiteSpace(child.PhotoUrl))
                return NotFound();

            // /uploads/{kind}/{tenant}/{school}/{file}: only a file of the child's own school.
            var parts = child.PhotoUrl.Split('?')[0].Trim('/').Split('/');
            if (parts.Length < 5 || !parts[0].Equals("uploads", StringComparison.OrdinalIgnoreCase)
                || parts[2] != child.TenantId.ToString() || parts[3] != child.SchoolId.ToString())
                return NotFound();

            var root = Path.GetFullPath(UploadPaths.Root(_config, _env));
            var file = Path.GetFullPath(Path.Combine(root, Path.Combine(parts.Skip(1).ToArray())));
            if (!file.StartsWith(root, StringComparison.OrdinalIgnoreCase) || !System.IO.File.Exists(file))
                return NotFound();

            string type = Path.GetExtension(file).ToLowerInvariant() switch
            {
                ".png"  => "image/png",
                ".webp" => "image/webp",
                ".gif"  => "image/gif",
                _       => "image/jpeg"
            };
            return PhysicalFile(file, type);
        }

        private async Task<ParentPrintHeader> HeaderAsync(ParentChild child)
        {
            var header = new ParentPrintHeader { SchoolName = child.SchoolName };
            try
            {
                var profile = await _settings.GetBasicProfileAsync(child.TenantId, child.SchoolId, NoUser);
                if (!string.IsNullOrWhiteSpace(profile?.SchoolName)) header.SchoolName = profile.SchoolName.Trim();
                header.Address = string.Join(", ", new[] { profile?.AddressLine1, profile?.City, profile?.State }
                    .Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => p!.Trim()));
            }
            catch (Exception ex) { _logger.LogWarning(ex, "School header not read for parent print"); }
            return header;
        }

        private async Task LogViewAsync(ParentChild child, string action, string? detail)
        {
            try { await _parents.LogAsync(child.TenantId, child.SchoolId, child.StudentId, Mobile, action, detail); }
            catch (Exception ex) { _logger.LogWarning(ex, "Parent {Action} not logged", action); }
        }
    }
}
