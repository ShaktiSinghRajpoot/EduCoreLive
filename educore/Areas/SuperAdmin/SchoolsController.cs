using educore.Models;
using EduCoreDataAccessLayer.Extensions;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.SuperAdmin;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.SuperAdmin.Controllers
{
    [Area("SuperAdmin")]
    [Authorize(Roles = AppRoles.SuperAdmin)]
    public class SchoolsController : Controller
    {
        private readonly ISchoolService _schoolService;
        public SchoolsController(ISchoolService schoolService)
        {
            _schoolService = schoolService;
        }

        [HttpGet]
        public async Task<IActionResult> SchoolList()
        {
            var userId = User.Identity.GetUserId();
            var tenantId = User.Identity.GetTenantId();
            var schools = await _schoolService.GetSchoolsAsync(tenantId, userId);
            return View(schools);
        }

        [HttpGet]
        public async Task<IActionResult> Create()
        {
            var model = new SchoolManageModel
            {
                Operation = "I",
                TenantMode = "existing",
                CreateSchoolAdmin = true,
                AutoGeneratePassword = true,
                EnableEmail = true,
                AddressTypeId = 1,
                ContactTypeId = 1
            };

            await FillDropdownsAsync(model);

            return View(model);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Create(SchoolManageModel model)
        {
            model.Operation = "I";

            ValidateTenant(model);
            ValidateSchoolAdmin(model);

            if (!ModelState.IsValid)
            {
                var errors = ModelState
        .Where(x => x.Value.Errors.Count > 0)
        .Select(x => new
        {
            Field = x.Key,
            Errors = x.Value.Errors.Select(e => e.ErrorMessage)
        })
        .ToList();

                await FillDropdownsAsync(model);
                return View(model);
            }

            try
            {
                var userId = User.Identity.GetUserId();
                var tenantId = User.Identity.GetTenantId();
                await _schoolService.CreateSchoolAsync(model, tenantId, userId);

                TempData["Success"] = "School created successfully.";
                return RedirectToAction(nameof(SchoolList));
            }
            catch (Exception ex)
            {
                ModelState.AddModelError("", ex.Message);
                await FillDropdownsAsync(model);
                return View(model);
            }
        }

        [HttpGet]
        public async Task<IActionResult> Edit(int id)
        {
            var userId = User.Identity.GetUserId();
            var tenantId = User.Identity.GetTenantId();
            var model = await _schoolService.GetSchoolByIdAsync(id, tenantId, userId);

            if (model == null)
                return NotFound();

            model.Operation = "U";

            if (string.IsNullOrWhiteSpace(model.TenantMode))
                model.TenantMode = "existing";

            await FillDropdownsAsync(model);

            return View("Create", model);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Edit(SchoolManageModel model)
        {
            model.Operation = "U";

            ValidateTenant(model);
            ValidateSchoolAdmin(model);

            if (!ModelState.IsValid)
            {
                await FillDropdownsAsync(model);
                return View("Create", model);
            }

            try
            {
                var userId = User.Identity.GetUserId();
                var tenantId = User.Identity.GetTenantId();
                await _schoolService.SaveSchoolAsync(model, tenantId, userId);

                TempData["Success"] = "School updated successfully.";
                return RedirectToAction(nameof(SchoolList));
            }
            catch (Exception ex)
            {
                ModelState.AddModelError("", ex.Message);
                await FillDropdownsAsync(model);
                return View("Create", model);
            }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Delete(int id)
        {
            var userId = User.Identity.GetUserId();
            var tenantId = User.Identity.GetTenantId();
            await _schoolService.DeleteSchoolAsync(id, tenantId, userId);

            TempData["Success"] = "School deactivated successfully.";
            return RedirectToAction(nameof(SchoolList));
        }

        private void ValidateTenant(SchoolManageModel model)
        {
            if (model.TenantMode == "existing")
            {
                if (!model.TenantId.HasValue || model.TenantId.Value <= 0)
                    ModelState.AddModelError(nameof(model.TenantId), "Please select tenant.");
            }
            else if (model.TenantMode == "new")
            {
                if (string.IsNullOrWhiteSpace(model.TenantName))
                    ModelState.AddModelError(nameof(model.TenantName), "Tenant name is required.");

                if (string.IsNullOrWhiteSpace(model.TenantCode))
                    ModelState.AddModelError(nameof(model.TenantCode), "Tenant code is required.");
            }
            else
            {
                ModelState.AddModelError(nameof(model.TenantMode), "Please select tenant option.");
            }
        }

        private void ValidateSchoolAdmin(SchoolManageModel model)
        {
            if (!model.CreateSchoolAdmin)
                return;

            if (string.IsNullOrWhiteSpace(model.AdminFullName))
                ModelState.AddModelError(nameof(model.AdminFullName), "Admin full name is required.");

            if (string.IsNullOrWhiteSpace(model.AdminEmail))
                ModelState.AddModelError(nameof(model.AdminEmail), "Admin email is required.");

            if (!model.AutoGeneratePassword && string.IsNullOrWhiteSpace(model.Password))
                ModelState.AddModelError(nameof(model.Password), "Password is required.");
        }
        private async Task FillDropdownsAsync(SchoolManageModel model)
        {
            var d = await _schoolService.GetSchoolDropdownsAsync();

            model.StatusList = d.Statuses.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.BoardList = d.Boards.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.SchoolTypeList = d.SchoolTypes.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.OwnershipTypeList = d.OwnershipTypes.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.MediumList = d.Mediums.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.AddressTypeList = d.AddressTypes.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.ContactTypeList = d.ContactTypes.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.AcademicYearList = d.AcademicYears.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.DateFormatList = d.DateFormats.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.TimeFormatList = d.TimeFormats.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.TenantList = d.Tenants.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();
        }
    }
}