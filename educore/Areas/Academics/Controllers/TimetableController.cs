using educore.Areas.School.Controllers;   // the timetable / period payload classes still live beside SchoolSettingsController
using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Academics.Controllers
{
    /// <summary>
    /// Timetable, Period Structure and Smart Bell. Moved here out of
    /// SchoolSettingsController, unchanged.
    /// </summary>
    [Area("Academics")]
    [RequiresModule(SchoolModule.Academics)]
    public class TimetableController : Controller
    {
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly ISchoolCalendarService _schoolCalendarService;
        private readonly ITimetableService _timetableService;
        private readonly IBaseService _baseService;

        public TimetableController(ISchoolSettingsService schoolSettingsService, ISchoolCalendarService schoolCalendarService, ITimetableService timetableService, IBaseService baseService)
        {
            _baseService = baseService;
            _schoolSettingsService = schoolSettingsService;
            _schoolCalendarService = schoolCalendarService;
            _timetableService = timetableService;
        }

        private int SmTenant() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SmSchool() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int SmUser()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // the session picker: the asked session, or the current one (same as in SchoolSettingsController)
        private async Task<int> ResolveSessionAsync(int academicYearId)
        {
            var years = await _baseService.GetSelectListAsync(
                "config.sp_dropdown_common", "AcademicYear", SmTenant().ToString(), SmSchool().ToString());

            if (academicYearId <= 0 && years.Any())
            {
                var current = years.FirstOrDefault(y => y.Selected) ?? years.First();
                int.TryParse(current.Value, out academicYearId);
            }

            ViewBag.AcademicYears  = years;
            ViewBag.AcademicYearId = academicYearId;
            return academicYearId;
        }

        #region Timetable
        // The weekly grid. Periods come from Period Structure, day columns from the
        // School Calendar's weekly offs, sections/subjects/teachers from their own
        // masters — the page holds no data of its own.
        [HasPermission("academics.view")]
        [Route("academics/timetable")]
        public async Task<IActionResult> Timetable(int academicYearId = 0)
        {
            // Sections are per session, so the grid belongs to one.
            await ResolveSessionAsync(academicYearId);
            // Add / edit / delete buttons are shown only with academics.manage
            // (a teacher has academics.view and would be refused on save).
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "academics.manage");
            return View();
        }

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> TimetableSetup(int academicYearId = 0)
        {
            var setup = await _timetableService.GetSetupAsync(
                SmTenant(), SmSchool(), SmUser(), academicYearId);
            return Json(setup);
        }

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> TimetableGrid(int sectionId)
        {
            var grid = await _timetableService.GetGridAsync(sectionId, SmTenant(), SmSchool(), SmUser());
            return Json(grid);
        }

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> TimetableTeacherGrid(int staffId)
        {
            var rows = await _timetableService.GetTeacherGridAsync(staffId, SmTenant(), SmSchool(), SmUser());
            return Json(rows);
        }

        public class TimetableCellDto
        {
            public int     SectionId { get; set; }
            public int     Day       { get; set; }
            public int     PeriodSeq { get; set; }
            public int     SubjectId { get; set; }
            public int?    StaffId   { get; set; }
            public string? Room      { get; set; }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> SaveTimetableCell([FromBody] TimetableCellDto dto)
        {
            var result = await _timetableService.SaveCellAsync(
                dto?.SectionId ?? 0, dto?.Day ?? 0, dto?.PeriodSeq ?? 0,
                dto?.SubjectId ?? 0, dto?.StaffId, dto?.Room,
                SmTenant(), SmSchool(), SmUser());

            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> ClearTimetableCell([FromBody] TimetableCellDto dto)
        {
            var result = await _timetableService.ClearCellAsync(
                dto?.SectionId ?? 0, dto?.Day ?? 0, dto?.PeriodSeq ?? 0, SmTenant(), SmSchool(), SmUser());

            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> CopyTimetableDay([FromBody] TimetableCellDto dto)
        {
            var result = await _timetableService.CopyDayAsync(
                dto?.SectionId ?? 0, dto?.Day ?? 0, SmTenant(), SmSchool(), SmUser());

            return Json(new { success = result.Success, message = result.Message, copied = result.Copied, skipped = result.Skipped });
        }

        // ── School view: one day, every section, with the teachers' requests in their cells ──

        [HasPermission("academics.view")]
        [Route("academics/timetable/school")]
        public async Task<IActionResult> TimetableSchool(int academicYearId = 0)
        {
            await ResolveSessionAsync(academicYearId);
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "academics.manage");
            return View();
        }

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> TimetableSchoolData(int academicYearId = 0)
        {
            var setup   = await _timetableService.GetSetupAsync(SmTenant(), SmSchool(), SmUser(), academicYearId);
            var entries = await _timetableService.GetSchoolViewAsync(SmTenant(), SmSchool(), SmUser(), academicYearId);
            // Requests are only shown to those who can approve them.
            var pending = await HasPermissionAttribute.UserHasAsync(this, "academics.manage")
                ? await _timetableService.GetPendingRequestsAsync(SmTenant(), SmSchool(), SmUser())
                : new List<TimetableRequestRow>();

            return Json(new
            {
                days     = setup.Days.Select(d => new { day = d.DayOfWeek, label = d.DayLabel }),
                periods  = setup.Periods.Select(x => new { day = x.DayOfWeek, seq = x.PeriodSeq, label = x.Label, type = x.PeriodType,
                                                          time = x.StartTime + "–" + x.EndTime }),
                sections = setup.Sections.Select(x => new { id = x.SectionId, cls = x.ClassName, sec = x.SectionName, label = x.Label }),
                teachers = setup.Teachers.Select(x => new { id = x.StaffId, name = x.FullName }),
                entries  = entries.Select(e => new { sec = e.SectionId, day = e.DayOfWeek, seq = e.PeriodSeq,
                                                     subjectId = e.SubjectId, subject = e.SubjectName, staffId = e.StaffId, staff = e.StaffName }),
                pending  = pending.Select(r => new { id = r.RequestId, sec = r.SectionId, day = r.DayOfWeek, seq = r.PeriodSeq,
                                                     subject = r.SubjectName, teacher = r.TeacherName })
            });
        }

        // ── Teachers' period requests (they ask on My Timetable, an admin decides here) ──

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> TimetableRequests()
        {
            var rows = await _timetableService.GetPendingRequestsAsync(SmTenant(), SmSchool(), SmUser());
            return Json(rows.Select(r => new
            {
                id = r.RequestId, day = r.DayOfWeek, seq = r.PeriodSeq, period = r.PeriodLabel, section = r.SectionLabel,
                subject = r.SubjectName, teacher = r.TeacherName, liveNow = r.LiveNow, at = r.RequestedAt
            }));
        }

        public class TimetableRequestDto
        {
            public int     RequestId { get; set; }
            public string? Reason    { get; set; }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> ApproveTimetableRequest([FromBody] TimetableRequestDto dto)
        {
            var result = await _timetableService.ApproveRequestAsync(dto?.RequestId ?? 0, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> RejectTimetableRequest([FromBody] TimetableRequestDto dto)
        {
            var result = await _timetableService.RejectRequestAsync(dto?.RequestId ?? 0, dto?.Reason, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = result.Success, message = result.Message });
        }
        #endregion

        #region PeriodStructure
        // The daily bell schedule: a default schedule plus an optional custom one
        // per weekday (e.g. a short Saturday). Every schedule seeds the page; Save
        // posts one schedule back (replace-all), "Use default" drops a day's own.
        [HasPermission("academics.view")]
        [Route("academics/periods")]
        public async Task<IActionResult> PeriodStructure()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var periods = await _schoolSettingsService.GetAllPeriodSchedulesAsync(tenantId, schoolId, actionUserId);

            // Shape the page's JS consumes: name / start / end / type, plus the day
            // the row belongs to (null = the default schedule).
            var shaped = periods.Select(p => new
            {
                id    = p.PeriodId,
                day   = p.DayOfWeek,
                name  = p.Label,
                start = p.StartTime,
                end   = p.EndTime,
                type  = p.PeriodType
            });
            ViewBag.PeriodJson = System.Text.Json.JsonSerializer.Serialize(shaped);

            // The day selector lists the weekdays that are not weekly offs.
            var today    = Dates.Now.Date;
            var calendar = await _schoolCalendarService.GetCalendarAsync(today, today, tenantId, schoolId, actionUserId);
            ViewBag.WeeklyOffJson = System.Text.Json.JsonSerializer.Serialize(calendar.WeeklyOffDays);
            // Add / edit / delete buttons are shown only with academics.manage
            // (a teacher has academics.view and would be refused on save).
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "academics.manage");

            return View();
        }

        public class PeriodDayDto { public int Day { get; set; } }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> UseDefaultPeriodSchedule([FromBody] PeriodDayDto dto)
        {
            var result = await _schoolSettingsService.UseDefaultScheduleAsync(dto?.Day ?? -1, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = result.Success, message = result.Message });
        }

        // Smart Bell — a live kiosk display driven by the same schedule. Read-only:
        // it just needs the periods, the SERVER clock and today's calendar status;
        // the countdown + bell run in the browser off that seed.
        [HasPermission("academics.view")]
        [Route("academics/smart-bell")]
        public async Task<IActionResult> SmartBell()
        {
            ViewBag.BellStateJson = System.Text.Json.JsonSerializer.Serialize(await BuildBellStateAsync());
            return View();
        }

        // Re-sync endpoint. The kiosk calls this every few minutes, on midnight
        // rollover and whenever the tab wakes up, so a drifting/wrong PC clock,
        // a schedule edit or a newly-declared holiday can never ring the wrong bell.
        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> SmartBellState()
        {
            return Json(await BuildBellStateAsync());
        }

        // One payload for both the page seed and the re-sync: server wall clock,
        // today's resolved day status, and the schedule.
        private async Task<object> BuildBellStateAsync()
        {
            int tenantId = SmTenant(), schoolId = SmSchool(), actionUserId = SmUser();

            var now     = Dates.Now;                       // the school's clock — the single source of truth
            // Today's own schedule (a short Saturday rings only its periods), or the default.
            var periods = await _schoolSettingsService.GetPeriodStructureAsync(tenantId, schoolId, actionUserId, (int)now.DayOfWeek);
            var day     = await _schoolCalendarService.GetDayStatusAsync(now.Date, tenantId, schoolId, actionUserId);

            return new
            {
                date       = now.ToString("yyyy-MM-dd"),
                dateLabel  = now.ToString("ddd, d MMM yyyy"),
                dow        = (int)now.DayOfWeek,
                sec        = now.Hour * 3600 + now.Minute * 60 + now.Second,   // seconds since midnight
                dayType    = day.DayType,                                      // working | weekly_off | holiday | half_day
                title      = day.Title,
                isWorking  = day.IsWorking,
                halfDayEnd = day.HalfDayEnd,
                periods    = periods.Select(p => new
                {
                    name  = p.Label,
                    start = p.StartTime,
                    end   = p.EndTime,
                    type  = p.PeriodType
                })
            };
        }

        // Limits for the bell schedule. The label width matches
        // academic.period_structure.label; the types match its CHECK constraint.
        private const int PeriodLabelMaxLength = 50;
        private const int MaxPeriodsPerDay     = 60;

        private static readonly string[] AllowedPeriodTypes =
            { "class", "assembly", "break", "lunch", "diary" };

        // The page posts "HH:mm" from an <input type="time">. Accept a single-digit
        // hour and a stray seconds part too, and reject anything else rather than
        // letting PostgreSQL fail the ::time cast with its own wording.
        private static bool TryReadClockTime(string? value, out TimeSpan time)
        {
            time = TimeSpan.Zero;
            if (string.IsNullOrWhiteSpace(value)) return false;

            var formats = new[] { @"hh\:mm", @"h\:mm", @"hh\:mm\:ss", @"h\:mm\:ss" };
            if (!TimeSpan.TryParseExact(value.Trim(), formats,
                    System.Globalization.CultureInfo.InvariantCulture, out time))
                return false;

            return time >= TimeSpan.Zero && time < TimeSpan.FromDays(1);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> SavePeriodStructure([FromBody] PeriodStructureSaveDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var posted = dto?.Periods ?? new List<PeriodItemDto>();

            // null = the default schedule; 0..6 = that weekday's own schedule.
            var day = dto?.Day;
            if (day is < 0 or > 6)
                return Json(new { success = false, message = "Pick a day of the week." });

            // This schedule drives the timetable grid AND the Smart Bell kiosk, so
            // an empty save does not just clear a page - it stops the bell ringing.
            if (posted.Count == 0)
                return Json(new { success = false, message = "Add at least one period. An empty schedule stops the bell." });
            if (posted.Count > MaxPeriodsPerDay)
                return Json(new { success = false, message = $"A day cannot have more than {MaxPeriodsPerDay} periods." });

            var items = new List<PeriodStructureItem>();
            foreach (var p in posted)
            {
                var label = (p.Name ?? string.Empty).Trim();
                if (label.Length == 0)
                    return Json(new { success = false, message = "Every period needs a label." });
                if (label.Length > PeriodLabelMaxLength)
                    return Json(new { success = false, message = $"Label \"{label}\" is longer than {PeriodLabelMaxLength} characters." });
                // The timetable and the bell both show a period by its label, so two
                // periods with the same name are indistinguishable on screen.
                if (items.Any(x => x.Label.Equals(label, StringComparison.OrdinalIgnoreCase)))
                    return Json(new { success = false, message = $"There are two periods called \"{label}\"." });

                if (!TryReadClockTime(p.Start, out var start))
                    return Json(new { success = false, message = $"\"{label}\" has an invalid start time." });
                if (!TryReadClockTime(p.End, out var end))
                    return Json(new { success = false, message = $"\"{label}\" has an invalid end time." });
                if (end <= start)
                    return Json(new { success = false, message = $"\"{label}\" ends before it starts." });

                var type = string.IsNullOrWhiteSpace(p.Type) ? "class" : p.Type!.Trim().ToLowerInvariant();
                // An unknown type used to be quietly rewritten to "class", which hid
                // the mistake until someone noticed the wrong colour on the timeline.
                if (!AllowedPeriodTypes.Contains(type))
                    return Json(new { success = false, message = $"\"{label}\" has an unknown period type." });

                items.Add(new PeriodStructureItem
                {
                    Label      = label,
                    StartTime  = start.ToString(@"hh\:mm"),
                    EndTime    = end.ToString(@"hh\:mm"),
                    PeriodType = type
                });
            }

            // Sort before the overlap check so the answer does not depend on the
            // order the page happened to post them in.
            items = items.OrderBy(x => x.StartTime, StringComparer.Ordinal).ToList();
            for (int i = 1; i < items.Count; i++)
            {
                if (string.CompareOrdinal(items[i].StartTime, items[i - 1].EndTime) < 0)
                    return Json(new
                    {
                        success = false,
                        message = $"\"{items[i].Label}\" overlaps \"{items[i - 1].Label}\"."
                    });
            }

            var result = await _schoolSettingsService.SavePeriodStructureAsync(items, tenantId, schoolId, actionUserId, day);
            return Json(new { success = result.Success, message = result.Message });
        }
        #endregion
    }
}
