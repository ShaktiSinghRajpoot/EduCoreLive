namespace educore.Helpers
{
    /// <summary>
    /// Old links keep working while the pages move out of the one big "ERP" area
    /// into one area per module (Fees, Inventory, ...).
    ///
    /// /ERP/{Controller}/{rest}  ->  /{area}/{Controller}/{rest}  (query string kept)
    ///
    /// A bookmark, a link in a WhatsApp message or an open tab is sent on with a
    /// 301. A POST gets a 308 instead, so the browser repeats it with its body (a
    /// 301 would turn it into a GET and lose the form). Each phase of the move adds
    /// its controllers to <see cref="MovedControllers"/>; a controller that is not
    /// listed is still in ERP and is left alone.
    /// </summary>
    public static class LegacyErpRedirect
    {
        // controller name -> the area it lives in now
        public static readonly Dictionary<string, string> MovedControllers = new(StringComparer.OrdinalIgnoreCase)
        {
            { "Inventory", "Inventory" },
            { "StoreRegister", "Inventory" },
            { "Transport", "Transport" },
            { "MyBus", "Transport" },
            { "Fee", "Fees" },
            { "FeeDashboard", "Fees" },
            { "FeeDues", "Fees" },
            { "FeeDueReminders", "Fees" },
            { "DayClose", "Fees" },
            { "Expense", "Accounts" },
            { "Staff", "Staff" },
            { "StaffAttendance", "Staff" },
            { "Leave", "Staff" },
            { "Payroll", "Staff" },
            { "MyLeave", "Staff" },
            { "MyPayslip", "Staff" },
            { "MyAttendance", "Staff" },
            { "Exam", "Exams" },
            { "AdmitCard", "Exams" },
            { "ReportCard", "Exams" },
            { "Homework", "Academics" },
            { "MyTimetable", "Academics" },
            { "Attendance", "Attendance" },
            { "AttendanceOverview", "Attendance" },
            { "Admission", "Students" },
            { "Certificate", "Students" },
            { "DataChecks", "Students" },
            { "Enquiry", "Students" },
            { "FrontOffice", "Students" },
            { "IdCard", "Students" },
            { "Registration", "Students" },
            { "Student", "Students" },
            { "Tc", "Students" },
        };

        // Pages that got a short address of their own: "Controller/Action" -> new path.
        // An id after the action is carried over: Staff/StaffProfile/{id} -> /staff/profile/{id}.
        // (Their old long form would not open: an action with its own route answers only there.)
        public static readonly Dictionary<string, string> MovedPages = new(StringComparer.OrdinalIgnoreCase)
        {
            { "Inventory", "/inventory" },
            { "Inventory/Index", "/inventory" },
            { "Inventory/StoreDashboard", "/inventory" },
            { "Inventory/InventoryItem", "/inventory/store" },
            { "Inventory/StoreLocations", "/inventory/locations" },
            { "Inventory/SupplierMaster", "/inventory/suppliers" },
            { "Inventory/PurchaseEntry", "/inventory/purchase" },
            { "Inventory/StudentSale", "/inventory/give-items" },
            { "Inventory/ClassSale", "/inventory/class-items" },
            { "Inventory/OrderList", "/inventory/order-list" },
            { "StoreRegister", "/inventory/register" },
            { "StoreRegister/Index", "/inventory/register" },
            { "Transport", "/transport/live" },
            { "Transport/Index", "/transport/live" },
            { "Transport/Routes", "/transport/routes" },
            { "Transport/Vehicles", "/transport/vehicles" },
            { "Transport/Assign", "/transport/assign" },
            { "Transport/LiveTracking", "/transport/live" },
            { "Transport/TripHistory", "/transport/trips" },
            { "MyBus", "/my-bus" },
            { "MyBus/Index", "/my-bus" },
            { "FeeDashboard", "/fees" },
            { "FeeDashboard/Index", "/fees" },
            { "Fee/ManageFee", "/fees/collect" },
            { "Fee/Reports", "/fees/reports" },
            { "Fee/YearEnd", "/fees/year-end" },
            { "FeeDues", "/fees/dues" },
            { "FeeDues/Index", "/fees/dues" },
            { "FeeDueReminders", "/fees/dues" },
            { "FeeDueReminders/Index", "/fees/dues" },
            { "DayClose", "/fees/day-close" },
            { "DayClose/Index", "/fees/day-close" },
            // receipts left Fee for the always-on Receipt controller
            { "Fee/GetReceipt", "/school/receipt/getreceipt" },
            { "Fee/GetSchoolHeader", "/school/receipt/getschoolheader" },
            { "Fee/CancelReceipt", "/school/receipt/cancelreceipt" },
            { "Fee/SaveReceiptFormat", "/school/receipt/savereceiptformat" },
            // fee heads and structure left SchoolSettings (which is still in ERP)
            { "SchoolSettings/FeeHead", "/fees/heads" },
            { "SchoolSettings/FeeStructure", "/fees/structure" },
            { "SchoolSettings/SaveFeeHead", "/fees/feesetup/savefeehead" },
            { "SchoolSettings/GetFeeHeadById", "/fees/feesetup/getfeeheadbyid" },
            { "SchoolSettings/DeleteFeeHead", "/fees/feesetup/deletefeehead" },
            { "SchoolSettings/ToggleFeeHeadStatus", "/fees/feesetup/togglefeeheadstatus" },
            { "SchoolSettings/CopyFeeStructure", "/fees/feesetup/copyfeestructure" },
            { "SchoolSettings/GetFeeStructureByClass", "/fees/feesetup/getfeestructurebyclass" },
            { "SchoolSettings/SaveFeeStructure", "/fees/feesetup/savefeestructure" },
            { "SchoolSettings/DeleteFeeStructure", "/fees/feesetup/deletefeestructure" },
            { "Expense", "/accounts/expenses" },
            { "Expense/Index", "/accounts/expenses" },
            { "Expense/CashBook", "/accounts/cash-book" },
            { "Staff", "/staff" },
            { "Staff/StaffList", "/staff" },
            { "Staff/Inactive", "/staff/inactive" },
            { "Staff/AddStaff", "/staff/add" },
            { "Staff/StaffProfile", "/staff/profile" },
            { "Staff/EditStaff", "/staff/edit" },
            { "StaffAttendance", "/staff/attendance" },
            { "StaffAttendance/Index", "/staff/attendance" },
            { "Leave", "/staff/leave" },
            { "Leave/LeaveManagement", "/staff/leave" },
            { "Payroll", "/staff/payroll" },
            { "Payroll/PayrollManagement", "/staff/payroll" },
            { "MyLeave", "/my-leave" },
            { "MyLeave/Index", "/my-leave" },
            { "MyPayslip", "/my-payslip" },
            { "MyPayslip/Index", "/my-payslip" },
            { "MyAttendance", "/my-attendance" },
            { "MyAttendance/Index", "/my-attendance" },
            { "SchoolSettings/StaffMasters", "/staff/departments" },
            { "SchoolSettings/SaveDepartment", "/staff/staffmasters/savedepartment" },
            { "SchoolSettings/SaveDesignation", "/staff/staffmasters/savedesignation" },
            { "SchoolSettings/DeleteMaster", "/staff/staffmasters/deletemaster" },
            { "SchoolSettings/ToggleMaster", "/staff/staffmasters/togglemaster" },
            { "Exam", "/exams/schedule" },
            { "Exam/CreateExam", "/exams/schedule" },
            { "Exam/Datesheet", "/exams/datesheet" },
            { "Exam/MarkEntry", "/exams/marks" },
            { "Exam/GradeScale", "/exams/grades" },
            { "Exam/ResultSheet", "/exams/results" },
            { "AdmitCard", "/exams/admit-cards" },
            { "AdmitCard/Index", "/exams/admit-cards" },
            { "ReportCard", "/exams/report-cards" },
            { "ReportCard/Index", "/exams/report-cards" },
            { "Homework", "/academics/homework" },
            { "Homework/Index", "/academics/homework" },
            { "MyTimetable", "/my-timetable" },
            { "MyTimetable/Index", "/my-timetable" },
            { "Attendance", "/attendance/mark" },
            { "Attendance/StudentAttendance", "/attendance/mark" },
            { "Attendance/AttendanceReport", "/attendance/register" },
            { "AttendanceOverview", "/attendance/overview" },
            { "AttendanceOverview/Index", "/attendance/overview" },
            { "Student", "/students" },
            { "Student/StudentList", "/students" },
            { "Student/Promotion", "/students/promotion" },
            { "Student/PromoteHistory", "/students/promotion/history" },
            { "Student/Inactive", "/students/left" },
            { "Student/Dashboard", "/students/profile" },
            { "Student/EditStudent", "/students/edit" },
            { "Admission/Create", "/students/admission/new" },
            { "Enquiry", "/students/enquiries" },
            { "Enquiry/EnquiryCRM", "/students/enquiries" },
            { "SchoolSettings/EnquiryCRM", "/students/enquiries" },
            { "FrontOffice", "/students/front-office" },
            { "FrontOffice/Index", "/students/front-office" },
            { "Registration", "/students/registrations" },
            { "Registration/Index", "/students/registrations" },
            { "Certificate", "/students/certificates" },
            { "Certificate/Index", "/students/certificates" },
            { "IdCard", "/students/id-cards" },
            { "IdCard/Index", "/students/id-cards" },
            { "DataChecks", "/students/data-checks" },
            { "DataChecks/Index", "/students/data-checks" },
            { "Tc/Register", "/students/tc-register" },
            // timetable, periods and Smart Bell left SchoolSettings (which is still in ERP)
            { "SchoolSettings/Timetable", "/academics/timetable" },
            { "SchoolSettings/TimetableSchool", "/academics/timetable/school" },
            { "SchoolSettings/PeriodStructure", "/academics/periods" },
            { "SchoolSettings/SmartBell", "/academics/smart-bell" },
            { "SchoolSettings/TimetableSetup", "/academics/timetable/timetablesetup" },
            { "SchoolSettings/TimetableGrid", "/academics/timetable/timetablegrid" },
            { "SchoolSettings/TimetableTeacherGrid", "/academics/timetable/timetableteachergrid" },
            { "SchoolSettings/SaveTimetableCell", "/academics/timetable/savetimetablecell" },
            { "SchoolSettings/ClearTimetableCell", "/academics/timetable/cleartimetablecell" },
            { "SchoolSettings/CopyTimetableDay", "/academics/timetable/copytimetableday" },
            { "SchoolSettings/TimetableSchoolData", "/academics/timetable/timetableschooldata" },
            { "SchoolSettings/TimetableRequests", "/academics/timetable/timetablerequests" },
            { "SchoolSettings/ApproveTimetableRequest", "/academics/timetable/approvetimetablerequest" },
            { "SchoolSettings/RejectTimetableRequest", "/academics/timetable/rejecttimetablerequest" },
            { "SchoolSettings/UseDefaultPeriodSchedule", "/academics/timetable/usedefaultperiodschedule" },
            { "SchoolSettings/SmartBellState", "/academics/timetable/smartbellstate" },
            { "SchoolSettings/SavePeriodStructure", "/academics/timetable/saveperiodstructure" },
        };

        public static IApplicationBuilder UseLegacyErpRedirect(this IApplicationBuilder app)
        {
            return app.Use(async (context, next) =>
            {
                var path = context.Request.Path.Value ?? "";
                if (path.StartsWith("/ERP/", StringComparison.OrdinalIgnoreCase))
                {
                    // "/ERP/Fee/ManageFee" -> controller "Fee", rest "/ManageFee"
                    var afterArea = path.Substring(5);
                    int slash = afterArea.IndexOf('/');
                    var controller = slash < 0 ? afterArea : afterArea.Substring(0, slash);
                    var rest = slash < 0 ? "" : afterArea.Substring(slash);

                    // "Staff/StaffProfile/{id}": the page's first two segments, then the rest
                    var parts = afterArea.TrimEnd('/').Split('/', 3);
                    var pageKey = parts.Length >= 2 ? parts[0] + "/" + parts[1] : parts[0];
                    var pageRest = parts.Length == 3 ? "/" + parts[2] : "";

                    string? target = null;
                    if (MovedPages.TryGetValue(afterArea.TrimEnd('/'), out var page))
                        target = page;
                    else if (pageRest != "" && MovedPages.TryGetValue(pageKey, out var pageWithId))
                        target = pageWithId + pageRest;
                    else if (MovedControllers.TryGetValue(controller, out var area))
                        target = "/" + area.ToLowerInvariant() + "/" + controller.ToLowerInvariant() + rest;

                    if (target != null)
                    {
                        target += context.Request.QueryString.Value;
                        bool isGet = HttpMethods.IsGet(context.Request.Method) || HttpMethods.IsHead(context.Request.Method);
                        context.Response.StatusCode = isGet ? StatusCodes.Status301MovedPermanently
                                                            : StatusCodes.Status308PermanentRedirect;
                        context.Response.Headers.Location = target;
                        return;
                    }
                }
                await next();
            });
        }
    }
}
