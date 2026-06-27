using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Admin.Controllers
{
    [Area("Admin")]
    [HasPermission("rbac.manage")]
    public class RolesController : Controller
    {
        private readonly IRbacService _rbac;
        private readonly IPermissionService _perms;

        public RolesController(IRbacService rbac, IPermissionService perms)
        {
            _rbac = rbac;
            _perms = perms;
        }

        // ── GET: /Admin/Roles ───────────────────────────────────
        public async Task<IActionResult> Index()
        {
            var roles = await _rbac.GetRolesAsync(TenantId(), SchoolId(), UserId());
            return View(roles);
        }

        // ── POST: create / rename a role ────────────────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save(RoleModel model)
        {
            if (string.IsNullOrWhiteSpace(model.RoleName))
            {
                TempData["ErrorMessage"] = "Role name is required.";
                return RedirectToAction("Index");
            }

            var op = model.RoleId > 0 ? "UPDATE" : "INSERT";
            var (id, message) = await _rbac.SaveRoleAsync(model, op, TenantId(), SchoolId(), UserId());

            if (id <= 0) TempData["ErrorMessage"] = message;
            else TempData["SuccessMessage"] = op == "INSERT" ? "Role created." : "Role updated.";

            // New role → go straight to its (empty) permission matrix.
            if (id > 0 && op == "INSERT")
                return RedirectToAction("Permissions", new { id });
            return RedirectToAction("Index");
        }

        // ── POST: delete a role ─────────────────────────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Delete(int id)
        {
            var (ok, message) = await _rbac.DeleteRoleAsync(id, TenantId(), SchoolId(), UserId());
            TempData[ok > 0 ? "SuccessMessage" : "ErrorMessage"] = ok > 0 ? "Role deleted." : message;
            return RedirectToAction("Index");
        }

        // ── GET: /Admin/Roles/Permissions/{id} (the matrix) ─────
        public async Task<IActionResult> Permissions(int id = 0)
        {
            var matrix = await _rbac.GetMatrixAsync(id, TenantId(), SchoolId(), UserId());
            if (matrix == null) return RedirectToAction("Index");
            return View(matrix);
        }

        // ── POST: save the matrix ───────────────────────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SavePermissions(int roleId, int[] permissionIds)
        {
            var (ok, message) = await _rbac.SavePermissionsAsync(
                roleId, permissionIds ?? Array.Empty<int>(), TenantId(), SchoolId(), UserId());

            if (ok)
            {
                // Live invalidation so the next request sees the change for everyone with this role.
                _perms.InvalidateRole(TenantId(), SchoolId(), roleId);
                TempData["SuccessMessage"] = "Permissions updated.";
            }
            else
            {
                TempData["ErrorMessage"] = message;
            }
            return RedirectToAction("Permissions", new { id = roleId });
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
