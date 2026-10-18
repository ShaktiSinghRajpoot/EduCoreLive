using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class MessageLogService : IMessageLogService
    {
        private readonly PgExec _db;
        private const string SpLog       = "core.sp_message_log";
        private const string SpMessaging = "core.sp_school_messaging";

        public MessageLogService(PgExec db)
        {
            _db = db;
        }

        public async Task<bool> IsWhatsAppOnAsync(int tenantId, int schoolId)
        {
            if (tenantId <= 1 || schoolId <= 0) return false;
            // the switch is read through the Summary-free path: a one-row query via the function
            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id", NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id", NpgsqlDbType.Integer) { Value = schoolId },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "whatsapp_on_cursor" }
            };
            bool on = false;
            await _db.ExecuteCursorsAsync("core.sp_whatsapp_on", p, async reader =>
            {
                var cols = reader.Columns();
                if (await reader.ReadAsync()) on = DbRead.Bool(reader, cols, "whatsapp_on");
            });
            return on;
        }

        public async Task AddAsync(MessageLogEntry e, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || e == null) return;
            var p = LogParams("Add", tenantId, schoolId, actionUserId);
            p[4].Value  = e.AlertType;
            p[5].Value  = (object?)e.StudentId ?? DBNull.Value;
            p[6].Value  = (object?)e.ToName ?? DBNull.Value;
            p[7].Value  = (object?)e.ToPhone ?? DBNull.Value;
            p[8].Value  = (object?)e.MessageText ?? DBNull.Value;
            p[9].Value  = (object?)e.Template ?? DBNull.Value;
            p[10].Value = e.Status;
            p[11].Value = (object?)e.ProviderRef ?? DBNull.Value;
            p[12].Value = (object?)e.Error ?? DBNull.Value;
            await _db.ExecuteCursorsAsync(SpLog, p, async reader => { while (await reader.ReadAsync()) { } });
        }

        public async Task<List<MessageLogRow>> ListAsync(string? from, string? to, string? alertType, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<MessageLogRow>();
            if (tenantId <= 1 || schoolId <= 0) return list;
            var p = LogParams("List", tenantId, schoolId, actionUserId);
            p[4].Value  = string.IsNullOrWhiteSpace(alertType) ? DBNull.Value : alertType;
            p[13].Value = string.IsNullOrWhiteSpace(from) ? DBNull.Value : from;
            p[14].Value = string.IsNullOrWhiteSpace(to) ? DBNull.Value : to;
            await _db.ExecuteCursorsAsync(SpLog, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new MessageLogRow
                    {
                        LogId       = DbRead.Int(reader, cols, "log_id"),
                        SentAt      = DbRead.NStr(reader, cols, "sent_at"),
                        AlertType   = DbRead.Str(reader, cols, "alert_type"),
                        ToName      = DbRead.NStr(reader, cols, "to_name"),
                        ToPhone     = DbRead.NStr(reader, cols, "to_phone"),
                        MessageText = DbRead.NStr(reader, cols, "message_text"),
                        Status      = DbRead.Str(reader, cols, "status"),
                        Error       = DbRead.NStr(reader, cols, "error"),
                        SentBy      = DbRead.NStr(reader, cols, "sent_by")
                    });
            });
            return list;
        }

        public async Task<MessageSummary> SummaryAsync(string? from, string? to, string? alertType, int tenantId, int schoolId, int actionUserId)
        {
            var sum = new MessageSummary();
            if (tenantId <= 1 || schoolId <= 0) return sum;
            var p = LogParams("Summary", tenantId, schoolId, actionUserId);
            p[4].Value  = string.IsNullOrWhiteSpace(alertType) ? DBNull.Value : alertType;
            p[13].Value = string.IsNullOrWhiteSpace(from) ? DBNull.Value : from;
            p[14].Value = string.IsNullOrWhiteSpace(to) ? DBNull.Value : to;
            await _db.ExecuteCursorsAsync(SpLog, p, async reader =>
            {
                var cols = reader.Columns();
                if (await reader.ReadAsync())
                {
                    sum.Sent    = DbRead.Int(reader, cols, "sent");
                    sum.Failed  = DbRead.Int(reader, cols, "failed");
                    sum.Test    = DbRead.Int(reader, cols, "test");
                    sum.NoPhone = DbRead.Int(reader, cols, "no_phone");
                }
            });
            return sum;
        }

        public async Task<(bool On, int SentThisMonth)> GetSchoolWhatsAppAsync(int schoolId, int superUserId)
        {
            bool on = false; int sent = 0;
            await _db.ExecuteCursorsAsync(SpMessaging, MessagingParams("Get", schoolId, superUserId, null), async reader =>
            {
                var cols = reader.Columns();
                if (await reader.ReadAsync())
                {
                    on   = DbRead.Bool(reader, cols, "whatsapp_on");
                    sent = DbRead.Int(reader, cols, "sent_this_month");
                }
            });
            return (on, sent);
        }

        public async Task SaveSchoolWhatsAppAsync(int schoolId, bool on, int superUserId)
        {
            await _db.ExecuteCursorsAsync(SpMessaging, MessagingParams("Save", schoolId, superUserId, on),
                async reader => { while (await reader.ReadAsync()) { } });
        }

        // Fixed positional layout matching sp_message_log.
        private static NpgsqlParameter[] LogParams(string operation, int tenantId, int schoolId, int actionUserId) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },      // 0
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },       // 1
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },       // 2
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },   // 3
            new("p_alert_type",     NpgsqlDbType.Varchar) { Value = DBNull.Value },   // 4
            new("p_student_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },   // 5
            new("p_to_name",        NpgsqlDbType.Varchar) { Value = DBNull.Value },   // 6
            new("p_to_phone",       NpgsqlDbType.Varchar) { Value = DBNull.Value },   // 7
            new("p_message_text",   NpgsqlDbType.Text)    { Value = DBNull.Value },   // 8
            new("p_template",       NpgsqlDbType.Varchar) { Value = DBNull.Value },   // 9
            new("p_status",         NpgsqlDbType.Varchar) { Value = DBNull.Value },   // 10
            new("p_provider_ref",   NpgsqlDbType.Varchar) { Value = DBNull.Value },   // 11
            new("p_error",          NpgsqlDbType.Varchar) { Value = DBNull.Value },   // 12
            new("p_from",           NpgsqlDbType.Unknown) { Value = DBNull.Value },   // 13
            new("p_to",             NpgsqlDbType.Unknown) { Value = DBNull.Value },   // 14
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "message_log_cursor" }
        };

        private static NpgsqlParameter[] MessagingParams(string operation, int schoolId, int superUserId, bool? on) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = superUserId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_whatsapp_on",    NpgsqlDbType.Boolean) { Value = (object?)on ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "school_messaging_cursor" }
        };
    }
}
