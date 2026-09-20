using System.Data;
using EduCoreDataAccessLayer.Helpers;
using System.Text.Json;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class InventoryService : IInventoryService
    {
        private readonly PgExec _db;
        private const string Sp         = "core.sp_inventory_manage";
        private const string SpPurchase = "core.sp_inventory_purchase_manage";

        public InventoryService(PgExec db)
        {
            _db = db;
        }

        // ── Items ───────────────────────────────────────────────────────────
        public async Task<List<InventoryItem>> GetItemsAsync(
            int tenantId, int schoolId, int actionUserId, string? search = null, string? status = null)
        {
            var items = new List<InventoryItem>();
            if (tenantId <= 1 || schoolId <= 0) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("ListItems", tenantId, schoolId, actionUserId,
                           search: search, filterStatus: status));

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
                description: input.Description, isActive: input.IsActive));
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
                quantity: input.Quantity, issuedTo: input.IssuedTo, remarks: input.Remarks));
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
                    MovementDate = DbRead.Date(r, "movement_date") ?? default,
                    MovementType = Str(r, "movement_type"),
                    Quantity     = DecVal(r, "quantity"),
                    BalanceAfter = DecVal(r, "balance_after"),
                    IssuedTo     = Str(r, "issued_to"),
                    Remarks      = Str(r, "remarks"),
                    ReferenceId  = IntVal(r, "reference_id")
                });
            return rows;
        }


        // ── Suppliers ───────────────────────────────────────────────────────
        public async Task<List<InventorySupplier>> GetSuppliersAsync(
            int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<InventorySupplier>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("ListSuppliers", tenantId, schoolId, actionUserId));

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
                    IsActive      = BoolVal(r, "is_active")
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

        // ── Purchases ───────────────────────────────────────────────────────
        public async Task<List<PurchaseListItem>> GetPurchasesAsync(
            int tenantId, int schoolId, int actionUserId,
            DateOnly? fromDate = null, DateOnly? toDate = null)
        {
            var list = new List<PurchaseListItem>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                SpPurchase, PurchaseParams("List", tenantId, schoolId, actionUserId,
                                           fromDate: fromDate, toDate: toDate));

            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
                list.Add(new PurchaseListItem
                {
                    PurchaseId   = IntVal(r, "purchase_id"),
                    PurchaseDate = DbRead.Date(r, "purchase_date") ?? default,
                    SupplierName = Str(r, "supplier_name"),
                    InvoiceNo    = Str(r, "invoice_no"),
                    PaymentMode  = Str(r, "payment_mode"),
                    SubTotal     = DecVal(r, "sub_total"),
                    TaxTotal     = DecVal(r, "tax_total"),
                    GrandTotal   = DecVal(r, "grand_total"),
                    IsCancelled  = BoolVal(r, "is_cancelled"),
                    LineCount    = IntVal(r, "line_count")
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
                PurchaseDate = DbRead.Date(h, "purchase_date") ?? default,
                SupplierId   = IntVal(h, "supplier_id") is var sid && sid > 0 ? sid : null,
                SupplierName = Str(h, "supplier_name"),
                InvoiceNo    = Str(h, "invoice_no"),
                PaymentMode  = Str(h, "payment_mode"),
                Remarks      = Str(h, "remarks"),
                SubTotal     = DecVal(h, "sub_total"),
                TaxTotal     = DecVal(h, "tax_total"),
                GrandTotal   = DecVal(h, "grand_total"),
                IsCancelled  = BoolVal(h, "is_cancelled"),
                CancelReason = Str(h, "cancel_reason")
            };

            if (ds.Tables.Count > 1)
                foreach (DataRow r in ds.Tables[1].Rows)
                    detail.Lines.Add(new PurchaseLine
                    {
                        ItemId     = IntVal(r, "item_id"),
                        ItemName   = Str(r, "item_name"),
                        Quantity   = DecVal(r, "quantity"),
                        UnitPrice  = DecVal(r, "unit_price"),
                        TaxPercent = DecVal(r, "tax_percent"),
                        LineTotal  = DecVal(r, "line_total")
                    });

            return detail;
        }

        public async Task<InventoryResult> SavePurchaseAsync(
            PurchaseInput input, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            // camelCase keys, matching the ->> lookups in the proc.
            var itemsJson = JsonSerializer.Serialize(
                (input.Items ?? new List<PurchaseLineInput>())
                .Where(i => i.ItemId > 0)
                .Select(i => new
                {
                    itemId     = i.ItemId,
                    quantity   = i.Quantity,
                    unitPrice  = i.UnitPrice,
                    taxPercent = i.TaxPercent
                }));

            return await RunAsync(SpPurchase,
                PurchaseParams("Save", tenantId, schoolId, actionUserId,
                    supplierId: input.SupplierId, purchaseDate: input.PurchaseDate,
                    invoiceNo: input.InvoiceNo, paymentMode: input.PaymentMode,
                    remarks: input.Remarks, itemsJson: itemsJson));
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
                    Id           = IntVal(r, "item_id") + IntVal(r, "supplier_id") + IntVal(r, "purchase_id"),
                    CurrentStock = DecVal(r, "current_stock"),
                    GrandTotal   = DecVal(r, "grand_total")
                };
            }
            catch (PostgresException ex)
            {
                // Every RAISE in these procs is a rule the store keeper needs to
                // read — "Only 3 Piece of School Tie left", "already cancelled" —
                // so the proc's own wording goes straight back to the screen.
                return new InventoryResult { Message = ex.MessageText };
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
            IsActive     = BoolVal(r, "is_active")
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
            string? search = null, string? filterStatus = null) => new NpgsqlParameter[]
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
            new("p_result", NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "inventory_cursor" }
        };

        private static NpgsqlParameter[] PurchaseParams(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? purchaseId = null, int? supplierId = null, DateOnly? purchaseDate = null,
            string? invoiceNo = null, string? paymentMode = null, string? remarks = null,
            string? itemsJson = null, DateOnly? fromDate = null, DateOnly? toDate = null)
            => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_purchase_id",    NpgsqlDbType.Integer) { Value = (object?)purchaseId ?? DBNull.Value },
            new("p_supplier_id",    NpgsqlDbType.Integer) { Value = (object?)supplierId ?? DBNull.Value },
            new("p_purchase_date",  NpgsqlDbType.Date)    { Value = purchaseDate.HasValue ? purchaseDate.Value : (object)DBNull.Value },
            new("p_invoice_no",     NpgsqlDbType.Text)    { Value = (object?)invoiceNo ?? DBNull.Value },
            new("p_payment_mode",   NpgsqlDbType.Text)    { Value = (object?)paymentMode ?? DBNull.Value },
            new("p_remarks",        NpgsqlDbType.Text)    { Value = (object?)remarks ?? DBNull.Value },
            new("p_items",          NpgsqlDbType.Jsonb)   { Value = (object?)itemsJson ?? "[]" },
            new("p_from_date",      NpgsqlDbType.Date)    { Value = fromDate.HasValue ? fromDate.Value : (object)DBNull.Value },
            new("p_to_date",        NpgsqlDbType.Date)    { Value = toDate.HasValue ? toDate.Value : (object)DBNull.Value },
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
