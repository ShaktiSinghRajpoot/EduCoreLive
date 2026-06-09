using educore.Models;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using System.Threading.Tasks;

namespace educore.Areas.Admin.Controllers
{ 
    [Area("Admin")]
    //[Authorize(Roles = AppRoles.SchoolAdmin)]
    public class SchoolSettingsController : Controller
    {
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IBaseService _baseService;
        private readonly IWebHostEnvironment _webHostEnvironment;

        public SchoolSettingsController(ISchoolSettingsService schoolSettingsService, IBaseService BaseService, IWebHostEnvironment webHostEnvironment)
        {
            _schoolSettingsService = schoolSettingsService;
            _baseService = BaseService;
            _webHostEnvironment = webHostEnvironment;
        }

        #region BasicProfile
        [HttpGet]
        public async Task<IActionResult> BasicProfile()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var model = await _schoolSettingsService.GetBasicProfileAsync(tenantId, schoolId, actionUserId);

            if (model == null) return RedirectToAction("AccessDenied", "Account", new { area = "" });

            await FillDropdowns(model, tenantId, schoolId);

            return View(model);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> BasicProfile(SchoolManageModel model, IFormFile? LogoImageFile)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            model.TenantId = tenantId;
            model.SchoolId = schoolId;

            // Remove fields not editable/required on Basic Profile page
            ModelState.Remove(nameof(model.TenantId));
            ModelState.Remove(nameof(model.SchoolId));
            ModelState.Remove(nameof(model.TenantMode));
            ModelState.Remove(nameof(model.TenantName));
            ModelState.Remove(nameof(model.TenantCode));
            ModelState.Remove(nameof(model.TenantEmail));
            ModelState.Remove(nameof(model.TenantPhone));

            ModelState.Remove(nameof(model.SchoolCode));
            ModelState.Remove(nameof(model.SchoolName));
            ModelState.Remove(nameof(model.BoardId));
            ModelState.Remove(nameof(model.BoardName));
            ModelState.Remove(nameof(model.SchoolTypeId));
            ModelState.Remove(nameof(model.SchoolTypeName));
            ModelState.Remove(nameof(model.StatusId));
            ModelState.Remove(nameof(model.StatusName));

            ModelState.Remove(nameof(model.AdminFullName));
            ModelState.Remove(nameof(model.AdminEmail));
            ModelState.Remove(nameof(model.AdminPhone));
            ModelState.Remove(nameof(model.Password));
            ModelState.Remove(nameof(model.CreateSchoolAdmin));
            ModelState.Remove(nameof(model.AutoGeneratePassword));

            ModelState.Remove(nameof(model.HeaderImageUrl));
            ModelState.Remove(nameof(model.LogoUrl));

            // Server-side logo validation
            if (LogoImageFile != null && LogoImageFile.Length > 0)
            {
                var allowedTypes = new[] { "image/jpeg", "image/png", "image/webp" };

                if (!allowedTypes.Contains(LogoImageFile.ContentType.ToLower()))
                {
                    ModelState.AddModelError("LogoImageFile", "Only JPG, PNG or WEBP image is allowed.");
                }

                if (LogoImageFile.Length > 2 * 1024 * 1024)
                {
                    ModelState.AddModelError("LogoImageFile", "Logo image must be less than 2 MB.");
                }
            }

            if (!ModelState.IsValid)
            {
                await FillDropdowns(model, tenantId, schoolId);
                return View(model);
            }

            if (LogoImageFile != null && LogoImageFile.Length > 0)
            {
                string logoPath = await SaveSchoolImageAsync(LogoImageFile, tenantId, schoolId, "logo");
                model.LogoUrl = logoPath;
            }

            var schoolIdResult = await _schoolSettingsService.SaveBasicProfileAsync(model, tenantId, schoolId, actionUserId);
            if (schoolIdResult <= 0)
            {
                TempData["Result"] = "0";
                TempData["Message"] = "Basic profile could not be updated.";

                await FillDropdowns(model, tenantId, schoolId);
                return View(model);
            }

            TempData["Result"] = "1";
            TempData["Message"] = "Basic profile updated successfully.";

            return RedirectToAction(nameof(BasicProfile));
        }
        private async Task<string> SaveSchoolImageAsync(IFormFile file, int tenantId, int schoolId, string imageType)
        {
            string extension = Path.GetExtension(file.FileName).ToLower();
            string[] allowedExtensions = { ".jpg", ".jpeg", ".png", ".webp" };

            if (!allowedExtensions.Contains(extension)) throw new InvalidOperationException("Only JPG, JPEG, PNG and WEBP images are allowed.");

            string folderPath = Path.Combine(_webHostEnvironment.WebRootPath, "uploads", "schools", tenantId.ToString(), schoolId.ToString());
            if (!Directory.Exists(folderPath)) Directory.CreateDirectory(folderPath);

            string fileName = imageType + "_" + DateTime.Now.ToString("yyyyMMddHHmmssfff") + extension;
            string fullPath = Path.Combine(folderPath, fileName);

            using (var stream = new FileStream(fullPath, FileMode.Create))
            {
                await file.CopyToAsync(stream);
            }

            return "/uploads/schools/" + tenantId + "/" + schoolId + "/" + fileName;
        }

