using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Configuration;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    public class EnquiryService : IEnquiryService
    {
        private readonly string _connectionString;
        private const string SpMain     = "core.sp_enquiry_crm_manage";
        private const string SpFollowup = "core.sp_enquiry_followup_manage";

        public EnquiryService(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
        }

        // ── Page load ────────────────────────────────────────────
        public async Task<EnquiryCrmPageModel> GetEnquiryCrmPageAsync(
            int tenantId, int schoolId, int actionUserId)
        {
            var (items, totalCount) = await GetEnquiriesAsync(tenantId, schoolId, actionUserId, 1, 10);
            return new EnquiryCrmPageModel
            {
                Enquiries  = items,
                TotalCount = totalCount,
                PageNumber = 1,
                PageSize   = 10,
                Stats      = await GetKpiStatsAsync(tenantId, schoolId, actionUserId)
            };
        }

        // ── Filtered + paginated list ────────────────────────────
        public async Task<(List<EnquiryListModel> Items, int TotalCount)> GetEnquiriesAsync(
            int     tenantId,
            int     schoolId,
            int     actionUserId,
            int     pageNumber       = 1,
            int     pageSize         = 10,
            string? search           = null,
            string? filterSession    = null,
            string? filterPriority   = null,
            string? filterClass      = null,
            string? filterSource     = null,
            string? filterPipeline   = null,
            int?    filterAssignedTo = null,
            bool    filterOverdue    = false,
            bool    filterToday      = false)
        {
            var list = new List<EnquiryListModel>();
            if (tenantId <= 1 || schoolId <= 0) return (list, 0);

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",        NpgsqlDbType.Text)    { Value = "GetEnquiries" },
                new("p_tenant_id",        NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",        NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",   NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_page_number",      NpgsqlDbType.Integer) { Value = pageNumber },
                new("p_page_size",        NpgsqlDbType.Integer) { Value = pageSize },
                new("p_search",           NpgsqlDbType.Text)    { Value = (object?)search          ?? DBNull.Value },
                new("p_filter_session",   NpgsqlDbType.Text)    { Value = (object?)filterSession   ?? DBNull.Value },
                new("p_filter_priority",  NpgsqlDbType.Text)    { Value = (object?)filterPriority  ?? DBNull.Value },
                new("p_filter_class",     NpgsqlDbType.Text)    { Value = (object?)filterClass     ?? DBNull.Value },
                new("p_filter_source",    NpgsqlDbType.Text)    { Value = (object?)filterSource    ?? DBNull.Value },
                new("p_filter_pipeline",  NpgsqlDbType.Text)    { Value = (object?)filterPipeline  ?? DBNull.Value },
                new("p_filter_assigned_to", NpgsqlDbType.Integer){ Value = (object?)filterAssignedTo ?? DBNull.Value },
                new("p_filter_overdue",   NpgsqlDbType.Boolean) { Value = filterOverdue },
                new("p_filter_today",     NpgsqlDbType.Boolean) { Value = filterToday },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "p_result" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return (list, 0);

            int totalCount = 0;
            foreach (DataRow row in ds.Tables[0].Rows)
            {
                if (totalCount == 0 && row.Table.Columns.Contains("total_count"))
                    totalCount = row["total_count"] == DBNull.Value ? 0 : Convert.ToInt32(row["total_count"]);
                list.Add(MapListRow(row, tenantId, schoolId));
            }
            return (list, totalCount);
        }

        // ── KPI stats ────────────────────────────────────────────
        public async Task<EnquiryStatsModel> GetKpiStatsAsync(
            int tenantId, int schoolId, int actionUserId)
        {
            var stats = new EnquiryStatsModel();
            if (tenantId <= 1 || schoolId <= 0) return stats;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "GetKpiStats" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "kpi_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return stats;

            var row = ds.Tables[0].Rows[0];
            stats.TotalLeads        = IntVal(row, "total_leads");
            stats.DueToday          = IntVal(row, "due_today");
            stats.OverdueCount      = IntVal(row, "overdue_count");
            stats.CampusVisits      = IntVal(row, "campus_visits");
            stats.Admitted          = IntVal(row, "admitted");
            stats.CntNew            = IntVal(row, "cnt_new");
            stats.CntFollowup       = IntVal(row, "cnt_followup");
            stats.CntInterested     = IntVal(row, "cnt_interested");
            stats.CntCampusVisit    = IntVal(row, "cnt_campusvisit");
            stats.CntRegistered     = IntVal(row, "cnt_registered");
            stats.CntNotInterested  = IntVal(row, "cnt_not_interested");
            stats.ConversionRate    = row["conversion_rate"] == DBNull.Value
                                        ? 0 : Convert.ToDecimal(row["conversion_rate"]);
            return stats;
        }

        // ── Single enquiry ───────────────────────────────────────
        public async Task<EnquiryModel?> GetEnquiryByIdAsync(
            int enquiryId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0) return null;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "GetEnquiryById" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = enquiryId },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "enquiry_by_id_cursor" }

            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;
            return MapBaseRow(ds.Tables[0].Rows[0], tenantId, schoolId);
        }

        // ── Save enquiry ─────────────────────────────────────────
        public async Task<int> SaveEnquiryAsync(EnquiryModel model, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return 0;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",              NpgsqlDbType.Text)    { Value = "SaveEnquiry" },
                new("p_tenant_id",              NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",              NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",         NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",             NpgsqlDbType.Integer) { Value = model.EnquiryId > 0 ? model.EnquiryId : DBNull.Value },
                new("p_student_name",           NpgsqlDbType.Text)    { Value = model.StudentName },
                new("p_gender",                 NpgsqlDbType.Text)    { Value = (object?)model.Gender                 ?? DBNull.Value },
                new("p_dob",                    NpgsqlDbType.Date)    { Value = (object?)model.Dob                    ?? DBNull.Value },
                new("p_class_name",             NpgsqlDbType.Text)    { Value = model.ClassName },
                new("p_session",                NpgsqlDbType.Text)    { Value = model.Session },
                new("p_interested_stream",      NpgsqlDbType.Text)    { Value = (object?)model.InterestedStream       ?? DBNull.Value },
                new("p_father_name",            NpgsqlDbType.Text)    { Value = (object?)model.FatherName             ?? DBNull.Value },
                new("p_father_mobile",          NpgsqlDbType.Text)    { Value = (object?)model.FatherMobile           ?? DBNull.Value },
                new("p_mother_name",            NpgsqlDbType.Text)    { Value = (object?)model.MotherName             ?? DBNull.Value },
                new("p_mother_mobile",          NpgsqlDbType.Text)    { Value = (object?)model.MotherMobile           ?? DBNull.Value },
                new("p_mobile",                 NpgsqlDbType.Text)    { Value = model.Mobile },
                new("p_alt_mobile",             NpgsqlDbType.Text)    { Value = (object?)model.AltMobile              ?? DBNull.Value },
                new("p_city",                   NpgsqlDbType.Text)    { Value = (object?)model.City                   ?? DBNull.Value },
                new("p_area_locality",          NpgsqlDbType.Text)    { Value = (object?)model.AreaLocality           ?? DBNull.Value },
                new("p_lead_source",            NpgsqlDbType.Text)    { Value = model.LeadSource },
                new("p_referrer_name",          NpgsqlDbType.Text)    { Value = (object?)model.ReferrerName           ?? DBNull.Value },
                new("p_referrer_mobile",        NpgsqlDbType.Text)    { Value = (object?)model.ReferrerMobile         ?? DBNull.Value },
                new("p_priority",               NpgsqlDbType.Text)    { Value = model.Priority },
                new("p_status",                 NpgsqlDbType.Text)    { Value = model.Status },
                new("p_assigned_to_id",         NpgsqlDbType.Integer) { Value = (object?)model.AssignedToId          ?? DBNull.Value },
                new("p_lost_reason",            NpgsqlDbType.Text)    { Value = (object?)model.LostReason             ?? DBNull.Value },
                new("p_next_followup_date",     NpgsqlDbType.Date)    { Value = (object?)model.NextFollowupDate       ?? DBNull.Value },
                new("p_notes",                  NpgsqlDbType.Text)    { Value = (object?)model.Notes                  ?? DBNull.Value },
                new("p_estimated_fee",          NpgsqlDbType.Numeric) { Value = (object?)model.EstimatedFee          ?? DBNull.Value },
                new("p_registration_number",    NpgsqlDbType.Text)    { Value = (object?)model.RegistrationNumber     ?? DBNull.Value },
                new("p_registration_date",      NpgsqlDbType.Date)    { Value = (object?)model.RegistrationDate       ?? DBNull.Value },
                new("p_registration_fee_paid",  NpgsqlDbType.Boolean) { Value = model.RegistrationFeePaid },
                new("p_parent_email",           NpgsqlDbType.Text)    { Value = (object?)model.ParentEmail       ?? DBNull.Value },
                new("p_current_class",          NpgsqlDbType.Text)    { Value = (object?)model.CurrentClass      ?? DBNull.Value },
                new("p_current_school",         NpgsqlDbType.Text)    { Value = (object?)model.CurrentSchool     ?? DBNull.Value },
                new("p_transport_required",     NpgsqlDbType.Boolean) { Value = model.TransportRequired },
                new("p_whatsapp_number",        NpgsqlDbType.Text)    { Value = (object?)model.WhatsAppNumber    ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "save_enquiry_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return 0;
            var row = ds.Tables[0].Rows[0];
            return row["enquiry_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["enquiry_id"]);
        }

        // ── Status update (AJAX) ─────────────────────────────────
        public async Task<(int Success, string Message)> UpdateStatusAsync(
            int enquiryId, string status, string? lostReason,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0)
                return (0, "Invalid request.");

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "UpdateStatus" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = enquiryId },
                new("p_status",         NpgsqlDbType.Text)    { Value = status },
                new("p_lost_reason",    NpgsqlDbType.Text)    { Value = (object?)lostReason ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "update_status_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return (0, "No response.");
            var row     = ds.Tables[0].Rows[0];
            int success = row["success"] == DBNull.Value ? 0 : Convert.ToInt32(row["success"]);
            string msg  = row.Table.Columns.Contains("message") && row["message"] != DBNull.Value
                            ? row["message"].ToString()! : (success > 0 ? "Status updated." : "Error.");
            return (success, msg);
        }

        // ── Register enquiry ─────────────────────────────────────
        public async Task<(int Success, string Message, string? RegistrationNumber)> RegisterEnquiryAsync(
            int enquiryId, string? registrationNumber, DateOnly? registrationDate,
            bool registrationFeePaid, bool autoGenerate, string? prefix,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0)
                return (0, "Invalid request.", null);

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",             NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",             NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",        NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",            NpgsqlDbType.Integer) { Value = enquiryId },
                new("p_registration_number",   NpgsqlDbType.Text)    { Value = (object?)registrationNumber ?? DBNull.Value },
                new("p_registration_date",     NpgsqlDbType.Date)    { Value = (object?)registrationDate   ?? DBNull.Value },
                new("p_registration_fee_paid", NpgsqlDbType.Boolean) { Value = registrationFeePaid },
                new("p_auto_generate",         NpgsqlDbType.Boolean) { Value = autoGenerate },
                new("p_prefix",                NpgsqlDbType.Text)    { Value = (object?)prefix ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "register_enquiry_cursor" }
            };

            try
            {
                using var dal = new PostgreSqlDal(_connectionString);
                var ds = await dal.ExecuteProcedureWithCursorsAsync("core.sp_enquiry_register", parameters);

                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return (0, "No response.", null);

                var row     = ds.Tables[0].Rows[0];
                int success = row["success"] != DBNull.Value && Convert.ToBoolean(row["success"]) ? 1 : 0;
                string msg  = row.Table.Columns.Contains("message") && row["message"] != DBNull.Value
                                ? row["message"].ToString()! : (success > 0 ? "Registration completed." : "Error.");
                string? regNo = row.Table.Columns.Contains("registration_number") && row["registration_number"] != DBNull.Value
                                ? row["registration_number"].ToString() : null;
                return (success, msg, regNo);
            }
            catch (PostgresException pex)
            {
                // Surface the proc's RAISE EXCEPTION message (e.g. "already admitted").
                return (0, pex.MessageText, null);
            }
            catch
            {
                return (0, "Unable to complete registration.", null);
            }
        }

        // ── Log follow-up ────────────────────────────────────────
        public async Task<int> LogFollowupAsync(
            int      enquiryId,
            string   followupType,
            string?  outcome,
            string?  notes,
            DateOnly? nextFollowupDate,
            string?  newStatus,
            string?  lostReason,
            int      tenantId,
            int      schoolId,
            int      actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0) return 0;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",           NpgsqlDbType.Text)    { Value = "LogFollowup" },
                new("p_tenant_id",           NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",           NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",      NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",          NpgsqlDbType.Integer) { Value = enquiryId },
                new("p_followup_type",       NpgsqlDbType.Text)    { Value = followupType },
                new("p_outcome",             NpgsqlDbType.Text)    { Value = (object?)outcome          ?? DBNull.Value },
                new("p_notes",               NpgsqlDbType.Text)    { Value = (object?)notes            ?? DBNull.Value },
                new("p_next_followup_date",  NpgsqlDbType.Date)    { Value = (object?)nextFollowupDate ?? DBNull.Value },
                new("p_new_status",          NpgsqlDbType.Text)    { Value = (object?)newStatus        ?? DBNull.Value },
                new("p_lost_reason",         NpgsqlDbType.Text)    { Value = (object?)lostReason       ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "log_followup_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFollowup, parameters);

            return ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0 ? 1 : 0;
        }

        // ── Follow-up history ────────────────────────────────────
        public async Task<List<EnquiryFollowupModel>> GetFollowupsAsync(
            int enquiryId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<EnquiryFollowupModel>();
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0) return list;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "GetFollowups" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = enquiryId },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "get_followups_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFollowup, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                list.Add(new EnquiryFollowupModel
                {
                    FollowupId = IntVal(row, "followup_id"),
                    EnquiryId  = enquiryId,
                    FollowupDate = row["followup_date"] == DBNull.Value ? DateTime.UtcNow : Convert.ToDateTime(row["followup_date"]),
                    FollowupType = row["followup_type"] == DBNull.Value ? "Call": row["followup_type"].ToString()!,
                    Outcome=row["outcome"]== DBNull.Value ? null: row["outcome"].ToString(),
                    Notes  = row["notes"]               == DBNull.Value ? null                  : row["notes"].ToString(),
                    NextFollowupDate  = row["next_followup_date"]  == DBNull.Value ? null                  : DateOnly.FromDateTime(Convert.ToDateTime(row["next_followup_date"])),
                    StatusBefore      = row["status_before"]       == DBNull.Value ? null                  : row["status_before"].ToString(),
                    StatusAfter       = row["status_after"]        == DBNull.Value ? null                  : row["status_after"].ToString(),
                    CreatedBy         = IntVal(row, "created_by"),
                    CreatedAt         = row["created_at"]          == DBNull.Value ? DateTime.UtcNow       : Convert.ToDateTime(row["created_at"])
                });
            }
            return list;
        }

        // ── Status history ───────────────────────────────────────
        public async Task<List<EnquiryStatusHistoryModel>> GetStatusHistoryAsync(
            int enquiryId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<EnquiryStatusHistoryModel>();
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0) return list;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "GetStatusHistory" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = enquiryId },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "status_history_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFollowup, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                list.Add(new EnquiryStatusHistoryModel
                {
                    HistoryId  = IntVal(row, "history_id"),
                    EnquiryId  = enquiryId,
                    StatusFrom = row["status_from"]  == DBNull.Value ? null             : row["status_from"].ToString(),
                    StatusTo   = row["status_to"]    == DBNull.Value ? string.Empty     : row["status_to"].ToString()!,
                    ChangeNote = row["change_note"]  == DBNull.Value ? null             : row["change_note"].ToString(),
                    ChangedBy  = IntVal(row, "changed_by"),
                    CreatedAt  = row["created_at"]   == DBNull.Value ? DateTime.UtcNow  : Convert.ToDateTime(row["created_at"])
                });
            }
            return list;
        }

        // ── Delete ───────────────────────────────────────────────
        public async Task<int> DeleteEnquiryAsync(
            int enquiryId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0) return 0;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "DeleteEnquiry" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = enquiryId },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "delete_enquiry_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);
            return ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0 ? 1 : 0;
        }

        // ── Private mappers ──────────────────────────────────────
        private static EnquiryListModel MapListRow(DataRow row, int tenantId, int schoolId)
        {
            var m = new EnquiryListModel();
            FillBaseFields(m, row, tenantId, schoolId);
            m.IsOverdue        = BoolVal(row, "is_overdue");
            m.IsToday          = BoolVal(row, "is_today");
            m.DaysSinceEnquiry = Has(row, "days_since_enquiry") ? IntVal(row, "days_since_enquiry") : 0;
            m.FollowupCount    = Has(row, "followup_count")     ? IntVal(row, "followup_count")     : 0;
            return m;
        }

        private static EnquiryModel MapBaseRow(DataRow row, int tenantId, int schoolId)
        {
            var m = new EnquiryModel();
            FillBaseFields(m, row, tenantId, schoolId);
            return m;
        }

        private static void FillBaseFields(EnquiryModel m, DataRow row, int tenantId, int schoolId)
        {
            m.EnquiryId             = IntVal(row, "enquiry_id");
            m.TenantId              = tenantId;
            m.SchoolId              = schoolId;
            m.StudentName           = Str(row, "student_name");
            m.Gender                = NullStr(row, "gender");
            //m.Dob                   = Has(row,"dob") && row["dob"] != DBNull.Value
            //                            ? DateOnly.FromDateTime(Convert.ToDateTime(row["dob"])) : null;
            m.ClassName             = Str(row, "class_name");
            m.Session               = Str(row, "session");
            m.InterestedStream      = NullStr(row, "interested_stream");
            m.ParentName            = NullStr(row, Has(row,"parent_name") ? "parent_name" : "derived_parent_name");
            m.FatherName            = NullStr(row, "father_name");
            m.FatherMobile          = NullStr(row, "father_mobile");
            m.MotherName            = NullStr(row, "mother_name");
            m.MotherMobile          = NullStr(row, "mother_mobile");
            m.Mobile                = Str(row, "mobile");
            m.AltMobile             = NullStr(row, "alt_mobile");
            m.City                  = NullStr(row, "city");
            m.AreaLocality          = NullStr(row, "area_locality");
            m.LeadSource            = Has(row,"lead_source") && row["lead_source"] != DBNull.Value
                                        ? row["lead_source"].ToString()! : "Walk-in";
            m.ReferrerName          = NullStr(row, "referrer_name");
            m.Priority              = Has(row,"priority") && row["priority"] != DBNull.Value
                                        ? row["priority"].ToString()! : "Warm";
            m.Status                = Has(row,"status") && row["status"] != DBNull.Value
                                        ? row["status"].ToString()! : "New";
            m.AssignedToId          = Has(row,"assigned_to_id") && row["assigned_to_id"] != DBNull.Value
                                        ? Convert.ToInt32(row["assigned_to_id"]) : null;
            m.LostReason            = NullStr(row, "lost_reason");
            m.EnquiryDate = Has(row, "enquiry_date") && row["enquiry_date"] != DBNull.Value
     ? (DateOnly)row["enquiry_date"]
     : DateOnly.FromDateTime(DateTime.Today);
            m.NextFollowupDate = Has(row, "next_followup_date") && row["next_followup_date"] != DBNull.Value
     ? (DateOnly?)row["next_followup_date"]
     : null;
            m.Notes                 = NullStr(row, "notes");
            m.EstimatedFee          = Has(row,"estimated_fee") && row["estimated_fee"] != DBNull.Value
                                        ? Convert.ToDecimal(row["estimated_fee"]) : null;
            m.RegistrationNumber    = NullStr(row, "registration_number");
            m.RegistrationFeePaid   = BoolVal(row, "registration_fee_paid");
            m.ParentEmail           = NullStr(row, "parent_email");
            m.CurrentClass          = NullStr(row, "current_class");
            m.CurrentSchool         = NullStr(row, "current_school");
            m.TransportRequired     = BoolVal(row, "transport_required");
            m.WhatsAppNumber        = NullStr(row, "whatsapp_number");
            m.AdmissionId           = Has(row,"admission_id") && row["admission_id"] != DBNull.Value
                                        ? Convert.ToInt32(row["admission_id"]) : null;
            m.CreatedAt             = Has(row,"created_at") && row["created_at"] != DBNull.Value
                                        ? Convert.ToDateTime(row["created_at"]) : DateTime.UtcNow;
            m.UpdatedAt             = Has(row,"updated_at") && row["updated_at"] != DBNull.Value
                                        ? Convert.ToDateTime(row["updated_at"]) : DateTime.UtcNow;
        }

        // ── Tiny helpers ─────────────────────────────────────────
        private static bool    Has(DataRow r, string col)      => r.Table.Columns.Contains(col);
        private static int     IntVal(DataRow r, string col)   => Has(r,col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col])   : 0;
        private static bool    BoolVal(DataRow r, string col)  => Has(r,col) && r[col] != DBNull.Value && Convert.ToBoolean(r[col]);
        private static string  Str(DataRow r, string col)      => Has(r,col) && r[col] != DBNull.Value ? r[col].ToString()!        : string.Empty;
        private static string? NullStr(DataRow r, string col)  => Has(r,col) && r[col] != DBNull.Value ? r[col].ToString()         : null;
    }
}
