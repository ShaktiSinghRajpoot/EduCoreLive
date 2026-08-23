using educore.Models;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using System.Threading.Tasks;

namespace educore.Areas.ERP.Controllers
{ 
    [Area("ERP")]
    //[Authorize(Roles = AppRoles.SchoolAdmin)]
    public class SchoolSettingsController : Controller
    {
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IBaseService _baseService;
        private readonly IWebHostEnvironment _webHostEnvironment;
        private readonly IStaffService _staffService;
        private readonly IClassTeacherService _classTeacherService;
        private readonly ISchoolCalendarService _schoolCalendarService;
        private readonly ISubjectService _subjectService;
        private readonly ITimetableService _timetableService;

        public SchoolSettingsController(ISchoolSettingsService schoolSettingsService, IBaseService BaseService, IWebHostEnvironment webHostEnvironment, IStaffService staffService, IClassTeacherService classTeacherService, ISchoolCalendarService schoolCalendarService, ISubjectService subjectService, ITimetableService timetableService)
        {
            _schoolSettingsService = schoolSettingsService;
            _baseService = BaseService;
            _webHostEnvironment = webHostEnvironment;
            _staffService = staffService;
            _classTeacherService = classTeacherService;
            _schoolCalendarService = schoolCalendarService;
            _subjectService = subjectService;
            _timetableService = timetableService;
        }

        #region BasicProfile
        [HttpGet]
        [HasPermission("settings.view")]
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
        [HasPermission("settings.manage")]
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


        #region Documents
        // Print formats for everything the school hands out (fee receipt today; TC and
        // ID card once those documents exist). The school profile holds identity data —
        // how a document prints belongs here, not there.
        [HttpGet]
        [HasPermission("settings.view")]
        public async Task<IActionResult> Documents()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            // The letterhead (name, address, logo) so the preview looks like the real print.
            var model = await _schoolSettingsService.GetBasicProfileAsync(tenantId, schoolId, actionUserId);

            if (model == null) return RedirectToAction("AccessDenied", "Account", new { area = "" });

            ViewBag.ReceiptFormat = await _schoolSettingsService.GetReceiptFormatAsync(tenantId, schoolId, actionUserId);
            ViewBag.TcFormat      = await _schoolSettingsService.GetTcFormatAsync(tenantId, schoolId, actionUserId);
            ViewBag.IdCardFormat  = await _schoolSettingsService.GetIdCardFormatAsync(tenantId, schoolId, actionUserId);

            return View(model);
        }

