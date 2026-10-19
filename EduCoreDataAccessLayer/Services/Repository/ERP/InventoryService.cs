using System.Data;
using EduCoreDataAccessLayer.Helpers;
using System.Text.Json;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class InventoryService : IInventoryService
    {
        private readonly PgExec _db;
        private readonly ILogger<InventoryService> _logger;
        private const string Sp         = "core.sp_inventory_manage";
        private const string SpPurchase = "core.sp_inventory_purchase_manage";

        public InventoryService(PgExec db, ILogger<InventoryService> logger)
        {
            _db = db;
            _logger = logger;
        }

        // ── Items ───────────────────────────────────────────────────────────
        public async Task<List<InventoryItem>> GetItemsAsync(
            int tenantId, int schoolId, int actionUserId, string? search = null, string? status = null,
            int? locationId = null)
        {
            var items = new List<InventoryItem>();
            if (tenantId <= 1 || schoolId <= 0) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("ListItems", tenantId, schoolId, actionUserId,
                           search: search, filterStatus: status,
                           locationId: locationId > 0 ? locationId : null));

            if (ds.Tables.Count == 0) return items;
            foreach (DataRow row in ds.Tables[0].Rows) items.Add(ReadItem(row));
            return items;
        }

        public async Task<InventoryItem?> GetItemAsync(
            int itemId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || itemId <= 0) return null;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("GetItem", tenantId, schoolId, actionUserId, itemId: itemId));

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;
            return ReadItem(ds.Tables[0].Rows[0]);
        }

        public async Task<InventoryResult> SaveItemAsync(
            InventoryItemInput input, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            return await RunAsync(Sp, Params("SaveItem", tenantId, schoolId, actionUserId,
                itemId: input.ItemId, itemName: input.ItemName, sku: input.Sku,
                category: input.Category, subCategory: input.SubCategory,
                itemType: input.ItemType, unitType: input.UnitType,
                openingStock: input.OpeningStock, minStock: input.MinStock,
                costPrice: input.CostPrice, sellingPrice: input.SellingPrice,
                brand: input.Brand, model: input.Model,
                description: input.Description, isActive: input.IsActive,
                locationId: input.LocationId > 0 ? input.LocationId : null));
        }

        public async Task<InventoryResult> DeleteItemAsync(
            int itemId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            return await RunAsync(Sp, Params("DeleteItem", tenantId, schoolId, actionUserId,
                itemId: itemId));
        }

        // ── Stock ───────────────────────────────────────────────────────────
        public async Task<InventoryResult> MoveStockAsync(
            StockMovementInput input, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            return await RunAsync(Sp, Params("MoveStock", tenantId, schoolId, actionUserId,
                itemId: input.ItemId, movementType: input.MovementType,
                quantity: input.Quantity, issuedTo: input.IssuedTo, remarks: input.Remarks,
                locationId: input.LocationId > 0 ? input.LocationId : null));
        }

        public async Task<List<StockMovement>> GetItemLedgerAsync(
            int itemId, int tenantId, int schoolId, int actionUserId)
        {
            var rows = new List<StockMovement>();
            if (tenantId <= 1 || schoolId <= 0 || itemId <= 0) return rows;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("ItemLedger", tenantId, schoolId, actionUserId, itemId: itemId));

            if (ds.Tables.Count == 0) return rows;
            foreach (DataRow r in ds.Tables[0].Rows)
                rows.Add(new StockMovement
                {
                    MovementId   = IntVal(r, "movement_id"),
                    MovementDate = DbRead.NStr(r, "movement_date") ?? default,
                    MovementType = Str(r, "movement_type"),
                    Quantity     = DecVal(r, "quantity"),
                    BalanceAfter = DecVal(r, "balance_after"),
                    Balance      = DecVal(r, "balance"),
                    UnitRate     = Has(r, "unit_rate") && r["unit_rate"] != DBNull.Value
                                       ? Convert.ToDecimal(r["unit_rate"]) : null,
                    CreatedBy    = Str(r, "created_by_name"),
                    InvoiceNo    = Str(r, "invoice_no"),
                    IssuedTo     = Str(r, "issued_to"),
                    Remarks      = Str(r, "remarks"),
                    ReferenceId  = IntVal(r, "reference_id"),
                    LocationName    = Str(r, "location_name"),
                    LocationBalance = DecVal(r, "location_balance"),
                    TransferWith    = Str(r, "transfer_with")
                });
            return rows;
        }

        public async Task<List<ItemLocationStock>> GetItemStockByLocationAsync(
            int itemId, int tenantId, int schoolId, int actionUserId)
        {
            var rows = new List<ItemLocationStock>();
            if (tenantId <= 1 || schoolId <= 0 || itemId <= 0) return rows;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("ItemStock", tenantId, schoolId, actionUserId, itemId: itemId));

            if (ds.Tables.Count == 0) return rows;
            foreach (DataRow r in ds.Tables[0].Rows)
                rows.Add(new ItemLocationStock
                {
                    LocationId   = IntVal(r, "location_id"),
                    LocationName = Str(r, "location_name"),
                    IsDefault    = BoolVal(r, "is_default"),
                    IsActive     = BoolVal(r, "is_active"),
                    Quantity     = DecVal(r, "quantity")
                });
            return rows;
        }

        // ── Locations and transfers ─────────────────────────────────────────
        public async Task<List<InventoryLocation>> GetLocationsAsync(
            int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<InventoryLocation>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            // The proc creates the default "Main Store" if the school has none yet.
            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("ListLocations", tenantId, schoolId, actionUserId));

            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
                list.Add(new InventoryLocation
                {
                    LocationId   = IntVal(r, "location_id"),
                    LocationName = Str(r, "location_name"),
                    IsDefault    = BoolVal(r, "is_default"),
                    IsActive     = BoolVal(r, "is_active"),
                    ItemCount    = IntVal(r, "item_count"),
                    TotalQty     = DecVal(r, "total_qty"),
                    StockValue   = DecVal(r, "stock_value")
                });
            return list;
        }

        public async Task<InventoryResult> SaveLocationAsync(
            int locationId, string? name, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            return await RunAsync(Sp, Params("SaveLocation", tenantId, schoolId, actionUserId,
                locationId: locationId > 0 ? locationId : null, locationName: name));
        }

        public async Task<InventoryResult> SetLocationActiveAsync(
            int locationId, bool isActive, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            return await RunAsync(Sp, Params("SetLocationActive", tenantId, schoolId, actionUserId,
                locationId: locationId, isActive: isActive));
        }

        public async Task<InventoryResult> TransferStockAsync(
            StockTransferInput input, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };
            if (input.ToLocationId <= 0)
                return new InventoryResult { Message = "Choose where the stock is going." };

            return await RunAsync(Sp, Params("Transfer", tenantId, schoolId, actionUserId,
                itemId: input.ItemId, quantity: input.Quantity, remarks: input.Reason,
                locationId: input.FromLocationId > 0 ? input.FromLocationId : null,
                toLocationId: input.ToLocationId));
        }

        public async Task<List<StockTransfer>> GetTransfersAsync(
            int tenantId, int schoolId, int actionUserId, int? itemId = null, int? locationId = null)
        {
            var list = new List<StockTransfer>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("ListTransfers", tenantId, schoolId, actionUserId,
                           itemId: itemId > 0 ? itemId : null,
                           locationId: locationId > 0 ? locationId : null));

            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
                list.Add(new StockTransfer
                {
                    TransferId   = IntVal(r, "transfer_id"),
                    TransferDate = Str(r, "transfer_date"),
                    ItemId       = IntVal(r, "item_id"),
                    ItemName     = Str(r, "item_name"),
                    UnitType     = Str(r, "unit_type"),
                    FromLocation = Str(r, "from_location"),
                    ToLocation   = Str(r, "to_location"),
                    Quantity     = DecVal(r, "quantity"),
                    Reason       = Str(r, "reason"),
                    CreatedBy    = Str(r, "created_by_name"),
                    CreatedAt    = Str(r, "created_at")
                });
            return list;
        }


        // ── Suppliers ───────────────────────────────────────────────────────
        public async Task<List<InventorySupplier>> GetSuppliersAsync(
            int tenantId, int schoolId, int actionUserId, string? search = null, string? status = null)
        {
            var list = new List<InventorySupplier>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("ListSuppliers", tenantId, schoolId, actionUserId,
                           search: search, filterStatus: status));

            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
                list.Add(new InventorySupplier
                {
                    SupplierId    = IntVal(r, "supplier_id"),
                    SupplierName  = Str(r, "supplier_name"),
                    ContactPerson = Str(r, "contact_person"),
                    Mobile        = Str(r, "mobile"),
                    Email         = Str(r, "email"),
                    Address       = Str(r, "address"),
                    Gstin         = Str(r, "gstin"),
                    IsActive      = BoolVal(r, "is_active"),
                    BillCount     = IntVal(r, "bill_count"),
                    TotalBilled   = DecVal(r, "total_billed"),
                    LastBillDate  = Str(r, "last_bill_date"),
                    Due           = DecVal(r, "due")
                });
            return list;
        }

        public async Task<InventoryResult> SaveSupplierAsync(
            InventorySupplier input, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            return await RunAsync(Sp, Params("SaveSupplier", tenantId, schoolId, actionUserId,
                supplierId: input.SupplierId, supplierName: input.SupplierName,
                contactPerson: input.ContactPerson, mobile: input.Mobile,
                email: input.Email, address: input.Address, gstin: input.Gstin));
        }

        public async Task<InventoryResult> DeleteSupplierAsync(
            int supplierId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            return await RunAsync(Sp, Params("DeleteSupplier", tenantId, schoolId, actionUserId,
                supplierId: supplierId));
        }

        public async Task<InventoryResult> SetSupplierActiveAsync(
            int supplierId, bool isActive, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            return await RunAsync(Sp, Params("SetSupplierActive", tenantId, schoolId, actionUserId,
                supplierId: supplierId, isActive: isActive));
        }

        // ── Purchases ───────────────────────────────────────────────────────
        public async Task<List<PurchaseListItem>> GetPurchasesAsync(
            int tenantId, int schoolId, int actionUserId,
            string? fromDate = null, string? toDate = null, int? supplierId = null)
        {
            var list = new List<PurchaseListItem>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            // A filter date the browser mangled is dropped (Dates.Norm returns
            // null) rather than reaching the proc and failing the whole list.
            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                SpPurchase, PurchaseParams("List", tenantId, schoolId, actionUserId,
                                           fromDate: Dates.Norm(fromDate), toDate: Dates.Norm(toDate),
                                           supplierId: supplierId > 0 ? supplierId : null));

            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
                list.Add(new PurchaseListItem
                {
                    PurchaseId   = IntVal(r, "purchase_id"),
                    PurchaseDate = DbRead.NStr(r, "purchase_date") ?? default,
                    SupplierName = Str(r, "supplier_name"),
                    InvoiceNo    = Str(r, "invoice_no"),
                    PaymentMode  = Str(r, "payment_mode"),
                    SubTotal     = DecVal(r, "sub_total"),
                    TaxTotal     = DecVal(r, "tax_total"),
                    GrandTotal   = DecVal(r, "grand_total"),
                    IsCancelled  = BoolVal(r, "is_cancelled"),
                    LineCount    = IntVal(r, "line_count"),
                    ItemQty      = DecVal(r, "item_qty"),
                    LocationName   = Str(r, "location_name"),
                    ReturnedQty    = DecVal(r, "returned_qty"),
                    ReturnedAmount = DecVal(r, "returned_amount")
                });
            return list;
        }

        public async Task<PurchaseDetail?> GetPurchaseAsync(
            int purchaseId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || purchaseId <= 0) return null;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                SpPurchase, PurchaseParams("Get", tenantId, schoolId, actionUserId,
                                           purchaseId: purchaseId));

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            var h = ds.Tables[0].Rows[0];
            var detail = new PurchaseDetail
            {
                PurchaseId   = IntVal(h, "purchase_id"),
                PurchaseDate = DbRead.NStr(h, "purchase_date") ?? default,
                SupplierId   = IntVal(h, "supplier_id") is var sid && sid > 0 ? sid : null,
                SupplierName = Str(h, "supplier_name"),
                InvoiceNo    = Str(h, "invoice_no"),
                PaymentMode  = Str(h, "payment_mode"),
                Remarks      = Str(h, "remarks"),
                SubTotal     = DecVal(h, "sub_total"),
                TaxTotal     = DecVal(h, "tax_total"),
                GrandTotal   = DecVal(h, "grand_total"),
                IsCancelled  = BoolVal(h, "is_cancelled"),
                CancelReason = Str(h, "cancel_reason"),
                LocationName   = Str(h, "location_name"),
                CreatedBy      = Str(h, "created_by_name"),
                CreatedAt      = Str(h, "created_at"),
                CancelledBy    = Str(h, "cancelled_by_name"),
                CancelledAt    = Str(h, "cancelled_at"),
                ReturnedAmount = DecVal(h, "returned_amount")
            };

            if (ds.Tables.Count > 1)
                foreach (DataRow r in ds.Tables[1].Rows)
                    detail.Lines.Add(new PurchaseLine
                    {
                        PurchaseItemId = IntVal(r, "purchase_item_id"),
                        ItemId     = IntVal(r, "item_id"),
                        ItemName   = Str(r, "item_name"),
                        Quantity   = DecVal(r, "quantity"),
                        UnitPrice  = DecVal(r, "unit_price"),
                        TaxPercent = DecVal(r, "tax_percent"),
                        LineTotal  = DecVal(r, "line_total"),
                        UnitType       = Str(r, "unit_type"),
                        ReturnedQty    = DecVal(r, "returned_qty"),
                        ReturnedAmount = DecVal(r, "returned_amount")
                    });

            // The returns made against the bill: a second, small call (the proc
            // keeps them in their own operation, see inventory.sql).
            var rs = await _db.ExecuteProcedureWithCursorsAsync(
                SpPurchase, PurchaseParams("Returns", tenantId, schoolId, actionUserId,
                                           purchaseId: purchaseId));
            if (rs.Tables.Count > 0)
                foreach (DataRow r in rs.Tables[0].Rows)
                    detail.Returns.Add(new PurchaseReturn
                    {
                        ReturnId       = IntVal(r, "return_id"),
                        ReturnDate     = Str(r, "return_date"),
                        PurchaseItemId = IntVal(r, "purchase_item_id"),
                        ItemName       = Str(r, "item_name"),
                        Quantity       = DecVal(r, "quantity"),
                        UnitPrice      = DecVal(r, "unit_price"),
                        TaxPercent     = DecVal(r, "tax_percent"),
                        Amount         = DecVal(r, "amount"),
                        Reason         = Str(r, "reason"),
                        LocationName   = Str(r, "location_name"),
                        CreatedBy      = Str(r, "created_by_name"),
                        CreatedAt      = Str(r, "created_at")
                    });

            return detail;
        }

        public async Task<InventoryResult> SavePurchaseAsync(
            PurchaseInput input, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            var purchaseDate = Dates.Norm(input.PurchaseDate);
            if (purchaseDate == null)
                return new InventoryResult { Message = "Choose a valid purchase date." };

            // A line with no item is refused, not silently dropped: the bill
            // would otherwise save with fewer lines than the user typed.
            var lines = input.Items ?? new List<PurchaseLineInput>();
            if (lines.Any(i => i.ItemId <= 0))
                return new InventoryResult { Message = "Every line needs an item." };

            // camelCase keys, matching the ->> lookups in the proc.
            var itemsJson = JsonSerializer.Serialize(
                lines.Select(i => new
                {
                    itemId     = i.ItemId,
                    quantity   = i.Quantity,
                    unitPrice  = i.UnitPrice,
                    taxPercent = i.TaxPercent
                }));

            return await RunAsync(SpPurchase,
                PurchaseParams("Save", tenantId, schoolId, actionUserId,
                    supplierId: input.SupplierId, purchaseDate: purchaseDate,
                    invoiceNo: input.InvoiceNo, paymentMode: input.PaymentMode,
                    remarks: input.Remarks, itemsJson: itemsJson,
                    locationId: input.LocationId > 0 ? input.LocationId : null));
        }

        public async Task<InventoryResult> CancelPurchaseAsync(
            int purchaseId, string? reason, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            return await RunAsync(SpPurchase,
                PurchaseParams("Cancel", tenantId, schoolId, actionUserId,
                    purchaseId: purchaseId, remarks: reason));
        }

        public async Task<InventoryResult> ReturnToSupplierAsync(
            PurchaseReturnInput input, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            // Lines with nothing to return are simply not part of the return;
            // the proc checks every quantity that is sent.
            var lines = (input.Lines ?? new List<PurchaseReturnLineInput>())
                        .Where(l => l.PurchaseItemId > 0 && l.Quantity != 0).ToList();
            if (lines.Count == 0)
                return new InventoryResult { Message = "Enter a quantity to return on at least one line." };

            var itemsJson = JsonSerializer.Serialize(
                lines.Select(l => new { purchaseItemId = l.PurchaseItemId, quantity = l.Quantity }));

            return await RunAsync(SpPurchase,
                PurchaseParams("Return", tenantId, schoolId, actionUserId,
                    purchaseId: input.PurchaseId, remarks: input.Reason, itemsJson: itemsJson));
        }

        // ── Shared plumbing ─────────────────────────────────────────────────
        private async Task<InventoryResult> RunAsync(string sp, NpgsqlParameter[] parameters)
        {
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(sp, parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new InventoryResult { Message = "Nothing was changed." };

                var r = ds.Tables[0].Rows[0];
                return new InventoryResult
                {
                    Success      = BoolVal(r, "success"),
                    Message      = Str(r, "message"),
                    Id           = IntVal(r, "item_id") + IntVal(r, "supplier_id") + IntVal(r, "purchase_id")
                                 + IntVal(r, "location_id"),
                    CurrentStock = DecVal(r, "current_stock"),
                    GrandTotal   = DecVal(r, "grand_total")
                };
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Inventory call {Proc} rejected. SqlState {SqlState}", sp, ex.SqlState);
                return new InventoryResult { Message = Friendly(ex) };
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Inventory call {Proc} failed.", sp);
                return new InventoryResult { Message = "Something went wrong. Please try again." };
            }
        }

        // Every RAISE in these procs (SqlState P0001) is a rule the store keeper
        // needs to read -- "Only 3 Piece of School Tie left", "already cancelled" --
        // so its wording goes straight back. Anything else is a database error
        // whose raw text ("duplicate key value violates unique constraint ...")
        // means nothing on screen, so it is turned into a sentence here.
        private static string Friendly(PostgresException ex)
        {
            if (ex.SqlState == PostgresErrorCodes.RaiseException) return ex.MessageText;

            switch (ex.SqlState)
            {
                case PostgresErrorCodes.UniqueViolation:
                    return ex.ConstraintName switch
                    {
                        "ux_inventory_item_name"        => "An item with this name already exists.",
                        "ux_inventory_item_sku"         => "Another item already uses this code.",
                        "ux_inventory_supplier_name"    => "A supplier with this name already exists.",
                        "ux_inventory_purchase_invoice" => "This bill number is already entered for this supplier.",
                        "ux_inventory_location_name"    => "A location with this name already exists.",
                        _                               => "This record already exists."
                    };
                case PostgresErrorCodes.CheckViolation:
                    return ex.ConstraintName == "chk_inv_loc_stock"
                        ? "There is not enough stock at that location."
                        : "One of the values is not allowed. Check quantities, prices and tax.";
                case PostgresErrorCodes.NumericValueOutOfRange:
                    return "One of the numbers is too large.";
                case PostgresErrorCodes.StringDataRightTruncation:
                    return "One of the text fields is too long.";
                case PostgresErrorCodes.InvalidTextRepresentation:
                case PostgresErrorCodes.InvalidDatetimeFormat:
                case PostgresErrorCodes.DatetimeFieldOverflow:
                    return "One of the values is not in the right format.";
                default:
                    return "Could not save. Please check the values and try again.";
            }
        }

        private static InventoryItem ReadItem(DataRow r) => new()
        {
            ItemId       = IntVal(r, "item_id"),
            ItemName     = Str(r, "item_name"),
            Sku          = Str(r, "sku"),
            Category     = Str(r, "category"),
            SubCategory  = Str(r, "sub_category"),
            ItemType     = Str(r, "item_type"),
            UnitType     = Str(r, "unit_type"),
            CurrentStock = DecVal(r, "current_stock"),
            MinStock     = DecVal(r, "min_stock"),
            CostPrice    = DecVal(r, "cost_price"),
            SellingPrice = DecVal(r, "selling_price"),
            Brand        = Str(r, "brand"),
            Model        = Str(r, "model"),
            Description  = Str(r, "description"),
            StockValue   = DecVal(r, "stock_value"),
            StockStatus  = Str(r, "stock_status"),
            IsActive     = BoolVal(r, "is_active"),
            LocationsHeld = IntVal(r, "locations_held"),
            OpeningQty    = DecVal(r, "opening_qty"),
            AddedQty      = DecVal(r, "added_qty"),
            ForClass      = Str(r, "for_class")
        };

        // Positional: the proc's parameter order.
        private static NpgsqlParameter[] Params(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? itemId = null, string? itemName = null, string? sku = null,
            string? category = null, string? subCategory = null, string? itemType = null,
            string? unitType = null, decimal? openingStock = null, decimal? minStock = null,
            decimal? costPrice = null, decimal? sellingPrice = null, string? brand = null,
            string? model = null, string? description = null, bool? isActive = null,
            int? supplierId = null, string? supplierName = null, string? contactPerson = null,
            string? mobile = null, string? email = null, string? address = null,
            string? gstin = null, string? movementType = null, decimal? quantity = null,
            string? issuedTo = null, string? remarks = null,
            string? search = null, string? filterStatus = null,
            int? locationId = null, int? toLocationId = null, string? locationName = null) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_item_id",        NpgsqlDbType.Integer) { Value = (object?)itemId ?? DBNull.Value },
            new("p_item_name",      NpgsqlDbType.Text)    { Value = (object?)itemName ?? DBNull.Value },
            new("p_sku",            NpgsqlDbType.Text)    { Value = (object?)sku ?? DBNull.Value },
            new("p_category",       NpgsqlDbType.Text)    { Value = (object?)category ?? DBNull.Value },
            new("p_sub_category",   NpgsqlDbType.Text)    { Value = (object?)subCategory ?? DBNull.Value },
            new("p_item_type",      NpgsqlDbType.Text)    { Value = (object?)itemType ?? DBNull.Value },
            new("p_unit_type",      NpgsqlDbType.Text)    { Value = (object?)unitType ?? DBNull.Value },
            new("p_opening_stock",  NpgsqlDbType.Numeric) { Value = (object?)openingStock ?? 0m },
            new("p_min_stock",      NpgsqlDbType.Numeric) { Value = (object?)minStock ?? 0m },
            new("p_cost_price",     NpgsqlDbType.Numeric) { Value = (object?)costPrice ?? 0m },
            new("p_selling_price",  NpgsqlDbType.Numeric) { Value = (object?)sellingPrice ?? 0m },
            new("p_brand",          NpgsqlDbType.Text)    { Value = (object?)brand ?? DBNull.Value },
            new("p_model",          NpgsqlDbType.Text)    { Value = (object?)model ?? DBNull.Value },
            new("p_description",    NpgsqlDbType.Text)    { Value = (object?)description ?? DBNull.Value },
            new("p_is_active",      NpgsqlDbType.Boolean) { Value = (object?)isActive ?? DBNull.Value },
            new("p_supplier_id",    NpgsqlDbType.Integer) { Value = (object?)supplierId ?? DBNull.Value },
            new("p_supplier_name",  NpgsqlDbType.Text)    { Value = (object?)supplierName ?? DBNull.Value },
            new("p_contact_person", NpgsqlDbType.Text)    { Value = (object?)contactPerson ?? DBNull.Value },
            new("p_mobile",         NpgsqlDbType.Text)    { Value = (object?)mobile ?? DBNull.Value },
            new("p_email",          NpgsqlDbType.Text)    { Value = (object?)email ?? DBNull.Value },
            new("p_address",        NpgsqlDbType.Text)    { Value = (object?)address ?? DBNull.Value },
            new("p_gstin",          NpgsqlDbType.Text)    { Value = (object?)gstin ?? DBNull.Value },
            new("p_movement_type",  NpgsqlDbType.Text)    { Value = (object?)movementType ?? DBNull.Value },
            new("p_quantity",       NpgsqlDbType.Numeric) { Value = (object?)quantity ?? DBNull.Value },
            new("p_issued_to",      NpgsqlDbType.Text)    { Value = (object?)issuedTo ?? DBNull.Value },
            new("p_remarks",        NpgsqlDbType.Text)    { Value = (object?)remarks ?? DBNull.Value },
            new("p_search",         NpgsqlDbType.Text)    { Value = (object?)search ?? DBNull.Value },
            new("p_filter_status",  NpgsqlDbType.Text)    { Value = (object?)filterStatus ?? DBNull.Value },
            new("p_location_id",    NpgsqlDbType.Integer) { Value = (object?)locationId ?? DBNull.Value },
            new("p_to_location_id", NpgsqlDbType.Integer) { Value = (object?)toLocationId ?? DBNull.Value },
            new("p_location_name",  NpgsqlDbType.Text)    { Value = (object?)locationName ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "inventory_cursor" }
        };

        private static NpgsqlParameter[] PurchaseParams(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? purchaseId = null, int? supplierId = null, string? purchaseDate = null,
            string? invoiceNo = null, string? paymentMode = null, string? remarks = null,
            string? itemsJson = null, string? fromDate = null, string? toDate = null,
            int? locationId = null)
            => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_purchase_id",    NpgsqlDbType.Integer) { Value = (object?)purchaseId ?? DBNull.Value },
            new("p_supplier_id",    NpgsqlDbType.Integer) { Value = (object?)supplierId ?? DBNull.Value },
            new("p_purchase_date",  NpgsqlDbType.Unknown)    { Value = (object?)purchaseDate ?? DBNull.Value },
            new("p_invoice_no",     NpgsqlDbType.Text)    { Value = (object?)invoiceNo ?? DBNull.Value },
            new("p_payment_mode",   NpgsqlDbType.Text)    { Value = (object?)paymentMode ?? DBNull.Value },
            new("p_remarks",        NpgsqlDbType.Text)    { Value = (object?)remarks ?? DBNull.Value },
            new("p_items",          NpgsqlDbType.Jsonb)   { Value = (object?)itemsJson ?? "[]" },
            new("p_from_date",      NpgsqlDbType.Unknown)    { Value = (object?)fromDate ?? DBNull.Value },
            new("p_to_date",        NpgsqlDbType.Unknown)    { Value = (object?)toDate ?? DBNull.Value },
            new("p_location_id",    NpgsqlDbType.Integer) { Value = (object?)locationId ?? DBNull.Value },
            new("p_result",  NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "purchase_cursor" },
            new("p_result2", NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "purchase_cursor2" }
        };

        private static bool Has(DataRow r, string c) => r.Table.Columns.Contains(c);
        private static int IntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static decimal DecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : 0m;
        private static bool BoolVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value && Convert.ToBoolean(r[c]);
        private static string Str(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
    }
}
