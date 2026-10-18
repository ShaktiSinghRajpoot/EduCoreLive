using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// Books & Uniform Register (/ERP/StoreRegister): a class's children down the side,
    /// the store's items across the top, ✓ for what each child has (this session,
    /// not returned) and ✗ for what they do not.
    ///
    /// Store staff (inventory.view) open any class of any session. Anyone else sees
    /// only the sections they are class teacher of in the current session. Unpaid
    /// amounts go only to users who may see fees.
    /// </summary>
    [Area("ERP")]
    [Authorize(Policy = "SchoolUserOnly")]
    [RequiresModule(SchoolModule.Inventory)]
    public class StoreRegisterController : Controller
    {
        private readonly IStudentSaleService _sales;
        private readonly IClassTeacherService _classTeacher;

        public StoreRegisterController(IStudentSaleService sales, IClassTeacherService classTeacher)
        {
            _sales = sales;
            _classTeacher = classTeacher;
        }

        public async Task<IActionResult> Index([FromServices] IBaseService baseService, [FromServices] ISchoolSettingsService settings)
        {
            bool storeStaff = await HasPermissionAttribute.UserHasAsync(this, "inventory.view");
            ViewBag.StoreStaff = storeStaff;
            ViewBag.CanGive = await HasPermissionAttribute.UserHasAsync(this, "inventory.manage");   // the "Give items" tab
            if (storeStaff)
            {
                try { ViewBag.ClassList = await baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
                catch { ViewBag.ClassList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }
                try { ViewBag.YearList = await baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString()); }
                catch { ViewBag.YearList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }
            }
            else
            {
                // a class teacher: their own sections of this session
                ViewBag.MyClasses = await _classTeacher.GetClassesOfAsync(TenantId(), SchoolId(), UserId());
            }
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> Data(string? year, string? cls, string? sec)
        {
            if (string.IsNullOrWhiteSpace(year) || string.IsNullOrWhiteSpace(cls))
                return Json(new { success = false, message = "Choose the session and class." });

            if (!await HasPermissionAttribute.UserHasAsync(this, "inventory.view"))
            {
                var mine = await _classTeacher.GetClassesOfAsync(TenantId(), SchoolId(), UserId());
                bool ok = mine.Any(m => m.SessionName == year && m.ClassName == cls && (m.SectionName ?? "") == (sec ?? ""));
                if (!ok) return Json(new { success = false, message = "You can see only the class you are class teacher of." });
            }

            bool canViewFees = await HasPermissionAttribute.UserHasAsync(this, "fees.view");
            var reg = await _sales.GetRegisterAsync(year, cls, sec, TenantId(), SchoolId(), UserId());

            // Sizes are separate items ("Uniform Set - 24", "- 28", "- 32"). When the store
            // sells more than one item with the same name before the last " - ", they share
            // one column under that name; an item with no such sibling keeps its full name
            // ("English Reader - Class 3"). Decided from everything the store sells, so the
            // column is the same in every class even if only one size was given there.
            var forSale = await _sales.GetItemsAsync(null, null, TenantId(), SchoolId(), UserId());
            var sized = forSale.GroupBy(i => BaseName(i.ItemName)).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
            return Json(new
            {
                success = true,
                students = reg.Students.Select(s => new { id = s.StudentId, name = s.StudentName, admNo = s.AdmissionNo ?? "", sec = s.Section ?? "", roll = s.RollNo ?? "" }),
                items    = reg.Items.Select(i => new
                {
                    id = i.ItemId, name = i.ItemName, category = i.Category,
                    column = sized.Contains(BaseName(i.ItemName)) ? BaseName(i.ItemName) : i.ItemName
                }),
                held     = reg.Held.Select(h => new { s = h.StudentId, i = h.ItemId, qty = h.Quantity, unpaid = canViewFees ? h.Unpaid : (decimal?)null })
            });
        }

        // "Uniform Set - 28" -> "Uniform Set"; a name with no " - " stays as it is.
        private static string BaseName(string name)
        {
            int i = name.LastIndexOf(" - ", StringComparison.Ordinal);
            return i > 0 ? name.Substring(0, i).Trim() : name;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
