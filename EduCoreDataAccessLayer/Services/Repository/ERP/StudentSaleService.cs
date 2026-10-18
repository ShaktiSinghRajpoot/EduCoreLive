using System.Data;
using System.Text.Json;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class StudentSaleService : IStudentSaleService
    {
        private readonly PgExec _db;
        private readonly ILogger<StudentSaleService> _logger;
        private const string Sp = "core.sp_inventory_student_sale";

        public StudentSaleService(PgExec db, ILogger<StudentSaleService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<List<SaleItem>> GetItemsAsync(string? className, int? locationId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<SaleItem>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var p = Params("Items", tenantId, schoolId, actionUserId);
            p[6].Value = string.IsNullOrWhiteSpace(className) ? DBNull.Value : className.Trim();
            p[7].Value = locationId > 0 ? locationId : DBNull.Value;

            await _db.ExecuteCursorsAsync(Sp, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new SaleItem
                    {
                        ItemId       = DbRead.Int(reader, cols, "item_id"),
                        ItemName     = DbRead.Str(reader, cols, "item_name"),
                        Category     = DbRead.Str(reader, cols, "category"),
                        UnitType     = DbRead.Str(reader, cols, "unit_type"),
                        SellingPrice = DbRead.Dec(reader, cols, "selling_price"),
                        InStock      = DbRead.Dec(reader, cols, "in_stock"),
                        KitQty       = DbRead.Dec(reader, cols, "kit_qty")
                    });
            });
            return list;
        }

        public async Task<SaleStudent?> GetStudentAsync(int studentId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0) return null;

            var p = Params("Student", tenantId, schoolId, actionUserId);
            p[4].Value = studentId;

            SaleStudent? student = null;
            await _db.ExecuteCursorsAsync(Sp, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                {
                    student ??= new SaleStudent
                    {
                        StudentId   = DbRead.Int(reader, cols, "student_id"),
                        StudentName = DbRead.Str(reader, cols, "student_name"),
                        AdmissionNo = DbRead.NStr(reader, cols, "admission_no")
                    };
                    student.Sessions.Add(new SaleSession
                    {
                        AcademicYear = DbRead.Str(reader, cols, "academic_year"),
                        ClassName    = DbRead.Str(reader, cols, "class_name"),
                        Section      = DbRead.NStr(reader, cols, "section"),
                        IsCurrent    = DbRead.Bool(reader, cols, "is_current")
                    });
                }
            });
            return student;
        }

        public async Task<InventoryResult> SellAsync(int studentId, string academicYear, int? locationId, List<SaleLineInput> items,
                                                     int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return new InventoryResult { Message = "Choose a student." };

            var p = Params("Sell", tenantId, schoolId, actionUserId);
            p[4].Value = studentId;
            p[5].Value = string.IsNullOrWhiteSpace(academicYear) ? DBNull.Value : academicYear.Trim();
            p[7].Value = locationId > 0 ? locationId : DBNull.Value;
            p[8].Value = ItemsJson(items);
            return await RunAsync(p, "sale_id");
        }

        public async Task<InventoryResult> ReturnAsync(int lineId, string reason, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || lineId <= 0)
                return new InventoryResult { Message = "Choose the item to return." };

            var p = Params("Return", tenantId, schoolId, actionUserId);
            p[9].Value  = lineId;
            p[10].Value = reason ?? string.Empty;
            return await RunAsync(p, null);
        }

        public async Task<List<StudentSaleRow>> GetSalesAsync(int? studentId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<StudentSaleRow>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var p = Params("List", tenantId, schoolId, actionUserId);
            p[4].Value = studentId > 0 ? studentId : DBNull.Value;

            await _db.ExecuteCursorsAsync(Sp, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new StudentSaleRow
                    {
                        LineId       = DbRead.Int(reader, cols, "line_id"),
                        SaleId       = DbRead.Int(reader, cols, "sale_id"),
                        SaleDate     = DbRead.NStr(reader, cols, "sale_date"),
                        StudentId    = DbRead.Int(reader, cols, "student_id"),
                        StudentName  = DbRead.Str(reader, cols, "student_name"),
                        AdmissionNo  = DbRead.NStr(reader, cols, "admission_no"),
                        ClassName    = DbRead.NStr(reader, cols, "class_name"),
                        AcademicYear = DbRead.NStr(reader, cols, "academic_year"),
                        ItemName     = DbRead.Str(reader, cols, "item_name"),
                        Quantity     = DbRead.Dec(reader, cols, "quantity"),
                        Amount       = DbRead.Dec(reader, cols, "amount"),
                        Paid         = DbRead.Dec(reader, cols, "paid"),
                        OpenAmount   = DbRead.Dec(reader, cols, "open_amount"),
                        Returned     = DbRead.Bool(reader, cols, "returned"),
                        ReturnReason = DbRead.NStr(reader, cols, "return_reason"),
                        SoldBy       = DbRead.NStr(reader, cols, "sold_by")
                    });
            });
            return list;
        }

        public async Task<InventoryResult> SaveKitAsync(string className, List<SaleLineInput> items, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new InventoryResult { Message = "Invalid school scope." };

            var p = Params("SaveKit", tenantId, schoolId, actionUserId);
            p[6].Value = className ?? string.Empty;
            p[8].Value = ItemsJson(items);
            return await RunAsync(p, null);
        }

        // [{"itemId":5,"qty":2}, ...] -- the shape the proc reads with jsonb_to_recordset
        private static string ItemsJson(List<SaleLineInput>? items) =>
            JsonSerializer.Serialize((items ?? new List<SaleLineInput>())
                .Where(i => i.ItemId > 0 && i.Qty > 0)
                .Select(i => new Dictionary<string, object> { ["itemId"] = i.ItemId, ["qty"] = i.Qty }));

        private async Task<InventoryResult> RunAsync(NpgsqlParameter[] p, string? idColumn)
        {
            try
            {
                var result = new InventoryResult { Message = "Nothing was changed." };
                await _db.ExecuteCursorsAsync(Sp, p, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        result.Success    = DbRead.Bool(reader, cols, "success");
                        result.Message    = DbRead.Str(reader, cols, "message");
                        result.Id         = idColumn == null ? 0 : DbRead.Int(reader, cols, idColumn);
                        result.GrandTotal = DbRead.Dec(reader, cols, "total");
                    }
                });
                return result;
            }
            catch (PostgresException ex)
            {
                // a proc RAISE: out of stock, already paid, not enrolled ...
                _logger.LogWarning(ex, "Student sale rejected. SqlState {SqlState}", ex.SqlState);
                return new InventoryResult { Message = ex.MessageText };
            }
        }

        // Fixed positional layout matching sp_inventory_student_sale.
        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Varchar) { Value = operation },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_class",          NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_location_id",    NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_items",          NpgsqlDbType.Jsonb)   { Value = DBNull.Value },
                new("p_line_id",        NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_reason",         NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_sale_cursor" }
            };
        }
    }
}
