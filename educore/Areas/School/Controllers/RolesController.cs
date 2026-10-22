using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.School.Controllers
{
    [Area("School")]
    [HasPermission("rbac.manage")]
    public class RolesController : Controller
    {
        private readonly IRbacService _rbac;
        private readonly IPermissionService _perms;
        private readonly ModuleFlags _modules;

        public RolesController(IRbacService rbac, IPermissionService perms, ModuleFlags modules)
        {
            _rbac = rbac;
            _perms = perms;
            _modules = modules;
        }

        // Permission features of the modules that are off for this school. Their rows
        // are not shown and their templates are not offered (the grants are kept).
        private async Task<HashSet<string>> ModulesOffAsync()
        {
            var m = await _modules.GetAsync();
            var off = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!m.EnableTransport) off.Add("transport");
            if (!m.EnableExams)     off.Add("exams");
            if (!m.EnableInventory) off.Add("inventory");
            if (!m.EnablePayroll)   off.Add("payroll");
            if (!m.EnableAttendance) off.Add("attendance");
            if (!m.EnableAcademics) off.Add("academics");
            if (!m.EnableFees)      off.Add("fees");
            if (!m.EnableAccounts)  off.Add("expenses");
            return off;
        }

        // rbac.manage lets a user see the roles, but changing them stays with the School
        // Admin: whoever can edit roles could give their own role every permission.
        private const string OnlyAdmin = "Only a School Admin can change roles and their permissions.";

        // ── GET: /school/roles ───────────────────────────────────
        [Route("school/roles")]
        public async Task<IActionResult> Index()
        {
            var roles = await _rbac.GetRolesAsync(TenantId(), SchoolId(), UserId());
            var off = await ModulesOffAsync();
            ViewBag.Templates = RoleTemplates.All.Where(t => !off.Contains(t.Module ?? "")).ToList();
            return View(roles);
        }

        // ── POST: create / rename a role ────────────────────────
        // templateName (new roles only) = "Start from template" on the create form.
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save(RoleModel model, string? templateName)
        {
            if (!await HasPermissionAttribute.UserIsAdminAsync(this))
            {
                TempData["ErrorMessage"] = OnlyAdmin;
                return RedirectToAction("Index");
            }
            if (string.IsNullOrWhiteSpace(model.RoleName))
            {
                TempData["ErrorMessage"] = "Role name is required.";
                return RedirectToAction("Index");
            }

            var op = model.RoleId > 0 ? "UPDATE" : "INSERT";
            var (id, message) = await _rbac.SaveRoleAsync(model, op, TenantId(), SchoolId(), UserId());

            if (id <= 0) TempData["ErrorMessage"] = message;
            else TempData["SuccessMessage"] = op == "INSERT" ? "Role created." : "Role updated.";

            if (id > 0 && op == "INSERT")
            {
                var template = RoleTemplates.Find(templateName);
                if (template != null && template.Keys.Length > 0)
                    await ApplyTemplateAsync(id, template);
            }

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
            if (!await HasPermissionAttribute.UserIsAdminAsync(this))
            {
                TempData["ErrorMessage"] = OnlyAdmin;
                return RedirectToAction("Index");
            }
            var (ok, message) = await _rbac.DeleteRoleAsync(id, TenantId(), SchoolId(), UserId());
            TempData[ok > 0 ? "SuccessMessage" : "ErrorMessage"] = ok > 0 ? "Role deleted." : message;
            return RedirectToAction("Index");
        }

        // ── GET: /school/roles/permissions/{id} (the matrix) ─────
        [Route("school/roles/permissions/{id?}")]
        public async Task<IActionResult> Permissions(int id = 0)
        {
            var matrix = await _rbac.GetMatrixAsync(id, TenantId(), SchoolId(), UserId());
            if (matrix == null) return RedirectToAction("Index");
            ViewBag.ModulesOff = await ModulesOffAsync();
            return View(matrix);
        }

        // ── POST: save the matrix ───────────────────────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SavePermissions(int roleId, int[] permissionIds)
        {
            if (!await HasPermissionAttribute.UserIsAdminAsync(this))
            {
                TempData["ErrorMessage"] = OnlyAdmin;
                return RedirectToAction("Index");
            }
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

        // Ticks the template's keys on a just-created role. Only keys that exist in the
        // catalog are used; the save proc writes the audit row as for a manual save.
        private async Task ApplyTemplateAsync(int roleId, RoleTemplates.RoleTemplate template)
        {
            var catalog = await _rbac.GetCatalogAsync();
            var ids = catalog.Where(p => RoleTemplates.Grants(template, p.PermissionKey))
                             .Select(p => p.PermissionId)
                             .ToList();
            if (ids.Count == 0) return;

            var (ok, message) = await _rbac.SavePermissionsAsync(roleId, ids, TenantId(), SchoolId(), UserId());
            if (ok)
            {
                _perms.InvalidateRole(TenantId(), SchoolId(), roleId);
                TempData["SuccessMessage"] = $"Role created with the {template.Name} permissions. Review the ticks below.";
            }
            else
            {
                TempData["ErrorMessage"] = "Role created, but the template could not be applied: " + message;
            }
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
