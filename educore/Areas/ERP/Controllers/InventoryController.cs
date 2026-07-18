using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    // Stock / store module. Stub pages for now — gated by fees.view until a
    // dedicated inventory.* permission is added to the RBAC catalog.
    [HasPermission("fees.view")]
    public class InventoryController : Controller
    {
        // ── Pages ────────────────────────────────────────────────
        public IActionResult InventoryItem() => View();
        public IActionResult PurchaseEntry() => View();
    }
}
