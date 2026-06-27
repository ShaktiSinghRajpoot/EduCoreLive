using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;
using System.Data;
using System.Text.Json;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    public class TransportService : ITransportService
    {
        private readonly PgExec _db;
        private const string SpRoute   = "core.sp_transport_route_manage";
        private const string SpVehicle = "core.sp_transport_vehicle_manage";
        private const string SpAssign  = "core.sp_transport_assign_manage";
        private const string SpRoutesDropdown = "core.sp_transport_routes_dropdown";

        // WHY: log the real cause before catch blocks swallow it into a friendly message.
        private readonly ILogger<TransportService> _logger;

        public TransportService(PgExec db, ILogger<TransportService> logger)
        {
            _db = db;
            _logger = logger;
        }

        // ── Routes + stops ───────────────────────────────────────
        public async Task<List<TransportRoute>> GetRoutesAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<TransportRoute>();
            var ds = await ExecAsync(SpRoute, RouteParams("GetRoutes", tenantId, schoolId, actionUserId));
            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                list.Add(new TransportRoute
                {
                    RouteId     = ToInt(r["route_id"]),
                    RouteName   = r["route_name"]?.ToString() ?? string.Empty,
                    Description = r["description"] == DBNull.Value ? null : r["description"].ToString(),
                    IsActive    = r["is_active"] != DBNull.Value && Convert.ToBoolean(r["is_active"]),
                    StopCount   = ToInt(r["stop_count"]),
                    MinFare     = r["min_fare"] == DBNull.Value ? null : Convert.ToDecimal(r["min_fare"]),
                    MaxFare     = r["max_fare"] == DBNull.Value ? null : Convert.ToDecimal(r["max_fare"])
                });
            }
            return list;
        }

        public async Task<List<TransportStop>> GetStopsAsync(int routeId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<TransportStop>();
            var p = RouteParams("GetStops", tenantId, schoolId, actionUserId);
            p[4].Value = routeId;   // p_route_id
            var ds = await ExecAsync(SpRoute, p);
            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                list.Add(new TransportStop
                {
                    StopId       = ToInt(r["stop_id"]),
                    RouteId      = ToInt(r["route_id"]),
                    StopName     = r["stop_name"]?.ToString() ?? string.Empty,
                    MonthlyFare  = r["monthly_fare"] == DBNull.Value ? 0 : Convert.ToDecimal(r["monthly_fare"]),
                    DisplayOrder = ToInt(r["display_order"])
                });
            }
            return list;
        }

        public async Task<(bool, string, int)> SaveRouteAsync(TransportRoute route, int tenantId, int schoolId, int actionUserId)
        {
            var stopsJson = JsonSerializer.Serialize((route.Stops ?? new List<TransportStop>()).Select((s, i) => new
            {
                stopId       = s.StopId,
                stopName     = s.StopName,
                monthlyFare  = s.MonthlyFare,
                displayOrder = s.DisplayOrder > 0 ? s.DisplayOrder : i + 1
            }));

            var p = RouteParams("SaveRoute", tenantId, schoolId, actionUserId);
            p[4].Value = route.RouteId > 0 ? route.RouteId : DBNull.Value;
            p[5].Value = (object?)route.RouteName ?? DBNull.Value;
            p[6].Value = (object?)route.Description ?? DBNull.Value;
            p[7].Value = stopsJson;

            try
            {
                var ds = await ExecAsync(SpRoute, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), row["message"].ToString()!,
                        row.Table.Columns.Contains("route_id") && row["route_id"] != DBNull.Value ? ToInt(row["route_id"]) : 0);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Save route rejected for school {SchoolId} (route {RouteId}). SqlState {SqlState}", schoolId, route.RouteId, pex.SqlState);
                return (false, pex.MessageText, 0);
            }
        }

        public Task<(bool, string)> DeleteRouteAsync(int routeId, int tenantId, int schoolId, int actionUserId)
            => SimpleRouteOp("DeleteRoute", routeId, tenantId, schoolId, actionUserId);

        public Task<(bool, string)> ToggleRouteStatusAsync(int routeId, int tenantId, int schoolId, int actionUserId)
            => SimpleRouteOp("ToggleRouteStatus", routeId, tenantId, schoolId, actionUserId);

        private async Task<(bool, string)> SimpleRouteOp(string op, int routeId, int tenantId, int schoolId, int actionUserId)
        {
            var p = RouteParams(op, tenantId, schoolId, actionUserId);
            p[4].Value = routeId;
            try
            {
                var ds = await ExecAsync(SpRoute, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), row["message"].ToString()!);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Transport operation rejected for school {SchoolId}. SqlState {SqlState}", schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
        }

        // ── Vehicles ─────────────────────────────────────────────
        public async Task<List<TransportVehicle>> GetVehiclesAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<TransportVehicle>();
            var ds = await ExecAsync(SpVehicle, VehicleParams("GetVehicles", tenantId, schoolId, actionUserId));
            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                list.Add(new TransportVehicle
                {
                    VehicleId   = ToInt(r["vehicle_id"]),
                    VehicleNo   = r["vehicle_no"]?.ToString() ?? string.Empty,
                    Capacity    = r["capacity"] == DBNull.Value ? null : ToInt(r["capacity"]),
                    DriverName  = r["driver_name"] == DBNull.Value ? null : r["driver_name"].ToString(),
                    DriverPhone = r["driver_phone"] == DBNull.Value ? null : r["driver_phone"].ToString(),
                    RouteId     = r["route_id"] == DBNull.Value ? null : ToInt(r["route_id"]),
                    RouteName   = r["route_name"] == DBNull.Value ? null : r["route_name"].ToString(),
                    IsActive    = r["is_active"] != DBNull.Value && Convert.ToBoolean(r["is_active"])
                });
            }
            return list;
        }

        public async Task<(bool, string)> SaveVehicleAsync(TransportVehicle v, int tenantId, int schoolId, int actionUserId)
        {
            var p = VehicleParams("SaveVehicle", tenantId, schoolId, actionUserId);
            p[4].Value = v.VehicleId > 0 ? v.VehicleId : DBNull.Value;
            p[5].Value = (object?)v.VehicleNo ?? DBNull.Value;
            p[6].Value = (object?)v.Capacity ?? DBNull.Value;
            p[7].Value = (object?)v.DriverName ?? DBNull.Value;
            p[8].Value = (object?)v.DriverPhone ?? DBNull.Value;
            p[9].Value = v.RouteId.HasValue && v.RouteId > 0 ? v.RouteId.Value : DBNull.Value;
            try
            {
                var ds = await ExecAsync(SpVehicle, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), row["message"].ToString()!);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Transport operation rejected for school {SchoolId}. SqlState {SqlState}", schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
        }

        public Task<(bool, string)> DeleteVehicleAsync(int vehicleId, int tenantId, int schoolId, int actionUserId)
            => SimpleVehicleOp("DeleteVehicle", vehicleId, tenantId, schoolId, actionUserId);

        public Task<(bool, string)> ToggleVehicleStatusAsync(int vehicleId, int tenantId, int schoolId, int actionUserId)
            => SimpleVehicleOp("ToggleVehicleStatus", vehicleId, tenantId, schoolId, actionUserId);

        private async Task<(bool, string)> SimpleVehicleOp(string op, int vehicleId, int tenantId, int schoolId, int actionUserId)
        {
            var p = VehicleParams(op, tenantId, schoolId, actionUserId);
            p[4].Value = vehicleId;
            try
            {
                var ds = await ExecAsync(SpVehicle, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), row["message"].ToString()!);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Transport operation rejected for school {SchoolId}. SqlState {SqlState}", schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
        }

        // ── Assignment ───────────────────────────────────────────
        public async Task<List<TransportRouteOption>> GetRoutesDropdownAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<TransportRouteOption>();
            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id", NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id", NpgsqlDbType.Integer) { Value = schoolId },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };
            var ds = await ExecAsync(SpRoutesDropdown, p);
            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                list.Add(new TransportRouteOption
                {
                    RouteId     = ToInt(r["route_id"]),
                    RouteName   = r["route_name"]?.ToString() ?? string.Empty,
                    StopId      = ToInt(r["stop_id"]),
                    StopName    = r["stop_name"]?.ToString() ?? string.Empty,
                    MonthlyFare = r["monthly_fare"] == DBNull.Value ? 0 : Convert.ToDecimal(r["monthly_fare"])
                });
            }
            return list;
        }

        public async Task<StudentTransportAssignment?> GetAssignmentAsync(int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var p = AssignParams("GetForStudent", tenantId, schoolId, actionUserId, studentId);
            var ds = await ExecAsync(SpAssign, p);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;
            var r = ds.Tables[0].Rows[0];
            return new StudentTransportAssignment
            {
                AssignmentId = ToInt(r["assignment_id"]),
                RouteId      = ToInt(r["route_id"]),
                StopId       = ToInt(r["stop_id"]),
                MonthlyFare  = r["monthly_fare"] == DBNull.Value ? 0 : Convert.ToDecimal(r["monthly_fare"]),
                //StartDate    = r["start_date"] == DBNull.Value ? null : DateOnly.FromDateTime(Convert.ToDateTime(r["start_date"])),
                StartDate = r["start_date"] == DBNull.Value ? null : (DateOnly)r["start_date"],
                RouteName    = r["route_name"] == DBNull.Value ? null : r["route_name"].ToString(),
                StopName     = r["stop_name"] == DBNull.Value ? null : r["stop_name"].ToString()
            };
        }

        public async Task<(bool, string, decimal, int)> SaveAssignmentAsync(
            int studentId, int routeId, int stopId, string? academicYear, DateOnly? startDate, int months,
            int tenantId, int schoolId, int actionUserId)
        {
            var p = AssignParams("SaveAssignment", tenantId, schoolId, actionUserId, studentId);
            p[5].Value = routeId;
            p[6].Value = stopId;
            p[7].Value = (object?)academicYear ?? DBNull.Value;
            p[8].Value = startDate.HasValue ? startDate.Value : DBNull.Value;
            p[9].Value = months > 0 ? months : 12;
            try
            {
                var ds = await ExecAsync(SpAssign, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), row["message"].ToString()!,
                        row.Table.Columns.Contains("monthly_fare") && row["monthly_fare"] != DBNull.Value ? Convert.ToDecimal(row["monthly_fare"]) : 0,
                        row.Table.Columns.Contains("months_generated") && row["months_generated"] != DBNull.Value ? ToInt(row["months_generated"]) : 0);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Save transport assignment rejected for student {StudentId}, school {SchoolId}. SqlState {SqlState}", studentId, schoolId, pex.SqlState);
                return (false, pex.MessageText, 0, 0);
            }
        }

        public async Task<(bool, string)> RemoveAssignmentAsync(int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var p = AssignParams("RemoveAssignment", tenantId, schoolId, actionUserId, studentId);
            try
            {
                var ds = await ExecAsync(SpAssign, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), row["message"].ToString()!);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Transport operation rejected for school {SchoolId}. SqlState {SqlState}", schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
        }

        // ── Param builders ───────────────────────────────────────
        private static NpgsqlParameter[] RouteParams(string op, int t, int s, int u) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = op },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = t },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = s },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = u },
            new("p_route_id",       NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_route_name",     NpgsqlDbType.Text)    { Value = DBNull.Value },
            new("p_description",    NpgsqlDbType.Text)    { Value = DBNull.Value },
            new("p_stops",          NpgsqlDbType.Jsonb)   { Value = DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
        };

        private static NpgsqlParameter[] VehicleParams(string op, int t, int s, int u) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = op },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = t },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = s },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = u },
            new("p_vehicle_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_vehicle_no",     NpgsqlDbType.Text)    { Value = DBNull.Value },
            new("p_capacity",       NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_driver_name",    NpgsqlDbType.Text)    { Value = DBNull.Value },
            new("p_driver_phone",   NpgsqlDbType.Text)    { Value = DBNull.Value },
            new("p_route_id",       NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
        };

        private static NpgsqlParameter[] AssignParams(string op, int t, int s, int u, int studentId) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = op },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = t },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = s },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = u },
            new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
            new("p_route_id",       NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_stop_id",        NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_academic_year",  NpgsqlDbType.Text)    { Value = DBNull.Value },
            new("p_start_date",     NpgsqlDbType.Date)    { Value = DBNull.Value },
            new("p_months",         NpgsqlDbType.Integer) { Value = 12 },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
        };

        private async Task<DataSet> ExecAsync(string sp, NpgsqlParameter[] p)
            => await _db.ExecuteProcedureWithCursorsAsync(sp, p);

        private static int ToInt(object v) => v == DBNull.Value ? 0 : Convert.ToInt32(v);
    }
}
