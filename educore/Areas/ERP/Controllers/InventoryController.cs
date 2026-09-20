using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    // Stock / store module. Still gated by fees.view until a dedicated
    // inventory.* permission is added to the RBAC catalog.
    [HasPermission("fees.view")]
    public class InventoryController : Controller
    {
        private readonly IInventoryService _inventory;

        public InventoryController(IInventoryService inventory)
        {
            _inventory = inventory;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // ── Pages ───────────────────────────────────────────────────────────
        // The page's four cards are computed from the item list it already loads,
        // so there is no second source here to disagree with them.
        public IActionResult InventoryItem() => View();

        public async Task<IActionResult> PurchaseEntry()
        {
            // Both pickers come from the database; the shell had them hardcoded.
            ViewBag.Suppliers = await _inventory.GetSuppliersAsync(TenantId(), SchoolId(), UserId());
            ViewBag.Items     = await _inventory.GetItemsAsync(TenantId(), SchoolId(), UserId());
            return View();
        }

        // ── Items ───────────────────────────────────────────────────────────
        // The page searches and filters client-side, so it loads the list once.
        // A school's store is small enough for that.
        [HttpGet]
        public async Task<IActionResult> Items(string? search = null, string? status = null)
        {
            var rows = await _inventory.GetItemsAsync(TenantId(), SchoolId(), UserId(), search, status);

            return Json(rows.Select(r => new
            {
                id       = r.ItemId,
                name     = r.ItemName,
                sku      = r.Sku,
                category = r.Category,
                subCat   = r.SubCategory,
                type     = r.ItemType,
                unit     = r.UnitType,
                stock    = r.CurrentStock,
                minStock = r.MinStock,
                value    = r.StockValue,
                status   = r.StockStatus
            }));
        }

        [HttpGet]
        public async Task<IActionResult> Item(int id)
        {
            var item = await _inventory.GetItemAsync(id, TenantId(), SchoolId(), UserId());
            if (item == null) return Json(new { success = false, message = "Item not found." });

            return Json(new
            {
                success = true,
                id       = item.ItemId,
                name     = item.ItemName,
                sku      = item.Sku,
                category = item.Category,
                subCat   = item.SubCategory,
                type     = item.ItemType,
                unit     = item.UnitType,
                stock        = item.CurrentStock,
                minStock     = item.MinStock,
                costPrice    = item.CostPrice,
                sellingPrice = item.SellingPrice,
                brand        = item.Brand,
                model        = item.Model,
                description  = item.Description,
                isActive     = item.IsActive
            });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveItem([FromBody] InventoryItemInput input)
        {
            if (input == null) return Json(new { success = false, message = "Nothing to save." });

            var res = await _inventory.SaveItemAsync(input, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, id = res.Id });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteItem([FromBody] IdRequest req)
        {
            var res = await _inventory.DeleteItemAsync(req?.Id ?? 0, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // ── Stock ───────────────────────────────────────────────────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> MoveStock([FromBody] StockMovementInput input)
        {
            if (input == null) return Json(new { success = false, message = "Nothing to record." });

            var res = await _inventory.MoveStockAsync(input, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, stock = res.CurrentStock });
        }

        [HttpGet]
        public async Task<IActionResult> Ledger(int id)
        {
            var rows = await _inventory.GetItemLedgerAsync(id, TenantId(), SchoolId(), UserId());

            return Json(rows.Select(r => new
            {
                date    = r.MovementDate.ToString("dd MMM yyyy"),
                type    = r.MovementType,
                qty     = r.Quantity,
                balance = r.BalanceAfter,
                to      = r.IssuedTo,
                remarks = r.Remarks
            }));
        }

        // ── Suppliers ───────────────────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> Suppliers()
        {
            var rows = await _inventory.GetSuppliersAsync(TenantId(), SchoolId(), UserId());

            return Json(rows.Select(r => new
            {
                id      = r.SupplierId,
                name    = r.SupplierName,
                contact = r.ContactPerson,
                mobile  = r.Mobile,
                email   = r.Email,
                address = r.Address,
                gstin   = r.Gstin
            }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveSupplier([FromBody] InventorySupplier input)
        {
            if (input == null) return Json(new { success = false, message = "Nothing to save." });

            var res = await _inventory.SaveSupplierAsync(input, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, id = res.Id });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteSupplier([FromBody] IdRequest req)
        {
            var res = await _inventory.DeleteSupplierAsync(req?.Id ?? 0, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // ── Purchases ───────────────────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> Purchases(DateOnly? from = null, DateOnly? to = null)
        {
            var rows = await _inventory.GetPurchasesAsync(TenantId(), SchoolId(), UserId(), from, to);

            return Json(rows.Select(r => new
            {
                id        = r.PurchaseId,
                date      = r.PurchaseDate.ToString("dd MMM yyyy"),
                supplier  = r.SupplierName,
                invoice   = r.InvoiceNo,
                mode      = r.PaymentMode,
                subTotal  = r.SubTotal,
                tax       = r.TaxTotal,
                total     = r.GrandTotal,
                lines     = r.LineCount,
                cancelled = r.IsCancelled
            }));
        }

        [HttpGet]
        public async Task<IActionResult> Purchase(int id)
        {
            var p = await _inventory.GetPurchaseAsync(id, TenantId(), SchoolId(), UserId());
            if (p == null) return Json(new { success = false, message = "Purchase not found." });

            return Json(new
            {
                success   = true,
                id        = p.PurchaseId,
                date      = p.PurchaseDate.ToString("yyyy-MM-dd"),
                supplier  = p.SupplierName,
                invoice   = p.InvoiceNo,
                mode      = p.PaymentMode,
                remarks   = p.Remarks,
                subTotal  = p.SubTotal,
                tax       = p.TaxTotal,
                total     = p.GrandTotal,
                cancelled = p.IsCancelled,
                reason    = p.CancelReason,
                lines     = p.Lines.Select(l => new
                {
                    itemId = l.ItemId,
                    name   = l.ItemName,
                    qty    = l.Quantity,
                    price  = l.UnitPrice,
                    tax    = l.TaxPercent,
                    total  = l.LineTotal
                })
            });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SavePurchase([FromBody] PurchaseInput input)
        {
            if (input == null) return Json(new { success = false, message = "Nothing to save." });

            var res = await _inventory.SavePurchaseAsync(input, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, id = res.Id, total = res.GrandTotal });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CancelPurchase([FromBody] CancelRequest req)
        {
            var res = await _inventory.CancelPurchaseAsync(
                req?.Id ?? 0, req?.Reason, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // Small request shapes for the JSON posts above.
        public class IdRequest     { public int Id { get; set; } }
        public class CancelRequest { public int Id { get; set; } public string? Reason { get; set; } }
    }
}
