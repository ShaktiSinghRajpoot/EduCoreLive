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

            // Only surface structures for classes that still exist in Academic Setup.
            // A class that was renamed/removed leaves an orphaned structure behind;
            // listing it lets the user click "Edit" on a class that has no chip to
            // select, so the form submits with no class and fails with a flashing
            // "select at least one class" error. Hide those orphans from the list.
            if (availableClasses.Count > 0)
            {
                var currentClasses = new HashSet<string>(availableClasses, StringComparer.OrdinalIgnoreCase);
                existingStructures = existingStructures
                    .Where(s => currentClasses.Contains(s.ClassName))
                    .ToList();
            }

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
                    CollectionPoint = fh.CollectionPoint,
                    IsRefundable    = fh.IsRefundable,
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
        // Enquiry CRM is owned by EnquiryController (which loads the page model).
        // Kept here so the old SchoolSettings/EnquiryCRM URL keeps working.
        public IActionResult EnquiryCRM()
        {
            return RedirectToAction("EnquiryCRM", "Enquiry");
        }
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

        #region ClassSection
        // Classes & Sections — configured per academic year. This is the single
        // page for academic structure (replaces the old AcademicSetup page); it
        // reads/writes through the same academic-setup stored procedure.
        public async Task<IActionResult> ClassSection(int academicYearId = 0)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var academicYears = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            if (academicYearId <= 0 && academicYears.Any())
            {
                // Default to the current session (falls back to the most recent year).
                var current = academicYears.FirstOrDefault(y => y.Selected) ?? academicYears.First();
                academicYearId = Convert.ToInt32(current.Value);
            }

            var setup = await _schoolSettingsService.GetAcademicSetupAsync(tenantId, schoolId, academicYearId, actionUserId);

            // Full shape the page's JS consumes (order = display order; strength is live).
            var classes = (setup?.ClassDetails ?? new List<AcademicClassDetail>()).Select(c => new
            {
                name        = c.ClassName,
                rank        = c.DisplayOrder,
                stream      = c.Stream,
                coordinator = c.Coordinator,
                sections    = c.Sections.Select(s => new
                {
                    name     = s.SectionName,
                    capacity = s.Capacity,
                    room     = s.RoomNo,
                    strength = s.Strength
                })
            });

            ViewBag.AcademicYears = academicYears;
            ViewBag.AcademicYearId = academicYearId;
            ViewBag.ClassDataJson = System.Text.Json.JsonSerializer.Serialize(classes);

            return View();
        }

        // Persists the full structure for one academic year (replace-all),
        // matching the stored procedure's semantics.
        [HttpPost]
        public async Task<IActionResult> SaveClassSection([FromBody] ClassSectionSaveDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            if (dto == null || dto.AcademicYearId <= 0)
                return Json(new { success = false, message = "Select an academic year first." });

            var model = new AcademicSetupModel { AcademicYearId = dto.AcademicYearId };

            foreach (var c in dto.Classes ?? new List<ClassSectionItemDto>())
            {
                var name = (c.Name ?? string.Empty).Trim();
                if (name.Length == 0 ||
                    model.ClassDetails.Any(x => x.ClassName.Equals(name, StringComparison.OrdinalIgnoreCase)))
                    continue;

                var sections = (c.Sections ?? new List<SectionItemDto>())
                    .Where(s => !string.IsNullOrWhiteSpace(s.Name))
                    .Select((s, i) => new AcademicSectionDetail
                    {
                        SectionName  = s.Name!.Trim(),
                        DisplayOrder = i + 1,
                        Capacity     = s.Capacity,
                        RoomNo       = string.IsNullOrWhiteSpace(s.Room) ? null : s.Room!.Trim()
                    })
                    .ToList();

                model.ClassDetails.Add(new AcademicClassDetail
                {
                    ClassName    = name,
                    DisplayOrder = c.Rank,
                    Stream       = string.IsNullOrWhiteSpace(c.Stream) ? null : c.Stream!.Trim(),
                    Coordinator  = string.IsNullOrWhiteSpace(c.Coordinator) ? null : c.Coordinator!.Trim(),
                    Sections     = sections
                });
            }

            int result;
            try
            {
                result = await _schoolSettingsService.SaveAcademicSetupAsync(model, tenantId, schoolId, actionUserId);
            }
            catch (Npgsql.PostgresException ex)
            {
                // Surfaces the "students still enrolled" guard (and any other SP RAISE).
                return Json(new { success = false, message = ex.MessageText });
            }

            return Json(new { success = result > 0 });
        }
        #endregion

        #region AcademicYear
        // Academic Year / Session management — create, edit, set-current, delete.
        public async Task<IActionResult> AcademicYears()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var years = await _schoolSettingsService.GetAcademicYearsAsync(tenantId, schoolId, actionUserId);

            ViewBag.YearsJson = System.Text.Json.JsonSerializer.Serialize(years.Select(y => new
            {
                id           = y.AcademicYearId,
                name         = y.AcademicYearName,
                startDate    = y.StartDate?.ToString("yyyy-MM-dd"),
                endDate      = y.EndDate?.ToString("yyyy-MM-dd"),
                isCurrent    = y.IsCurrent,
                classCount   = y.ClassCount,
                studentCount = y.StudentCount
            }));

            return View();
        }

        [HttpPost]
        public async Task<IActionResult> SaveAcademicYear([FromBody] AcademicYearSaveDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            if (dto == null || string.IsNullOrWhiteSpace(dto.Name))
                return Json(new { success = false, message = "Academic year name is required." });

            var model = new AcademicYearModel
            {
                AcademicYearId   = dto.Id,
                AcademicYearName = dto.Name.Trim(),
                StartDate        = ParseDate(dto.StartDate),
                EndDate          = ParseDate(dto.EndDate),
                IsCurrent        = dto.IsCurrent
            };

            try
            {
                var (ok, msg, id) = await _schoolSettingsService.SaveAcademicYearAsync(model, tenantId, schoolId, actionUserId);
                return Json(new { success = ok, message = msg, id });
            }
            catch (Npgsql.PostgresException ex)
            {
                return Json(new { success = false, message = ex.MessageText });
            }
        }

        [HttpPost]
        public async Task<IActionResult> SetCurrentAcademicYear([FromBody] AcademicYearIdDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            try
            {
                var (ok, msg) = await _schoolSettingsService.SetCurrentAcademicYearAsync(dto?.Id ?? 0, tenantId, schoolId, actionUserId);
                return Json(new { success = ok, message = msg });
            }
            catch (Npgsql.PostgresException ex)
            {
                return Json(new { success = false, message = ex.MessageText });
            }
        }

        [HttpPost]
        public async Task<IActionResult> DeleteAcademicYear([FromBody] AcademicYearIdDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            try
            {
                var (ok, msg) = await _schoolSettingsService.DeleteAcademicYearAsync(dto?.Id ?? 0, tenantId, schoolId, actionUserId);
                return Json(new { success = ok, message = msg });
            }
            catch (Npgsql.PostgresException ex)
            {
                return Json(new { success = false, message = ex.MessageText });
            }
        }

        private static DateTime? ParseDate(string? s) =>
            DateTime.TryParse(s, out var d) ? d : (DateTime?)null;
        #endregion

        public IActionResult AssignClassTeacher()
        {
            return View();
        }

        public IActionResult Timetable()
        {
            return View();
        }

        public IActionResult PeriodStructure()
        {
            return View();
        }
    }

    // ── Payload for the Classes & Sections save (per academic year) ──
    public class ClassSectionSaveDto
    {
        public int AcademicYearId { get; set; }
        public List<ClassSectionItemDto> Classes { get; set; } = new();
    }

    public class ClassSectionItemDto
    {
        public string? Name { get; set; }
        public int Rank { get; set; }
        public string? Stream { get; set; }
        public string? Coordinator { get; set; }
        public List<SectionItemDto> Sections { get; set; } = new();
    }

    public class SectionItemDto
    {
        public string? Name { get; set; }
        public int? Capacity { get; set; }
        public string? Room { get; set; }
    }

    // ── Payload for Academic Year / Session save ──
    public class AcademicYearSaveDto
    {
        public int Id { get; set; }
        public string? Name { get; set; }
        public string? StartDate { get; set; }
        public string? EndDate { get; set; }
        public bool IsCurrent { get; set; }
    }

    public class AcademicYearIdDto
    {
        public int Id { get; set; }
    }
}