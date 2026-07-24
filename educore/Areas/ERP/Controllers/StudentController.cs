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
        private readonly IWebHostEnvironment _env;

        public StudentController(
            IBaseService baseService,
            IAdmissionService admissionService,
            IAdmissionWorkflowService admissionWorkflowService,
            IWebHostEnvironment env)
        {
            _baseService = baseService;
            _admissionService = admissionService;
            _admissionWorkflowService = admissionWorkflowService;
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

            return View();
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
        public async Task<IActionResult> UploadPhoto(int id, IFormFile? photo)
        {
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
