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
    /// <summary>
    /// Announcements / Notice Board. One procedure, core.sp_announcement_manage,
    /// picked by p_operation (Board | List | SeenBy | Read | Save | Delete).
    /// </summary>
    public class NoticeService : INoticeService
    {
        private const string Sp = "core.sp_announcement_manage";
        private readonly PgExec _db;
        private readonly ILogger<NoticeService> _logger;

        public NoticeService(PgExec db, ILogger<NoticeService> logger)
        {
            _db = db;
            _logger = logger;
        }

        private static bool InScope(int tenantId, int schoolId) => tenantId > 1 && schoolId > 0;

        public Task<List<Notice>> GetBoardAsync(int tenantId, int schoolId, int actionUserId)
            => ReadNoticesAsync("Board", tenantId, schoolId, actionUserId);

        public Task<List<Notice>> GetAllAsync(int tenantId, int schoolId, int actionUserId)
            => ReadNoticesAsync("List", tenantId, schoolId, actionUserId);

        public async Task<Notice?> GetAsync(int id, int tenantId, int schoolId, int actionUserId)
        {
            var all = await GetAllAsync(tenantId, schoolId, actionUserId);
            return all.FirstOrDefault(n => n.Id == id);
        }

        private async Task<List<Notice>> ReadNoticesAsync(string operation, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<Notice>();
            if (!InScope(tenantId, schoolId)) return list;

            await _db.ExecuteCursorsAsync(Sp, Params(operation, tenantId, schoolId, actionUserId), async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                {
                    list.Add(new Notice
                    {
                        Id         = DbRead.Int(reader, cols, "announcement_id"),
                        Title      = DbRead.Str(reader, cols, "title"),
                        Body       = DbRead.Str(reader, cols, "body"),
                        Category   = DbRead.Str(reader, cols, "category"),
                        Audience   = DbRead.Str(reader, cols, "audience"),
                        ClassNames = DbRead.NStr(reader, cols, "class_names"),
                        IsPinned   = DbRead.Bool(reader, cols, "is_pinned"),
                        ShowUntil  = DbRead.NStr(reader, cols, "show_until"),
                        CreatedAt  = DbRead.DateTimeN(reader, cols, "created_at"),
                        PostedBy   = DbRead.NStr(reader, cols, "posted_by"),
                        IsRead     = DbRead.Bool(reader, cols, "is_read"),
                        SeenCount  = DbRead.Int(reader, cols, "seen_count"),
                        StaffCount = DbRead.Int(reader, cols, "staff_count")
                    });
                }
            });
            return list;
        }

        public async Task<List<NoticeReader>> GetSeenByAsync(int id, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<NoticeReader>();
            if (!InScope(tenantId, schoolId) || id <= 0) return list;

            await _db.ExecuteCursorsAsync(Sp, Params("SeenBy", tenantId, schoolId, actionUserId, id), async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new NoticeReader
                    {
                        Name   = DbRead.Str(reader, cols, "name"),
                        ReadAt = DbRead.DateTimeN(reader, cols, "read_at")
                    });
            });
            return list;
        }

        public async Task MarkReadAsync(int? id, int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId) || actionUserId <= 0) return;
            await _db.ExecuteCursorsAsync(Sp, Params("Read", tenantId, schoolId, actionUserId, id), async reader =>
            {
                while (await reader.ReadAsync()) { }
            });
        }

        public Task<(bool Success, string Message)> SaveAsync(Notice n, int tenantId, int schoolId, int actionUserId)
            => WriteAsync(Params("Save", tenantId, schoolId, actionUserId, n.Id > 0 ? n.Id : null, n), "save", tenantId, schoolId);

        public Task<(bool Success, string Message)> DeleteAsync(int id, int tenantId, int schoolId, int actionUserId)
            => WriteAsync(Params("Delete", tenantId, schoolId, actionUserId, id), "delete", tenantId, schoolId);

        private async Task<(bool Success, string Message)> WriteAsync(NpgsqlParameter[] parameters, string what, int tenantId, int schoolId)
        {
            if (!InScope(tenantId, schoolId))
                return (false, "Invalid request.");
            try
            {
                string msg = "Saved.";
                await _db.ExecuteCursorsAsync(Sp, parameters, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                        msg = DbRead.NStr(reader, cols, "message") ?? msg;
                });
                return (true, msg);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Notice {What} rejected for school {SchoolId}. SqlState {SqlState}", what, schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error on notice {What} for school {SchoolId}.", what, schoolId);
                return (false, "Could not save. Please try again.");
            }
        }

        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId,
                                                int? id = null, Notice? n = null) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_id",             NpgsqlDbType.Integer) { Value = (object?)id ?? DBNull.Value },
            new("p_title",          NpgsqlDbType.Text)    { Value = (object?)n?.Title ?? DBNull.Value },
            new("p_body",           NpgsqlDbType.Text)    { Value = (object?)n?.Body ?? DBNull.Value },
            new("p_category",       NpgsqlDbType.Text)    { Value = (object?)n?.Category ?? DBNull.Value },
            new("p_audience",       NpgsqlDbType.Text)    { Value = (object?)n?.Audience ?? DBNull.Value },
            new("p_class_names",    NpgsqlDbType.Text)    { Value = (object?)n?.ClassNames ?? DBNull.Value },
            new("p_is_pinned",      NpgsqlDbType.Boolean) { Value = n?.IsPinned ?? false },
            new("p_show_until",     NpgsqlDbType.Date)    { Value = (object?)Dates.Parse(n?.ShowUntil) ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "announcement_cursor" }
        };
    }
}
