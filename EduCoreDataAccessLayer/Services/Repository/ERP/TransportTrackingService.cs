using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;
using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class TransportTrackingService : ITransportTrackingService
    {
        private const string SpTrip     = "core.sp_transport_trip_manage";
        private const string SpTracking = "core.sp_transport_tracking_manage";
        private const string SpPublic   = "core.sp_transport_track_public";

        // A share token is 32 random bytes, base64url without padding = 43 characters.
        private static readonly Regex TokenFormat = new("^[A-Za-z0-9_-]{43}$", RegexOptions.Compiled);

        private readonly PgExec _db;
        private readonly AppCache _cache;
        private readonly ILogger<TransportTrackingService> _logger;

        public TransportTrackingService(PgExec db, AppCache cache, ILogger<TransportTrackingService> logger)
        {
            _db = db;
            _cache = cache;
            _logger = logger;
        }

        // ── Driver ───────────────────────────────────────────────
        public async Task<List<MyBusVehicle>> GetMyBusesAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<MyBusVehicle>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTrip, TripParams("MyBus", tenantId, schoolId, actionUserId));
            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                list.Add(new MyBusVehicle
                {
                    VehicleId   = Int(r["vehicle_id"]),
                    VehicleNo   = Str(r["vehicle_no"]) ?? string.Empty,
                    RouteId     = NInt(r["route_id"]),
                    RouteName   = Str(r["route_name"]),
                    TripId      = NInt(r["trip_id"]),
                    StartedAt   = Str(r["started_at"]),
                    LastPointAt = Str(r["last_point_at"]),
                    PointCount  = Int(r["point_count"])
                });
            }
            return list;
        }

        /// <summary>
        /// Used by the side menu on every page, so it is cached for 5 minutes per user.
        /// A driver change therefore shows in the menu within 5 minutes; the My Bus page
        /// itself always reads the database.
        /// </summary>
        public Task<bool> IsDriverAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || actionUserId <= 0) return Task.FromResult(false);
            string key = AppCache.Key("isdriver:u" + actionUserId, tenantId, schoolId);
            return _cache.GetOrCreateAsync(key, async () =>
                (await GetMyBusesAsync(tenantId, schoolId, actionUserId)).Count > 0,
                TimeSpan.FromMinutes(5));
        }

        public async Task<(bool, string, int)> StartTripAsync(int vehicleId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return (false, "Invalid school scope.", 0);
            var p = TripParams("StartTrip", tenantId, schoolId, actionUserId);
            p[4].Value = vehicleId;
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTrip, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), Str(row["message"]) ?? "", Int(row["trip_id"]));
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Start trip rejected for vehicle {VehicleId}, school {SchoolId}. SqlState {SqlState}", vehicleId, schoolId, pex.SqlState);
                // 23505 = two starts raced for the same bus; the other one won.
                return (false, pex.SqlState == "23505" ? "A trip was just started on this bus. Reload the page." : pex.MessageText, 0);
            }
        }

        public async Task<(bool, string)> EndTripAsync(int tripId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return (false, "Invalid school scope.");
            var p = TripParams("EndTrip", tenantId, schoolId, actionUserId);
            p[5].Value = tripId;
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTrip, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), Str(row["message"]) ?? "");
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "End trip rejected for trip {TripId}, school {SchoolId}. SqlState {SqlState}", tripId, schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
        }

        public async Task<(bool, bool, string)> AddPointAsync(TripPointRequest pt, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return (false, false, "Invalid school scope.");
            var p = TripParams("AddPoint", tenantId, schoolId, actionUserId);
            p[5].Value  = pt.TripId;
            p[6].Value  = ToDecimalOrNull(pt.Lat);        // the proc refuses a missing lat/lng/accuracy
            p[7].Value  = ToDecimalOrNull(pt.Lng);
            p[8].Value  = ToDecimalOrNull(pt.Accuracy);
            p[9].Value  = ToDecimalOrNull(pt.Speed);
            p[10].Value = ToDecimalOrNull(pt.Heading);
            // Phone time in Unix ms; 0 = let the server use its own clock.
            p[11].Value = pt.RecordedAt > 0
                ? DateTimeOffset.FromUnixTimeMilliseconds(pt.RecordedAt).UtcDateTime
                : DBNull.Value;
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTrip, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), Convert.ToBoolean(row["accepted"]), Str(row["message"]) ?? "");
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "GPS point rejected for trip {TripId}, school {SchoolId}. SqlState {SqlState}", pt.TripId, schoolId, pex.SqlState);
                return (false, false, pex.MessageText);
            }
        }

        // ── Staff ────────────────────────────────────────────────
        public async Task<List<LiveTrip>> GetLiveTripsAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<LiveTrip>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTracking, TrackingParams("LiveList", tenantId, schoolId, actionUserId));
            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                list.Add(new LiveTrip
                {
                    TripId      = Int(r["trip_id"]),
                    VehicleId   = Int(r["vehicle_id"]),
                    VehicleNo   = Str(r["vehicle_no"]) ?? string.Empty,
                    RouteName   = Str(r["route_name"]),
                    DriverName  = Str(r["driver_name"]),
                    StartedAt   = Str(r["started_at"]),
                    LastPointAt = Str(r["last_point_at"]),
                    AgeSeconds  = NInt(r["age_seconds"]),
                    Lat         = NDec(r["lat"]),
                    Lng         = NDec(r["lng"]),
                    AccuracyM   = NDec(r["accuracy_m"]),
                    SpeedMps    = NDec(r["speed_mps"]),
                    PointCount  = Int(r["point_count"])
                });
            }
            return list;
        }

        public async Task<List<TripHistoryRow>> GetTripHistoryAsync(int? vehicleId, string? fromDate, string? toDate, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<TripHistoryRow>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var p = TrackingParams("TripHistory", tenantId, schoolId, actionUserId);
            p[4].Value = vehicleId.HasValue && vehicleId > 0 ? vehicleId.Value : DBNull.Value;
            p[7].Value = (object?)fromDate ?? DBNull.Value;
            p[8].Value = (object?)toDate ?? DBNull.Value;
            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTracking, p);
            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                list.Add(new TripHistoryRow
                {
                    TripId      = Int(r["trip_id"]),
                    VehicleId   = Int(r["vehicle_id"]),
                    VehicleNo   = Str(r["vehicle_no"]),
                    RouteName   = Str(r["route_name"]),
                    DriverName  = Str(r["driver_name"]),
                    StartedAt   = Str(r["started_at"]),
                    EndedAt     = Str(r["ended_at"]),
                    EndReason   = Str(r["end_reason"]),
                    PointCount  = Int(r["point_count"]),
                    IsRunning   = r["is_running"] != DBNull.Value && Convert.ToBoolean(r["is_running"]),
                    DurationMin = Int(r["duration_min"])
                });
            }
            return list;
        }

        public async Task<List<TripPoint>> GetTripPointsAsync(int tripId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<TripPoint>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var p = TrackingParams("TripPoints", tenantId, schoolId, actionUserId);
            p[5].Value = tripId;
            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTracking, p);
            if (ds.Tables.Count == 0) return list;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                list.Add(new TripPoint
                {
                    Lat        = Convert.ToDecimal(r["lat"]),
                    Lng        = Convert.ToDecimal(r["lng"]),
                    SpeedMps   = NDec(r["speed_mps"]),
                    RecordedAt = Str(r["recorded_at"])
                });
            }
            return list;
        }

        // ── Share links ──────────────────────────────────────────
        public async Task<Dictionary<int, string>> GetShareLinksAsync(int tenantId, int schoolId, int actionUserId)
        {
            var map = new Dictionary<int, string>();
            if (tenantId <= 1 || schoolId <= 0) return map;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTracking, TrackingParams("ShareList", tenantId, schoolId, actionUserId));
            if (ds.Tables.Count == 0) return map;
            foreach (DataRow r in ds.Tables[0].Rows)
                map[Int(r["route_id"])] = Str(r["created_at"]) ?? "";
            return map;
        }

        public async Task<(bool, string, string?)> CreateShareLinkAsync(int routeId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return (false, "Invalid school scope.", null);

            // The raw token leaves this method once, for the office to copy. Only its
            // hash reaches the database, so a database leak cannot be replayed as links.
            string token = NewToken();
            var p = TrackingParams("ShareCreate", tenantId, schoolId, actionUserId);
            p[6].Value = routeId;
            p[9].Value = HashToken(token);
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTracking, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), Str(row["message"]) ?? "", token);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Create share link rejected for route {RouteId}, school {SchoolId}. SqlState {SqlState}", routeId, schoolId, pex.SqlState);
                return (false, pex.MessageText, null);
            }
        }

        public async Task<(bool, string)> RevokeShareLinkAsync(int routeId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return (false, "Invalid school scope.");
            var p = TrackingParams("ShareRevoke", tenantId, schoolId, actionUserId);
            p[6].Value = routeId;
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpTracking, p);
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), Str(row["message"]) ?? "");
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Revoke share link rejected for route {RouteId}, school {SchoolId}. SqlState {SqlState}", routeId, schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
        }

        public async Task<PublicTrack?> GetPublicTrackAsync(string? token)
        {
            // A malformed token never reaches the database.
            if (string.IsNullOrEmpty(token) || !TokenFormat.IsMatch(token)) return null;

            var p = new NpgsqlParameter[]
            {
                new("p_token_hash", NpgsqlDbType.Varchar) { Value = HashToken(token) },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };
            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpPublic, p);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            var track = new PublicTrack { RouteName = Str(ds.Tables[0].Rows[0]["route_name"]) ?? "" };
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                if (r["trip_id"] == DBNull.Value) continue;   // valid link, no bus on a trip
                track.Buses.Add(new PublicBus
                {
                    VehicleNo   = Str(r["vehicle_no"]) ?? "",
                    Lat         = NDec(r["lat"]),
                    Lng         = NDec(r["lng"]),
                    AgeSeconds  = NInt(r["age_seconds"]),
                    LastPointAt = Str(r["last_point_at"])
                });
            }
            return track;
        }

        // ── Token helpers ────────────────────────────────────────
        private static string NewToken()
        {
            byte[] bytes = RandomNumberGenerator.GetBytes(32);
            return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }

        /// <summary>Lowercase hex sha256 -- the only form of a token the database ever sees.</summary>
        private static string HashToken(string token)
            => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();

        // ── Param builders ───────────────────────────────────────
        private static NpgsqlParameter[] TripParams(string op, int t, int s, int u) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Varchar)     { Value = op },
            new("p_tenant_id",      NpgsqlDbType.Integer)     { Value = t },
            new("p_school_id",      NpgsqlDbType.Integer)     { Value = s },
            new("p_action_user_id", NpgsqlDbType.Integer)     { Value = u },
            new("p_vehicle_id",     NpgsqlDbType.Integer)     { Value = DBNull.Value },
            new("p_trip_id",        NpgsqlDbType.Integer)     { Value = DBNull.Value },
            new("p_lat",            NpgsqlDbType.Numeric)     { Value = DBNull.Value },
            new("p_lng",            NpgsqlDbType.Numeric)     { Value = DBNull.Value },
            new("p_accuracy",       NpgsqlDbType.Numeric)     { Value = DBNull.Value },
            new("p_speed",          NpgsqlDbType.Numeric)     { Value = DBNull.Value },
            new("p_heading",        NpgsqlDbType.Numeric)     { Value = DBNull.Value },
            new("p_recorded_at",    NpgsqlDbType.TimestampTz) { Value = DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
        };

        private static NpgsqlParameter[] TrackingParams(string op, int t, int s, int u) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Varchar) { Value = op },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = t },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = s },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = u },
            new("p_vehicle_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_trip_id",        NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_route_id",       NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_from_date",      NpgsqlDbType.Varchar) { Value = DBNull.Value },
            new("p_to_date",        NpgsqlDbType.Varchar) { Value = DBNull.Value },
            new("p_token_hash",     NpgsqlDbType.Varchar) { Value = DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
        };

        // Anything that is not a plain finite number (NaN, Infinity, 1e300) becomes NULL
        // here rather than an overflow exception; the proc then refuses or drops it.
        private static object ToDecimalOrNull(double? v)
            => v.HasValue && double.IsFinite(v.Value) && Math.Abs(v.Value) < 1e9 ? (decimal)v.Value : DBNull.Value;

        private static int      Int(object v)  => v == DBNull.Value ? 0 : Convert.ToInt32(v);
        private static int?     NInt(object v) => v == DBNull.Value ? null : Convert.ToInt32(v);
        private static decimal? NDec(object v) => v == DBNull.Value ? null : Convert.ToDecimal(v);
        private static string?  Str(object v)  => v == DBNull.Value ? null : v.ToString();
    }
}
