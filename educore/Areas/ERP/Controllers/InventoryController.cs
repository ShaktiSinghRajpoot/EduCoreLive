using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    // Stock / store module. Reading needs inventory.view; every write action
    // below also needs inventory.manage (which implies view). Cancelling a
    // purchase is a write like any other -- there is no separate key for it.
    [HasPermission("inventory.view")]
    [RequiresModule(SchoolModule.Inventory)]
    public class InventoryController : Controller
    {
        private readonly IInventoryService _inventory;
        private readonly IStudentSaleService _sales;   // books & uniform sold to students

        public InventoryController(IInventoryService inventory, IStudentSaleService sales)
        {
            _inventory = inventory;
            _sales = sales;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // ── Pages ───────────────────────────────────────────────────────────
        // The page's four cards are computed from the item list it already loads,
        // so there is no second source here to disagree with them.
        public async Task<IActionResult> InventoryItem([FromServices] IBaseService baseService)
        {
            // for "Which class is it for?" on a saleable item
            try { ViewBag.ClassList = await baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.ClassList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }
            return View();
        }

        // Store locations (add / rename / deactivate) and the transfer history.
        public IActionResult StoreLocations() => View();

        // Supplier list / search / add / edit / deactivate / remove.
        public IActionResult SupplierMaster() => View();

        public async Task<IActionResult> PurchaseEntry()
        {
            // Both pickers come from the database; the shell had them hardcoded.
            // Inactive items and inactive suppliers are left out: the proc
            // refuses both on a new bill anyway.
            ViewBag.Suppliers = (await _inventory.GetSuppliersAsync(TenantId(), SchoolId(), UserId()))
                                .Where(s => s.IsActive).ToList();
            ViewBag.Locations = (await _inventory.GetLocationsAsync(TenantId(), SchoolId(), UserId()))
                                .Where(l => l.IsActive).ToList();
            ViewBag.Items     = (await _inventory.GetItemsAsync(TenantId(), SchoolId(), UserId()))
                                .Where(i => i.IsActive).ToList();
            // The school's date, not the browser's UTC one (toISOString), so the
            // default is right before 05:30 in the morning too.
            ViewBag.Today     = Dates.Today;
            return View();
        }

        // ── Items ───────────────────────────────────────────────────────────
        // The page searches and filters client-side, so it loads the list once.
        // A school's store is small enough for that.
        // With a location, stock / value / status are the figures AT that location.
        [HttpGet]
        public async Task<IActionResult> Items(string? search = null, string? status = null, int? location = null)
        {
            var rows = await _inventory.GetItemsAsync(TenantId(), SchoolId(), UserId(), search, status, location);

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
                status   = r.StockStatus,
                active   = r.IsActive,
                places   = r.LocationsHeld,
                opening  = r.OpeningQty,
                added    = r.AddedQty
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
                isActive     = item.IsActive,
                forClass     = await _sales.GetItemClassAsync(id, TenantId(), SchoolId(), UserId())   // null = every class
            });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SaveItem([FromBody] InventoryItemInput input)
        {
            if (input == null) return Json(new { success = false, message = "Nothing to save." });
            bool saleable = string.Equals(input.ItemType, "Saleable", StringComparison.OrdinalIgnoreCase);

            // A new saleable item in sizes ("24, 28, 32"): one item per size, named
            // "Uniform - 24" and so on, which the register shows as one "Uniform" column.
            var sizes = (input.Sizes ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                                           .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            if (saleable && input.ItemId == 0 && sizes.Count > 0)
            {
                string baseName = input.ItemName.Trim(), baseSku = (input.Sku ?? "").Trim();
                int made = 0;
                foreach (var size in sizes)
                {
                    input.ItemName = baseName + " - " + size;
                    input.Sku = baseSku == "" ? null : baseSku + "-" + size;   // an SKU must stay unique
                    var r = await _inventory.SaveItemAsync(input, TenantId(), SchoolId(), UserId());
                    if (!r.Success)
                        return Json(new { success = false, message = (made > 0 ? made + " size(s) saved, then " : "") + input.ItemName + ": " + r.Message });
                    await _sales.SetItemClassAsync(r.Id, input.ForClass, TenantId(), SchoolId(), UserId());
                    made++;
                }
                return Json(new { success = true, message = made + " sizes saved: " + baseName + " - " + string.Join(", ", sizes) + "." });
            }

            var res = await _inventory.SaveItemAsync(input, TenantId(), SchoolId(), UserId());
            if (res.Success && saleable)
                await _sales.SetItemClassAsync(input.ItemId > 0 ? input.ItemId : res.Id, input.ForClass, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, id = res.Id });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> DeleteItem([FromBody] IdRequest req)
        {
            var res = await _inventory.DeleteItemAsync(req?.Id ?? 0, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // ── Stock ───────────────────────────────────────────────────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
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
                date    = Dates.Show(r.MovementDate),
                type    = r.MovementType,
                qty     = r.Quantity,
                balance = r.Balance,
                rate    = r.UnitRate,
                by      = r.CreatedBy,
                invoice = r.InvoiceNo,
                to      = r.IssuedTo,
                remarks = r.Remarks,
                place   = r.LocationName,
                placeBalance = r.LocationBalance,
                with    = r.TransferWith
            }));
        }

        // One item's stock, location by location.
        [HttpGet]
        public async Task<IActionResult> ItemStock(int id)
        {
            var rows = await _inventory.GetItemStockByLocationAsync(id, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(r => new
            {
                id        = r.LocationId,
                name      = r.LocationName,
                isDefault = r.IsDefault,
                active    = r.IsActive,
                qty       = r.Quantity
            }));
        }

        // ── Locations and transfers ─────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> Locations()
        {
            var rows = await _inventory.GetLocationsAsync(TenantId(), SchoolId(), UserId());
            return Json(rows.Select(r => new
            {
                id        = r.LocationId,
                name      = r.LocationName,
                isDefault = r.IsDefault,
                active    = r.IsActive,
                items     = r.ItemCount,
                qty       = r.TotalQty,
                value     = r.StockValue
            }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SaveLocation([FromBody] LocationRequest req)
        {
            if (req == null) return Json(new { success = false, message = "Nothing to save." });

            var res = await _inventory.SaveLocationAsync(req.Id, req.Name, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, id = res.Id });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SetLocationActive([FromBody] ActiveRequest req)
        {
            if (req == null) return Json(new { success = false, message = "Nothing to change." });

            var res = await _inventory.SetLocationActiveAsync(req.Id, req.Active, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> TransferStock([FromBody] StockTransferInput input)
        {
            if (input == null) return Json(new { success = false, message = "Nothing to transfer." });

            var res = await _inventory.TransferStockAsync(input, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, stock = res.CurrentStock });
        }

        [HttpGet]
        public async Task<IActionResult> Transfers(int? itemId = null, int? location = null)
        {
            var rows = await _inventory.GetTransfersAsync(TenantId(), SchoolId(), UserId(), itemId, location);
            return Json(rows.Select(r => new
            {
                id      = r.TransferId,
                date    = Dates.Show(r.TransferDate),
                item    = r.ItemName,
                unit    = r.UnitType,
                from    = r.FromLocation,
                to      = r.ToLocation,
                qty     = r.Quantity,
                reason  = r.Reason,
                by      = r.CreatedBy,
                at      = r.CreatedAt
            }));
        }

        // ── Suppliers ───────────────────────────────────────────────────────
        // status: null = all live suppliers, "Active" or "Inactive".
        [HttpGet]
        public async Task<IActionResult> Suppliers(string? search = null, string? status = null)
        {
            var rows = await _inventory.GetSuppliersAsync(TenantId(), SchoolId(), UserId(), search, status);

            return Json(rows.Select(r => new
            {
                id      = r.SupplierId,
                name    = r.SupplierName,
                contact = r.ContactPerson,
                mobile  = r.Mobile,
                email   = r.Email,
                address = r.Address,
                gstin   = r.Gstin,
                active  = r.IsActive,
                bills   = r.BillCount,
                billed  = r.TotalBilled,
                lastBill = Dates.Show(r.LastBillDate)
            }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SaveSupplier([FromBody] InventorySupplier input)
        {
            if (input == null) return Json(new { success = false, message = "Nothing to save." });

            // Optional, but when given it must be a 10-digit Indian mobile (same rule
            // as StaffModel.Mobile); "12" used to be saved.
            input.Mobile = (input.Mobile ?? "").Trim();
            if (input.Mobile != "" && !System.Text.RegularExpressions.Regex.IsMatch(input.Mobile, "^[6-9][0-9]{9}$"))
                return Json(new { success = false, message = "Enter a valid 10-digit mobile number." });

            var res = await _inventory.SaveSupplierAsync(input, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, id = res.Id });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> DeleteSupplier([FromBody] IdRequest req)
        {
            var res = await _inventory.DeleteSupplierAsync(req?.Id ?? 0, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SetSupplierActive([FromBody] ActiveRequest req)
        {
            if (req == null) return Json(new { success = false, message = "Nothing to change." });

            var res = await _inventory.SetSupplierActiveAsync(req.Id, req.Active, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // ── Purchases ───────────────────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> Purchases(string? from = null, string? to = null, int? supplierId = null)
        {
            var rows = await _inventory.GetPurchasesAsync(TenantId(), SchoolId(), UserId(), from, to, supplierId);

            return Json(rows.Select(r => new
            {
                id        = r.PurchaseId,
                date      = Dates.Show(r.PurchaseDate, "dd MMM yyyy"),
                iso       = r.PurchaseDate,
                qty       = r.ItemQty,
                supplier  = r.SupplierName,
                invoice   = r.InvoiceNo,
                mode      = r.PaymentMode,
                subTotal  = r.SubTotal,
                tax       = r.TaxTotal,
                total     = r.GrandTotal,
                lines     = r.LineCount,
                cancelled = r.IsCancelled,
                place     = r.LocationName,
                returnedQty    = r.ReturnedQty,
                returnedAmount = r.ReturnedAmount
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
                date      = Dates.Show(p.PurchaseDate),
                supplier  = p.SupplierName,
                invoice   = p.InvoiceNo,
                mode      = p.PaymentMode,
                remarks   = p.Remarks,
                subTotal  = p.SubTotal,
                tax       = p.TaxTotal,
                total     = p.GrandTotal,
                cancelled = p.IsCancelled,
                reason    = p.CancelReason,
                place     = p.LocationName,
                createdBy = p.CreatedBy,
                createdAt = p.CreatedAt,
                cancelledBy = p.CancelledBy,
                cancelledAt = p.CancelledAt,
                returnedAmount = p.ReturnedAmount,
                lines     = p.Lines.Select(l => new
                {
                    lineId = l.PurchaseItemId,
                    itemId = l.ItemId,
                    name   = l.ItemName,
                    unit   = l.UnitType,
                    qty    = l.Quantity,
                    price  = l.UnitPrice,
                    tax    = l.TaxPercent,
                    total  = l.LineTotal,
                    returnedQty    = l.ReturnedQty,
                    returnedAmount = l.ReturnedAmount
                }),
                returns   = p.Returns.Select(r => new
                {
                    date   = Dates.Show(r.ReturnDate),
                    name   = r.ItemName,
                    qty    = r.Quantity,
                    amount = r.Amount,
                    reason = r.Reason,
                    place  = r.LocationName,
                    by     = r.CreatedBy,
                    at     = r.CreatedAt
                })
            });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SavePurchase([FromBody] PurchaseInput input)
        {
            if (input == null) return Json(new { success = false, message = "Nothing to save." });

            var res = await _inventory.SavePurchaseAsync(input, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, id = res.Id, total = res.GrandTotal });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> CancelPurchase([FromBody] CancelRequest req)
        {
            var res = await _inventory.CancelPurchaseAsync(
                req?.Id ?? 0, req?.Reason, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // Return part of a bill to its supplier (some quantity of some lines).
        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> ReturnToSupplier([FromBody] PurchaseReturnInput input)
        {
            if (input == null) return Json(new { success = false, message = "Nothing to return." });

            var res = await _inventory.ReturnToSupplierAsync(input, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // ── Books & uniform: sell to a student (inventory_student_sale.sql) ─────
        // The items leave the store and one fee line per item goes on the child's
        // account, so the parent pays at Collect Fees now or later.
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> StudentSale([FromServices] ISchoolSettingsService settings)
        {
            // the current session's first day, for the summary's "This session" button
            try { ViewBag.SessionStart = (await settings.GetAcademicYearsAsync(TenantId(), SchoolId(), UserId())).FirstOrDefault(y => y.IsCurrent)?.StartDate; }
            catch { ViewBag.SessionStart = null; }
            ViewBag.Locations = (await _inventory.GetLocationsAsync(TenantId(), SchoolId(), UserId()))
                                .Where(l => l.IsActive).ToList();
            return View();
        }

        // Find a child by name, admission no, father's name or mobile (this session's students).
        [HttpGet]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SaleSearch(string? q, [FromServices] IAdmissionService admissions,
                                                    [FromServices] ISchoolSettingsService settings)
        {
            if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) return Json(Array.Empty<object>());
            string? current = null;
            try { current = (await settings.GetAcademicYearsAsync(TenantId(), SchoolId(), UserId())).FirstOrDefault(y => y.IsCurrent)?.AcademicYearName; }
            catch { /* search every session */ }
            var (rows, _) = await admissions.GetStudentsAsync(TenantId(), SchoolId(), UserId(),
                pageNumber: 1, pageSize: 20, search: q.Trim(), filterYear: current, filterStatus: "Active");
            return Json(rows.Select(s => new
            {
                id = s.StudentId, name = s.StudentName, admNo = s.AdmissionNo, cls = s.ClassName, sec = s.Section ?? "",
                guardian = s.GuardianName ?? "", mobile = s.Mobile ?? ""
            }));
        }

        [HttpGet]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SaleStudent(int id)
        {
            var st = await _sales.GetStudentAsync(id, TenantId(), SchoolId(), UserId());
            if (st == null) return Json(new { success = false, message = "Student not found, or has left the school." });
            return Json(new
            {
                success = true, id = st.StudentId, name = st.StudentName, admNo = st.AdmissionNo ?? "",
                sessions = st.Sessions.Select(x => new { year = x.AcademicYear, cls = x.ClassName, sec = x.Section ?? "", current = x.IsCurrent })
            });
        }

        // Items for sale; with a class, that class's set comes filled in.
        [HttpGet]
        public async Task<IActionResult> SaleItems(string? cls, int? location)
        {
            var items = await _sales.GetItemsAsync(cls, location, TenantId(), SchoolId(), UserId());
            return Json(items.Select(i => new
            {
                id = i.ItemId, name = i.ItemName, category = i.Category, unit = i.UnitType,
                price = i.SellingPrice, stock = i.InStock, kit = i.KitQty, forClass = i.ForClass
            }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> Sell([FromBody] SellRequest req)
        {
            if (req == null) return Json(new { success = false, message = "Nothing to give." });
            var res = await _sales.SellAsync(req.StudentId, req.AcademicYear ?? "", req.LocationId,
                req.Items ?? new List<SaleLineInput>(), TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, saleId = res.Id, total = res.GrandTotal });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SaleReturn([FromBody] CancelRequest req)
        {
            var res = await _sales.ReturnAsync(req?.Id ?? 0, req?.Reason ?? "", TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // Store summary for a date range: bought, sold, margin, collected, unpaid, stock.
        [HttpGet]
        public async Task<IActionResult> StoreSummary(string? from, string? to)
        {
            var s = await _sales.GetSummaryAsync(from ?? "", to ?? "", TenantId(), SchoolId(), UserId());
            return Json(new
            {
                bought = s.Bought, sold = s.Sold, cost = s.CostOfSold, margin = s.Sold - s.CostOfSold,
                collected = s.Collected, unpaid = s.Unpaid, stock = s.StockValue
            });
        }

        [HttpGet]
        public async Task<IActionResult> Sales(int? studentId)
        {
            var rows = await _sales.GetSalesAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(r => new
            {
                lineId = r.LineId, saleId = r.SaleId, date = r.SaleDate, studentId = r.StudentId,
                name = r.StudentName, admNo = r.AdmissionNo ?? "", cls = r.ClassName ?? "", year = r.AcademicYear ?? "",
                item = r.ItemName, qty = r.Quantity, amount = r.Amount, paid = r.Paid, open = r.OpenAmount,
                returned = r.Returned, returnReason = r.ReturnReason ?? "", by = r.SoldBy ?? ""
            }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("inventory.manage")]
        public async Task<IActionResult> SaveClassKit([FromBody] KitRequest req)
        {
            var res = await _sales.SaveKitAsync(req?.ClassName ?? "", req?.Items ?? new List<SaleLineInput>(),
                TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        public class SellRequest
        {
            public int     StudentId    { get; set; }
            public string? AcademicYear { get; set; }
            public int?    LocationId   { get; set; }
            public List<SaleLineInput>? Items { get; set; }
        }
        public class KitRequest { public string? ClassName { get; set; } public List<SaleLineInput>? Items { get; set; } }

        // Small request shapes for the JSON posts above.
        public class IdRequest       { public int Id { get; set; } }
        public class CancelRequest   { public int Id { get; set; } public string? Reason { get; set; } }
        public class LocationRequest { public int Id { get; set; } public string? Name { get; set; } }
        public class ActiveRequest   { public int Id { get; set; } public bool Active { get; set; } }
    }
}
