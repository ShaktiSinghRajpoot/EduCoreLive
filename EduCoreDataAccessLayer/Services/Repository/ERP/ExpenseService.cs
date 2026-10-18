using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class ExpenseService : IExpenseService
    {
        private readonly PgExec _db;
        private readonly ILogger<ExpenseService> _logger;
        private const string Sp         = "core.sp_expense_manage";
        private const string SpCashbook = "core.sp_cashbook";

        public ExpenseService(PgExec db, ILogger<ExpenseService> logger)
        {
            _db = db;
            _logger = logger;
        }

        // ── Categories ──────────────────────────────────────────────────────
        public async Task<List<ExpenseCategory>> GetCategoriesAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<ExpenseCategory>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            await _db.ExecuteCursorsAsync(Sp, Params("Categories", tenantId, schoolId, actionUserId), async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new ExpenseCategory
                    {
                        CategoryId = DbRead.Int(reader, cols, "category_id"),
                        Name       = DbRead.Str(reader, cols, "name"),
                        IsActive   = DbRead.Bool(reader, cols, "is_active"),
                        Used       = DbRead.Int(reader, cols, "used")
                    });
            });
            return list;
        }

        public async Task<ExpenseResult> SaveCategoryAsync(int? categoryId, string name, int tenantId, int schoolId, int actionUserId)
        {
            var p = Params("SaveCategory", tenantId, schoolId, actionUserId);
            p[6].Value  = categoryId > 0 ? categoryId : DBNull.Value;
            p[13].Value = name ?? string.Empty;
            return await RunAsync(p, tenantId, schoolId);
        }

        public async Task<ExpenseResult> SetCategoryActiveAsync(int categoryId, bool active, int tenantId, int schoolId, int actionUserId)
        {
            var p = Params("SetCategoryActive", tenantId, schoolId, actionUserId);
            p[6].Value  = categoryId;
            p[14].Value = active;
            return await RunAsync(p, tenantId, schoolId);
        }

        // ── Expenses ────────────────────────────────────────────────────────
        public async Task<List<ExpenseRow>> GetExpensesAsync(string from, string to, int? categoryId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<ExpenseRow>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var p = Params("List", tenantId, schoolId, actionUserId);
            p[6].Value  = categoryId > 0 ? categoryId : DBNull.Value;
            p[15].Value = string.IsNullOrWhiteSpace(from) ? DBNull.Value : from;
            p[16].Value = string.IsNullOrWhiteSpace(to) ? DBNull.Value : to;

            await _db.ExecuteCursorsAsync(Sp, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new ExpenseRow
                    {
                        ExpenseId    = DbRead.Int(reader, cols, "expense_id"),
                        ExpenseDate  = DbRead.Str(reader, cols, "expense_date"),
                        CategoryId   = DbRead.Int(reader, cols, "category_id"),
                        Category     = DbRead.Str(reader, cols, "category"),
                        Amount       = DbRead.Dec(reader, cols, "amount"),
                        PaymentMode  = DbRead.Str(reader, cols, "payment_mode"),
                        PaidTo       = DbRead.NStr(reader, cols, "paid_to"),
                        ReferenceNo  = DbRead.NStr(reader, cols, "reference_no"),
                        Remarks      = DbRead.NStr(reader, cols, "remarks"),
                        IsCancelled  = DbRead.Bool(reader, cols, "is_cancelled"),
                        CancelReason = DbRead.NStr(reader, cols, "cancel_reason"),
                        CancelledBy  = DbRead.NStr(reader, cols, "cancelled_by"),
                        CancelledAt  = DbRead.NStr(reader, cols, "cancelled_at"),
                        CreatedBy    = DbRead.NStr(reader, cols, "created_by"),
                        CreatedAt    = DbRead.NStr(reader, cols, "created_at")
                    });
            });
            return list;
        }

        public async Task<ExpenseResult> SaveExpenseAsync(ExpenseInput input, int tenantId, int schoolId, int actionUserId)
        {
            if (input == null) return new ExpenseResult { Message = "Nothing to save." };
            var p = Params("Save", tenantId, schoolId, actionUserId);
            p[5].Value  = string.IsNullOrWhiteSpace(input.ExpenseDate) ? DBNull.Value : input.ExpenseDate;
            p[6].Value  = input.CategoryId > 0 ? input.CategoryId : DBNull.Value;
            p[7].Value  = input.Amount;
            p[9].Value  = (object?)input.PaymentMode ?? DBNull.Value;
            p[10].Value = (object?)input.PaidTo ?? DBNull.Value;
            p[11].Value = (object?)input.ReferenceNo ?? DBNull.Value;
            p[12].Value = (object?)input.Remarks ?? DBNull.Value;
            return await RunAsync(p, tenantId, schoolId);
        }

        public async Task<ExpenseResult> CancelExpenseAsync(int expenseId, string reason, int tenantId, int schoolId, int actionUserId)
        {
            var p = Params("Cancel", tenantId, schoolId, actionUserId);
            p[4].Value  = expenseId;
            p[13].Value = reason ?? string.Empty;   // p_name carries the reason
            return await RunAsync(p, tenantId, schoolId);
        }

        // ── Opening balance ─────────────────────────────────────────────────
        public async Task<CashbookOpening?> GetOpeningAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return null;
            CashbookOpening? o = null;
            await _db.ExecuteCursorsAsync(Sp, Params("GetOpening", tenantId, schoolId, actionUserId), async reader =>
            {
                var cols = reader.Columns();
                if (await reader.ReadAsync())
                    o = new CashbookOpening
                    {
                        AsOn      = DbRead.NStr(reader, cols, "as_on"),
                        Cash      = DbRead.Dec(reader, cols, "cash"),
                        Bank      = DbRead.Dec(reader, cols, "bank"),
                        UpdatedBy = DbRead.NStr(reader, cols, "updated_by"),
                        UpdatedAt = DbRead.NStr(reader, cols, "updated_at")
                    };
            });
            return o;
        }

        public async Task<ExpenseResult> SetOpeningAsync(string asOn, decimal cash, decimal bank, int tenantId, int schoolId, int actionUserId)
        {
            var p = Params("SetOpening", tenantId, schoolId, actionUserId);
            p[5].Value = string.IsNullOrWhiteSpace(asOn) ? DBNull.Value : asOn;
            p[7].Value = cash;
            p[8].Value = bank;
            return await RunAsync(p, tenantId, schoolId);
        }

        // ── Cash Book ───────────────────────────────────────────────────────
        public async Task<Cashbook> GetCashbookAsync(string from, string to, string book, int tenantId, int schoolId, int actionUserId)
        {
            var cb = new Cashbook();
            if (tenantId <= 1 || schoolId <= 0) return cb;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_from",           NpgsqlDbType.Unknown) { Value = from },
                new("p_to",             NpgsqlDbType.Unknown) { Value = to },
                new("p_book",           NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(book) ? "All" : book },
                new("p_summary", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cashbook_summary" },
                new("p_lines",   NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cashbook_lines" },
                new("p_heads",   NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cashbook_heads" },
                new("p_months",  NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cashbook_months" }
            };

            await _db.ExecuteCursorsAsync(SpCashbook, p,
                async reader =>   // summary
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        cb.BookFrom    = DbRead.NStr(reader, cols, "book_from");
                        cb.OpeningAsOn = DbRead.NStr(reader, cols, "opening_as_on");
                        cb.Opening     = DbRead.Dec(reader, cols, "opening");
                        cb.MoneyIn     = DbRead.Dec(reader, cols, "money_in");
                        cb.MoneyOut    = DbRead.Dec(reader, cols, "money_out");
                        cb.Closing     = DbRead.Dec(reader, cols, "closing");
                    }
                },
                async reader =>   // lines
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        cb.Lines.Add(new CashbookLine
                        {
                            LineDate = DbRead.Str(reader, cols, "line_date"),
                            Kind     = DbRead.Str(reader, cols, "kind"),
                            Ref      = DbRead.NStr(reader, cols, "ref"),
                            Detail   = DbRead.NStr(reader, cols, "detail"),
                            Category = DbRead.Str(reader, cols, "category"),
                            Mode     = DbRead.NStr(reader, cols, "mode"),
                            MoneyIn  = DbRead.Dec(reader, cols, "money_in"),
                            MoneyOut = DbRead.Dec(reader, cols, "money_out"),
                            Balance  = DbRead.Dec(reader, cols, "balance")
                        });
                },
                async reader =>   // by category
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        cb.Heads.Add(new CashbookHead
                        {
                            Category = DbRead.Str(reader, cols, "category"),
                            MoneyIn  = DbRead.Dec(reader, cols, "money_in"),
                            MoneyOut = DbRead.Dec(reader, cols, "money_out"),
                            Entries  = DbRead.Int(reader, cols, "entries")
                        });
                },
                async reader =>   // month by month
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        cb.Months.Add(new CashbookMonth
                        {
                            Month    = DbRead.Str(reader, cols, "month"),
                            MoneyIn  = DbRead.Dec(reader, cols, "money_in"),
                            MoneyOut = DbRead.Dec(reader, cols, "money_out"),
                            Net      = DbRead.Dec(reader, cols, "net")
                        });
                });
            return cb;
        }

        private async Task<ExpenseResult> RunAsync(NpgsqlParameter[] p, int tenantId, int schoolId)
        {
            if (tenantId <= 1 || schoolId <= 0) return new ExpenseResult { Message = "Invalid school scope." };
            try
            {
                var result = new ExpenseResult { Message = "Nothing was changed." };
                await _db.ExecuteCursorsAsync(Sp, p, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        result.Success = DbRead.Bool(reader, cols, "success");
                        result.Message = DbRead.Str(reader, cols, "message");
                        result.Id      = DbRead.Int(reader, cols, "id");
                    }
                });
                return result;
            }
            catch (PostgresException ex)
            {
                // a proc RAISE: future date, duplicate category, already cancelled ...
                _logger.LogWarning(ex, "Expense change rejected for school {SchoolId}. SqlState {SqlState}", schoolId, ex.SqlState);
                return new ExpenseResult { Message = ex.MessageText };
            }
        }

        // Fixed positional layout matching sp_expense_manage.
        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Varchar) { Value = operation },          // 0
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },           // 1
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },           // 2
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },       // 3
                new("p_expense_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },       // 4
                new("p_date",           NpgsqlDbType.Unknown) { Value = DBNull.Value },       // 5
                new("p_category_id",    NpgsqlDbType.Integer) { Value = DBNull.Value },       // 6
                new("p_amount",         NpgsqlDbType.Numeric) { Value = DBNull.Value },       // 7
                new("p_amount2",        NpgsqlDbType.Numeric) { Value = DBNull.Value },       // 8
                new("p_mode",           NpgsqlDbType.Varchar) { Value = DBNull.Value },       // 9
                new("p_paid_to",        NpgsqlDbType.Varchar) { Value = DBNull.Value },       // 10
                new("p_reference",      NpgsqlDbType.Varchar) { Value = DBNull.Value },       // 11
                new("p_remarks",        NpgsqlDbType.Varchar) { Value = DBNull.Value },       // 12
                new("p_name",           NpgsqlDbType.Varchar) { Value = DBNull.Value },       // 13
                new("p_active",         NpgsqlDbType.Boolean) { Value = DBNull.Value },       // 14
                new("p_from",           NpgsqlDbType.Unknown) { Value = DBNull.Value },       // 15
                new("p_to",             NpgsqlDbType.Unknown) { Value = DBNull.Value },       // 16
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "expense_cursor" }  // 17
            };
        }
    }
}
