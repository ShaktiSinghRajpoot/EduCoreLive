using educore.Models;
using EduCoreDataAccessLayer.Infrastructure;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services
{
    public interface ILoginService
    {
        Task<UserViewModel?> GetLoginInfoAsync(string email);
        Task<UserViewModel?> GetUserInfoByUserIdAsync(int userId);
        Task<List<UserViewModel>> GetUserRolesAsync(int userId);
        Task SaveLoginAttemptAsync(string email, bool isSuccess, string? failureReason);
        Task SaveUserSessionAsync(int userId, HttpContext httpContext);
        Task ChangePasswordAsync(int userId, string passwordHash);

        /// <summary>Stores an OTP hash for the user matched by email-or-phone; returns the user + contacts (null if no match).</summary>
        Task<UserViewModel?> RequestPasswordOtpAsync(string identifier, string otpHash);
        /// <summary>Verifies the OTP for the user and, on success, sets the new password. Returns OK | INVALID | EXPIRED | LOCKED.</summary>
        Task<string> ResetWithOtpAsync(int userId, string otpHash, string passwordHash);
    }

    public class LoginService : ILoginService
    {
        private readonly PgExec _db;

        public LoginService(PgExec db)
        {
            _db = db;
        }

        public async Task<UserViewModel?> GetLoginInfoAsync(string email)
        {
            var parameters = BuildLoginParameters(
                operationType: "GET_LOGIN_USER",
                email: email
            );

            var dal = _db;
            var ds = await dal.ExecuteProcedureWithCursorsAsync("core.sp_login_management", parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return null;

            return BindLoginUser(ds.Tables[0].Rows[0]);
        }

        public async Task<UserViewModel?> GetUserInfoByUserIdAsync(int userId)
        {
            var parameters = BuildLoginParameters(
                operationType: "GET_USER_BY_ID",
                userId: userId
            );

            var dal = _db;
            var ds = await dal.ExecuteProcedureWithCursorsAsync("core.sp_login_management", parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return null;

            return BindLoginUser(ds.Tables[0].Rows[0]);
        }

        public async Task<List<UserViewModel>> GetUserRolesAsync(int userId)
        {
            var roles = new List<UserViewModel>();

            var parameters = BuildLoginParameters(
                operationType: "GET_USER_ROLES",
                userId: userId
            );

            var dal = _db;
            var ds = await dal.ExecuteProcedureWithCursorsAsync("core.sp_login_management", parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return roles;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                roles.Add(BindLoginUser(row));
            }

            return roles;
        }

        public async Task SaveLoginAttemptAsync(string email, bool isSuccess, string? failureReason)
        {
            var parameters = BuildLoginParameters(
                operationType: "SAVE_LOGIN_ATTEMPT",
                email: email,
                isSuccess: isSuccess,
                failureReason: failureReason
            );

            var dal = _db;
            await dal.ExecuteNonQueryProcedureAsync("core.sp_login_management", parameters);
        }

        public async Task SaveUserSessionAsync(int userId, HttpContext httpContext)
        {
            var ipAddress = httpContext.Connection.RemoteIpAddress?.ToString();
            var userAgent = httpContext.Request.Headers["User-Agent"].ToString();

            var parameters = BuildLoginParameters(
                operationType: "SAVE_USER_SESSION",
                userId: userId,
                ipAddress: ipAddress,
                userAgent: userAgent
            );

            var dal = _db;
            await dal.ExecuteNonQueryProcedureAsync("core.sp_login_management", parameters);
        }

        public async Task ChangePasswordAsync(int userId, string passwordHash)
        {
            var parameters = BuildLoginParameters(
                operationType: "CHANGE_PASSWORD",
                userId: userId,
                passwordHash: passwordHash
            );

            var dal = _db;
            await dal.ExecuteNonQueryProcedureAsync("core.sp_login_management", parameters);
        }

        public async Task<UserViewModel?> RequestPasswordOtpAsync(string identifier, string otpHash)
        {
            var parameters = BuildResetParameters("REQUEST", identifier: identifier, otpHash: otpHash);

            var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_password_reset", parameters);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return null;

            var row = ds.Tables[0].Rows[0];
            return new UserViewModel
            {
                UserId = ToInt(row, "user_id"),
                Email = ToStringValue(row, "email"),
                Phone = ToStringValue(row, "phone"),
                FullName = ToStringValue(row, "full_name")
            };
        }

        public async Task<string> ResetWithOtpAsync(int userId, string otpHash, string passwordHash)
        {
            var parameters = BuildResetParameters("RESET_WITH_OTP", otpHash: otpHash, passwordHash: passwordHash, userId: userId);

            var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_password_reset", parameters);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return "EXPIRED";

            return ToStringValue(ds.Tables[0].Rows[0], "status") ?? "EXPIRED";
        }

        private static NpgsqlParameter[] BuildResetParameters(
            string operationType,
            string? identifier = null,
            string? otpHash = null,
            string? passwordHash = null,
            int? userId = null)
        {
            // Order matches the core.sp_password_reset signature (positional CALL).
            return new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation_type", operationType),
                new NpgsqlParameter("p_identifier", (object?)identifier ?? DBNull.Value),
                new NpgsqlParameter("p_otp_hash", (object?)otpHash ?? DBNull.Value),
                new NpgsqlParameter("p_password_hash", (object?)passwordHash ?? DBNull.Value),
                new NpgsqlParameter("p_user_id", (object?)userId ?? DBNull.Value),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "reset_cursor" }
            };
        }

        private static NpgsqlParameter[] BuildLoginParameters(
            string operationType,
            string? email = null,
            int? userId = null,
            bool? isSuccess = null,
            string? failureReason = null,
            string? ipAddress = null,
            string? userAgent = null,
            string? passwordHash = null)
        {
            // NOTE: order must match the core.sp_login_management signature exactly —
            // PgExec calls it as a positional stored procedure. p_password_hash sits
            // just before the p_result refcursor.
            return new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation_type", operationType),
                new NpgsqlParameter("p_email", (object?)email ?? DBNull.Value),
                new NpgsqlParameter("p_user_id", (object?)userId ?? DBNull.Value),
                new NpgsqlParameter("p_is_success", (object?)isSuccess ?? DBNull.Value),
                new NpgsqlParameter("p_failure_reason", (object?)failureReason ?? DBNull.Value),
                new NpgsqlParameter("p_ip_address", (object?)ipAddress ?? DBNull.Value),
                new NpgsqlParameter("p_user_agent", (object?)userAgent ?? DBNull.Value),
                new NpgsqlParameter("p_password_hash", (object?)passwordHash ?? DBNull.Value),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "login_cursor" }
            };
        }

        private static UserViewModel BindLoginUser(DataRow row)
        {
            return new UserViewModel
            {
                UserId = ToInt(row, "user_id"),
                TenantId = ToNullableInt(row, "tenant_id"),
                SchoolId = ToNullableInt(row, "school_id"),

                Email = ToStringValue(row, "email"),
                PasswordHash = ToStringValue(row, "password_hash"),

                IsActive = ToBool(row, "is_active"),
                IsDeleted = ToBool(row, "is_deleted"),
                MustChangePassword = ToBool(row, "must_change_password"),

                FullName = ToStringValue(row, "full_name"),
                Phone = ToStringValue(row, "phone"),

                RoleId = ToInt(row, "role_id"),
                RoleName = ToStringValue(row, "role_name"),
                RoleCode = ToStringValue(row, "role_code")
            };
        }

        private static bool HasColumn(DataRow row, string columnName)
        {
            return row.Table.Columns.Contains(columnName);
        }

        private static string? ToStringValue(DataRow row, string columnName)
        {
            if (!HasColumn(row, columnName) || row[columnName] == DBNull.Value)
                return null;

            return row[columnName]?.ToString();
        }

        private static int ToInt(DataRow row, string columnName)
        {
            if (!HasColumn(row, columnName) || row[columnName] == DBNull.Value)
                return 0;

            return Convert.ToInt32(row[columnName]);
        }

        private static int? ToNullableInt(DataRow row, string columnName)
        {
            if (!HasColumn(row, columnName) || row[columnName] == DBNull.Value)
                return null;

            return Convert.ToInt32(row[columnName]);
        }

        private static bool ToBool(DataRow row, string columnName)
        {
            if (!HasColumn(row, columnName) || row[columnName] == DBNull.Value)
                return false;

            return Convert.ToBoolean(row[columnName]);
        }
    }
}


