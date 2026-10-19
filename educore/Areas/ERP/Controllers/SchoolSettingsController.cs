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
        private readonly IConfiguration _config;
        private readonly IStaffService _staffService;
        private readonly IClassTeacherService _classTeacherService;
        private readonly ISchoolCalendarService _schoolCalendarService;
        private readonly ISubjectService _subjectService;
        private readonly ITimetableService _timetableService;
        private readonly IAdmissionWorkflowService _admissionWorkflowService;

        public SchoolSettingsController(ISchoolSettingsService schoolSettingsService, IBaseService BaseService, IWebHostEnvironment webHostEnvironment, IStaffService staffService, IClassTeacherService classTeacherService, ISchoolCalendarService schoolCalendarService, ISubjectService subjectService, ITimetableService timetableService, IAdmissionWorkflowService admissionWorkflowService, IConfiguration config)
        {
            _schoolSettingsService = schoolSettingsService;
            _baseService = BaseService;
            _webHostEnvironment = webHostEnvironment;
            _config = config;
            _staffService = staffService;
            _classTeacherService = classTeacherService;
            _schoolCalendarService = schoolCalendarService;
            _subjectService = subjectService;
            _timetableService = timetableService;
            _admissionWorkflowService = admissionWorkflowService;
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
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "settings.manage");

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

            // The page accepts "school.com", so add the scheme here rather than
            // failing [Url] with "Enter valid website URL." after the page said OK.
            if (!string.IsNullOrWhiteSpace(model.Website))
            {
                model.Website = model.Website.Trim();
                if (!model.Website.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                    && !model.Website.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                {
                    model.Website = "https://" + model.Website;
                    ModelState.Remove(nameof(model.Website));
                    if (!new System.ComponentModel.DataAnnotations.UrlAttribute().IsValid(model.Website))
                        ModelState.AddModelError(nameof(model.Website), "Enter valid website URL.");
                }
            }

            // Official / alternate phone may be a landline too (PhoneRules). The model's
            // mobile-only regex stays for the SuperAdmin wizard, so drop its verdict
            // here and apply the wider rule. Stored as digits only.
            ModelState.Remove(nameof(model.Phone));
            ModelState.Remove(nameof(model.AlternatePhone));
            if (string.IsNullOrWhiteSpace(model.Phone))
                ModelState.AddModelError(nameof(model.Phone), "Phone number is required.");
            else if (!PhoneRules.IsValid(model.Phone))
                ModelState.AddModelError(nameof(model.Phone), PhoneRules.Message);
            else
                model.Phone = PhoneRules.Clean(model.Phone)!;

            if (string.IsNullOrWhiteSpace(model.AlternatePhone))
                model.AlternatePhone = null;
            else if (!PhoneRules.IsValid(model.AlternatePhone))
                ModelState.AddModelError(nameof(model.AlternatePhone), PhoneRules.Message);
            else
                model.AlternatePhone = PhoneRules.Clean(model.AlternatePhone);

            // The model allows up to 2100; a school cannot be established in the future.
            if (model.EstablishedYear > Dates.Now.Year)
                ModelState.AddModelError(nameof(model.EstablishedYear), "Enter valid established year.");

            // Server-side logo validation
            if (LogoImageFile != null && LogoImageFile.Length > 0)
            {
                var allowedTypes = new[] { "image/jpeg", "image/png", "image/webp" };
                var allowedExtensions = new[] { ".jpg", ".jpeg", ".png", ".webp" };

                if (!allowedTypes.Contains(LogoImageFile.ContentType.ToLower()))
                {
                    ModelState.AddModelError("LogoImageFile", "Only JPG, PNG or WEBP image is allowed.");
                }
                // Checked here too: SaveSchoolImageAsync throws on any other
                // extension, and a .jfif JPEG passed the content-type check.
                else if (!allowedExtensions.Contains(Path.GetExtension(LogoImageFile.FileName).ToLower()))
                {
                    ModelState.AddModelError("LogoImageFile", "Only .jpg, .jpeg, .png or .webp files are allowed.");
                }

                if (LogoImageFile.Length > 2 * 1024 * 1024)
                {
                    ModelState.AddModelError("LogoImageFile", "Logo image must be less than 2 MB.");
                }
            }

            if (!ModelState.IsValid)
            {
                await RestoreReadOnlyFields(model, tenantId, schoolId, actionUserId);
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

                await RestoreReadOnlyFields(model, tenantId, schoolId, actionUserId);
                await FillDropdowns(model, tenantId, schoolId);
                return View(model);
            }

            TempData["Result"] = "1";
            TempData["Message"] = "Basic profile updated successfully.";

            return RedirectToAction(nameof(BasicProfile));
        }

        // Take the logo off (receipts, TC and ID cards then print without one).
        // The proc clears logo_url and hands back the old URL; the file is deleted
        // only when that URL is in THIS school's upload folder, and the name is cut
        // down to a bare file name so the path cannot walk anywhere else (the same
        // rule as the student photo replace in StudentController).
        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]
        public async Task<IActionResult> RemoveLogo()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var (ok, message, oldUrl) = await _schoolSettingsService.RemoveLogoAsync(tenantId, schoolId, actionUserId);

            var prefix = UploadPaths.UrlFor("schools", tenantId, schoolId, "");
            if (ok && !string.IsNullOrWhiteSpace(oldUrl)
                   && oldUrl.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                var oldName = Path.GetFileName(oldUrl);
                if (!string.IsNullOrWhiteSpace(oldName))
                {
                    var folder = UploadPaths.FolderFor(_config, _webHostEnvironment, "schools", tenantId, schoolId);
                    try { System.IO.File.Delete(Path.Combine(folder, oldName)); } catch { }
                }
            }

            return Json(new { success = ok, message });
        }

        // ── School Setup › Seal & Signature ─────────────────────────────────────
        // The head of school's signature and the school seal, printed on certificates,
        // report cards, circulars, TC and admit cards (Views/Shared/_HeadSignature).
        [HttpGet]
        [HasPermission("settings.view")]
        public async Task<IActionResult> SealSignature()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "settings.manage");
            var model = await _schoolSettingsService.GetBasicProfileAsync(tenantId, schoolId, actionUserId) ?? new SchoolManageModel();
            return View(model);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]
        public async Task<IActionResult> UploadSignature(string kind, IFormFile? file)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            if (kind != "signature" && kind != "seal") return Json(new { success = false, message = "Choose signature or seal." });
            if (file == null || file.Length == 0) return Json(new { success = false, message = "Choose an image." });
            if (file.Length > 1024 * 1024) return Json(new { success = false, message = "The image must be under 1 MB." });

            string url;
            try { url = await SaveSchoolImageAsync(file, tenantId, schoolId, kind); }
            catch (InvalidOperationException ex) { return Json(new { success = false, message = ex.Message }); }

            var (ok, message, oldUrl) = await _schoolSettingsService.SaveSignatureImageAsync(kind, url, tenantId, schoolId, actionUserId);
            DeleteSchoolFile(ok ? oldUrl : url, tenantId, schoolId);   // the replaced file, or the new one when refused
            return Json(new { success = ok, message, url = ok ? url : null });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]
        public async Task<IActionResult> RemoveSignature(string kind)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var (ok, message, oldUrl) = await _schoolSettingsService.RemoveSignatureImageAsync(kind, tenantId, schoolId, actionUserId);
            if (ok) DeleteSchoolFile(oldUrl, tenantId, schoolId);
            return Json(new { success = ok, message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]
        public async Task<IActionResult> SaveSignatory(string? name, string? designation)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var (ok, message, _) = await _schoolSettingsService.SaveSignatoryAsync(name, designation, tenantId, schoolId, actionUserId);
            return Json(new { success = ok, message });
        }

        // Deletes a file only when its URL is in THIS school's upload folder, cut down to
        // a bare file name (same rule as RemoveLogo).
        private void DeleteSchoolFile(string? url, int tenantId, int schoolId)
        {
            var prefix = UploadPaths.UrlFor("schools", tenantId, schoolId, "");
            if (string.IsNullOrWhiteSpace(url) || !url.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return;
            var name = Path.GetFileName(url);
            if (string.IsNullOrWhiteSpace(name)) return;
            var folder = UploadPaths.FolderFor(_config, _webHostEnvironment, "schools", tenantId, schoolId);
            try { System.IO.File.Delete(Path.Combine(folder, name)); } catch { }
        }

        private async Task<string> SaveSchoolImageAsync(IFormFile file, int tenantId, int schoolId, string imageType)
        {
            string extension = Path.GetExtension(file.FileName).ToLower();
            string[] allowedExtensions = { ".jpg", ".jpeg", ".png", ".webp" };

            if (!allowedExtensions.Contains(extension)) throw new InvalidOperationException("Only JPG, JPEG, PNG and WEBP images are allowed.");

            string folderPath = UploadPaths.FolderFor(_config, _webHostEnvironment, "schools", tenantId, schoolId);

            string fileName = imageType + "_" + Dates.Now.ToString("yyyyMMddHHmmssfff") + extension;
            string fullPath = Path.Combine(folderPath, fileName);

            using (var stream = new FileStream(fullPath, FileMode.Create))
            {
                await file.CopyToAsync(stream);
            }

            return UploadPaths.UrlFor("schools", tenantId, schoolId, fileName);
        }

        // The form does not post the display-only fields (tenant, status, board and
        // its state lock, logo), so re-read them when the page is shown again after
        // a failed save. Otherwise the sidebar read "Tenant not available".
        private async Task RestoreReadOnlyFields(SchoolManageModel model, int tenantId, int schoolId, int actionUserId)
        {
            var saved = await _schoolSettingsService.GetBasicProfileAsync(tenantId, schoolId, actionUserId);
            if (saved == null) return;

            model.SchoolName         = saved.SchoolName;
            model.SchoolCode         = saved.SchoolCode;
            model.TenantName         = saved.TenantName;
            model.TenantCode         = saved.TenantCode;
            model.StatusId           = saved.StatusId;
            model.StatusName         = saved.StatusName;
            model.BoardId            = saved.BoardId;
            model.BoardName          = saved.BoardName;
            model.BoardStateId       = saved.BoardStateId;
            model.BoardRequiresState = saved.BoardRequiresState;
            model.SchoolTypeName     = saved.SchoolTypeName;
            model.CategoryName       = saved.CategoryName;
            model.BoardLabel         = saved.BoardLabel;
            model.TypeLabel          = saved.TypeLabel;
            model.LogoUrl            = saved.LogoUrl;
            model.HeaderImageUrl     = saved.HeaderImageUrl;
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
            // Add / edit / delete buttons are shown only with academics.manage
            // (a teacher has academics.view and would be refused on save).
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "academics.manage");
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
            // A session that has its classes can still take subjects / class teachers /
            // timetable from the earlier one.
            ViewBag.CanCopyExtras = structure.ClassCount > 0 && structure.SourceYearId > 0;
            ViewBag.CopyFromYearId = structure.SourceYearId;
            ViewBag.CopyFromYearName = structure.SourceYearName;
            // Add / edit / delete buttons are shown only with academics.manage
            // (a teacher has academics.view and would be refused on save).
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "academics.manage");

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

        // Subjects, class teachers and the timetable from an earlier session into this one
        // (which already has its classes). Anything already set is kept.
        [HttpPost]
        [HasPermission("academics.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CopySessionSetup([FromBody] CopySessionSetupDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            if (dto == null || dto.FromAcademicYearId <= 0 || dto.ToAcademicYearId <= 0)
                return Json(new { success = false, message = "Choose both sessions." });
            if (!dto.Subjects && !dto.Teachers && !dto.Timetable)
                return Json(new { success = false, message = "Tick at least one thing to copy." });

            var (ok, msg) = await _schoolSettingsService.CopySessionSetupAsync(
                dto.FromAcademicYearId, dto.ToAcademicYearId, dto.Subjects, dto.Teachers, dto.Timetable,
                tenantId, schoolId, actionUserId);
            return Json(new { success = ok, message = msg });
        }

        // Limits below match the academic.academic_classes / academic_class_sections
        // column widths. Without them an over-long name reaches PostgreSQL and the
        // user is shown the raw "value too long for type character varying(20)".
        private const int ClassNameMaxLength   = 50;
        private const int SectionNameMaxLength = 20;
        private const int CoordinatorMaxLength = 150;
        private const int RoomMaxLength        = 50;
        private const int RankMaxValue         = 999;
        private const int CapacityMaxValue     = 5000;

        // The values the page's stream dropdown offers. "sci" is the old single
        // Science option, still accepted so classes saved before the PCM/PCB split
        // can be re-saved without being rejected.
        private static readonly string[] AllowedStreams = { "gen", "pcm", "pcb", "com", "art", "voc", "sci" };

        // Persists the full structure for one academic year. Classes/sections not
        // in the payload are removed; the rest are updated in place (ids kept, so
        // subjects, exams, timetable and class teachers stay attached).
        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> SaveClassSection([FromBody] ClassSectionSaveDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            if (dto == null || dto.AcademicYearId <= 0)
                return Json(new { success = false, message = "Select an academic year first." });

            var model = new AcademicSetupModel { AcademicYearId = dto.AcademicYearId };

            // The page checks all of this in the browser, but the browser is not
            // the last word: a stale tab or a hand-made POST reaches the same
            // action. Reject a bad payload with a message instead of silently
            // dropping the offending row and reporting success.
            foreach (var c in dto.Classes ?? new List<ClassSectionItemDto>())
            {
                var name = (c.Name ?? string.Empty).Trim();
                if (name.Length == 0)
                    return Json(new { success = false, message = "Class name is required." });
                if (name.Length > ClassNameMaxLength)
                    return Json(new { success = false, message = $"Class name \"{name}\" is longer than {ClassNameMaxLength} characters." });
                if (model.ClassDetails.Any(x => x.ClassName.Equals(name, StringComparison.OrdinalIgnoreCase)))
                    return Json(new { success = false, message = $"There are two classes named \"{name}\". Two streams need two class names, e.g. \"{name} Science (PCM)\" and \"{name} Commerce\"." });
                if (c.Rank < 1 || c.Rank > RankMaxValue)
                    return Json(new { success = false, message = $"Order for \"{name}\" must be between 1 and {RankMaxValue}." });

                var stream = string.IsNullOrWhiteSpace(c.Stream) ? null : c.Stream!.Trim();
                // Stream drives a CSS class on the page, so only the four the
                // dropdown offers are allowed through.
                if (stream != null && !AllowedStreams.Contains(stream))
                    return Json(new { success = false, message = $"\"{name}\" has an unknown stream." });

                // Rank is the promotion order. Only stream variants of one class
                // (Class 11 PCM, Class 11 Commerce) may share it.
                bool isStream = stream != null && stream != "gen";
                var rankClash = model.ClassDetails.FirstOrDefault(x => x.DisplayOrder == c.Rank
                    && (!isStream || string.IsNullOrEmpty(x.Stream) || x.Stream == "gen"));
                if (rankClash != null)
                    return Json(new { success = false, message = $"Order {c.Rank} is used by both \"{rankClash.ClassName}\" and \"{name}\". Only stream classes (e.g. Class 11 PCM and Class 11 Commerce) can share an order." });

                var coordinator = string.IsNullOrWhiteSpace(c.Coordinator) ? null : c.Coordinator!.Trim();
                if (coordinator != null && coordinator.Length > CoordinatorMaxLength)
                    return Json(new { success = false, message = $"Coordinator name for \"{name}\" is longer than {CoordinatorMaxLength} characters." });

                var sections = new List<AcademicSectionDetail>();
                foreach (var s in c.Sections ?? new List<SectionItemDto>())
                {
                    var sectionName = (s.Name ?? string.Empty).Trim();
                    if (sectionName.Length == 0)
                        return Json(new { success = false, message = $"A section of \"{name}\" has no name." });
                    if (sectionName.Length > SectionNameMaxLength)
                        return Json(new { success = false, message = $"Section name \"{sectionName}\" is longer than {SectionNameMaxLength} characters." });
                    // Nothing in the database stops this, and everything downstream
                    // (enrolment, attendance, fees) joins sections by name.
                    if (sections.Any(x => x.SectionName.Equals(sectionName, StringComparison.OrdinalIgnoreCase)))
                        return Json(new { success = false, message = $"\"{name}\" has two sections named \"{sectionName}\"." });
                    if (s.Capacity is <= 0 or > CapacityMaxValue)
                        return Json(new { success = false, message = $"Capacity for {name} - {sectionName} must be between 1 and {CapacityMaxValue}." });

                    var room = string.IsNullOrWhiteSpace(s.Room) ? null : s.Room!.Trim();
                    if (room != null && room.Length > RoomMaxLength)
                        return Json(new { success = false, message = $"Room for {name} - {sectionName} is longer than {RoomMaxLength} characters." });

                    sections.Add(new AcademicSectionDetail
                    {
                        SectionName  = sectionName,
                        OriginalName = s.OriginalName?.Trim(),
                        DisplayOrder = sections.Count + 1,
                        Capacity     = s.Capacity,
                        RoomNo       = room
                    });
                }

                model.ClassDetails.Add(new AcademicClassDetail
                {
                    ClassName    = name,
                    OriginalName = c.OriginalName?.Trim(),
                    DisplayOrder = c.Rank,
                    Stream       = stream,
                    Coordinator  = coordinator,
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

            if (result <= 0)
                return Json(new { success = false, message = "The classes could not be saved. Refresh the page and try again." });

            return Json(new { success = true });
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
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]
        public async Task<IActionResult> SaveAcademicYear([FromBody] AcademicYearSaveDto dto)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            if (dto == null || string.IsNullOrWhiteSpace(dto.Name))
                return Json(new { success = false, message = "Academic year name is required." });
            // academic_years.academic_year_name is varchar(20).
            if (dto.Name.Trim().Length > 20)
                return Json(new { success = false, message = "Academic year name can be at most 20 characters." });

            // Dates.Norm turns an unreadable date into null, so a typo would
            // otherwise reach the database as "no date" and fail there.
            var startDate = Dates.Norm(dto.StartDate);
            var endDate   = Dates.Norm(dto.EndDate);
            if (startDate == null || endDate == null)
                return Json(new { success = false, message = "Start date and end date are both required." });
            if (string.CompareOrdinal(endDate, startDate) <= 0)   // ISO text compares as dates
                return Json(new { success = false, message = "End date must be after the start date." });

            var model = new AcademicYearModel
            {
                AcademicYearId   = dto.Id,
                AcademicYearName = dto.Name.Trim(),
                StartDate        = startDate,
                EndDate          = endDate,
                IsCurrent        = dto.IsCurrent,
                // Anything but the one other value means the default; the procedure
                // checks again, and a CHECK constraint backs both up.
                ChargeFeesFrom   = dto.ChargeFeesFrom == "SessionStart"
                                       ? "SessionStart" : "AdmissionMonth"
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
        [ValidateAntiForgeryToken]
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
        [ValidateAntiForgeryToken]
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

        #endregion

        private int SmTenant() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SmSchool() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int SmUser()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        [HttpGet]
        [HasPermission("academics.view")]
        public async Task<IActionResult> AssignClassTeacher(int academicYearId = 0)
        {
            // Sections are per session, so the grid belongs to one.
            await ResolveSessionAsync(academicYearId);
            // Add / edit / delete buttons are shown only with academics.manage
            // (a teacher has academics.view and would be refused on save).
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "academics.manage");
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
            var (ok, message) = await _classTeacherService.AssignAsync(dto?.SectionId ?? 0, dto?.StaffId, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message });
        }


        #region School Calendar
        // Working-day calendar: weekly off pattern + dated holiday / half-day /
        // working-day overrides. Feeds the Smart Bell and anything else that needs
        // to know whether the school is open. School events (PTM, functions ...) and
        // the exam periods sit on the same calendar. Every member of staff can SEE
        // it; changing anything needs academics.manage.
        [Authorize(Policy = "SchoolUserOnly")]
        public async Task<IActionResult> SchoolCalendar()
        {
            // Add / edit / delete buttons are shown only with academics.manage
            // (a teacher has academics.view and would be refused on save).
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "academics.manage");
            return View();
        }

        [HttpGet]
        [Authorize(Policy = "SchoolUserOnly")]
        public async Task<IActionResult> SchoolCalendarData(int? year)
        {
            var y    = year is >= 2000 and <= 2100 ? year.Value : Dates.Now.Year;
            var from = new DateTime(y, 1, 1);
            var data = await _schoolCalendarService.GetCalendarAsync(
                from, from.AddYears(1).AddDays(-1), SmTenant(), SmSchool(), SmUser());
            var events = await _schoolCalendarService.GetEventsAsync(
                $"{y}-01-01", $"{y}-12-31", SmTenant(), SmSchool(), SmUser());

            return Json(new { year = y, weeklyOffDays = data.WeeklyOffDays, entries = data.Entries, events });
        }

        public class SchoolEventDto
        {
            public int     Id        { get; set; }
            public string  Title     { get; set; } = string.Empty;
            public string  EventType { get; set; } = "Event";
            public string  StartDate { get; set; } = string.Empty;   // yyyy-MM-dd
            public string? EndDate   { get; set; }
            public string? StartTime { get; set; }                   // HH:mm
            public string? EndTime   { get; set; }
            public string? ForWhom   { get; set; }
            public string? Notes     { get; set; }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> SaveSchoolEvent([FromBody] SchoolEventDto dto)
        {
            var result = await _schoolCalendarService.SaveEventAsync(new SchoolEvent
            {
                Id        = dto?.Id ?? 0,
                Title     = dto?.Title ?? string.Empty,
                EventType = dto?.EventType ?? "Event",
                StartDate = dto?.StartDate ?? string.Empty,
                EndDate   = dto?.EndDate,
                StartTime = dto?.StartTime,
                EndTime   = dto?.EndTime,
                ForWhom   = dto?.ForWhom,
                Notes     = dto?.Notes
            }, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> DeleteSchoolEvent([FromBody] IdDto dto)
        {
            var result = await _schoolCalendarService.DeleteEventAsync(dto?.Id ?? 0, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = result.Success, message = result.Message });
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

        public class CalendarRangeDto
        {
            public string  From       { get; set; } = string.Empty;   // yyyy-MM-dd
            public string  To         { get; set; } = string.Empty;   // yyyy-MM-dd
            public string  DayType    { get; set; } = "holiday";
            public string  Title      { get; set; } = string.Empty;
            public string? HalfDayEnd { get; set; }
        }

        // A holiday (or half day / working day) over a date range: one entry per
        // day. Days that already have an entry are skipped and reported.
        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> SaveCalendarRange([FromBody] CalendarRangeDto dto)
        {
            var result = await _schoolCalendarService.SaveRangeAsync(dto?.From ?? string.Empty, dto?.To ?? string.Empty,
                new SchoolCalendarEntry
                {
                    DayType    = dto?.DayType ?? "holiday",
                    Title      = dto?.Title ?? string.Empty,
                    HalfDayEnd = dto?.HalfDayEnd
                }, SmTenant(), SmSchool(), SmUser());

            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("academics.manage")]
        public async Task<IActionResult> DeleteCalendarRange([FromBody] CalendarRangeDto dto)
        {
            var result = await _schoolCalendarService.DeleteRangeAsync(dto?.From ?? string.Empty, dto?.To ?? string.Empty,
                SmTenant(), SmSchool(), SmUser());
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

    public class CopySessionSetupDto
    {
        public int  FromAcademicYearId { get; set; }
        public int  ToAcademicYearId   { get; set; }
        public bool Subjects  { get; set; }
        public bool Teachers  { get; set; }
        public bool Timetable { get; set; }
    }

    public class ClassSectionItemDto
    {
        public string? Name { get; set; }
        public string? OriginalName { get; set; }   // name as loaded; null for a new class
        public int Rank { get; set; }
        public string? Stream { get; set; }
        public string? Coordinator { get; set; }
        public int? CoordinatorStaffId { get; set; }
        public List<SectionItemDto> Sections { get; set; } = new();
    }

    public class SectionItemDto
    {
        public string? Name { get; set; }
        public string? OriginalName { get; set; }   // name as loaded; null for a new section
        public int? Capacity { get; set; }
        public string? Room { get; set; }
    }

    // ── Payload for the Period Structure save (one whole schedule, replace-all) ──
    public class PeriodStructureSaveDto
    {
        public int? Day { get; set; }        // null = the default schedule, 0 = Sunday … 6 = Saturday
        public List<PeriodItemDto> Periods { get; set; } = new();
    }

    public class PeriodItemDto
    {
        public string? Name  { get; set; }
        public string? Start { get; set; }   // HH:mm
        public string? End   { get; set; }   // HH:mm
        public string? Type  { get; set; }   // class | assembly | break | lunch | diary
    }

    // ── Payload for Academic Year / Session save ──
    public class AcademicYearSaveDto
    {
        public int Id { get; set; }
        public string? Name { get; set; }
        public string? StartDate { get; set; }
        public string? EndDate { get; set; }
        public bool IsCurrent { get; set; }
        public string? ChargeFeesFrom { get; set; }
    }

    public class AcademicYearIdDto
    {
        public int Id { get; set; }
    }
}