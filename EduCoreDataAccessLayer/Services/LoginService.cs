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
    }

    public class LoginService : ILoginService
    {
        private readonly string _connectionString;

        public LoginService(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
        }

        public async Task<UserViewModel?> GetLoginInfoAsync(string email)
        {
            var parameters = BuildLoginParameters(
                operationType: "GET_LOGIN_USER",
                email: email
            );

            using var dal = new PostgreSqlDal(_connectionString);
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

            using var dal = new PostgreSqlDal(_connectionString);
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

            using var dal = new PostgreSqlDal(_connectionString);
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

            using var dal = new PostgreSqlDal(_connectionString);
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

            using var dal = new PostgreSqlDal(_connectionString);
            await dal.ExecuteNonQueryProcedureAsync("core.sp_login_management", parameters);
        }

        private static NpgsqlParameter[] BuildLoginParameters(
            string operationType,
            string? email = null,
            int? userId = null,
            bool? isSuccess = null,
            string? failureReason = null,
            string? ipAddress = null,
            string? userAgent = null)
        {
            return new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation_type", operationType),
                new NpgsqlParameter("p_email", (object?)email ?? DBNull.Value),
                new NpgsqlParameter("p_user_id", (object?)userId ?? DBNull.Value),
                new NpgsqlParameter("p_is_success", (object?)isSuccess ?? DBNull.Value),
                new NpgsqlParameter("p_failure_reason", (object?)failureReason ?? DBNull.Value),
                new NpgsqlParameter("p_ip_address", (object?)ipAddress ?? DBNull.Value),
                new NpgsqlParameter("p_user_agent", (object?)userAgent ?? DBNull.Value),
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