        // Save the default Transfer Certificate format (Documents & Formats page).
        public class TcFormatDto { public string? Format { get; set; } }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]
        public async Task<IActionResult> SaveTcFormat([FromBody] TcFormatDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var ok = await _schoolSettingsService.SaveTcFormatAsync(dto?.Format ?? "Basic", tenantId, schoolId, actionUserId);
            return Json(new { success = ok, message = ok ? "Transfer Certificate format saved." : "Could not save the format." });
        }

        // Save the default student ID-card layout (Documents & Formats page).
        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]
        public async Task<IActionResult> SaveIdCardFormat([FromBody] TcFormatDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var ok = await _schoolSettingsService.SaveIdCardFormatAsync(dto?.Format ?? "Portrait", tenantId, schoolId, actionUserId);
            return Json(new { success = ok, message = ok ? "ID card layout saved." : "Could not save the layout." });
        }
        #endregion


        #region FeeHead
        [HasPermission("fees.view")]
        public async Task<IActionResult> FeeHead(FeeHead query)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            // The SAME model drives the whole page: add-form fields (empty here),
            // the grid (query.Items) and the pager/filter (Page, Search, SortColumn…),
            // all bound from the query string. Server-side paging + sorting + search.
            query.Operation = "SaveFeeHead";
            await _schoolSettingsService.GetFeeHeadPageAsync(query, tenantId, schoolId, actionUserId);

            return View(query);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("fees.manage")]
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
        [HasPermission("fees.view")]
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
        [HasPermission("fees.manage")]
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
        [HasPermission("fees.manage")]
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
        [HasPermission("fees.view")]
        public async Task<IActionResult> FeeStructure()
        {
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value   ?? "0");

            // ── Academic years from DB (same source as AcademicSetup page) ──
            var ayItems = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", tenantId.ToString(), schoolId.ToString());
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
        [HasPermission("fees.view")]
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
        [HasPermission("fees.manage")]
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
        [HasPermission("fees.manage")]
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
        [HasPermission("enquiry.view")]
        public IActionResult EnquiryCRM()
        {
            return RedirectToAction("EnquiryCRM", "Enquiry");
        }
        [HasPermission("academics.view")]
        public async Task<IActionResult> SubjectManagement(int academicYearId = 0)
        {
            // class_subjects is keyed per session, so the page needs to know which
            // one. Same picker pattern as Classes & Sections.
            academicYearId = await ResolveSessionAsync(academicYearId);

            // The school's real classes for that session, each with its saved
            // subject count. The page then loads/saves one class at a time.
            ViewBag.Classes = await _subjectService.GetClassesAsync(
                SmTenant(), SmSchool(), SmUser(), academicYearId);
            return View();
        }

        // Session list + resolved id for the setup pages, so each one does not
        // repeat the "default to current" logic. Sets the two ViewBag keys the
        // pickers read.
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

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> ClassSubjects(int classId, int academicYearId = 0)
        {
            var subjects = await _subjectService.GetClassSubjectsAsync(
                classId, SmTenant(), SmSchool(), SmUser(), academicYearId);
            return Json(subjects.Select(s => s.SubjectName));
        }

        public class ClassSubjectsDto
        {
            public int ClassId { get; set; }
            public List<string> Subjects { get; set; } = new();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> SaveClassSubjects([FromBody] ClassSubjectsDto dto)
        {
            var result = await _subjectService.SaveClassSubjectsAsync(
                dto?.ClassId ?? 0, dto?.Subjects ?? new List<string>(), SmTenant(), SmSchool(), SmUser());

            return Json(new { success = result.Success, count = result.SubjectCount, message = result.Message });
        }

        #region ClassSection
        // Classes & Sections — configured per academic year. This is the single
        // page for academic structure (replaces the old AcademicSetup page); it
        // reads/writes through the same academic-setup stored procedure.
        [HasPermission("academics.view")]
        public async Task<IActionResult> ClassSection(int academicYearId = 0)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var academicYears = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", tenantId.ToString(), schoolId.ToString());
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
                coordinatorStaffId = c.CoordinatorStaffId,
                sections    = c.Sections.Select(s => new
                {
                    name     = s.SectionName,
                    capacity = s.Capacity,
                    room     = s.RoomNo,
                    strength = s.Strength,
                    teacher  = s.ClassTeacher
                })
            });

            // Teaching staff for the class-coordinator dropdown (coordinator is a
            // staff member, not free text).
            // Teaching staff for the coordinator dropdown — server-rendered options.
            var coordinators = (await _staffService.GetStaffAsync(tenantId, schoolId, actionUserId))
                .Where(s => string.Equals(s.StaffType, "Teaching", StringComparison.OrdinalIgnoreCase))
                .Select(s => new SelectListItem
                {
                    Value = s.StaffId.ToString(),
                    Text = s.FullName + (string.IsNullOrWhiteSpace(s.Designation) ? "" : $" ({s.Designation})")
                }).ToList();

            // A session with no classes cannot be used by anything downstream
            // (promotion has no ladder, the pickers are blank). Offer to copy the
            // previous session's structure instead of making them retype it.
            var structure = await _schoolSettingsService.GetSessionStructureAsync(
                tenantId, schoolId, actionUserId, academicYearId);

            ViewBag.AcademicYears = academicYears;
            ViewBag.AcademicYearId = academicYearId;
            ViewBag.ClassDataJson = System.Text.Json.JsonSerializer.Serialize(classes);
            ViewBag.Coordinators = coordinators;
            ViewBag.CanCopySetup = structure.ClassCount == 0 && structure.CanCopy;
            ViewBag.CopyFromYearId = structure.SourceYearId;
            ViewBag.CopyFromYearName = structure.SourceYearName;

            return View();
        }

        // Copies the previous session's classes + sections into this one — the
        // rollover step that has to happen before students can be promoted in.
        [HttpPost]
        [HasPermission("academics.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CopyClassSection([FromBody] CopyClassSectionDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            if (dto == null || dto.FromAcademicYearId <= 0 || dto.ToAcademicYearId <= 0)
                return Json(new { success = false, message = "Choose both sessions." });

            var result = await _schoolSettingsService.CloneAcademicYearAsync(
                dto.FromAcademicYearId, dto.ToAcademicYearId, tenantId, schoolId, actionUserId);

            return Json(new
            {
                success        = result.Success,
                message        = result.Message,
                classesCopied  = result.ClassesCopied,
                sectionsCopied = result.SectionsCopied
            });
        }

        // Persists the full structure for one academic year (replace-all),
        // matching the stored procedure's semantics.
        [HttpPost]
        [HasPermission("academics.manage")]
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
                    CoordinatorStaffId = c.CoordinatorStaffId is > 0 ? c.CoordinatorStaffId : null,
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
        [HasPermission("settings.view")]
        public async Task<IActionResult> AcademicYears()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            // Pass the list straight to the view for server-side rendering (no JSON blob).
            ViewBag.Years = await _schoolSettingsService.GetAcademicYearsAsync(tenantId, schoolId, actionUserId);

            return View();
        }

        [HttpPost]
        [HasPermission("settings.manage")]
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
        [HasPermission("settings.manage")]
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
        [HasPermission("settings.manage")]
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

        #region StaffMasters (Departments & Designations)
        // School-editable reference masters, kept under Settings alongside Users
        // & Roles. Feed the Add/Edit Staff dropdowns; staff_type is derived per
        // designation from its department.
        [HasPermission("staff.view")]
        public async Task<IActionResult> StaffMasters()
        {
            var masters = await _staffService.GetMastersAsync(SmTenant(), SmSchool(), SmUser());
            return View(masters);
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveDepartment([FromBody] EduCoreDataAccessLayer.Models.DepartmentMaster dept)
        {
            if (dept == null || string.IsNullOrWhiteSpace(dept.Name))
                return Json(new { success = false, message = "Department name is required." });
            var (ok, msg) = await _staffService.SaveDepartmentAsync(dept, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveDesignation([FromBody] EduCoreDataAccessLayer.Models.DesignationMaster desig)
        {
            if (desig == null || string.IsNullOrWhiteSpace(desig.Name))
                return Json(new { success = false, message = "Designation name is required." });
            var (ok, msg) = await _staffService.SaveDesignationAsync(desig, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteMaster(string kind, int id)
        {
            var (ok, msg) = await _staffService.DeleteMasterAsync(kind, id, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ToggleMaster(string kind, int id)
        {
            var (ok, msg) = await _staffService.ToggleMasterAsync(kind, id, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message = msg });
        }

        private int SmTenant() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SmSchool() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int SmUser()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        #endregion

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> AssignClassTeacher(int academicYearId = 0)
        {
            // Sections are per session, so the grid belongs to one.
            await ResolveSessionAsync(academicYearId);
            return View();
        }

        // ── Assign Class Teacher: real data for the grid ──
        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> ClassTeacherGrid(int academicYearId = 0)
        {
            var grid = await _classTeacherService.GetGridAsync(
                SmTenant(), SmSchool(), SmUser(), academicYearId);
            return Json(grid);
        }

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> ClassTeacherPool()
        {
            var teachers = await _classTeacherService.GetTeachersAsync(SmTenant(), SmSchool(), SmUser());
            return Json(teachers);
        }

        public class AssignClassTeacherDto { public int SectionId { get; set; } public int? StaffId { get; set; } }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> AssignClassTeacher([FromBody] AssignClassTeacherDto dto)
        {
            var (ok, message) = await _classTeacherService.AssignAsync(dto.SectionId, dto.StaffId, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message });
        }

        #region Timetable
        // The weekly grid. Periods come from Period Structure, day columns from the
        // School Calendar's weekly offs, sections/subjects/teachers from their own
        // masters — the page holds no data of its own.
        [HasPermission("academics.view")]
        public async Task<IActionResult> Timetable(int academicYearId = 0)
        {
            // Sections are per session, so the grid belongs to one.
            await ResolveSessionAsync(academicYearId);
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
        #endregion

        #region PeriodStructure
        // The daily bell schedule — one schedule per school. The list seeds the
        // page; Save posts the whole schedule back (replace-all).
        [HasPermission("academics.view")]
        public async Task<IActionResult> PeriodStructure()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var periods = await _schoolSettingsService.GetPeriodStructureAsync(tenantId, schoolId, actionUserId);

            // Shape the page's JS consumes: name / start / end / type.
            var shaped = periods.Select(p => new
            {
                id    = p.PeriodId,
                name  = p.Label,
                start = p.StartTime,
                end   = p.EndTime,
                type  = p.PeriodType
            });
            ViewBag.PeriodJson = System.Text.Json.JsonSerializer.Serialize(shaped);

            return View();
        }

        // Smart Bell — a live kiosk display driven by the same schedule. Read-only:
        // it just needs the periods, the SERVER clock and today's calendar status;
        // the countdown + bell run in the browser off that seed.
        [HasPermission("academics.view")]
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

            var now     = DateTime.Now;                    // server wall clock — the single source of truth
            var periods = await _schoolSettingsService.GetPeriodStructureAsync(tenantId, schoolId, actionUserId);
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

        [HttpPost]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> SavePeriodStructure([FromBody] PeriodStructureSaveDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var items = (dto?.Periods ?? new List<PeriodItemDto>()).Select(p => new PeriodStructureItem
            {
                Label      = (p.Name ?? string.Empty).Trim(),
                StartTime  = p.Start ?? string.Empty,
                EndTime    = p.End ?? string.Empty,
                PeriodType = string.IsNullOrWhiteSpace(p.Type) ? "class" : p.Type!.Trim().ToLowerInvariant()
            }).ToList();

            var result = await _schoolSettingsService.SavePeriodStructureAsync(items, tenantId, schoolId, actionUserId);
            return Json(new { success = result.Success, message = result.Message });
        }
        #endregion

        #region School Calendar
        // Working-day calendar: weekly off pattern + dated holiday / half-day /
        // working-day overrides. Feeds the Smart Bell and anything else that needs
        // to know whether the school is open.
        [HasPermission("academics.view")]
        public IActionResult SchoolCalendar()
        {
            return View();
        }

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> SchoolCalendarData(int? year)
        {
            var y    = year is >= 2000 and <= 2100 ? year.Value : DateTime.Now.Year;
            var from = new DateTime(y, 1, 1);
            var data = await _schoolCalendarService.GetCalendarAsync(
                from, from.AddYears(1).AddDays(-1), SmTenant(), SmSchool(), SmUser());

            return Json(new { year = y, weeklyOffDays = data.WeeklyOffDays, entries = data.Entries });
        }

        public class CalendarEntryDto
        {
            public string  Date       { get; set; } = string.Empty;   // yyyy-MM-dd
            public string  DayType    { get; set; } = "holiday";
            public string  Title      { get; set; } = string.Empty;
            public string? HalfDayEnd { get; set; }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> SaveCalendarEntry([FromBody] CalendarEntryDto dto)
        {
            var result = await _schoolCalendarService.SaveEntryAsync(new SchoolCalendarEntry
            {
                Date       = dto?.Date ?? string.Empty,
                DayType    = dto?.DayType ?? "holiday",
                Title      = dto?.Title ?? string.Empty,
                HalfDayEnd = dto?.HalfDayEnd
            }, SmTenant(), SmSchool(), SmUser());

            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> DeleteCalendarEntry([FromBody] IdDto dto)
        {
            var result = await _schoolCalendarService.DeleteEntryAsync(dto?.Id ?? 0, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = result.Success, message = result.Message });
        }

        public class IdDto { public int Id { get; set; } }
        public class WeeklyOffDto { public List<int> Days { get; set; } = new(); }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> SaveWeeklyOff([FromBody] WeeklyOffDto dto)
        {
            var result = await _schoolCalendarService.SaveWeeklyOffAsync(
                dto?.Days ?? new List<int>(), SmTenant(), SmSchool(), SmUser());

            return Json(new { success = result.Success, message = result.Message });
        }

        #endregion
    }

    // ── Payload for the Classes & Sections save (per academic year) ──
    public class ClassSectionSaveDto
    {
        public int AcademicYearId { get; set; }
        public List<ClassSectionItemDto> Classes { get; set; } = new();
    }

    // ── Payload for copying one session's structure into another ──
    public class CopyClassSectionDto
    {
        public int FromAcademicYearId { get; set; }
        public int ToAcademicYearId { get; set; }
    }

    public class ClassSectionItemDto
    {
        public string? Name { get; set; }
        public int Rank { get; set; }
        public string? Stream { get; set; }
        public string? Coordinator { get; set; }
        public int? CoordinatorStaffId { get; set; }
        public List<SectionItemDto> Sections { get; set; } = new();
    }

    public class SectionItemDto
    {
        public string? Name { get; set; }
        public int? Capacity { get; set; }
        public string? Room { get; set; }
    }

    // ── Payload for the Period Structure save (whole schedule, replace-all) ──
    public class PeriodStructureSaveDto
    {
        public List<PeriodItemDto> Periods { get; set; } = new();
    }

    public class PeriodItemDto
    {
        public string? Name  { get; set; }
        public string? Start { get; set; }   // HH:mm
        public string? End   { get; set; }   // HH:mm
        public string? Type  { get; set; }   // class | break | lunch
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