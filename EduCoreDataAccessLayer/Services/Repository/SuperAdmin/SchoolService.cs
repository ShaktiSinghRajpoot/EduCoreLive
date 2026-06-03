using educore.Models;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract.SuperAdmin;
using Microsoft.Extensions.Configuration;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services.Repository.SuperAdmin
{
    public class SchoolService : ISchoolService
    {
        private readonly string _connectionString;

        private const string SpSchoolManage = "core.sp_school_manage";
        private const string SpSchoolDropdowns = "config.sp_school_dropdowns";

        public SchoolService(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
        }

        public async Task<List<SchoolListModel>> GetSchoolsAsync(int tenantId, int actionUserId)
        {
            var schools = new List<SchoolListModel>();

            var parameters = BuildSchoolParameters("L", tenantId, actionUserId);

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpSchoolManage, parameters);

            if (ds.Tables.Count == 0)
                return schools;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                schools.Add(new SchoolListModel
                {
                    SchoolId = ToInt(row["school_id"], 0),
                    //TenantId = ToInt(row["tenant_id"], 0),
                    TenantName = row["tenant_name"]?.ToString(),
                    TenantCode = row["tenant_name"]?.ToString(),
                    SchoolCode = row["school_code"]?.ToString(),
                    SchoolName = row["school_name"]?.ToString(),
                    DisplayName = row["display_name"]?.ToString(),
                    StatusName = row["status_name"]?.ToString(),
                    BoardName = row["board_name"]?.ToString(),
                    SchoolTypeName = row["school_type_name"]?.ToString(),
                    City = row["city"]?.ToString(),
                    State = row["state"]?.ToString(),
                    ContactName = row["contact_name"]?.ToString(),
                    Phone = row["phone"]?.ToString(),
                    CreatedAt = ToDateTime(row["created_at"])
                });
            }

            return schools;
        }

        public async Task<int> CreateSchoolAsync(SchoolManageModel model, int tenantId, int actionUserId)
        {
            model.Operation = "I";

            var parameters = BuildSchoolParameters("I", tenantId, actionUserId, model);

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpSchoolManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return 0;

            return ToInt(ds.Tables[0].Rows[0]["school_id"], 0);
        }

        public async Task<int> SaveSchoolAsync(SchoolManageModel model, int tenantId, int actionUserId)
        {
            var operation = string.IsNullOrWhiteSpace(model.Operation) ? "I" : model.Operation;

            var parameters = BuildSchoolParameters(operation, tenantId, actionUserId, model);

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpSchoolManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return 0;

            return ToInt(ds.Tables[0].Rows[0]["school_id"], 0);
        }

        public async Task<SchoolManageModel?> GetSchoolByIdAsync(int schoolId, int tenantId, int actionUserId)
        {
            var model = new SchoolManageModel
            {
                SchoolId = schoolId,
                Operation = "G"
            };

            var parameters = BuildSchoolParameters("G", tenantId, actionUserId, model);

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpSchoolManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return null;

            var row = ds.Tables[0].Rows[0];

            return new SchoolManageModel
            {
                Operation = "U",

                TenantMode = "existing",
                TenantId = HasColumn(row, "tenant_id") ? ToInt(row["tenant_id"], tenantId) : tenantId,

                SchoolId = ToInt(row["school_id"], 0),
                SchoolName = row["school_name"]?.ToString(),
                DisplayName = row["display_name"]?.ToString(),
                StatusId = ToInt(row["status_id"], 0),

                RegistrationNumber = row["registration_number"]?.ToString(),
                AffiliationNumber = row["affiliation_number"]?.ToString(),
                BoardId = ToNullableInt(row["board_id"]),
                SchoolTypeId = ToNullableInt(row["school_type_id"]),
                OwnershipTypeId = ToNullableInt(row["ownership_type_id"]),
                MediumId = ToNullableInt(row["medium_id"]),
                EstablishedYear = ToNullableInt(row["established_year"]),
                Website = row["website"]?.ToString(),

                AddressTypeId = ToInt(row["address_type_id"], 1),
                AddressLine1 = row["address_line1"]?.ToString(),
                AddressLine2 = HasColumn(row, "address_line2") ? row["address_line2"]?.ToString() : null,
                City = row["city"]?.ToString(),
                District = row["district"]?.ToString(),
                State = row["state"]?.ToString(),
                Pincode = row["pincode"]?.ToString(),

                ContactTypeId = ToInt(row["contact_type_id"], 1),
                ContactName = row["contact_name"]?.ToString(),
                Designation = row["designation"]?.ToString(),
                ContactEmail = row["email"]?.ToString(),
                Phone = row["phone"]?.ToString(),
                AlternatePhone = row["alternate_phone"]?.ToString(),

                AcademicYearId = ToNullableInt(row["academic_year_id"]),
                DateFormatId = ToNullableInt(row["date_format_id"]),
                TimeFormatId = ToNullableInt(row["time_format_id"]),

                EnableSms = ToBool(row["enable_sms"]),
                EnableEmail = ToBool(row["enable_email"]),
                EnableWhatsapp = ToBool(row["enable_whatsapp"]),

                CreateSchoolAdmin = false,
                AutoGeneratePassword = true
            };
        }

        public async Task DeleteSchoolAsync(int schoolId, int tenantId, int actionUserId)
        {
            var model = new SchoolManageModel
            {
                SchoolId = schoolId,
                Operation = "D"
            };

            var parameters = BuildSchoolParameters("D", tenantId, actionUserId, model);

            using var dal = new PostgreSqlDal(_connectionString);
            await dal.ExecuteProcedureWithCursorsAsync(SpSchoolManage, parameters);
        }

        public async Task<SchoolDropdownModel> GetSchoolDropdownsAsync()
        {
            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_tenants", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_tenants" },
                new NpgsqlParameter("p_statuses", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_statuses" },
                new NpgsqlParameter("p_boards", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_boards" },
                new NpgsqlParameter("p_school_types", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_school_types" },
                new NpgsqlParameter("p_ownership_types", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_ownership_types" },
                new NpgsqlParameter("p_mediums", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_mediums" },
                new NpgsqlParameter("p_address_types", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_address_types" },
                new NpgsqlParameter("p_contact_types", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_contact_types" },
                new NpgsqlParameter("p_academic_years", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_academic_years" },
                new NpgsqlParameter("p_date_formats", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_date_formats" },
                new NpgsqlParameter("p_time_formats", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "cur_time_formats" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpSchoolDropdowns, parameters);

            return new SchoolDropdownModel
            {
                Tenants = ToDropdownList(ds, 0),
                Statuses = ToDropdownList(ds, 1),
                Boards = ToDropdownList(ds, 2),
                SchoolTypes = ToDropdownList(ds, 3),
                OwnershipTypes = ToDropdownList(ds, 4),
                Mediums = ToDropdownList(ds, 5),
                AddressTypes = ToDropdownList(ds, 6),
                ContactTypes = ToDropdownList(ds, 7),
                AcademicYears = ToDropdownList(ds, 8),
                DateFormats = ToDropdownList(ds, 9),
                TimeFormats = ToDropdownList(ds, 10)
            };
        }

        private static NpgsqlParameter[] BuildSchoolParameters(
            string operation,
            int tenantId,
            int actionUserId,
            SchoolManageModel? model = null)
        {
            return new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", operation),

                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_action_user_id", actionUserId),

                new NpgsqlParameter("p_tenant_mode", (object?)model?.TenantMode ?? DBNull.Value),
                new NpgsqlParameter("p_selected_tenant_id", (object?)model?.TenantId ?? DBNull.Value),
                new NpgsqlParameter("p_tenant_name", (object?)model?.TenantName ?? DBNull.Value),
                new NpgsqlParameter("p_tenant_code", (object?)model?.TenantCode ?? DBNull.Value),
                new NpgsqlParameter("p_tenant_email", (object?)model?.TenantEmail ?? DBNull.Value),
                new NpgsqlParameter("p_tenant_phone", (object?)model?.TenantPhone ?? DBNull.Value),

                new NpgsqlParameter("p_school_id", (object?)model?.SchoolId ?? DBNull.Value),
                new NpgsqlParameter("p_school_name", (object?)model?.SchoolName ?? DBNull.Value),
                new NpgsqlParameter("p_display_name", (object?)model?.DisplayName ?? DBNull.Value),
                new NpgsqlParameter("p_status_id", (object?)model?.StatusId ?? DBNull.Value),

                new NpgsqlParameter("p_registration_number", (object?)model?.RegistrationNumber ?? DBNull.Value),
                new NpgsqlParameter("p_affiliation_number", (object?)model?.AffiliationNumber ?? DBNull.Value),
                new NpgsqlParameter("p_board_id", (object?)model?.BoardId ?? DBNull.Value),
                new NpgsqlParameter("p_school_type_id", (object?)model?.SchoolTypeId ?? DBNull.Value),
                new NpgsqlParameter("p_ownership_type_id", (object?)model?.OwnershipTypeId ?? DBNull.Value),
                new NpgsqlParameter("p_medium_id", (object?)model?.MediumId ?? DBNull.Value),
                new NpgsqlParameter("p_established_year", (object?)model?.EstablishedYear ?? DBNull.Value),
                new NpgsqlParameter("p_website", (object?)model?.Website ?? DBNull.Value),

                new NpgsqlParameter("p_address_type_id", (object?)model?.AddressTypeId ?? DBNull.Value),
                new NpgsqlParameter("p_address_line1", (object?)model?.AddressLine1 ?? DBNull.Value),
                new NpgsqlParameter("p_address_line2", (object?)model?.AddressLine2 ?? DBNull.Value),
                new NpgsqlParameter("p_city", (object?)model?.City ?? DBNull.Value),
                new NpgsqlParameter("p_district", (object?)model?.District ?? DBNull.Value),
                new NpgsqlParameter("p_state", (object?)model?.State ?? DBNull.Value),
                new NpgsqlParameter("p_pincode", (object?)model?.Pincode ?? DBNull.Value),

                new NpgsqlParameter("p_contact_type_id", (object?)model?.ContactTypeId ?? DBNull.Value),
                new NpgsqlParameter("p_contact_name", (object?)model?.ContactName ?? DBNull.Value),
                new NpgsqlParameter("p_designation", (object?)model?.Designation ?? DBNull.Value),
                new NpgsqlParameter("p_contact_email", (object?)model?.ContactEmail ?? DBNull.Value),
                new NpgsqlParameter("p_phone", (object?)model?.Phone ?? DBNull.Value),
                new NpgsqlParameter("p_alternate_phone", (object?)model?.AlternatePhone ?? DBNull.Value),

                new NpgsqlParameter("p_academic_year_id", (object?)model?.AcademicYearId ?? DBNull.Value),
                new NpgsqlParameter("p_date_format_id", (object?)model?.DateFormatId ?? DBNull.Value),
                new NpgsqlParameter("p_time_format_id", (object?)model?.TimeFormatId ?? DBNull.Value),
                new NpgsqlParameter("p_enable_sms", (object?)model?.EnableSms ?? DBNull.Value),
                new NpgsqlParameter("p_enable_email", (object?)model?.EnableEmail ?? DBNull.Value),
                new NpgsqlParameter("p_enable_whatsapp", (object?)model?.EnableWhatsapp ?? DBNull.Value),

                new NpgsqlParameter("p_create_school_admin", (object?)model?.CreateSchoolAdmin ?? DBNull.Value),
                new NpgsqlParameter("p_admin_full_name", (object?)model?.AdminFullName ?? DBNull.Value),
                new NpgsqlParameter("p_admin_email", (object?)model?.AdminEmail ?? DBNull.Value),
                new NpgsqlParameter("p_admin_phone", (object?)model?.AdminPhone ?? DBNull.Value),
                new NpgsqlParameter("p_password_hash", (object?)model?.Password ?? DBNull.Value),

                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "school_cursor" }
            };
        }

        private static List<DropdownItem> ToDropdownList(DataSet ds, int tableIndex)
        {
            var list = new List<DropdownItem>();

            if (ds.Tables.Count <= tableIndex)
                return list;

            foreach (DataRow row in ds.Tables[tableIndex].Rows)
            {
                list.Add(new DropdownItem
                {
                    Id = ToInt(row["id"], 0),
                    Name = row["name"]?.ToString() ?? string.Empty
                });
            }

            return list;
        }

        private static bool HasColumn(DataRow row, string columnName)
        {
            return row.Table.Columns.Contains(columnName);
        }

        private static int? ToNullableInt(object value)
        {
            return value == DBNull.Value || value == null ? null : Convert.ToInt32(value);
        }

        private static int ToInt(object value, int defaultValue)
        {
            return value == DBNull.Value || value == null ? defaultValue : Convert.ToInt32(value);
        }

        private static DateTime ToDateTime(object value)
        {
            return value == DBNull.Value || value == null ? DateTime.MinValue : Convert.ToDateTime(value);
        }

        private static bool ToBool(object value)
        {
            return value != DBNull.Value && value != null && Convert.ToBoolean(value);
        }
    }
}