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

        public DashboardsController(IDashboardService dashboardService, IAdmissionWorkflowService workflow,
                                    ITransportTrackingService tracking, IBaseService baseService)
        {
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
        public async Task<IActionResult> Index()
        {
            int t = TenantId(), s = SchoolId(), u = UserId();
            var model = await _dashboardService.GetSummaryAsync(t, s, u);

            // Fee collections, outstanding dues and the defaulters list are finance data.
            if (!await Can("fees.view"))
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
            model.ShowAttendance = await Can("attendance.view");
            model.CanAdmit       = await Can("students.manage");

            if (!canStudents) { model.Students = 0; model.Classes.Clear(); }
            if (!canStaff)    { model.Staff = 0; model.OnLeaveToday = 0; model.Approvals.Clear(); }
            if (!model.ShowAttendance) { model.PresentToday = 0; model.MarkedToday = 0; }
            // Birthdays name students and staff: each kind needs its own module.
            model.Birthdays.RemoveAll(b => (b.Who == "Student" && !canStudents) || (b.Who != "Student" && !canStaff));

            try { model.IsDriver = await _tracking.IsDriverAsync(t, s, u); } catch { model.IsDriver = false; }

            // The current session for the hero chip (was a hard-coded "2025–26").
            try
            {
                var years = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", t.ToString(), s.ToString());
                model.SessionName = (years.FirstOrDefault(y => y.Selected) ?? years.FirstOrDefault())?.Text;
            }
            catch { model.SessionName = null; }

            model.QuickLinks = await BuildQuickLinksAsync(t, s, u, model.IsDriver);
            return View(model);
        }

        // Quick Access tiles the viewer can actually open: permission plus module switch.
        private async Task<List<DashboardLink>> BuildQuickLinksAsync(int t, int s, int u, bool isDriver)
        {
            bool exams = true, inventory = true, payroll = true, transport = true, registration = true;
            try
            {
                var mods = await _workflow.GetAdmissionWorkflowAsync(t, s, u);
                exams = mods.EnableExams; inventory = mods.EnableInventory; payroll = mods.EnablePayroll;
                transport = mods.EnableTransport; registration = mods.EnableRegistration;
            }
            catch { /* show the tiles; the pages themselves still refuse a switched-off module */ }

            var all = new (string Label, string Icon, string Url, string Color, string Key, bool On)[]
            {
                ("Enquiries",  "bx-message-square-detail", "/ERP/Enquiry/EnquiryCRM",      "#e83e8c", "enquiry.view",    true),
                ("Registrations", "bx-clipboard",    "/ERP/Registration",                  "#d97706", "registration.view", registration),
                ("Students",   "bx-group",           "/ERP/Student/StudentList",           "#ff8a00", "students.view",   true),
                ("Admission",  "bx-user-plus",       "/ERP/Admission/Create",              "#16a34a", "students.manage", true),
                ("Fees",       "bx-wallet",          "/ERP/Fee/ManageFee",                 "#0284c7", "fees.view",       true),
                ("Attendance", "bx-user-check",      "/ERP/Attendance/StudentAttendance",  "#d97706", "attendance.view", true),
                ("Exams",      "bx-file",            "/ERP/Exam/CreateExam",               "#dc2626", "exams.view",      exams),
                ("Staff",      "bx-id-card",         "/ERP/Staff/StaffList",               "#9333ea", "staff.view",      true),
                ("Payroll",    "bx-money",           "/ERP/Payroll/PayrollManagement",     "#16a34a", "payroll.view",    payroll),
                ("Leave",      "bx-calendar-minus",  "/ERP/Leave/LeaveManagement",         "#e83e8c", "staff.view",      true),
                ("Inventory",  "bx-package",         "/ERP/Inventory/InventoryItem",       "#ff5722", "inventory.view",  inventory),
                ("Transport",  "bx-bus",             "/ERP/Transport/LiveTracking",        "#0ea5e9", "transport.view",  transport),
                ("Reminders",  "bx-bell",            "/ERP/FeeDueReminders",               "#ff8a00", "fees.view",       true),
                // Was /ERP/Reports, which does not exist.
                ("Reports",    "bx-bar-chart-alt-2", "/ERP/Fee/Reports",                   "#009688", "fees.view",       true),
                ("Settings",   "bx-cog",             "/ERP/SchoolSettings/BasicProfile",   "#6b7280", "settings.view",   true),
            };

            var links = new List<DashboardLink>();
            if (isDriver)
                links.Add(new DashboardLink { Label = "My Bus", Icon = "bx-bus", Url = "/ERP/MyBus", Color = "#ff8a00" });
            foreach (var l in all)
                if (l.On && await Can(l.Key))
                    links.Add(new DashboardLink { Label = l.Label, Icon = l.Icon, Url = l.Url, Color = l.Color });
            return links;
        }
    }
}