        private async Task FillDropdowns(SchoolManageModel model, int tenantId, int schoolId)
        {
            var dropdowns = await _schoolSettingsService.GetBasicProfileDropdownsAsync(tenantId, schoolId);

            model.StatusList = dropdowns.Statuses.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
            model.BoardList = dropdowns.Boards.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
            model.SchoolTypeList = dropdowns.SchoolTypes.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
            model.OwnershipTypeList = dropdowns.OwnershipTypes.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
            model.MediumList = dropdowns.Mediums.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
            model.AddressTypeList = dropdowns.AddressTypes.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
            model.ContactTypeList = dropdowns.ContactTypes.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
            model.AcademicYearList = dropdowns.AcademicYears.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
            model.DateFormatList = dropdowns.DateFormats.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
            model.TimeFormatList = dropdowns.TimeFormats.Select(x => new SelectListItem { Value = x.Id.ToString(), Text = x.Name }).ToList();
        }

        #endregion

        #region AcademicSetup
        public async Task<IActionResult> AcademicSetup(int academicYearId = 0)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var academicYears = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            if (academicYearId <= 0 && academicYears.Any())
            {
                academicYearId = Convert.ToInt32(academicYears.First().Value);
            }

            var model = await _schoolSettingsService.GetAcademicSetupAsync(tenantId, schoolId, academicYearId, actionUserId);
            model ??= new AcademicSetupModel();

            model.AcademicYears = academicYears;
            model.AcademicYearId = academicYearId;

