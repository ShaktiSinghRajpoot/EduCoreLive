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

        public StudentController(
            IBaseService baseService,
            IAdmissionService admissionService,
            IAdmissionWorkflowService admissionWorkflowService)
        {
            _baseService = baseService;
            _admissionService = admissionService;
            _admissionWorkflowService = admissionWorkflowService;
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

        public IActionResult Promotion()
        {
            return View();
        }

        public IActionResult Inactive()
        {
            return View();
        }

        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public IActionResult Reactivate(int id)
        {
            // Replace with real service call once the SP is ready.
            TempData["SuccessMessage"] = "Student re-activated successfully.";
            return RedirectToAction("Inactive");
        }

        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public IActionResult Promotion(IFormCollection form)
        {
            // Replace with real service call once the promote SP is ready.
            // Expected payload: source year/class/section, target year/class/section,
            // per-student outcome (promote/retain/passout), carry-forward-dues flag.
            TempData["SuccessMessage"] = "Students promoted successfully.";
            return RedirectToAction("Promotion");
        }

        public IActionResult Dashboard(int id = 0)
        {
            ViewBag.StudentId = id;
            return View();
        }

        public IActionResult EditStudent(int id = 0)
        {
            ViewBag.StudentId = id;
            return View();
        }

        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public IActionResult EditStudent(int id, IFormCollection form)
        {
            // Replace with real service call once SP is ready
            TempData["SuccessMessage"] = "Student profile updated successfully.";
            return RedirectToAction("Dashboard", new { id });
        }
    }
}
