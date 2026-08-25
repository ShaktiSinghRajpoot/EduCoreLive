using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("staff.view")]
    public class StaffController : Controller
    {
        private readonly IStaffService _staffService;
        private readonly IPermissionService _perms;
        private readonly IPublicIdService _publicIds;

        public StaffController(IStaffService staffService, IPermissionService perms, IPublicIdService publicIds)
        {
            _staffService = staffService;
            _perms = perms;
            _publicIds = publicIds;
        }

        // ── GET: /ERP/Staff/StaffList ────────────────────────────
        // One StaffListItem does it all: bound filters/sort/page in via the query
        // string; the service fills Items + TotalCount. Tenant/school/user come
        // from CLAIMS only (never model-bound). Filter dropdowns are sourced from
        // the staff masters (not the current page) so they stay complete.
        public async Task<IActionResult> StaffList(StaffListItem query)
        {
            var dd = await _staffService.GetDropdownsAsync(TenantId(), SchoolId());
            query.DepartmentList = dd.Departments
                .Select(d => new SelectListItem { Text = d, Value = d }).ToList();
            query.StaffTypeList = dd.Designations
                .Select(x => x.StaffType)
                .Where(t => !string.IsNullOrWhiteSpace(t))
                .Distinct().OrderBy(t => t)
                .Select(t => new SelectListItem { Text = t, Value = t }).ToList();

            await _staffService.GetStaffListPageAsync(query, TenantId(), SchoolId(), UserId());
            return View(query);
        }

        // ── GET: /ERP/Staff/Inactive ─────────────────────────────
        // Same fat-model list pattern as StaffList, but pinned to status=Inactive.
        public async Task<IActionResult> Inactive(StaffListItem query)
        {
            query.FilterStatus = "Inactive";   // this page only ever shows inactive staff
            await _staffService.GetStaffListPageAsync(query, TenantId(), SchoolId(), UserId());
            return View(query);
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Reactivate(Guid id)
        {
            var staffId = await _publicIds.ResolveAsync(IPublicIdService.Staff, id, TenantId(), SchoolId());
            if (staffId == 0) return RedirectToAction("Inactive");

            var (ok, message) = await _staffService.ReactivateAsync(staffId, TenantId(), SchoolId(), UserId());
            TempData[ok > 0 ? "SuccessMessage" : "ErrorMessage"] = ok > 0 ? "Staff member re-activated successfully." : message;
            return RedirectToAction("Inactive");
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Deactivate(Guid id)
        {
            var staffId = await _publicIds.ResolveAsync(IPublicIdService.Staff, id, TenantId(), SchoolId());
            if (staffId == 0) return RedirectToAction("StaffList");

            var (ok, message) = await _staffService.DeactivateAsync(staffId, TenantId(), SchoolId(), UserId());
            TempData[ok > 0 ? "SuccessMessage" : "ErrorMessage"] =
                ok > 0 ? "Staff member deactivated." : message;
            return RedirectToAction("StaffList");
        }

        // ── GET: /ERP/Staff/AddStaff ─────────────────────────────
        public async Task<IActionResult> AddStaff()
        {
            var model = new StaffModel();
            await FillDropdownsAsync(model);
            return View(model);
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> AddStaff(StaffModel model)
        {
            ValidateLogin(model);
            if (!ModelState.IsValid)
            {
                await FillDropdownsAsync(model);
                return View(model);
            }

            var (id, message) = await _staffService.SaveStaffAsync(
                model, "INSERT", HashIfLogin(model), TenantId(), SchoolId(), UserId());

            if (id <= 0)
            {
                ModelState.AddModelError("", message);
                await FillDropdownsAsync(model);
                return View(model);
            }

            TempData["SuccessMessage"] = "Staff member added successfully.";
            return await RedirectToProfileAsync(id);
        }

        // ── GET: /ERP/Staff/StaffProfile/{publicId} ──────────────
        // The URL carries the uuid; ResolveStaffIdAsync turns it into the internal id and
        // enforces the tenant/school check while doing so. An unknown uuid and another
        // school's uuid both come back as 0, so this cannot be used to probe for real ids.
        public async Task<IActionResult> StaffProfile(Guid id)
        {
            var staffId = await _publicIds.ResolveAsync(IPublicIdService.Staff, id, TenantId(), SchoolId());
            if (staffId == 0) return RedirectToAction("StaffList");

            var model = await _staffService.GetStaffByIdAsync(staffId, TenantId(), SchoolId(), UserId());
            if (model == null) return RedirectToAction("StaffList");

            // Resolve the person's role IDs into readable names for the profile.
            if (model.UserId is not null && model.RoleIds.Count > 0)
            {
                var roles = (await _staffService.GetDropdownsAsync(TenantId(), SchoolId())).Roles;
                ViewBag.RoleNames = roles.Where(r => model.RoleIds.Contains(r.RoleId))
                                         .Select(r => r.RoleName).ToList();
            }
            return View(model);
        }

        // ── AJAX: designations for a department (+ cross-department roles) ──
        // POST + {value,text,...} mirrors the CRM cascade pattern; 'type' rides
        // along so the form can auto-fill Staff Type from the picked designation.
        [HttpPost]
        public async Task<IActionResult> GetDesignations(string? department)
        {
            var all = (await _staffService.GetDropdownsAsync(TenantId(), SchoolId())).Designations;
            var dept = (department ?? "").Trim();
            var list = all
                .Where(d => dept.Length == 0
                         || string.IsNullOrWhiteSpace(d.DefaultDepartment)
                         || string.Equals(d.DefaultDepartment, dept, StringComparison.OrdinalIgnoreCase))
                .Select(d => new { value = d.Name, text = d.Name, type = d.StaffType });
            return Json(list);
        }

        // ── GET: /ERP/Staff/EditStaff/{id} ───────────────────────
        public async Task<IActionResult> EditStaff(Guid id)
        {
            var staffId = await _publicIds.ResolveAsync(IPublicIdService.Staff, id, TenantId(), SchoolId());
            if (staffId == 0) return RedirectToAction("StaffList");

            var model = await _staffService.GetStaffByIdAsync(staffId, TenantId(), SchoolId(), UserId());
            if (model == null) return RedirectToAction("StaffList");
            await FillDropdownsAsync(model);
            return View(model);
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> EditStaff(Guid id, StaffModel model)
        {
            var staffId = await _publicIds.ResolveAsync(IPublicIdService.Staff, id, TenantId(), SchoolId());
            if (staffId == 0) return RedirectToAction("StaffList");

            model.StaffId = staffId;
            ValidateLogin(model);
            if (!ModelState.IsValid)
            {
                await FillDropdownsAsync(model);
                return View(model);
            }

            var (savedId, message) = await _staffService.SaveStaffAsync(
                model, "UPDATE", HashIfLogin(model), TenantId(), SchoolId(), UserId());

            if (savedId <= 0)
            {
                ModelState.AddModelError("", message);
                await FillDropdownsAsync(model);
                return View(model);
            }

            // Their role set may have changed — drop the cached roles so access refreshes.
            if (model.UserId is int uid)
                _perms.InvalidateUser(TenantId(), SchoolId(), uid);

            TempData["SuccessMessage"] = "Staff profile updated successfully.";
            return await RedirectToProfileAsync(savedId);
        }

        // Departments & Designations masters now live under Settings
        // (Admin/SchoolSettings/StaffMasters).

        // Save gives us the internal id; the profile URL needs the uuid, so read the row
        // back for it. One extra proc call on save only — StaffProfile would fetch anyway.
        private async Task<IActionResult> RedirectToProfileAsync(int staffId)
        {
            var saved = await _staffService.GetStaffByIdAsync(staffId, TenantId(), SchoolId(), UserId());
            if (saved == null) return RedirectToAction("StaffList");

            return RedirectToAction("StaffProfile", new { id = saved.PublicId });
        }

        // ── helpers ──────────────────────────────────────────────
        // Fill the model's dropdown sources (CRM-style Model.XList) so the view
        // binds them with asp-items — no ViewBag, no JSON serialize.
        private async Task FillDropdownsAsync(StaffModel model)
        {
            var dd = await _staffService.GetDropdownsAsync(TenantId(), SchoolId());
            model.DepartmentList = dd.Departments.Select(d => new SelectListItem { Text = d, Value = d }).ToList();
            model.RoleList = dd.Roles;
        }

        // Access validation. Creating a NEW login needs email + password + ≥1 role.
        // Editing a person who ALREADY has a login just needs ≥1 role (so they keep access).
        private void ValidateLogin(StaffModel model)
        {
            bool creating = model.CreateLogin && model.UserId is null;
            bool hasLogin = model.UserId is not null;

            if (creating)
            {
                if (string.IsNullOrWhiteSpace(model.Email))
                    ModelState.AddModelError(nameof(model.Email), "Email is required to create a login.");
                if (string.IsNullOrWhiteSpace(model.LoginPassword) || model.LoginPassword!.Length < 8)
                    ModelState.AddModelError(nameof(model.LoginPassword), "Password (min 8 chars) is required for the login.");
            }

            if ((creating || hasLogin) && (model.RoleIds == null || model.RoleIds.Count == 0))
                ModelState.AddModelError(nameof(model.RoleIds), "Select at least one role for the login.");

            // Resetting the password of an existing login needs a valid new password.
            if (hasLogin && model.ChangePassword
                && (string.IsNullOrWhiteSpace(model.LoginPassword) || model.LoginPassword!.Length < 8))
                ModelState.AddModelError(nameof(model.LoginPassword), "New password must be at least 8 characters.");
        }

        // Hash the entered password when creating a new login OR resetting an existing one.
        private static string? HashIfLogin(StaffModel model)
            => (model.CreateLogin || model.ChangePassword) && !string.IsNullOrWhiteSpace(model.LoginPassword)
                ? BCrypt.Net.BCrypt.HashPassword(model.LoginPassword)
                : null;

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
