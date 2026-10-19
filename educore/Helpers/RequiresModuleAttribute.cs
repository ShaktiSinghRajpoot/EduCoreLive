using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace educore.Helpers
{
    /// <summary>The optional modules a school can be given (Super Admin) and switch off (Modules &amp; Workflow).</summary>
    public enum SchoolModule
    {
        Transport,
        Exams,
        Inventory,
        Payroll,     // shown as "Staff": payroll, leave, staff attendance
        Attendance,
        Academics,
        Fees,
        Accounts
    }

    /// <summary>
    /// Controller guard for the module switches, e.g.
    /// <c>[RequiresModule(SchoolModule.Exams)]</c>.
    ///
    /// The side menu already hides a module that is switched off, but hiding a link
    /// is not turning something off: a bookmark, a typed URL or a stale tab still
    /// reached the page. Transport was the only module that checked server-side, and
    /// it did so with twenty-five lines inside its own controller -- copying those
    /// into three more controllers is how the toggles would have drifted apart, so
    /// the check lives here once, shaped like <see cref="HasPermissionAttribute"/>.
    ///
    /// This is NOT a permission check. Permissions decide what a user may do;
    /// this decides whether the school bought the module at all, so it refuses
    /// everyone equally and points at the screen where it can be turned back on.
    /// </summary>
    public sealed class RequiresModuleAttribute : TypeFilterAttribute
    {
        public RequiresModuleAttribute(SchoolModule module)
            : base(typeof(RequiresModuleFilter))
        {
            Arguments = new object[] { module };
        }

        private sealed class RequiresModuleFilter : IAsyncActionFilter
        {
            private readonly SchoolModule _module;
            private readonly IAdmissionWorkflowService _workflow;

            public RequiresModuleFilter(SchoolModule module, IAdmissionWorkflowService workflow)
            {
                _module = module;
                _workflow = workflow;
            }

            public async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
            {
                var user = context.HttpContext.User;
                int tenantId = ClaimInt(user, Common.SK_TenantId);
                int schoolId = ClaimInt(user, Common.SK_SchoolId);
                int userId   = ClaimInt(user, Common.SK_UserId);

                var settings = await _workflow.GetAdmissionWorkflowAsync(tenantId, schoolId, userId);

                bool enabled = _module switch
                {
                    SchoolModule.Transport => settings.EnableTransport,
                    SchoolModule.Exams     => settings.EnableExams,
                    SchoolModule.Inventory => settings.EnableInventory,
                    SchoolModule.Payroll   => settings.EnablePayroll,
                    SchoolModule.Attendance => settings.EnableAttendance,
                    SchoolModule.Academics => settings.EnableAcademics,
                    SchoolModule.Fees      => settings.EnableFees,
                    SchoolModule.Accounts  => settings.EnableAccounts,
                    _                      => true
                };

                if (enabled)
                {
                    await next();
                    return;
                }

                bool given = _module switch
                {
                    SchoolModule.Transport => settings.AllowTransport,
                    SchoolModule.Exams     => settings.AllowExams,
                    SchoolModule.Inventory => settings.AllowInventory,
                    SchoolModule.Payroll   => settings.AllowPayroll,
                    SchoolModule.Attendance => settings.AllowAttendance,
                    SchoolModule.Academics => settings.AllowAcademics,
                    SchoolModule.Fees      => settings.AllowFees,
                    SchoolModule.Accounts  => settings.AllowAccounts,
                    _                      => true
                };
                string msg = given
                    ? $"{Label(_module)} is turned off for this school. A School Admin can turn it on in Settings > Modules & Workflow."
                    : $"{Label(_module)} is not in your school's plan.";

                // An AJAX call cannot follow a redirect usefully -- it would parse the
                // settings page as its JSON payload -- so it gets the same refusal the
                // page gets, in the shape it expects.
                bool isAjax = string.Equals(
                    context.HttpContext.Request.Headers["X-Requested-With"],
                    "XMLHttpRequest", StringComparison.OrdinalIgnoreCase);

                if (isAjax)
                {
                    context.Result = new JsonResult(new { success = false, message = msg });
                    return;
                }

                if (context.Controller is Controller controller)
                {
                    controller.TempData["Result"] = "0";
                    controller.TempData["Message"] = msg;
                }

                // The dashboard, not the settings page: a teacher or accountant cannot
                // open the settings page, so sending them there was a dead end.
                context.Result = new RedirectToActionResult("Index", "Dashboards", new { area = "" });
            }

            private static string Label(SchoolModule m) => m switch
            {
                SchoolModule.Transport => "Transport module",
                SchoolModule.Exams     => "Exams module",
                SchoolModule.Inventory => "Inventory module",
                SchoolModule.Payroll   => "Staff module",
                SchoolModule.Attendance => "Attendance module",
                SchoolModule.Academics => "Academics module",
                SchoolModule.Fees      => "Fees module",
                SchoolModule.Accounts  => "Accounts module",
                _                      => "This module"
            };

            private static int ClaimInt(System.Security.Claims.ClaimsPrincipal u, string type) =>
                int.TryParse(u.FindFirst(type)?.Value, out var v) ? v : 0;
        }
    }
}
