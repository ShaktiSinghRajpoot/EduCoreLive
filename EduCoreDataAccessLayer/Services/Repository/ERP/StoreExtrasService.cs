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
    public class StoreExtrasService : IStoreExtrasService
    {
        private readonly PgExec _db;
        private readonly ILogger<StoreExtrasService> _logger;
        private const string PaySp = "core.sp_inventory_supplier_pay";

        public StoreExtrasService(PgExec db, ILogger<StoreExtrasService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<List<OrderLine>> GetOrderListAsync(string academicYear, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<OrderLine>();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(academicYear)) return list;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = academicYear.Trim() },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "order_list_cursor" }
            };
            await _db.ExecuteCursorsAsync("core.sp_inventory_order_list", p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new OrderLine
                    {
                        Item      = DbRead.Str(reader, cols, "item"),
                        Category  = DbRead.Str(reader, cols, "category"),
                        Unit      = DbRead.Str(reader, cols, "unit"),
                        Classes   = DbRead.Str(reader, cols, "classes"),
                        Children  = DbRead.Int(reader, cols, "children"),
                        Have      = DbRead.Int(reader, cols, "have"),
                        StillNeed = DbRead.Int(reader, cols, "still_need"),
                        InStock   = DbRead.Dec(reader, cols, "in_stock"),
                        ToOrder   = DbRead.Dec(reader, cols, "to_order"),
                        Sizes     = DbRead.Str(reader, cols, "sizes")
                    });
            });
            return list;
        }

        public async Task<InventoryResult> PaySupplierAsync(int supplierId, decimal amount, string? payDate, string? mode,
                                                            string? referenceNo, string? remarks, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || supplierId <= 0)
                return new InventoryResult { Message = "Choose the supplier." };
            var p = Params("Pay", tenantId, schoolId, actionUserId);
            p[4].Value = supplierId;
            p[5].Value = amount;
            p[6].Value = string.IsNullOrWhiteSpace(payDate) ? DBNull.Value : payDate.Trim();
            p[7].Value = string.IsNullOrWhiteSpace(mode) ? DBNull.Value : mode.Trim();
            p[8].Value = string.IsNullOrWhiteSpace(referenceNo) ? DBNull.Value : referenceNo.Trim();
            p[9].Value = string.IsNullOrWhiteSpace(remarks) ? DBNull.Value : remarks.Trim();
            return await RunAsync(p, "payment_id");
        }

        public async Task<List<SupplierPayment>> GetSupplierPaymentsAsync(int supplierId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<SupplierPayment>();
            if (tenantId <= 1 || schoolId <= 0 || supplierId <= 0) return list;
            var p = Params("List", tenantId, schoolId, actionUserId);
            p[4].Value = supplierId;
            await _db.ExecuteCursorsAsync(PaySp, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new SupplierPayment
                    {
                        PaymentId    = DbRead.Int(reader, cols, "payment_id"),
                        PayDate      = DbRead.NStr(reader, cols, "pay_date"),
                        Amount       = DbRead.Dec(reader, cols, "amount"),
                        PaymentMode  = DbRead.Str(reader, cols, "payment_mode"),
                        ReferenceNo  = DbRead.Str(reader, cols, "reference_no"),
                        Remarks      = DbRead.Str(reader, cols, "remarks"),
                        IsCancelled  = DbRead.Bool(reader, cols, "is_cancelled"),
                        CancelReason = DbRead.Str(reader, cols, "cancel_reason"),
                        PaidBy       = DbRead.NStr(reader, cols, "paid_by")
                    });
            });
            return list;
        }

        public async Task<InventoryResult> CancelSupplierPaymentAsync(int paymentId, string reason, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || paymentId <= 0)
                return new InventoryResult { Message = "Choose the payment." };
            var p = Params("Cancel", tenantId, schoolId, actionUserId);
            p[10].Value = paymentId;
            p[11].Value = reason ?? string.Empty;
            return await RunAsync(p, null);
        }

        private async Task<InventoryResult> RunAsync(NpgsqlParameter[] p, string? idColumn)
        {
            try
            {
                var result = new InventoryResult { Message = "Nothing was changed." };
                await _db.ExecuteCursorsAsync(PaySp, p, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        result.Success = DbRead.Bool(reader, cols, "success");
                        result.Message = DbRead.Str(reader, cols, "message");
                        result.Id      = idColumn == null ? 0 : DbRead.Int(reader, cols, idColumn);
                    }
                });
                return result;
            }
            catch (PostgresException ex)
            {
                // a proc RAISE: more than is due, no mode, already cancelled ...
                _logger.LogWarning(ex, "Supplier payment rejected. SqlState {SqlState}", ex.SqlState);
                return new InventoryResult { Message = ex.MessageText };
            }
        }

        // Fixed positional layout matching sp_inventory_supplier_pay.
        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Varchar) { Value = operation },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_supplier_id",    NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_amount",         NpgsqlDbType.Numeric) { Value = DBNull.Value },
                new("p_pay_date",       NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_payment_mode",   NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_reference_no",   NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_remarks",        NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_payment_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_reason",         NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "supplier_pay_cursor" }
            };
        }
    }
}
