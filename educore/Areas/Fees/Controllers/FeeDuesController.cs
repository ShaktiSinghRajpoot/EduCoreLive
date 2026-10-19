using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Fees.Controllers
{
    /// <summary>
    /// Month-wise Dues (/fees/dues): what is still unpaid month by month, class by
    /// class and child by child, with a warning on children who look like they have
    /// left the school (no attendance for three weeks while their class's register
    /// was kept). fee_month_dues.sql.
    /// </summary>
    [Area("Fees")]
    [RequiresModule(SchoolModule.Fees)]
    [HasPermission("fees.view")]
    public class FeeDuesController : Controller
    {
        private readonly IFeeMonthDuesService _dues;

        public FeeDuesController(IFeeMonthDuesService dues)
        {
            _dues = dues;
        }

        [Route("fees/dues")]
        public async Task<IActionResult> Index([FromServices] IBaseService baseService, [FromServices] ISchoolSettingsService settings)
        {
            // the reminder letter's letterhead (the same header a fee receipt prints)
            try
            {
                var school = await settings.GetBasicProfileAsync(TenantId(), SchoolId(), UserId());
                ViewBag.SchoolName    = school?.SchoolName ?? "";
                ViewBag.SchoolAddress = string.Join(", ", new[] { school?.AddressLine1, school?.City, school?.State }
                                                         .Where(p => !string.IsNullOrWhiteSpace(p)));
                var logo = school?.LogoUrl;
                ViewBag.SchoolLogo = string.IsNullOrWhiteSpace(logo) ? ""
                    : logo.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? logo
                    : $"{Request.Scheme}://{Request.Host}{(logo.StartsWith('/') ? "" : "/")}{logo}";
            }
            catch { ViewBag.SchoolName = ""; ViewBag.SchoolAddress = ""; ViewBag.SchoolLogo = ""; }
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "fees.manage");
            try { ViewBag.ClassList = await baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.ClassList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }
            try { ViewBag.YearList = await baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.YearList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }
            ViewBag.CanCollect = await HasPermissionAttribute.UserHasAsync(this, "fees.collect");
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> Data(string? year, string? from, string? upto, string? cls, string? sec)
        {
            if (string.IsNullOrWhiteSpace(year)) return Json(new { success = false, message = "Choose the session." });
            if (!string.IsNullOrWhiteSpace(from) && !string.IsNullOrWhiteSpace(upto) && string.CompareOrdinal(from, upto) > 0)
                return Json(new { success = false, message = "The \"from\" month is after the \"to\" month." });
            var d = await _dues.GetAsync(year, from, upto, cls, sec, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success  = true,
                months   = d.Months.Select(m => new { month = m.Month, due = m.Due, collected = m.Collected, pending = m.Pending, children = m.Children }),
                classes  = d.Classes.Select(c => new { cls = c.ClassName, sec = c.Section, children = c.Children, withDues = c.WithDues, pending = c.Pending }),
                students = d.Students.Select(s => new
                {
                    id = s.StudentId, publicId = s.PublicId, name = s.StudentName, admNo = s.AdmissionNo,
                    father = s.GuardianName, mobile = s.Mobile, cls = s.ClassName, sec = s.Section, roll = s.RollNo,
                    status = s.Status, pending = s.Pending, monthsCount = s.MonthsCount, months = s.Months,
                    oldest = s.OldestMonth, lastPaid = s.LastPayment, lastPresent = s.LastPresent,
                    classDays = s.ClassDays, presentDays = s.PresentDays, mayHaveLeft = s.MayHaveLeft,
                    lateFee = s.LateFee, lastReminded = s.LastReminded, note = s.FollowupNote, promise = s.PromiseDate,
                    noChase = s.NoChase, onHold = s.OnHold
                })
            });
        }

        // One child's attendance for the "may have left" warning.
        [HttpGet]
        public async Task<IActionResult> Attendance(int id, string? year)
        {
            var a = await _dues.GetAttendanceAsync(id, year ?? "", TenantId(), SchoolId(), UserId());
            if (a == null) return Json(new { success = false, message = "Student not found." });
            return Json(new
            {
                success = true, name = a.StudentName, lastPresent = a.LastPresent, lastMarked = a.LastMarked,
                streak = a.AbsentStreak, marked = a.Marked, present = a.Present,
                months = a.Months.Select(m => new { month = m.Month, present = m.Present, absent = m.Absent, leave = m.OnLeave })
            });
        }

        // ── follow-up notes ("father will pay on the 25th") ──
        [HttpGet]
        public async Task<IActionResult> Followups(int id)
        {
            var list = await _dues.GetFollowupsAsync(id, TenantId(), SchoolId(), UserId());
            return Json(list.Select(f => new { id = f.FollowupId, note = f.Note, promise = f.PromiseDate, done = f.IsDone, on = f.CreatedOn, by = f.CreatedBy }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("fees.collect")]
        public async Task<IActionResult> AddFollowup([FromBody] FollowupRequest req)
        {
            var r = await _dues.AddFollowupAsync(req?.StudentId ?? 0, req?.Note ?? "", req?.PromiseDate, TenantId(), SchoolId(), UserId());
            return Json(new { success = r.Success, message = r.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("fees.collect")]
        public async Task<IActionResult> FollowupDone([FromBody] IdRequest req)
        {
            var r = await _dues.FollowupDoneAsync(req?.Id ?? 0, TenantId(), SchoolId(), UserId());
            return Json(new { success = r.Success, message = r.Message });
        }

        // ── don't chase (scholarship, RTE seat, promise) ──
        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("fees.manage")]
        public async Task<IActionResult> NoChase([FromBody] NoChaseRequest req)
        {
            var r = await _dues.SetNoChaseAsync(req?.StudentId ?? 0, req?.Reason, req?.Until, req?.On ?? false, TenantId(), SchoolId(), UserId());
            return Json(new { success = r.Success, message = r.Message });
        }

        // ── the school's late fee and hold rule ──
        [HttpGet]
        public async Task<IActionResult> Settings()
        {
            var s = await _dues.GetSettingsAsync(TenantId(), SchoolId(), UserId());
            return Json(new { lateFee = s.LateFeeAmount, graceDays = s.GraceDays, holdMonths = s.HoldMonths });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("fees.manage")]
        public async Task<IActionResult> SaveSettings([FromBody] EduCoreDataAccessLayer.Models.ERP.FeeDuesSettings req)
        {
            if (req == null) return Json(new { success = false, message = "Nothing to save." });
            var r = await _dues.SaveSettingsAsync(req, TenantId(), SchoolId(), UserId());
            return Json(new { success = r.Success, message = r.Message });
        }

        // ── late fee: preview, then apply ──
        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("fees.manage")]
        public async Task<IActionResult> LateFeePreview([FromBody] LateFeeRequest req)
        {
            if (string.IsNullOrWhiteSpace(req?.Year)) return Json(new { success = false, message = "Choose the session." });
            var settings = await _dues.GetSettingsAsync(TenantId(), SchoolId(), UserId());
            if (settings.LateFeeAmount <= 0)
                return Json(new { success = false, message = "Set the late fee first (Settings on this page)." });
            var lines = await _dues.PreviewLateFeesAsync(req.Year!, req.StudentIds, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success = true, amount = settings.LateFeeAmount, graceDays = settings.GraceDays,
                lines = lines.Select(l => new { id = l.StudentId, name = l.StudentName, cls = l.ClassName, sec = l.Section, month = l.Month, amount = l.Amount })
            });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("fees.manage")]
        public async Task<IActionResult> LateFeeApply([FromBody] LateFeeRequest req)
        {
            if (string.IsNullOrWhiteSpace(req?.Year)) return Json(new { success = false, message = "Choose the session." });
            var r = await _dues.ApplyLateFeesAsync(req.Year!, req.StudentIds, TenantId(), SchoolId(), UserId());
            return Json(new { success = r.Success, message = r.Message, added = r.Count });
        }

        public class IdRequest       { public int Id { get; set; } }
        public class FollowupRequest { public int StudentId { get; set; } public string? Note { get; set; } public string? PromiseDate { get; set; } }
        public class NoChaseRequest  { public int StudentId { get; set; } public string? Reason { get; set; } public string? Until { get; set; } public bool On { get; set; } }
        public class LateFeeRequest  { public string? Year { get; set; } public List<int>? StudentIds { get; set; } }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
