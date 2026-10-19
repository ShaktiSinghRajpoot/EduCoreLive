using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using educore.Services;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Controllers
{
    [Authorize]
    public class DashboardsController : Controller
    {
        private readonly IDashboardService _dashboardService;
        private readonly IAdmissionWorkflowService _workflow;
        private readonly ITransportTrackingService _tracking;
        private readonly IBaseService _baseService;
        private readonly IStaffSelfService _self;
        private readonly ModuleFlags _modules;

        public DashboardsController(IDashboardService dashboardService, IAdmissionWorkflowService workflow,
                                    ITransportTrackingService tracking, IBaseService baseService,
                                    IStaffSelfService self, ModuleFlags modules)
        {
            _self = self;
            _modules = modules;
            _dashboardService = dashboardService;
            _workflow = workflow;
            _tracking = tracking;
            _baseService = baseService;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        private Task<bool> Can(string key) => HasPermissionAttribute.UserHasAsync(this, key);

        // The first page after sign-in. Every signed-in role lands here, so every block
        // follows the viewer's permissions: what a role cannot open is removed from the
        // model on the server (not just hidden in the page), and links it cannot follow
        // are not shown. A driver with no other permission sees a greeting and My Bus.
        // The next 30 days of the School Calendar for everyone: events and exam periods,
        // and the holidays / half days. A vacation is one entry per day in the calendar,
        // so days in a row with the same name are shown as one line ("Diwali 20-25 Oct").
        private static async Task<List<DashboardUpcoming>> UpcomingAsync(ISchoolCalendarService calendar, int t, int s, int u)
        {
            var list = new List<DashboardUpcoming>();
            try
            {
                var from = Dates.Now.Date;
                var to   = from.AddDays(30);
                var events = await calendar.GetEventsAsync(from.ToString("yyyy-MM-dd"), to.ToString("yyyy-MM-dd"), t, s, u);
                list.AddRange(events.Select(e => new DashboardUpcoming
                {
                    Start = e.StartDate, End = e.EndDate, Title = e.Title, Type = e.EventType, Time = e.StartTime, ForWhom = e.ForWhom
                }));

                var days = (await calendar.GetCalendarAsync(from, to, t, s, u)).Entries
                           .Where(x => x.DayType != "working").OrderBy(x => x.Date).ToList();
                DashboardUpcoming? run = null;
                foreach (var d in days)
                {
                    string type = d.DayType == "holiday" ? "Holiday" : "Half day";
                    string title = string.IsNullOrWhiteSpace(d.Title) ? type : d.Title;
                    bool nextDay = run != null && DateTime.Parse(run.End).AddDays(1).ToString("yyyy-MM-dd") == d.Date;
                    if (run != null && nextDay && run.Title == title && run.Type == type) { run.End = d.Date; continue; }
                    run = new DashboardUpcoming { Start = d.Date, End = d.Date, Title = title, Type = type };
                    list.Add(run);
                }
            }
            catch { /* the dashboard shows without it */ }
            return list.OrderBy(x => x.Start).ThenBy(x => x.Title).Take(8).ToList();
        }

        public async Task<IActionResult> Index([FromServices] IClassTeacherService classTeacher,
                                               [FromServices] ISchoolCalendarService calendar)
        {
            int t = TenantId(), s = SchoolId(), u = UserId();

            // The platform super admin has no school, so a school dashboard would be
            // empty. Their home is the Schools list.
            if (t == 1)
                return RedirectToAction("SchoolList", "Schools", new { area = "SuperAdmin" });

            var model = await _dashboardService.GetSummaryAsync(t, s, u);
            model.Upcoming = await UpcomingAsync(calendar, t, s, u);

            // A module that is off (or was not given) leaves nothing of itself here.
            var mods = await _modules.GetAsync();

            // Fee collections, outstanding dues and the defaulters list are finance data.
            if (!mods.EnableFees || !await Can("fees.view"))
            {
                model.ShowFinance = false;
                model.TodayCollection = 0;
                model.YesterdayCollection = 0;
                model.Outstanding = 0;
                model.DueStudents = 0;
                model.Trend.Clear();
                model.Modes.Clear();
                model.Defaulters.Clear();
                model.Recent.Clear();
            }

            bool canStudents = await Can("students.view");
            bool canStaff    = await Can("staff.view");
            model.ShowStudents   = canStudents;
            model.ShowStaff      = canStaff;
            model.ShowAttendance = mods.EnableAttendance && await Can("attendance.view");
            model.CanAdmit       = await Can("students.manage");

            if (!canStudents) { model.Students = 0; model.Classes.Clear(); }
            if (!canStaff)    { model.Staff = 0; model.OnLeaveToday = 0; model.Approvals.Clear(); }
            if (!model.ShowAttendance) { model.PresentToday = 0; model.MarkedToday = 0; }
            // Birthdays name students and staff: each kind needs its own module.
            model.Birthdays.RemoveAll(b => (b.Who == "Student" && !canStudents) || (b.Who != "Student" && !canStaff));

            // Leave lives in the Staff (payroll) module, the bus in Transport.
            if (!mods.EnablePayroll) { model.ShowLeave = false; model.OnLeaveToday = 0; model.Approvals.Clear(); }

            try { model.IsDriver = mods.EnableTransport && await _tracking.IsDriverAsync(t, s, u); } catch { model.IsDriver = false; }

            // The current session for the hero chip (was a hard-coded "2025–26").
            try
            {
                var years = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", t.ToString(), s.ToString());
                model.SessionName = (years.FirstOrDefault(y => y.Selected) ?? years.FirstOrDefault())?.Text;
            }
            catch { model.SessionName = null; }

            // Attendance section: staff today needs staff.view; the student list needs
            // attendance.view. Nothing is read when neither applies.
            model.CanOpenOverview = await Can("reports.view");
            if (model.ShowAttendance || model.ShowStaff)
            {
                try { await _dashboardService.FillAttendanceAsync(model, t, s, u); } catch { /* the section stays empty */ }
                if (!model.ShowAttendance) { model.StudentAttendanceDefaulters.Clear(); model.StudentAttendanceDefaulterCount = 0; }
                if (!model.ShowStaff)
                {
                    model.StaffToday = new DashboardStaffToday();
                    model.StaffAttendanceDefaulters.Clear(); model.StaffAttendanceDefaulterCount = 0;
                }
            }

            // A class teacher sees their class and whether today's register is taken.
            try { model.MyClasses = await classTeacher.GetClassesOfAsync(t, s, u); } catch { model.MyClasses = new(); }

            model.QuickLinks = await BuildQuickLinksAsync(t, s, u, model.IsDriver);
            return View(model);
        }

        // Quick Access tiles the viewer can actually open: permission plus module switch.
        private async Task<List<DashboardLink>> BuildQuickLinksAsync(int t, int s, int u, bool isDriver)
        {
            bool exams = true, inventory = true, payroll = true, transport = true, registration = true;
            bool attendance = true, fees = true;
            try
            {
                var mods = await _workflow.GetAdmissionWorkflowAsync(t, s, u);
                exams = mods.EnableExams; inventory = mods.EnableInventory; payroll = mods.EnablePayroll;
                transport = mods.EnableTransport; registration = mods.EnableRegistration;
                attendance = mods.EnableAttendance; fees = mods.EnableFees;
            }
            catch { /* show the tiles; the pages themselves still refuse a switched-off module */ }

            var all = new (string Label, string Icon, string Url, string Color, string Key, bool On)[]
            {
                ("Enquiries",  "bx-message-square-detail", "/ERP/Enquiry/EnquiryCRM",      "#e83e8c", "enquiry.view",    true),
                ("Registrations", "bx-clipboard",    "/ERP/Registration",                  "#d97706", "registration.view", registration),
                ("Students",   "bx-group",           "/ERP/Student/StudentList",           "#ff8a00", "students.view",   true),
                ("Admission",  "bx-user-plus",       "/ERP/Admission/Create",              "#16a34a", "students.manage", true),
                ("Fees",       "bx-wallet",          "/fees/collect",                      "#0284c7", "fees.view",       fees),
                ("Attendance", "bx-user-check",      "/ERP/Attendance/StudentAttendance",  "#d97706", "attendance.view", attendance),
                ("Exams",      "bx-file",            "/ERP/Exam/CreateExam",               "#dc2626", "exams.view",      exams),
                ("Staff",      "bx-id-card",         "/ERP/Staff/StaffList",               "#9333ea", "staff.view",      true),
                ("Payroll",    "bx-money",           "/ERP/Payroll/PayrollManagement",     "#16a34a", "payroll.view",    payroll),
                ("Leave",      "bx-calendar-minus",  "/ERP/Leave/LeaveManagement",         "#e83e8c", "staff.view",      payroll),
                ("Inventory",  "bx-package",         "/inventory/store",                   "#ff5722", "inventory.view",  inventory),
                ("Transport",  "bx-bus",             "/transport/live",                    "#0ea5e9", "transport.view",  transport),
                ("Reminders",  "bx-bell",            "/fees/dues",                         "#ff8a00", "fees.view",       fees),
                // Was /ERP/Reports, which does not exist.
                ("Reports",    "bx-bar-chart-alt-2", "/fees/reports",                      "#009688", "fees.view",       fees),
                ("Settings",   "bx-cog",             "/ERP/SchoolSettings/BasicProfile",   "#6b7280", "settings.view",   true),
            };

            var links = new List<DashboardLink>();
            if (isDriver)
                links.Add(new DashboardLink { Label = "My Bus", Icon = "bx-bus", Url = "/my-bus", Color = "#ff8a00" });
            // My Attendance / My Leave / My Payslip: for anyone with a current staff record
            // (no permission key). Leave and payslips belong to the Payroll module.
            bool hasStaff = false;
            try { hasStaff = await _self.HasStaffRecordAsync(t, s, u); } catch { hasStaff = false; }
            if (hasStaff)
                links.Add(new DashboardLink { Label = "My Attendance", Icon = "bx-user-check", Url = "/ERP/MyAttendance", Color = "#0f766e" });
            bool isStaff = payroll && hasStaff;
            if (isStaff)
            {
                links.Add(new DashboardLink { Label = "My Leave",   Icon = "bx-calendar-minus", Url = "/ERP/MyLeave",   Color = "#e83e8c" });
                links.Add(new DashboardLink { Label = "My Payslip", Icon = "bx-receipt",        Url = "/ERP/MyPayslip", Color = "#16a34a" });
            }
            foreach (var l in all)
                if (l.On && await Can(l.Key))
                    links.Add(new DashboardLink { Label = l.Label, Icon = l.Icon, Url = l.Url, Color = l.Color });
            return links;
        }
    }
}
