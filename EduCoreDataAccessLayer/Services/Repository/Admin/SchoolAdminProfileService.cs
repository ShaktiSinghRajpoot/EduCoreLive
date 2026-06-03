using educore.Models;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Configuration;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    public class SchoolAdminProfileService : ISchoolAdminProfileService
    {
        private readonly string _connectionString;

        private const string SpBasicProfileManage = "core.sp_school_admin_basic_profile_manage";
        private const string SpSchoolDropdowns = "config.sp_school_dropdowns";

        public SchoolAdminProfileService(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
        }

        public async Task<SchoolManageModel?> GetBasicProfileAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return null;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "GetBasicProfile"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_display_name", DBNull.Value),
                new NpgsqlParameter("p_registration_number", DBNull.Value),
                new NpgsqlParameter("p_affiliation_number", DBNull.Value),
                new NpgsqlParameter("p_board_id", DBNull.Value),
                new NpgsqlParameter("p_school_type_id", DBNull.Value),
                new NpgsqlParameter("p_ownership_type_id", DBNull.Value),
                new NpgsqlParameter("p_medium_id", DBNull.Value),
                new NpgsqlParameter("p_established_year", DBNull.Value),
                new NpgsqlParameter("p_website", DBNull.Value),
                new NpgsqlParameter("p_logo_url", DBNull.Value),
                new NpgsqlParameter("p_header_image_url", DBNull.Value),
                new NpgsqlParameter("p_address_type_id", DBNull.Value),
                new NpgsqlParameter("p_address_line1", DBNull.Value),
                new NpgsqlParameter("p_address_line2", DBNull.Value),
                new NpgsqlParameter("p_city", DBNull.Value),
                new NpgsqlParameter("p_district", DBNull.Value),
                new NpgsqlParameter("p_state", DBNull.Value),
                new NpgsqlParameter("p_pincode", DBNull.Value),
                new NpgsqlParameter("p_contact_type_id", DBNull.Value),
                new NpgsqlParameter("p_contact_name", DBNull.Value),
                new NpgsqlParameter("p_designation", DBNull.Value),
                new NpgsqlParameter("p_contact_email", DBNull.Value),
                new NpgsqlParameter("p_phone", DBNull.Value),
                new NpgsqlParameter("p_alternate_phone", DBNull.Value),
                new NpgsqlParameter("p_academic_year_id", DBNull.Value),
                new NpgsqlParameter("p_date_format_id", DBNull.Value),
                new NpgsqlParameter("p_time_format_id", DBNull.Value),
                new NpgsqlParameter("p_enable_sms", DBNull.Value),
                new NpgsqlParameter("p_enable_email", DBNull.Value),
                new NpgsqlParameter("p_enable_whatsapp", DBNull.Value),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "basic_profile_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpBasicProfileManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            var row = ds.Tables[0].Rows[0];
            var model = new SchoolManageModel();

            model.Operation = "UpdateBasicProfile";
            model.TenantId = row["tenant_id"] == DBNull.Value ? tenantId : Convert.ToInt32(row["tenant_id"]);
            model.TenantName = row["tenant_name"] == DBNull.Value ? null : row["tenant_name"].ToString();
            model.SchoolId = row["school_id"] == DBNull.Value ? schoolId : Convert.ToInt32(row["school_id"]);
            model.SchoolCode = row["school_code"] == DBNull.Value ? null : row["school_code"].ToString();
            model.SchoolName = row["school_name"] == DBNull.Value ? string.Empty : row["school_name"].ToString() ?? string.Empty;
            model.DisplayName = row["display_name"] == DBNull.Value ? null : row["display_name"].ToString();
            model.StatusId = row["status_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["status_id"]);
            model.RegistrationNumber = row["registration_number"] == DBNull.Value ? null : row["registration_number"].ToString();
            model.AffiliationNumber = row["affiliation_number"] == DBNull.Value ? null : row["affiliation_number"].ToString();
            model.BoardId = row["board_id"] == DBNull.Value ? null : Convert.ToInt32(row["board_id"]);
            model.BoardName = row["board_name"] == DBNull.Value ? null : row["board_name"].ToString();
            model.SchoolTypeId = row["school_type_id"] == DBNull.Value ? null : Convert.ToInt32(row["school_type_id"]);
            model.SchoolTypeName = row["school_type_name"] == DBNull.Value ? null : row["school_type_name"].ToString();
            model.OwnershipTypeId = row["ownership_type_id"] == DBNull.Value ? null : Convert.ToInt32(row["ownership_type_id"]);
            model.MediumId = row["medium_id"] == DBNull.Value ? null : Convert.ToInt32(row["medium_id"]);
            model.EstablishedYear = row["established_year"] == DBNull.Value ? null : Convert.ToInt32(row["established_year"]);
            model.Website = row["website"] == DBNull.Value ? null : row["website"].ToString();
            model.LogoUrl = row["logo_url"] == DBNull.Value ? null : row["logo_url"].ToString();
            model.HeaderImageUrl = row["header_image_url"] == DBNull.Value ? null : row["header_image_url"].ToString();
            model.AddressTypeId = row["address_type_id"] == DBNull.Value ? 1 : Convert.ToInt32(row["address_type_id"]);
            model.AddressLine1 = row["address_line1"] == DBNull.Value ? string.Empty : row["address_line1"].ToString() ?? string.Empty;
            model.AddressLine2 = row["address_line2"] == DBNull.Value ? null : row["address_line2"].ToString();
            model.City = row["city"] == DBNull.Value ? string.Empty : row["city"].ToString() ?? string.Empty;
            model.District = row["district"] == DBNull.Value ? null : row["district"].ToString();
            model.State = row["state"] == DBNull.Value ? string.Empty : row["state"].ToString() ?? string.Empty;
            model.Pincode = row["pincode"] == DBNull.Value ? string.Empty : row["pincode"].ToString() ?? string.Empty;
            model.ContactTypeId = row["contact_type_id"] == DBNull.Value ? 1 : Convert.ToInt32(row["contact_type_id"]);
            model.ContactName = row["contact_name"] == DBNull.Value ? string.Empty : row["contact_name"].ToString() ?? string.Empty;
            model.Designation = row["designation"] == DBNull.Value ? null : row["designation"].ToString();
            model.ContactEmail = row["email"] == DBNull.Value ? null : row["email"].ToString();
            model.Phone = row["phone"] == DBNull.Value ? string.Empty : row["phone"].ToString() ?? string.Empty;
            model.AlternatePhone = row["alternate_phone"] == DBNull.Value ? null : row["alternate_phone"].ToString();
            model.AcademicYearId = row["academic_year_id"] == DBNull.Value ? null : Convert.ToInt32(row["academic_year_id"]);
            model.DateFormatId = row["date_format_id"] == DBNull.Value ? null : Convert.ToInt32(row["date_format_id"]);
            model.TimeFormatId = row["time_format_id"] == DBNull.Value ? null : Convert.ToInt32(row["time_format_id"]);
            model.EnableSms = row["enable_sms"] != DBNull.Value && Convert.ToBoolean(row["enable_sms"]);
            model.EnableEmail = row["enable_email"] != DBNull.Value && Convert.ToBoolean(row["enable_email"]);
            model.EnableWhatsapp = row["enable_whatsapp"] != DBNull.Value && Convert.ToBoolean(row["enable_whatsapp"]);
            model.CreateSchoolAdmin = false;
            model.AutoGeneratePassword = true;

            return model;
        }

        public async Task<int> SaveBasicProfileAsync(SchoolManageModel model, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return 0;

            model.Operation = "UpdateBasicProfile";
            model.TenantId = tenantId;
            model.SchoolId = schoolId;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "UpdateBasicProfile"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_display_name", (object?)model.DisplayName ?? DBNull.Value),
                new NpgsqlParameter("p_registration_number", (object?)model.RegistrationNumber ?? DBNull.Value),
                new NpgsqlParameter("p_affiliation_number", (object?)model.AffiliationNumber ?? DBNull.Value),
                new NpgsqlParameter("p_board_id", (object?)model.BoardId ?? DBNull.Value),
                new NpgsqlParameter("p_school_type_id", (object?)model.SchoolTypeId ?? DBNull.Value),
                new NpgsqlParameter("p_ownership_type_id", (object?)model.OwnershipTypeId ?? DBNull.Value),
                new NpgsqlParameter("p_medium_id", (object?)model.MediumId ?? DBNull.Value),
                new NpgsqlParameter("p_established_year", (object?)model.EstablishedYear ?? DBNull.Value),
                new NpgsqlParameter("p_website", (object?)model.Website ?? DBNull.Value),
                new NpgsqlParameter("p_logo_url", (object?)model.LogoUrl ?? DBNull.Value),
                new NpgsqlParameter("p_header_image_url", (object?)model.HeaderImageUrl ?? DBNull.Value),
                new NpgsqlParameter("p_address_type_id", model.AddressTypeId),
                new NpgsqlParameter("p_address_line1", (object?)model.AddressLine1 ?? DBNull.Value),
                new NpgsqlParameter("p_address_line2", (object?)model.AddressLine2 ?? DBNull.Value),
                new NpgsqlParameter("p_city", (object?)model.City ?? DBNull.Value),
                new NpgsqlParameter("p_district", (object?)model.District ?? DBNull.Value),
                new NpgsqlParameter("p_state", (object?)model.State ?? DBNull.Value),
                new NpgsqlParameter("p_pincode", (object?)model.Pincode ?? DBNull.Value),
                new NpgsqlParameter("p_contact_type_id", model.ContactTypeId),
                new NpgsqlParameter("p_contact_name", (object?)model.ContactName ?? DBNull.Value),
                new NpgsqlParameter("p_designation", (object?)model.Designation ?? DBNull.Value),
                new NpgsqlParameter("p_contact_email", (object?)model.ContactEmail ?? DBNull.Value),
                new NpgsqlParameter("p_phone", (object?)model.Phone ?? DBNull.Value),
                new NpgsqlParameter("p_alternate_phone", (object?)model.AlternatePhone ?? DBNull.Value),
                new NpgsqlParameter("p_academic_year_id", (object?)model.AcademicYearId ?? DBNull.Value),
                new NpgsqlParameter("p_date_format_id", (object?)model.DateFormatId ?? DBNull.Value),
                new NpgsqlParameter("p_time_format_id", (object?)model.TimeFormatId ?? DBNull.Value),
                new NpgsqlParameter("p_enable_sms", model.EnableSms),
                new NpgsqlParameter("p_enable_email", model.EnableEmail),
                new NpgsqlParameter("p_enable_whatsapp", model.EnableWhatsapp),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "basic_profile_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpBasicProfileManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return 0;

            var row = ds.Tables[0].Rows[0];
            return row["school_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["school_id"]);
        }

        public async Task<SchoolDropdownModel> GetBasicProfileDropdownsAsync(int tenantId, int schoolId)
        {
            if (tenantId <= 1 || schoolId <= 0) return new SchoolDropdownModel();

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
            var dropdowns = new SchoolDropdownModel();

            if (ds.Tables.Count > 0) foreach (DataRow row in ds.Tables[0].Rows) dropdowns.Tenants.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 1) foreach (DataRow row in ds.Tables[1].Rows) dropdowns.Statuses.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 2) foreach (DataRow row in ds.Tables[2].Rows) dropdowns.Boards.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 3) foreach (DataRow row in ds.Tables[3].Rows) dropdowns.SchoolTypes.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 4) foreach (DataRow row in ds.Tables[4].Rows) dropdowns.OwnershipTypes.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 5) foreach (DataRow row in ds.Tables[5].Rows) dropdowns.Mediums.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 6) foreach (DataRow row in ds.Tables[6].Rows) dropdowns.AddressTypes.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 7) foreach (DataRow row in ds.Tables[7].Rows) dropdowns.ContactTypes.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 8) foreach (DataRow row in ds.Tables[8].Rows) dropdowns.AcademicYears.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 9) foreach (DataRow row in ds.Tables[9].Rows) dropdowns.DateFormats.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });
            if (ds.Tables.Count > 10) foreach (DataRow row in ds.Tables[10].Rows) dropdowns.TimeFormats.Add(new DropdownItem { Id = row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]), Name = row["name"] == DBNull.Value ? string.Empty : row["name"].ToString() ?? string.Empty });

            return dropdowns;
        }
    }
}
