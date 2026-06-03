using educore.Models;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Configuration;
using Npgsql;
using NpgsqlTypes;
using System.Data;
using System.Text.Json;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    public class SchoolSettingsService : ISchoolSettingsService
    {
        private readonly string _connectionString;
        private const string SpBasicProfileManage = "core.sp_school_admin_basic_profile_manage";
        private const string SpSchoolDropdowns = "config.sp_school_dropdowns";
        private const string SpAcademicSetupManage = "academic.sp_school_admin_academic_setup_manage";
        private const string SpFeeHeadManage = "core.sp_school_admin_fee_head_manage";
        private const string SpFeeStructureManage = "core.sp_school_admin_fee_structure_manage";

        public SchoolSettingsService(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
        }

        #region Basic Profile

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

        #endregion

        #region Academic Setup

        public async Task<AcademicSetupModel?> GetAcademicSetupAsync(int tenantId, int schoolId, int academicYearId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return null;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "GetAcademicSetup"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_academic_year_id", academicYearId),
                new NpgsqlParameter("p_academic_year_name", DBNull.Value),
                new NpgsqlParameter("p_setup_json", DBNull.Value),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpAcademicSetupManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return null;

            var model = new AcademicSetupModel();

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                if (model.AcademicYearId == 0)
                {
                    model.Operation = "SaveAcademicSetup";
                    model.TenantId = row["tenant_id"] == DBNull.Value ? tenantId : Convert.ToInt32(row["tenant_id"]);
                    model.SchoolId = row["school_id"] == DBNull.Value ? schoolId : Convert.ToInt32(row["school_id"]);
                    model.AcademicYearId = row["academic_year_id"] == DBNull.Value ? academicYearId : Convert.ToInt32(row["academic_year_id"]);
                    model.IsCurrent = row["is_current"] != DBNull.Value && Convert.ToBoolean(row["is_current"]);
                }

                if (row.Table.Columns.Contains("class_name") && row["class_name"] != DBNull.Value)
                {
                    var className = row["class_name"].ToString()?.Trim() ?? string.Empty;

                    if (!string.IsNullOrWhiteSpace(className))
                    {
                        if (!model.Classes.Any(x => x.Equals(className, StringComparison.OrdinalIgnoreCase)))
                            model.Classes.Add(className);

                        if (!model.ClassSections.ContainsKey(className))
                            model.ClassSections[className] = new List<string>();

                        if (row.Table.Columns.Contains("section_name") && row["section_name"] != DBNull.Value)
                        {
                            var sectionName = row["section_name"].ToString()?.Trim() ?? string.Empty;

                            if (!string.IsNullOrWhiteSpace(sectionName)
                                && !model.ClassSections[className].Any(x => x.Equals(sectionName, StringComparison.OrdinalIgnoreCase)))
                            {
                                model.ClassSections[className].Add(sectionName);
                            }
                        }
                    }
                }
            }

            return model;
        }

        public async Task<int> SaveAcademicSetupAsync(
            AcademicSetupModel model,
            int tenantId,
            int schoolId,
            int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return 0;

            model.TenantId = tenantId;
            model.SchoolId = schoolId;

            var setupJson = BuildAcademicSetupJson(model);

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "SaveAcademicSetup"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_academic_year_id", model.AcademicYearId),
                new NpgsqlParameter("p_academic_year_name", (object?)model.AcademicYearName ?? DBNull.Value),
                new NpgsqlParameter("p_setup_json", NpgsqlDbType.Text) { Value = setupJson },
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "academic_setup_save_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpAcademicSetupManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return 0;

            var row = ds.Tables[0].Rows[0];

            return row["success"] != DBNull.Value && Convert.ToBoolean(row["success"]) ? 1 : 0;
        }

        private string BuildAcademicSetupJson(AcademicSetupModel model)
        {
            var classes = new List<AcademicClassJsonModel>();

            foreach (var className in model.Classes.Where(x => !string.IsNullOrWhiteSpace(x)))
            {
                var cleanClassName = className.Trim();

                var sections = new List<string>();

                if (model.ClassSections.ContainsKey(cleanClassName))
                {
                    sections = model.ClassSections[cleanClassName]
                        .Where(x => !string.IsNullOrWhiteSpace(x))
                        .Select(x => x.Trim())
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .ToList();
                }

                classes.Add(new AcademicClassJsonModel
                {
                    ClassName = cleanClassName,
                    Sections = sections
                });
            }

            return JsonSerializer.Serialize(classes);
        }

        #endregion

        #region Fee Head

        public async Task<List<FeeHead>> GetFeeHeadAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<FeeHead>();

            if (tenantId <= 1 || schoolId <= 0) return list;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "GetFeeHead"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fee_head_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeHeadManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                var model = new FeeHead();

                model.Operation = "SaveFeeHead";
                model.TenantId = row["tenant_id"] == DBNull.Value ? tenantId : Convert.ToInt32(row["tenant_id"]);
                model.SchoolId = row["school_id"] == DBNull.Value ? schoolId : Convert.ToInt32(row["school_id"]);
                model.FeeHeadId = row["fee_head_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["fee_head_id"]);
                model.FeeHeadName = row["fee_head_name"] == DBNull.Value ? string.Empty : row["fee_head_name"].ToString() ?? string.Empty;
                model.Frequency = row["frequency"] == DBNull.Value ? string.Empty : row["frequency"].ToString() ?? string.Empty;
                model.DefaultAmount = row["default_amount"] == DBNull.Value ? 0 : Convert.ToDecimal(row["default_amount"]);
                model.FeeType = row["fee_type"] == DBNull.Value ? string.Empty : row["fee_type"].ToString() ?? string.Empty;
                model.FeeGroup = row["fee_group"] == DBNull.Value ? "Academic" : row["fee_group"].ToString() ?? "Academic";
                model.DisplayOrder = row["display_order"] == DBNull.Value ? 0 : Convert.ToInt32(row["display_order"]);
                model.IsActive = row["is_active"] != DBNull.Value && Convert.ToBoolean(row["is_active"]);

                list.Add(model);
            }

            return list;
        }

        public async Task<FeeHead?> GetFeeHeadByIdAsync(int feeHeadId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return null;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "GetFeeHeadById"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_fee_head_id", feeHeadId),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fee_head_by_id_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeHeadManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return null;

            var row = ds.Tables[0].Rows[0];

            var model = new FeeHead();

            model.Operation = "SaveFeeHead";
            model.TenantId = row["tenant_id"] == DBNull.Value ? tenantId : Convert.ToInt32(row["tenant_id"]);
            model.SchoolId = row["school_id"] == DBNull.Value ? schoolId : Convert.ToInt32(row["school_id"]);
            model.FeeHeadId = row["fee_head_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["fee_head_id"]);
            model.FeeHeadName = row["fee_head_name"] == DBNull.Value ? string.Empty : row["fee_head_name"].ToString() ?? string.Empty;
            model.Frequency = row["frequency"] == DBNull.Value ? string.Empty : row["frequency"].ToString() ?? string.Empty;
            model.DefaultAmount = row["default_amount"] == DBNull.Value ? 0 : Convert.ToDecimal(row["default_amount"]);
            model.FeeType = row["fee_type"] == DBNull.Value ? string.Empty : row["fee_type"].ToString() ?? string.Empty;
            model.FeeGroup = row["fee_group"] == DBNull.Value ? "Academic" : row["fee_group"].ToString() ?? "Academic";
            model.DisplayOrder = row["display_order"] == DBNull.Value ? 0 : Convert.ToInt32(row["display_order"]);
            model.IsActive = row["is_active"] != DBNull.Value && Convert.ToBoolean(row["is_active"]);

            return model;
        }

        public async Task<int> SaveFeeHeadAsync(FeeHead model, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return 0;

            model.TenantId = tenantId;
            model.SchoolId = schoolId;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "SaveFeeHead"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_fee_head_id", model.FeeHeadId),
                new NpgsqlParameter("p_fee_head_name", model.FeeHeadName),
                new NpgsqlParameter("p_frequency", model.Frequency),
                new NpgsqlParameter("p_default_amount", model.DefaultAmount),
                new NpgsqlParameter("p_fee_type", model.FeeType),
                new NpgsqlParameter("p_fee_group", model.FeeGroup),
                new NpgsqlParameter("p_display_order", model.DisplayOrder),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "save_fee_head_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeHeadManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return 0;

            return 1;
        }

        public async Task<int> DeleteFeeHeadAsync(int feeHeadId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return 0;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "DeleteFeeHead"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_fee_head_id", feeHeadId),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "delete_fee_head_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeHeadManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return 0;

            return 1;
        }

        public async Task<int> ToggleFeeHeadStatusAsync(int feeHeadId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return 0;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "ToggleFeeHeadStatus"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_fee_head_id", feeHeadId),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "toggle_fee_head_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeHeadManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return 0;

            return 1;
        }

        #endregion

        #region Fee Structure

        public async Task<List<FeeStructureModel>> GetFeeStructureAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<FeeStructureModel>();

            if (tenantId <= 1 || schoolId <= 0) return list;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "GetFeeStructure"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fee_structure_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeStructureManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                var model = new FeeStructureModel();

                model.Operation = "SaveFeeStructure";
                model.TenantId = row["tenant_id"] == DBNull.Value ? tenantId : Convert.ToInt32(row["tenant_id"]);
                model.SchoolId = row["school_id"] == DBNull.Value ? schoolId : Convert.ToInt32(row["school_id"]);
                model.FeeStructureId = row["fee_structure_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["fee_structure_id"]);
                model.ClassName = row["class_name"] == DBNull.Value ? string.Empty : row["class_name"].ToString() ?? string.Empty;
                model.AcademicYear = row["academic_year"] == DBNull.Value ? string.Empty : row["academic_year"].ToString() ?? string.Empty;
                model.OneTimeTotal = row["one_time_total"] == DBNull.Value ? 0 : Convert.ToDecimal(row["one_time_total"]);
                model.MonthlyTotal = row["monthly_total"] == DBNull.Value ? 0 : Convert.ToDecimal(row["monthly_total"]);
                model.YearlyTotal = row["yearly_total"] == DBNull.Value ? 0 : Convert.ToDecimal(row["yearly_total"]);
                model.AnnualTotal = row["annual_total"] == DBNull.Value ? 0 : Convert.ToDecimal(row["annual_total"]);
                model.IsActive = row["is_active"] != DBNull.Value && Convert.ToBoolean(row["is_active"]);
                model.FeeHeadNames = row["fee_head_names"] == DBNull.Value ? string.Empty : row["fee_head_names"].ToString() ?? string.Empty;
                model.CreatedBy = row["created_by"] == DBNull.Value ? 0 : Convert.ToInt32(row["created_by"]);
                model.UpdatedBy = row["updated_by"] == DBNull.Value ? 0 : Convert.ToInt32(row["updated_by"]);
                model.UpdatedAt = row["updated_at"] == DBNull.Value ? null : Convert.ToDateTime(row["updated_at"]);

                list.Add(model);
            }

            return list;
        }

        public async Task<FeeStructureModel?> GetFeeStructureByClassAsync(string className, string academicYear, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return null;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "GetFeeStructureByClass"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_class_name", className),
                new NpgsqlParameter("p_academic_year", academicYear),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fee_structure_by_class_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeStructureManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return null;

            var row = ds.Tables[0].Rows[0];

            var model = new FeeStructureModel();

            model.Operation = "SaveFeeStructure";
            model.TenantId = row["tenant_id"] == DBNull.Value ? tenantId : Convert.ToInt32(row["tenant_id"]);
            model.SchoolId = row["school_id"] == DBNull.Value ? schoolId : Convert.ToInt32(row["school_id"]);
            model.FeeStructureId = row["fee_structure_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["fee_structure_id"]);
            model.ClassName = row["class_name"] == DBNull.Value ? string.Empty : row["class_name"].ToString() ?? string.Empty;
            model.AcademicYear = row["academic_year"] == DBNull.Value ? string.Empty : row["academic_year"].ToString() ?? string.Empty;
            model.OneTimeTotal = row["one_time_total"] == DBNull.Value ? 0 : Convert.ToDecimal(row["one_time_total"]);
            model.MonthlyTotal = row["monthly_total"] == DBNull.Value ? 0 : Convert.ToDecimal(row["monthly_total"]);
            model.YearlyTotal = row["yearly_total"] == DBNull.Value ? 0 : Convert.ToDecimal(row["yearly_total"]);
            model.AnnualTotal = row["annual_total"] == DBNull.Value ? 0 : Convert.ToDecimal(row["annual_total"]);
            model.IsActive = row["is_active"] != DBNull.Value && Convert.ToBoolean(row["is_active"]);

            model.FeeHeads = await GetFeeStructureDetailsAsync(className, academicYear, tenantId, schoolId, actionUserId);

            return model;
        }

        public async Task<List<FeeStructureDetailModel>> GetFeeStructureDetailsAsync(string className, string academicYear, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<FeeStructureDetailModel>();

            if (tenantId <= 1 || schoolId <= 0) return list;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "GetFeeStructureDetails"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_class_name", className),
                new NpgsqlParameter("p_academic_year", academicYear),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fee_structure_detail_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeStructureManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                var model = new FeeStructureDetailModel();

                model.TenantId = row["tenant_id"] == DBNull.Value ? tenantId : Convert.ToInt32(row["tenant_id"]);
                model.SchoolId = row["school_id"] == DBNull.Value ? schoolId : Convert.ToInt32(row["school_id"]);
                model.FeeStructureDetailId = row["fee_structure_detail_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["fee_structure_detail_id"]);
                model.FeeStructureId = row["fee_structure_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["fee_structure_id"]);
                model.FeeHeadId = row["fee_head_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["fee_head_id"]);
                model.FeeHeadName = row["fee_head_name"] == DBNull.Value ? string.Empty : row["fee_head_name"].ToString() ?? string.Empty;
                model.Frequency = row["frequency"] == DBNull.Value ? string.Empty : row["frequency"].ToString() ?? string.Empty;
                model.Amount = row["amount"] == DBNull.Value ? 0 : Convert.ToDecimal(row["amount"]);
                model.IsSelected = row["is_selected"] != DBNull.Value && Convert.ToBoolean(row["is_selected"]);

                list.Add(model);
            }

            return list;
        }

        public async Task<int> SaveFeeStructureAsync(FeeStructureModel model, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return 0;

            model.TenantId = tenantId;
            model.SchoolId = schoolId;

            if (model.SelectedClasses == null || model.SelectedClasses.Count == 0) return 0;

            var selectedFeeHeads = model.FeeHeads.Where(x => x.IsSelected).ToList();

            if (selectedFeeHeads.Count == 0) return 0;

            foreach (var className in model.SelectedClasses)
            {
                decimal oneTimeTotal = selectedFeeHeads.Where(x => x.Frequency == "One Time").Sum(x => x.Amount);
                decimal monthlyTotal = selectedFeeHeads.Where(x => x.Frequency == "Monthly").Sum(x => x.Amount);
                decimal yearlyTotal = selectedFeeHeads.Where(x => x.Frequency == "Yearly").Sum(x => x.Amount);
                decimal annualTotal = oneTimeTotal + (monthlyTotal * 12) + yearlyTotal;

                var headerParameters = new NpgsqlParameter[]
                {
                    new NpgsqlParameter("p_operation", "SaveFeeStructure"),
                    new NpgsqlParameter("p_tenant_id", tenantId),
                    new NpgsqlParameter("p_school_id", schoolId),
                    new NpgsqlParameter("p_action_user_id", actionUserId),
                    new NpgsqlParameter("p_class_name", className),
                    new NpgsqlParameter("p_academic_year", model.AcademicYear),
                    new NpgsqlParameter("p_one_time_total", oneTimeTotal),
                    new NpgsqlParameter("p_monthly_total", monthlyTotal),
                    new NpgsqlParameter("p_yearly_total", yearlyTotal),
                    new NpgsqlParameter("p_annual_total", annualTotal),
                    new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "save_fee_structure_cursor" }
                };

                using var dal = new PostgreSqlDal(_connectionString);
                var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeStructureManage, headerParameters);

                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    continue;

                foreach (var feeHead in selectedFeeHeads)
                {
                    var detailParameters = new NpgsqlParameter[]
                    {
                        new NpgsqlParameter("p_operation", "SaveFeeStructureDetail"),
                        new NpgsqlParameter("p_tenant_id", tenantId),
                        new NpgsqlParameter("p_school_id", schoolId),
                        new NpgsqlParameter("p_action_user_id", actionUserId),
                        new NpgsqlParameter("p_class_name", className),
                        new NpgsqlParameter("p_academic_year", model.AcademicYear),
                        new NpgsqlParameter("p_fee_head_id", feeHead.FeeHeadId),
                        new NpgsqlParameter("p_fee_head_name", feeHead.FeeHeadName),
                        new NpgsqlParameter("p_frequency", feeHead.Frequency),
                        new NpgsqlParameter("p_amount", feeHead.Amount),
                        new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "save_fee_structure_detail_cursor" }
                    };

                    using var detailDal = new PostgreSqlDal(_connectionString);
                    await detailDal.ExecuteProcedureWithCursorsAsync(SpFeeStructureManage, detailParameters);
                }
            }

            return 1;
        }

        public async Task<int> DeleteFeeStructureAsync(int feeStructureId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return 0;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "DeleteFeeStructure"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_fee_structure_id", feeStructureId),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "delete_fee_structure_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpFeeStructureManage, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return 0;

            return 1;
        }

        #endregion
    }
}
