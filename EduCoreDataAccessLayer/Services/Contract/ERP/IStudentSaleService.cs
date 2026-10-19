using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Books & uniform sold to a student: off the store's shelf, onto the student's
    /// fee account (inventory_student_sale.sql).
    /// </summary>
    public interface IStudentSaleService
    {
        /// <summary>Saleable items with stock at the location; className fills in that class's set.</summary>
        Task<List<SaleItem>> GetItemsAsync(string? className, int? locationId, int tenantId, int schoolId, int actionUserId);

        /// <summary>The child and their class in this and any later session; null if not found / left.</summary>
        Task<SaleStudent?> GetStudentAsync(int studentId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Give the items and add one fee line per item in that session. Id = sale id.</summary>
        Task<InventoryResult> SellAsync(int studentId, string academicYear, int? locationId, List<SaleLineInput> items,
                                        int tenantId, int schoolId, int actionUserId);

        /// <summary>Take an unpaid line back: fee line closed, item back in stock.</summary>
        Task<InventoryResult> ReturnAsync(int lineId, string reason, int tenantId, int schoolId, int actionUserId);

        /// <summary>Swap a sold line to another size of the same item ("28 for 32").</summary>
        Task<InventoryResult> ExchangeAsync(int lineId, int itemId, int tenantId, int schoolId, int actionUserId);

        /// <summary>The latest sales, line by line (one student, or everyone).</summary>
        Task<List<StudentSaleRow>> GetSalesAsync(int? studentId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Who in a class-section holds which item this session (the ✓ / ✗ register).</summary>
        Task<StoreRegister> GetRegisterAsync(string academicYear, string className, string? section,
                                             int tenantId, int schoolId, int actionUserId);

        /// <summary>Bought, sold, cost, collected, unpaid and stock of saleable items between two dates.</summary>
        Task<StoreSummary> GetSummaryAsync(string from, string to, int tenantId, int schoolId, int actionUserId);

        /// <summary>Which class a saleable item is for (null = every class).</summary>
        Task<string?> GetItemClassAsync(int itemId, int tenantId, int schoolId, int actionUserId);
        Task<InventoryResult> SetItemClassAsync(int itemId, string? className, int tenantId, int schoolId, int actionUserId);

        /// <summary>The whole session for the register's every-class overview.</summary>
        Task<StoreRegisterOverview> GetOverviewAsync(string academicYear, int tenantId, int schoolId, int actionUserId);

        /// <summary>Replace one class's set of items.</summary>
        Task<InventoryResult> SaveKitAsync(string className, List<SaleLineInput> items, int tenantId, int schoolId, int actionUserId);
    }
}
