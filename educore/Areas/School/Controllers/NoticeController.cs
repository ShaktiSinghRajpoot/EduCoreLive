using educore.Services.Notifications;
using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using educore.Models;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.School.Controllers
{
    /// <summary>
    /// Notice Board (/notices). Every school user reads the live notices here
    /// and in the navbar bell; opening the board marks them read. Posting, editing
    /// and deleting need notices.manage (School Admin bypasses). Parents have no
    /// login, so a notice reaches them as a printed circular or a WhatsApp share.
    /// </summary>
    [Area("School")]
    [Authorize(Policy = "SchoolUserOnly")]
    public class NoticeController : Controller
    {
        private static readonly string[] Categories = { "General", "Circular", "Holiday", "Event", "PTM", "Exam", "Fee" };
        private static readonly string[] Audiences  = { "Everyone", "Staff", "Parents", "Classes" };

        private readonly INoticeService _notices;
        private readonly IBaseService _baseService;
        private readonly ISchoolSettingsService _settings;
        private readonly IStaffAttendanceService _att;

        public NoticeController(INoticeService notices, IBaseService baseService, ISchoolSettingsService settings,
                                IStaffAttendanceService att)
        {
            _notices = notices;
            _baseService = baseService;
            _settings = settings;
            _att = att;
        }

        [Route("notices")]
        public async Task<IActionResult> Index([FromServices] ModuleFlags modules, [FromServices] SchoolMessenger messenger)
        {
            ViewBag.CanManage = await CanManageAsync();
            ViewBag.WhatsAppOn = await messenger.IsOnAsync(TenantId(), SchoolId());   // "Send on WhatsApp" per notice
            ViewBag.WhatsAppTest = messenger.TestMode;
            ViewBag.Categories = await modules.ExamsOn() ? Categories : Categories.Where(c => c != "Exam").ToArray();
            return View();
        }

        // ── GET: /school/notice/List ── the board (managers also get expired notices)
        [HttpGet]
        public async Task<IActionResult> List()
        {
            bool canManage = await CanManageAsync();
            var rows = canManage
                ? await _notices.GetAllAsync(TenantId(), SchoolId(), UserId())
                : await _notices.GetBoardAsync(TenantId(), SchoolId(), UserId());

            // Opening the board is reading it. The rows above still carry the old
            // flags, so this load can show "New" on what was unread.
            if (rows.Any(r => !r.IsRead))
                await _notices.MarkReadAsync(null, TenantId(), SchoolId(), UserId());

            var today = Dates.Today;
            return Json(rows.Select(r => new
            {
                id       = r.Id,
                title    = r.Title,
                body     = r.Body,
                category = r.Category,
                audience = r.Audience,
                audienceText = r.AudienceText,
                classes  = r.ClassNames,
                pinned   = r.IsPinned,
                until    = r.ShowUntil,
                expired  = r.ShowUntil != null && string.CompareOrdinal(r.ShowUntil, today) < 0,
                posted   = r.CreatedAt?.ToString("dd MMM yyyy, hh:mm tt"),
                by       = r.PostedBy,
                isNew    = !r.IsRead,
                seen     = r.SeenCount,
                staff    = r.StaffCount
            }));
        }

        // ── GET: /school/notice/Latest ── navbar bell: newest 5 and the unread count
        [HttpGet]
        public async Task<IActionResult> Latest()
        {
            var rows = await _notices.GetBoardAsync(TenantId(), SchoolId(), UserId());

            // Periods this teacher covers for an absent colleague, from today on, come
            // first in the bell (QA BUG-116). The bell must never fail over them.
            var covers = new List<object>();
            try
            {
                foreach (var x in (await _att.GetMySubstitutionsAsync(TenantId(), SchoolId(), UserId())).Take(5))
                    covers.Add(new
                    {
                        title    = "Cover " + (x.PeriodLabel ?? "slot " + x.PeriodSeq) + " — " + x.SectionLabel
                                   + (string.IsNullOrWhiteSpace(x.SubjectName) ? "" : " · " + x.SubjectName),
                        category = "Substitute" + (string.IsNullOrWhiteSpace(x.OriginalName) ? "" : " for " + x.OriginalName),
                        posted   = x.DayLabel,
                        isNew    = true,
                        url      = Url.Action("Index", "MyTimetable", new { area = "Academics" })
                    });
            }
            catch { /* no staff record, or the module is off: just the notices */ }

            var notices = rows.OrderByDescending(r => r.CreatedAt).Take(5).Select(r => (object)new
            {
                title    = r.Title,
                category = r.Category,
                posted   = r.CreatedAt?.ToString("dd MMM"),
                isNew    = !r.IsRead,
                url      = (string?)null
            });
            return Json(new
            {
                unread = rows.Count(r => !r.IsRead) + covers.Count,
                items  = covers.Concat(notices)
            });
        }

        // ── GET: /school/notice/Classes ── class names for the "Selected classes" audience
        [HttpGet]
        public async Task<IActionResult> Classes()
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString());
            return Json(items.Select(x => x.Text).Where(t => !string.IsNullOrWhiteSpace(t)).Distinct().ToList());
        }

        [HttpGet]
        public async Task<IActionResult> SeenBy(int id)
        {
            var rows = await _notices.GetSeenByAsync(id, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(r => new { name = r.Name, at = r.ReadAt?.ToString("dd MMM, hh:mm tt") }));
        }

        // A notice to parents on WhatsApp: the parents of the notice's audience (everyone /
        // parents = every current student; classes = those classes). A number shared by
        // brothers and sisters gets the notice once. Staff-only notices are not sent.
        [HttpPost]
        [HasPermission("notices.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SendWhatsApp(int id, [FromServices] SchoolMessenger messenger,
                                                      [FromServices] IAdmissionService admissions)
        {
            if (!await messenger.IsOnAsync(TenantId(), SchoolId()))
                return Json(new { success = false, message = "WhatsApp is not switched on for this school." });
            var n = (await _notices.GetAllAsync(TenantId(), SchoolId(), UserId())).FirstOrDefault(x => x.Id == id);
            if (n == null) return Json(new { success = false, message = "Notice not found." });
            if (n.Audience == "Staff") return Json(new { success = false, message = "This notice is for staff only, so it is not sent to parents." });

            string? current = null;
            try { current = (await _settings.GetAcademicYearsAsync(TenantId(), SchoolId(), UserId())).FirstOrDefault(y => y.IsCurrent)?.AcademicYearName; }
            catch { /* every active student */ }
            var (students, _) = await admissions.GetStudentsAsync(TenantId(), SchoolId(), UserId(), pageNumber: 1, pageSize: 5000,
                                                                  filterYear: current, filterStatus: "Active");
            var classes = (n.ClassNames ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                                               .ToHashSet(StringComparer.OrdinalIgnoreCase);
            var to = students.Where(st => n.Audience != "Classes" || classes.Contains(st.ClassName))
                             .GroupBy(st => WhatsAppChannel.ToWhatsAppNumber(st.Mobile) ?? "none-" + st.StudentId)   // one message per number
                             .Select(g => g.First()).ToList();
            if (to.Count == 0) return Json(new { success = false, message = "No parents to send to." });

            string schoolName = "";
            try { schoolName = (await _settings.GetBasicProfileAsync(TenantId(), SchoolId(), UserId()))?.SchoolName ?? ""; }
            catch { }

            var counts = new Dictionary<string, int>();
            foreach (var st in to)
            {
                var status = await messenger.SendAsync(TenantId(), SchoolId(), UserId(), SchoolMessenger.Notice,
                    st.StudentId, st.GuardianName ?? st.StudentName, st.Mobile, new[] { schoolName, n.Title, n.Body });
                counts[status] = counts.GetValueOrDefault(status) + 1;
            }
            string Part(string k, string label) => counts.GetValueOrDefault(k) > 0 ? $"{counts[k]} {label}" : "";
            var msg = string.Join(", ", new[] { Part("Sent", "sent"), Part("Test", "recorded in test mode (WhatsApp account not connected yet)"),
                                               Part("Failed", "failed"), Part("NoPhone", "with no mobile number") }.Where(x => x != ""));
            return Json(new { success = counts.GetValueOrDefault("Sent") + counts.GetValueOrDefault("Test") > 0, message = "Notice on WhatsApp: " + msg + "." });
        }

        [HttpPost]
        [HasPermission("notices.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save([FromBody] NoticeRequest req)
        {
            if (req == null)
                return Json(new { success = false, message = "Invalid request." });

            var n = new Notice
            {
                Id         = req.Id ?? 0,
                Title      = (req.Title ?? "").Trim(),
                Body       = (req.Body ?? "").Trim(),
                Category   = Categories.Contains(req.Category) ? req.Category! : "General",
                Audience   = Audiences.Contains(req.Audience) ? req.Audience! : "Everyone",
                ClassNames = req.Classes == null ? null : string.Join(",", req.Classes.Where(c => !string.IsNullOrWhiteSpace(c)).Select(c => c.Trim())),
                IsPinned   = req.Pinned,
                ShowUntil  = string.IsNullOrWhiteSpace(req.Until) ? null : Dates.Norm(req.Until)
            };
            var (ok, msg) = await _notices.SaveAsync(n, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("notices.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Delete(int id)
        {
            var (ok, msg) = await _notices.DeleteAsync(id, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        // ── GET: /school/notice/Print/5 ── the notice as a circular on the school letterhead
        [HttpGet]
        public async Task<IActionResult> Print(int id)
        {
            var n = await _notices.GetAsync(id, TenantId(), SchoolId(), UserId());
            if (n == null) return NotFound();

            var school = await _settings.GetBasicProfileAsync(TenantId(), SchoolId(), UserId())
                         ?? new SchoolManageModel { SchoolName = "Your School" };
            ViewBag.School = school;
            ViewBag.Logo = AbsoluteLogo(school.LogoUrl);
            return View(n);
        }

        public class NoticeRequest
        {
            public int?      Id       { get; set; }
            public string?   Title    { get; set; }
            public string?   Body     { get; set; }
            public string?   Category { get; set; }
            public string?   Audience { get; set; }
            public string[]? Classes  { get; set; }
            public bool      Pinned   { get; set; }
            public string?   Until    { get; set; }
        }

        private Task<bool> CanManageAsync() => HasPermissionAttribute.UserHasAsync(this, "notices.manage");

        private string? AbsoluteLogo(string? logoUrl)
        {
            if (string.IsNullOrWhiteSpace(logoUrl)) return null;
            if (logoUrl.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return logoUrl;
            var slash = logoUrl.StartsWith('/') ? "" : "/";
            return $"{Request.Scheme}://{Request.Host}{slash}{logoUrl}";
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
