using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Expenses and the Cash Book (expense_cashbook.sql).</summary>
    public interface IExpenseService
    {
        Task<List<ExpenseCategory>> GetCategoriesAsync(int tenantId, int schoolId, int actionUserId);
        Task<ExpenseResult> SaveCategoryAsync(int? categoryId, string name, int tenantId, int schoolId, int actionUserId);
        Task<ExpenseResult> SetCategoryActiveAsync(int categoryId, bool active, int tenantId, int schoolId, int actionUserId);

        /// <summary>Expenses between two dates (yyyy-MM-dd), optionally of one category.</summary>
        Task<List<ExpenseRow>> GetExpensesAsync(string from, string to, int? categoryId, int tenantId, int schoolId, int actionUserId);
        Task<ExpenseResult> SaveExpenseAsync(ExpenseInput input, int tenantId, int schoolId, int actionUserId);
        Task<ExpenseResult> CancelExpenseAsync(int expenseId, string reason, int tenantId, int schoolId, int actionUserId);

        Task<CashbookOpening?> GetOpeningAsync(int tenantId, int schoolId, int actionUserId);
        Task<ExpenseResult> SetOpeningAsync(string asOn, decimal cash, decimal bank, int tenantId, int schoolId, int actionUserId);

        /// <summary>The Cash Book for a range; book = All | Cash | Bank.</summary>
        Task<Cashbook> GetCashbookAsync(string from, string to, string book, int tenantId, int schoolId, int actionUserId);
    }
}
