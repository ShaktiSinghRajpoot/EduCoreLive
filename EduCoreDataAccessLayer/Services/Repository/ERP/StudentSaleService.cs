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
                        KitQty       = DbRead.Dec(reader, cols, "kit_qty"),
                        ForClass     = DbRead.NStr(reader, cols, "for_class")
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

        public async Task<StoreRegister> GetRegisterAsync(string academicYear, string className, string? section,
                                                          int tenantId, int schoolId, int actionUserId)
        {
            var reg = new StoreRegister();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(academicYear) || string.IsNullOrWhiteSpace(className))
                return reg;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = academicYear.Trim() },
                new("p_class",          NpgsqlDbType.Varchar) { Value = className.Trim() },
                new("p_section",        NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(section) ? DBNull.Value : section.Trim() },
                new("p_students", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "register_students" },
                new("p_items",    NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "register_items" },
                new("p_held",     NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "register_held" }
            };

            await _db.ExecuteCursorsAsync("core.sp_inventory_class_register", p,
                async reader =>   // the children
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        reg.Students.Add(new StoreRegisterStudent
                        {
                            StudentId   = DbRead.Int(reader, cols, "student_id"),
                            StudentName = DbRead.Str(reader, cols, "student_name"),
                            AdmissionNo = DbRead.NStr(reader, cols, "admission_no"),
                            Section     = DbRead.NStr(reader, cols, "section"),
                            RollNo      = DbRead.NStr(reader, cols, "roll_no")
                        });
                },
                async reader =>   // the columns
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        reg.Items.Add(new SaleItem
                        {
                            ItemId   = DbRead.Int(reader, cols, "item_id"),
                            ItemName = DbRead.Str(reader, cols, "item_name"),
                            Category = DbRead.Str(reader, cols, "category")
                        });
                },
                async reader =>   // who holds what
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        reg.Held.Add(new StoreRegisterHeld
                        {
                            StudentId = DbRead.Int(reader, cols, "student_id"),
                            ItemId    = DbRead.Int(reader, cols, "item_id"),
                            Quantity  = DbRead.Dec(reader, cols, "quantity"),
                            Unpaid    = DbRead.Dec(reader, cols, "unpaid")
                        });
                });
            return reg;
        }

        public async Task<StoreSummary> GetSummaryAsync(string from, string to, int tenantId, int schoolId, int actionUserId)
        {
            var sum = new StoreSummary();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(from) || string.IsNullOrWhiteSpace(to)) return sum;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_from",           NpgsqlDbType.Unknown) { Value = from },
                new("p_to",             NpgsqlDbType.Unknown) { Value = to },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "store_summary_cursor" }
            };
            await _db.ExecuteCursorsAsync("core.sp_inventory_store_summary", p, async reader =>
            {
                var cols = reader.Columns();
                if (await reader.ReadAsync())
                {
                    sum.Bought     = DbRead.Dec(reader, cols, "bought");
                    sum.Sold       = DbRead.Dec(reader, cols, "sold");
                    sum.CostOfSold = DbRead.Dec(reader, cols, "cost_of_sold");
                    sum.Collected  = DbRead.Dec(reader, cols, "collected");
                    sum.Unpaid     = DbRead.Dec(reader, cols, "unpaid");
                    sum.StockValue = DbRead.Dec(reader, cols, "stock_value");
                }
            });
            return sum;
        }

        public async Task<string?> GetItemClassAsync(int itemId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || itemId <= 0) return null;
            var p = Params("ItemClass", tenantId, schoolId, actionUserId);
            p[12].Value = itemId;
            string? cls = null;
            await _db.ExecuteCursorsAsync(Sp, p, async reader =>
            {
                var cols = reader.Columns();
                if (await reader.ReadAsync()) cls = DbRead.NStr(reader, cols, "for_class");
            });
            return cls;
        }

        public async Task<InventoryResult> SetItemClassAsync(int itemId, string? className, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || itemId <= 0)
                return new InventoryResult { Message = "Invalid item." };
            var p = Params("SetItemClass", tenantId, schoolId, actionUserId);
            p[6].Value  = string.IsNullOrWhiteSpace(className) ? DBNull.Value : className.Trim();
            p[12].Value = itemId;
            return await RunAsync(p, null);
        }

        public async Task<StoreRegisterOverview> GetOverviewAsync(string academicYear, int tenantId, int schoolId, int actionUserId)
        {
            var ov = new StoreRegisterOverview();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(academicYear)) return ov;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = academicYear.Trim() },
                new("p_students", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "overview_students" },
                new("p_items",    NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "overview_items" },
                new("p_held",     NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "overview_held" }
            };
            await _db.ExecuteCursorsAsync("core.sp_inventory_register_overview", p,
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        ov.Students.Add(new OverviewStudent
                        {
                            StudentId  = DbRead.Int(reader, cols, "student_id"),
                            ClassName  = DbRead.Str(reader, cols, "class_name"),
                            Section    = DbRead.Str(reader, cols, "section"),
                            ClassOrder = DbRead.Int(reader, cols, "class_order")
                        });
                },
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        ov.Items.Add(new SaleItem
                        {
                            ItemId   = DbRead.Int(reader, cols, "item_id"),
                            ItemName = DbRead.Str(reader, cols, "item_name"),
                            Category = DbRead.Str(reader, cols, "category"),
                            ForClass = DbRead.NStr(reader, cols, "for_class")
                        });
                },
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        ov.Held.Add((DbRead.Int(reader, cols, "student_id"), DbRead.Int(reader, cols, "item_id")));
                });
            return ov;
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
                    { Direction = ParameterDirection.InputOutput, Value = "student_sale_cursor" },
                new("p_item_id",        NpgsqlDbType.Integer) { Value = DBNull.Value }   // 12: after p_result, as in the proc
            };
        }
    }
}
