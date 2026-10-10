using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    public interface IInventoryService
    {
        // ── Items ───────────────────────────────────────────────────────────
        /// locationId: stock at that location instead of the school-wide total.
        Task<List<InventoryItem>> GetItemsAsync(
            int tenantId, int schoolId, int actionUserId,
            string? search = null, string? status = null, int? locationId = null);

        Task<InventoryItem?> GetItemAsync(
            int itemId, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> SaveItemAsync(
            InventoryItemInput input, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> DeleteItemAsync(
            int itemId, int tenantId, int schoolId, int actionUserId);

        // ── Stock ───────────────────────────────────────────────────────────
        Task<InventoryResult> MoveStockAsync(
            StockMovementInput input, int tenantId, int schoolId, int actionUserId);

        Task<List<StockMovement>> GetItemLedgerAsync(
            int itemId, int tenantId, int schoolId, int actionUserId);

        Task<List<ItemLocationStock>> GetItemStockByLocationAsync(
            int itemId, int tenantId, int schoolId, int actionUserId);

        // ── Locations and transfers ─────────────────────────────────────────
        Task<List<InventoryLocation>> GetLocationsAsync(
            int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> SaveLocationAsync(
            int locationId, string? name, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> SetLocationActiveAsync(
            int locationId, bool isActive, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> TransferStockAsync(
            StockTransferInput input, int tenantId, int schoolId, int actionUserId);

        Task<List<StockTransfer>> GetTransfersAsync(
            int tenantId, int schoolId, int actionUserId,
            int? itemId = null, int? locationId = null);

        // ── Suppliers ───────────────────────────────────────────────────────
        /// status: null = all live suppliers, "Active" or "Inactive".
        Task<List<InventorySupplier>> GetSuppliersAsync(
            int tenantId, int schoolId, int actionUserId,
            string? search = null, string? status = null);

        Task<InventoryResult> SaveSupplierAsync(
            InventorySupplier input, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> DeleteSupplierAsync(
            int supplierId, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> SetSupplierActiveAsync(
            int supplierId, bool isActive, int tenantId, int schoolId, int actionUserId);

        // ── Purchases ───────────────────────────────────────────────────────
        Task<List<PurchaseListItem>> GetPurchasesAsync(
            int tenantId, int schoolId, int actionUserId,
            string? fromDate = null, string? toDate = null, int? supplierId = null);

        Task<PurchaseDetail?> GetPurchaseAsync(
            int purchaseId, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> SavePurchaseAsync(
            PurchaseInput input, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> CancelPurchaseAsync(
            int purchaseId, string? reason, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> ReturnToSupplierAsync(
            PurchaseReturnInput input, int tenantId, int schoolId, int actionUserId);
    }
}
