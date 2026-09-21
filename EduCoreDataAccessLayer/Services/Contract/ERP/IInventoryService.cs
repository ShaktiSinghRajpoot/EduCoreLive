using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    public interface IInventoryService
    {
        // ── Items ───────────────────────────────────────────────────────────
        Task<List<InventoryItem>> GetItemsAsync(
            int tenantId, int schoolId, int actionUserId,
            string? search = null, string? status = null);

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

        // ── Suppliers ───────────────────────────────────────────────────────
        Task<List<InventorySupplier>> GetSuppliersAsync(
            int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> SaveSupplierAsync(
            InventorySupplier input, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> DeleteSupplierAsync(
            int supplierId, int tenantId, int schoolId, int actionUserId);

        // ── Purchases ───────────────────────────────────────────────────────
        Task<List<PurchaseListItem>> GetPurchasesAsync(
            int tenantId, int schoolId, int actionUserId,
            string? fromDate = null, string? toDate = null);

        Task<PurchaseDetail?> GetPurchaseAsync(
            int purchaseId, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> SavePurchaseAsync(
            PurchaseInput input, int tenantId, int schoolId, int actionUserId);

        Task<InventoryResult> CancelPurchaseAsync(
            int purchaseId, string? reason, int tenantId, int schoolId, int actionUserId);
    }
}
