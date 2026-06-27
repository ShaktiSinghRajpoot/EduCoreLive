using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("staff.view")]
    public class StaffController : Controller
    {
        private readonly IStaffService _staffService;
        private readonly IPermissionService _perms;

        public StaffController(IStaffService staffService, IPermissionService perms)
        {
            _staffService = staffService;
            _perms = perms;
        }

        // ── GET: /ERP/Staff/StaffList ────────────────────────────
        public async Task<IActionResult> StaffList()
        {
            var staff = await _staffService.GetStaffAsync(TenantId(), SchoolId(), UserId());
            return View(staff);
        }

        // ── GET: /ERP/Staff/Inactive ─────────────────────────────
        public async Task<IActionResult> Inactive()
        {
            var staff = await _staffService.GetStaffAsync(TenantId(), SchoolId(), UserId(), statusFilter: "Inactive");
            return View(staff);
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Reactivate(int id)
        {
            var (ok, message) = await _staffService.ReactivateAsync(id, TenantId(), SchoolId(), UserId());
            TempData[ok > 0 ? "SuccessMessage" : "ErrorMessage"] =
                ok > 0 ? "Staff member re-activated successfully." : message;
            return RedirectToAction("Inactive");
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Deactivate(int id)
        {
            var (ok, message) = await _staffService.DeactivateAsync(id, TenantId(), SchoolId(), UserId());
            TempData[ok > 0 ? "SuccessMessage" : "ErrorMessage"] =
                ok > 0 ? "Staff member deactivated." : message;
            return RedirectToAction("StaffList");
        }

        // ── GET: /ERP/Staff/AddStaff ─────────────────────────────
        public async Task<IActionResult> AddStaff()
        {
            await FillDropdownsAsync();
            return View(new StaffModel());
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> AddStaff(StaffModel model)
        {
            ValidateLogin(model);
            if (!ModelState.IsValid)
            {
                await FillDropdownsAsync();
                return View(model);
            }

            var (id, message) = await _staffService.SaveStaffAsync(
                model, "INSERT", HashIfLogin(model), TenantId(), SchoolId(), UserId());

            if (id <= 0)
            {
                ModelState.AddModelError("", message);
                await FillDropdownsAsync();
                return View(model);
            }

            TempData["SuccessMessage"] = "Staff member added successfully.";
            return RedirectToAction("StaffProfile", new { id });
        }

        // ── GET: /ERP/Staff/StaffProfile/{id} ────────────────────
        public async Task<IActionResult> StaffProfile(int id = 0)
        {
            var model = await _staffService.GetStaffByIdAsync(id, TenantId(), SchoolId(), UserId());
            if (model == null) return RedirectToAction("StaffList");
            return View(model);
        }

        // ── GET: /ERP/Staff/EditStaff/{id} ───────────────────────
        public async Task<IActionResult> EditStaff(int id = 0)
        {
            var model = await _staffService.GetStaffByIdAsync(id, TenantId(), SchoolId(), UserId());
            if (model == null) return RedirectToAction("StaffList");
            await FillDropdownsAsync();
            return View(model);
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> EditStaff(int id, StaffModel model)
        {
            model.StaffId = id;
            ValidateLogin(model);
            if (!ModelState.IsValid)
            {
                await FillDropdownsAsync();
                return View(model);
            }

            var (savedId, message) = await _staffService.SaveStaffAsync(
                model, "UPDATE", HashIfLogin(model), TenantId(), SchoolId(), UserId());

            if (savedId <= 0)
            {
                ModelState.AddModelError("", message);
                await FillDropdownsAsync();
                return View(model);
            }

            // Their role set may have changed — drop the cached roles so access refreshes.
            if (model.UserId is int uid)
                _perms.InvalidateUser(TenantId(), SchoolId(), uid);

            TempData["SuccessMessage"] = "Staff profile updated successfully.";
            return RedirectToAction("StaffProfile", new { id });
        }

        // ── helpers ──────────────────────────────────────────────
        private async Task FillDropdownsAsync()
        {
            ViewBag.Dropdowns = await _staffService.GetDropdownsAsync(TenantId(), SchoolId());
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
        }

        private static string? HashIfLogin(StaffModel model)
            => model.CreateLogin && !string.IsNullOrWhiteSpace(model.LoginPassword)
                ? BCrypt.Net.BCrypt.HashPassword(model.LoginPassword)
                : null;

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
