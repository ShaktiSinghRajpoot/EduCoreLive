using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    public class StaffService : IStaffService
    {
        private readonly PgExec _db;
        private readonly ILogger<StaffService> _logger;

        private const string SpManage = "core.sp_staff_manage";
        private const string SpDropdowns = "config.sp_staff_dropdowns";
        private const string SpUserRoles = "core.sp_user_roles_resolve";

        public StaffService(PgExec db, ILogger<StaffService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<List<StaffListItem>> GetStaffAsync(
            int tenantId, int schoolId, int actionUserId,
            string? search = null, string? statusFilter = null)
        {
            var items = new List<StaffListItem>();
            if (tenantId <= 1 || schoolId <= 0) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                SpManage, BuildParameters("LIST", tenantId, schoolId, actionUserId,
                    search: search, statusFilter: statusFilter));

            if (ds.Tables.Count == 0) return items;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                items.Add(new StaffListItem
                {
                    StaffId      = IntVal(row, "staff_id"),
                    EmployeeCode = NullStr(row, "employee_code"),
                    FullName     = Str(row, "full_name"),
                    Gender       = NullStr(row, "gender"),
                    Mobile       = NullStr(row, "mobile"),
                    Email        = NullStr(row, "email"),
                    StaffType    = NullStr(row, "staff_type"),
                    Department   = NullStr(row, "department"),
                    Designation  = NullStr(row, "designation"),
                   // JoiningDate  = DateVal(row, "joining_date"),
                    Status       = Str(row, "status"),
                    HasLogin     = row.Table.Columns.Contains("user_id") && row["user_id"] != DBNull.Value
                });
            }
            return items;
        }

        public async Task<StaffModel?> GetStaffByIdAsync(int staffId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || staffId <= 0) return null;

            var p = BuildParameters("GET", tenantId, schoolId, actionUserId, staffId: staffId);
            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpManage, p);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;
            var row = ds.Tables[0].Rows[0];

            var model = new StaffModel
            {
                StaffId         = IntVal(row, "staff_id"),
                EmployeeCode    = NullStr(row, "employee_code"),
                FullName        = Str(row, "full_name"),
                Gender          = NullStr(row, "gender"),
               // DateOfBirth     = DateVal(row, "dob"),
                Mobile          = NullStr(row, "mobile"),
                AltMobile       = NullStr(row, "alt_mobile"),
                Email           = NullStr(row, "email"),
                BloodGroup      = NullStr(row, "blood_group"),
                Address         = NullStr(row, "address"),
                StaffType       = NullStr(row, "staff_type"),
                Department      = NullStr(row, "department"),
                Designation     = NullStr(row, "designation"),
                //JoiningDate     = DateVal(row, "joining_date"),
                Qualification   = NullStr(row, "qualification"),
                ExperienceYears = NullIntVal(row, "experience_years"),
                Status          = Str(row, "status"),
                MonthlySalary   = NullDecVal(row, "monthly_salary"),
                BankAccountNo   = NullStr(row, "bank_account_no"),
                IfscCode        = NullStr(row, "ifsc_code"),
                Pan             = NullStr(row, "pan"),
                Aadhaar         = NullStr(row, "aadhaar"),
                UserId          = NullIntVal(row, "user_id")
            };

            // Pre-fill the person's current roles so the edit form can check them.
            if (model.UserId is int uid)
            {
                var rds = await _db.ExecuteProcedureWithCursorsAsync(
                    SpUserRoles,
                    new NpgsqlParameter[]
                    {
                        Int("p_tenant_id", tenantId),
                        Int("p_school_id", schoolId),
                        Int("p_user_id", uid),
                        new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "user_roles_cursor" }
                    });
                if (rds.Tables.Count > 0)
                    foreach (DataRow rr in rds.Tables[0].Rows)
                        model.RoleIds.Add(IntVal(rr, "role_id"));
            }

            return model;
        }

        public async Task<(int StaffId, string Message)> SaveStaffAsync(
            StaffModel model, string operation, string? passwordHash,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return (0, "Invalid request.");

            try
            {
                var p = BuildParameters(operation, tenantId, schoolId, actionUserId,
                    staffId: model.StaffId, model: model, passwordHash: passwordHash);

                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpManage, p);
                var id = (ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0)
                    ? IntVal(ds.Tables[0].Rows[0], "staff_id") : 0;
                return (id, "Saved.");
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Staff {Op} business-rule error (SqlState {State})", operation, ex.SqlState);
                return (0, ex.MessageText);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Staff {Op} unexpected error", operation);
                return (0, "Could not save staff. Please try again.");
            }
        }

        public Task<(int StaffId, string Message)> DeactivateAsync(int staffId, int tenantId, int schoolId, int actionUserId)
            => RunActionAsync("DELETE", staffId, tenantId, schoolId, actionUserId);

        public Task<(int StaffId, string Message)> ReactivateAsync(int staffId, int tenantId, int schoolId, int actionUserId)
            => RunActionAsync("REACTIVATE", staffId, tenantId, schoolId, actionUserId);

        private async Task<(int StaffId, string Message)> RunActionAsync(
            string operation, int staffId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || staffId <= 0) return (0, "Invalid request.");
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(
                    SpManage, BuildParameters(operation, tenantId, schoolId, actionUserId, staffId: staffId));
                return (staffId, "Done.");
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Staff {Op} business-rule error (SqlState {State})", operation, ex.SqlState);
                return (0, ex.MessageText);
            }
        }

        public async Task<StaffDropdowns> GetDropdownsAsync(int tenantId, int schoolId)
        {
            var result = new StaffDropdowns();
            if (tenantId <= 1 || schoolId <= 0) return result;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",    NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",    NpgsqlDbType.Integer) { Value = schoolId },
                new("p_departments",  NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "departments_cursor" },
                new("p_designations", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "designations_cursor" },
                new("p_roles",        NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "roles_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpDropdowns, p);

            if (ds.Tables.Count > 0)
                foreach (DataRow r in ds.Tables[0].Rows)
                    result.Departments.Add(Str(r, "name"));

            if (ds.Tables.Count > 1)
                foreach (DataRow r in ds.Tables[1].Rows)
                    result.Designations.Add(new DesignationOption { Name = Str(r, "name"), StaffType = Str(r, "staff_type") });

            if (ds.Tables.Count > 2)
                foreach (DataRow r in ds.Tables[2].Rows)
                    result.Roles.Add(new RoleOption { RoleId = IntVal(r, "role_id"), RoleName = Str(r, "role_name") });

            return result;
        }

        // ── Build the positional parameter array for core.sp_staff_manage ──
        // Order MUST match the proc signature exactly (CommandType.StoredProcedure
        // binds positionally).
        private static NpgsqlParameter[] BuildParameters(
            string operation, int tenantId, int schoolId, int actionUserId,
            int staffId = 0, StaffModel? model = null, string? passwordHash = null,
            string? search = null, string? statusFilter = null)
        {
            return new NpgsqlParameter[]
            {
                Txt("p_operation", operation),
                Int("p_tenant_id", tenantId),
                Int("p_school_id", schoolId),
                Int("p_action_user_id", actionUserId),
                NInt("p_staff_id", staffId > 0 ? staffId : (int?)null),
                Txt("p_employee_code", model?.EmployeeCode),
                Txt("p_full_name", model?.FullName),
                Txt("p_gender", model?.Gender),
                NDate("p_dob", model?.DateOfBirth),
                Txt("p_mobile", model?.Mobile),
                Txt("p_alt_mobile", model?.AltMobile),
                Txt("p_email", model?.Email),
                Txt("p_blood_group", model?.BloodGroup),
                Txt("p_address", model?.Address),
                Txt("p_staff_type", model?.StaffType),
                Txt("p_department", model?.Department),
                Txt("p_designation", model?.Designation),
                NDate("p_joining_date", model?.JoiningDate),
                Txt("p_qualification", model?.Qualification),
                NInt("p_experience_years", model?.ExperienceYears),
                Txt("p_status", model?.Status),
                NDec("p_monthly_salary", model?.MonthlySalary),
                Txt("p_bank_account_no", model?.BankAccountNo),
                Txt("p_ifsc_code", model?.IfscCode),
                Txt("p_pan", model?.Pan),
                Txt("p_aadhaar", model?.Aadhaar),
                Bool("p_create_login", model?.CreateLogin ?? false),
                Txt("p_password_hash", passwordHash),
                new("p_role_ids", NpgsqlDbType.Array | NpgsqlDbType.Integer)
                    { Value = (object?)model?.RoleIds?.ToArray() ?? Array.Empty<int>() },
                Txt("p_search", search),
                Txt("p_status_filter", statusFilter),
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "staff_cursor" }
            };
        }

        // ── param builders ──
        private static NpgsqlParameter Txt(string n, string? v) => new(n, NpgsqlDbType.Text) { Value = string.IsNullOrWhiteSpace(v) ? DBNull.Value : v };
        private static NpgsqlParameter Int(string n, int v) => new(n, NpgsqlDbType.Integer) { Value = v };
        private static NpgsqlParameter NInt(string n, int? v) => new(n, NpgsqlDbType.Integer) { Value = (object?)v ?? DBNull.Value };
        private static NpgsqlParameter NDec(string n, decimal? v) => new(n, NpgsqlDbType.Numeric) { Value = (object?)v ?? DBNull.Value };
        private static NpgsqlParameter NDate(string n, DateTime? v) => new(n, NpgsqlDbType.Date) { Value = (object?)v ?? DBNull.Value };
        private static NpgsqlParameter Bool(string n, bool v) => new(n, NpgsqlDbType.Boolean) { Value = v };

        // ── DataRow read helpers (tolerate missing/NULL columns) ──
        private static bool Has(DataRow r, string c) => r.Table.Columns.Contains(c);
        private static int IntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static int? NullIntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : (int?)null;
        private static decimal? NullDecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : (decimal?)null;
        private static string Str(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString() : null;
        
        //private static DateTime? DateVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDateTime(r[c]) : (DateTime?)null;

    }
}