            return View(model);
        }
        [HttpPost]
        public async Task<IActionResult> SaveAcademicSetup(AcademicSetupModel model)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
            var result = await _schoolSettingsService.SaveAcademicSetupAsync(model, tenantId, schoolId, actionUserId);
            if (result > 0)
            {
                TempData["SuccessMessage"] = "Academic setup saved successfully.";
            }
            else
            {
                TempData["ErrorMessage"] = "Unable to save academic setup.";
            }
            return RedirectToAction(nameof(AcademicSetup));
        }

        #endregion

        #region FeeHead
        public async Task<IActionResult> FeeHead()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var model = new FeeHead();
            model.Operation = "SaveFeeHead";

            ViewBag.FeeHeads = await _schoolSettingsService.GetFeeHeadAsync(tenantId, schoolId, actionUserId);

            return View(model);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveFeeHead(FeeHead model)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            if (string.IsNullOrWhiteSpace(model.FeeHeadName))
            {
                TempData["ErrorMessage"] = "Please enter fee head name.";
                return RedirectToAction(nameof(FeeHead));
            }

            if (string.IsNullOrWhiteSpace(model.Frequency))
            {
                TempData["ErrorMessage"] = "Please select billing cycle.";
                return RedirectToAction(nameof(FeeHead));
            }

            if (string.IsNullOrWhiteSpace(model.FeeType))
            {
                TempData["ErrorMessage"] = "Please select fee type.";
                return RedirectToAction(nameof(FeeHead));
            }

            var result = await _schoolSettingsService.SaveFeeHeadAsync(model, tenantId, schoolId, actionUserId);

            if (result > 0)
                TempData["SuccessMessage"] = "Fee head saved successfully.";
            else
                TempData["ErrorMessage"] = "Unable to save fee head.";

            return RedirectToAction(nameof(FeeHead));
        }
        [HttpGet]
        public async Task<IActionResult> GetFeeHeadById(int id)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var model = await _schoolSettingsService.GetFeeHeadByIdAsync(id, tenantId, schoolId, actionUserId);

            if (model == null)
                return Json(new { success = false, message = "Fee head not found." });

            return Json(new { success = true, data = model });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteFeeHead(int id)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var result = await _schoolSettingsService.DeleteFeeHeadAsync(id, tenantId, schoolId, actionUserId);

            if (result > 0)
                TempData["SuccessMessage"] = "Fee head deleted successfully.";
            else
                TempData["ErrorMessage"] = "Unable to delete fee head.";

            return RedirectToAction(nameof(FeeHead));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ToggleFeeHeadStatus(int id)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var result = await _schoolSettingsService.ToggleFeeHeadStatusAsync(id, tenantId, schoolId, actionUserId);

            if (result > 0)
                TempData["SuccessMessage"] = "Fee head status updated successfully.";
            else
                TempData["ErrorMessage"] = "Unable to update fee head status.";

            return RedirectToAction(nameof(FeeHead));
        }
        #endregion

        #region FeeStructure

        [HttpGet]
        public async Task<IActionResult> FeeStructure()
        {
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value   ?? "0");

            // ── Academic years from DB (same source as AcademicSetup page) ──
            var ayItems = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            var academicYears = ayItems.Select(x => x.Text).ToList();

            // ── Classes from DB: configured via Academic Setup ───────────────
            // Use the first available academic year to load the class list.
            int firstAyId = ayItems.Any() ? Convert.ToInt32(ayItems.First().Value) : 0;
            var academicSetup = await _schoolSettingsService.GetAcademicSetupAsync(tenantId, schoolId, firstAyId, actionUserId);
            var availableClasses = academicSetup?.Classes ?? new List<string>();

            // ── Fee heads for the school ────────────────────────────────────
            var rawFeeHeads = await _schoolSettingsService.GetFeeHeadAsync(tenantId, schoolId, actionUserId);

            // ── Existing structures — marks which classes are already set up ─
            var existingStructures = await _schoolSettingsService.GetFeeStructureAsync(tenantId, schoolId, actionUserId);

            // Current academic year string (e.g. "2026-2027")
            string currentAy = academicYears.FirstOrDefault()
                ?? (DateTime.Now.Month >= 4
                    ? $"{DateTime.Now.Year}-{DateTime.Now.Year + 1}"
                    : $"{DateTime.Now.Year - 1}-{DateTime.Now.Year}");

            var model = new FeeStructureModel
            {
                AcademicYear       = currentAy,
                AvailableClasses   = availableClasses,
                AcademicYears      = academicYears,
                ExistingStructures = existingStructures,
                FeeHeads           = rawFeeHeads.Select(fh => new FeeStructureDetailModel
                {
                    FeeHeadId   = fh.FeeHeadId,
                    FeeHeadName = fh.FeeHeadName,
                    Frequency   = fh.Frequency,
                    FeeType     = fh.FeeType,
                    FeeGroup    = fh.Frequency == "One Time" ? "one-time"
                                : fh.Frequency == "Monthly"  ? "monthly"
                                :                              "yearly",
                    Amount      = fh.DefaultAmount,
                    IsSelected  = fh.FeeType == "Mandatory"
                }).ToList()
            };

            return View(model);
        }

        // Called by JS edit handler — returns saved fee head amounts for a class+year
        [HttpGet]
        public async Task<IActionResult> GetFeeStructureByClass(string className, string academicYear)
        {
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value   ?? "0");

            if (string.IsNullOrWhiteSpace(className) || string.IsNullOrWhiteSpace(academicYear))
                return Json(new { success = false, message = "Class and academic year are required." });

            var details = await _schoolSettingsService.GetFeeStructureDetailsAsync(
                className, academicYear, tenantId, schoolId, actionUserId);

            if (details == null || details.Count == 0)
                return Json(new { success = false, message = "No saved structure found for this class and year." });

            return Json(new
            {
                success = true,
                data = details.Select(d => new
                {
                    feeHeadId = d.FeeHeadId,
                    amount    = d.Amount
                })
            });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveFeeStructure(FeeStructureModel model)
        {
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value  ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value  ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value    ?? "0");

            if (string.IsNullOrWhiteSpace(model.AcademicYear))
            {
                TempData["ErrorMessage"] = "Please select an academic year.";
                return RedirectToAction(nameof(FeeStructure));
            }

            if (model.SelectedClasses == null || model.SelectedClasses.Count == 0)
            {
                TempData["ErrorMessage"] = "Please select at least one class.";
                return RedirectToAction(nameof(FeeStructure));
            }

            var selectedFeeHeads = model.FeeHeads?.Where(x => x.IsSelected).ToList();
            if (selectedFeeHeads == null || selectedFeeHeads.Count == 0)
            {
                TempData["ErrorMessage"] = "Please select at least one fee head.";
                return RedirectToAction(nameof(FeeStructure));
            }

            var result = await _schoolSettingsService.SaveFeeStructureAsync(model, tenantId, schoolId, actionUserId);

            if (result > 0)
                TempData["SuccessMessage"] = $"Fee structure saved for {model.SelectedClasses.Count} class(es).";
            else
                TempData["ErrorMessage"] = "Unable to save fee structure. Please try again.";

            return RedirectToAction(nameof(FeeStructure));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteFeeStructure(int id)
        {
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value   ?? "0");

            var result = await _schoolSettingsService.DeleteFeeStructureAsync(id, tenantId, schoolId, actionUserId);

            TempData[result > 0 ? "SuccessMessage" : "ErrorMessage"] =
                result > 0 ? "Fee structure deleted." : "Unable to delete fee structure.";

            return RedirectToAction(nameof(FeeStructure));
        }

        #endregion

        public IActionResult SubjectManagement()
        {
            ViewBag.Classes = new List<string>
            {
                "Nursery","LKG","UKG",
                "Class 1","Class 2","Class 3","Class 4","Class 5",
                "Class 6","Class 7","Class 8",
                "Class 9","Class 10",
                "Class 11 Science","Class 11 Commerce",
                "Class 12 Science","Class 12 Commerce"
            };

            return View();
        }
    }
}