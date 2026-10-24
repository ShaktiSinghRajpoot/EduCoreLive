using System.Data;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services.Contract.SuperAdmin;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.SuperAdmin
{
    public class WebsiteEnquiryService : IWebsiteEnquiryService
    {
        private const string SpSave = "core.sp_website_enquiry_save";
        private const string SpManage = "core.sp_website_enquiry_manage";

        private readonly PgExec _db;
        private readonly AppCache _cache;
        private readonly ILogger<WebsiteEnquiryService> _logger;

        public WebsiteEnquiryService(PgExec db, AppCache cache, ILogger<WebsiteEnquiryService> logger)
        {
            _db = db;
            _cache = cache;
            _logger = logger;
        }

        // the menu badge; platform data, so the key is the platform's (tenant 1, school 0)
        private static string NewCountKey => AppCache.Key("website-enquiries-new", 1, 0);

        public async Task<(bool Success, string Message)> SaveAsync(WebsiteEnquiry e, string? ipAddress)
        {
            var p = new NpgsqlParameter[]
            {
                new("p_contact_name", NpgsqlDbType.Varchar) { Value = (object?)e.ContactName ?? DBNull.Value },
                new("p_designation",  NpgsqlDbType.Varchar) { Value = (object?)e.Designation ?? DBNull.Value },
                new("p_school_name",  NpgsqlDbType.Varchar) { Value = (object?)e.SchoolName ?? DBNull.Value },
                new("p_city",         NpgsqlDbType.Varchar) { Value = (object?)e.City ?? DBNull.Value },
                new("p_phone",        NpgsqlDbType.Varchar) { Value = (object?)e.Phone ?? DBNull.Value },
                new("p_email",        NpgsqlDbType.Varchar) { Value = (object?)e.Email ?? DBNull.Value },
                new("p_students",     NpgsqlDbType.Varchar) { Value = (object?)e.Students ?? DBNull.Value },
                new("p_message",      NpgsqlDbType.Varchar) { Value = (object?)e.Message ?? DBNull.Value },
                new("p_ip_address",   NpgsqlDbType.Varchar) { Value = (object?)ipAddress ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "enquiry_save_cursor" }
            };
            try
            {
                await _db.ExecuteProcedureWithCursorsAsync(SpSave, p);
                _cache.Remove(NewCountKey);
                return (true, "Thank you. We will call you within one working day.");
            }
            catch (PostgresException pg)
            {
                _logger.LogWarning(pg, "Website enquiry refused: {SqlState} {Message}", pg.SqlState, pg.MessageText);
                return (false, pg.SqlState == "P0001" ? pg.MessageText : "Could not send your enquiry. Please call us.");
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Website enquiry failed");
                return (false, "Could not send your enquiry. Please call us.");
            }
        }

        public async Task<List<WebsiteEnquiry>> GetListAsync(string? statusFilter, int tenantId, int actionUserId)
        {
            var list = new List<WebsiteEnquiry>();
            if (tenantId != 1) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpManage, ManageParams("LIST", tenantId, actionUserId, 0, null, null, statusFilter));
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow r in ds.Tables[0].Rows)
            {
                list.Add(new WebsiteEnquiry
                {
                    EnquiryId   = Convert.ToInt32(r["enquiry_id"]),
                    ContactName = Str(r, "contact_name") ?? "",
                    Designation = Str(r, "designation"),
                    SchoolName  = Str(r, "school_name") ?? "",
                    City        = Str(r, "city"),
                    Phone       = Str(r, "phone") ?? "",
                    Email       = Str(r, "email"),
                    Students    = Str(r, "students"),
                    Message     = Str(r, "message"),
                    Status      = Str(r, "status") ?? "New",
                    Note        = Str(r, "note"),
                    CreatedAt   = Str(r, "created_at"),
                    UpdatedAt   = Str(r, "updated_at")
                });
            }
            return list;
        }

        public async Task<int> CountNewAsync(int tenantId, int actionUserId)
        {
            if (tenantId != 1) return 0;
            return await _cache.GetOrCreateAsync(NewCountKey, async () =>
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpManage, ManageParams("COUNT_NEW", tenantId, actionUserId, 0, null, null, null));
                return ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0 ? 0 : Convert.ToInt32(ds.Tables[0].Rows[0]["new_count"]);
            }, TimeSpan.FromMinutes(1));
        }

        public async Task<(bool Success, string Message)> SetStatusAsync(int enquiryId, string status, string? note, int tenantId, int actionUserId)
        {
            if (tenantId != 1) return (false, "Only the platform can change enquiries.");
            try
            {
                await _db.ExecuteProcedureWithCursorsAsync(SpManage, ManageParams("STATUS", tenantId, actionUserId, enquiryId, status, note, null));
                _cache.Remove(NewCountKey);
                return (true, "Saved.");
            }
            catch (PostgresException pg)
            {
                _logger.LogWarning(pg, "Website enquiry status refused: {SqlState} {Message}", pg.SqlState, pg.MessageText);
                return (false, pg.SqlState == "P0001" ? pg.MessageText : "Could not save.");
            }
        }

        private static NpgsqlParameter[] ManageParams(string op, int tenantId, int actionUserId, int enquiryId,
                                                      string? status, string? note, string? statusFilter) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Varchar) { Value = op },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = enquiryId },
            new("p_status",         NpgsqlDbType.Varchar) { Value = (object?)status ?? DBNull.Value },
            new("p_note",           NpgsqlDbType.Varchar) { Value = (object?)note ?? DBNull.Value },
            new("p_status_filter",  NpgsqlDbType.Varchar) { Value = (object?)statusFilter ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "enquiry_manage_cursor" }
        };

        private static string? Str(DataRow r, string col) =>
            r.Table.Columns.Contains(col) && r[col] != DBNull.Value ? r[col].ToString() : null;
    }
}
