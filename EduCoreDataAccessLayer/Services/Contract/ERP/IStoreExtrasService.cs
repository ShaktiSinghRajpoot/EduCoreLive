using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Store work real schools do around the shelf (inventory_store_extras.sql):
    /// the order list before a session, and paying suppliers for credit bills.
    /// </summary>
    public interface IStoreExtrasService
    {
        /// <summary>Per item (sizes together): children of its classes in the session, given, stock, to order.</summary>
        Task<List<OrderLine>> GetOrderListAsync(string academicYear, int tenantId, int schoolId, int actionUserId);

        /// <summary>Pay a supplier (at most what is due). Id = payment id.</summary>
        Task<InventoryResult> PaySupplierAsync(int supplierId, decimal amount, string? payDate, string? mode,
                                               string? referenceNo, string? remarks, int tenantId, int schoolId, int actionUserId);

        /// <summary>A supplier's payments, newest first (cancelled ones too).</summary>
        Task<List<SupplierPayment>> GetSupplierPaymentsAsync(int supplierId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Cancel a payment: it stays on record and the amount is due again.</summary>
        Task<InventoryResult> CancelSupplierPaymentAsync(int paymentId, string reason, int tenantId, int schoolId, int actionUserId);
    }
}
