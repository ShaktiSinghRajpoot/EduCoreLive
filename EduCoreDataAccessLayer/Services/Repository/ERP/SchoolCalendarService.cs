using System.Data;
using System.Globalization;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class SchoolCalendarService : ISchoolCalendarService
    {
        private readonly PgExec _db;
        private const string Sp = "academic.sp_school_admin_calendar_manage";

        public SchoolCalendarService(PgExec db)
        {
            _db = db;
        }

        public async Task<SchoolCalendarData> GetCalendarAsync(
            DateTime from, DateTime to, int tenantId, int schoolId, int actionUserId)
        {
            var data = new SchoolCalendarData();
            if (tenantId <= 1 || schoolId <= 0) return data;

            var p = Params("GetCalendar", tenantId, schoolId, actionUserId);
            p[5].Value = DateOnly.FromDateTime(from);      // p_date
            p[6].Value = DateOnly.FromDateTime(to);        // p_to_date

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0) return data;

            foreach (DataRow row in ds.Tables[0].Rows)
                data.Entries.Add(ReadEntry(row));

            if (ds.Tables.Count > 1 && ds.Tables[1].Rows.Count > 0)
                data.WeeklyOffDays = ParseDays(Str(ds.Tables[1].Rows[0], "weekly_off_days"));

            return data;
        }

        public async Task<SchoolDayStatus> GetDayStatusAsync(
            DateTime date, int tenantId, int schoolId, int actionUserId)
        {
            // Unscoped callers (or a school with no calendar yet) fall back to the
            // old behaviour: open every day except Sunday.
            var fallback = new SchoolDayStatus
            {
                Date       = date.ToString("yyyy-MM-dd"),
                DayOfWeek  = (int)date.DayOfWeek,
                DayType    = date.DayOfWeek == DayOfWeek.Sunday ? "weekly_off" : "working",
                Title      = date.DayOfWeek == DayOfWeek.Sunday ? "Sunday" : string.Empty,
                IsWorking  = date.DayOfWeek != DayOfWeek.Sunday
            };
            if (tenantId <= 1 || schoolId <= 0) return fallback;

            var p = Params("GetDayStatus", tenantId, schoolId, actionUserId);
            p[5].Value = DateOnly.FromDateTime(date);      // p_date

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return fallback;

            var row = ds.Tables[0].Rows[0];
            return new SchoolDayStatus
            {
                Date       = Str(row, "calendar_date"),
                DayOfWeek  = IntVal(row, "day_of_week"),
                DayType    = Str(row, "day_type"),
                Title      = Str(row, "title"),
                HalfDayEnd = NullStr(row, "half_day_end"),
                IsWorking  = Has(row, "is_working") && row["is_working"] != DBNull.Value && Convert.ToBoolean(row["is_working"])
            };
        }

        public async Task<SchoolCalendarSaveResult> SaveEntryAsync(
            SchoolCalendarEntry entry, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new SchoolCalendarSaveResult { Message = "Invalid school context." };

            if (entry == null || !DateTime.TryParseExact(entry.Date, "yyyy-MM-dd",
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
                return new SchoolCalendarSaveResult { Message = "Pick a valid date." };

            var p = Params("SaveEntry", tenantId, schoolId, actionUserId);
            p[5].Value = DateOnly.FromDateTime(date);                                   // p_date
            p[7].Value = string.IsNullOrWhiteSpace(entry.DayType)                       // p_day_type
                            ? "holiday" : entry.DayType.Trim().ToLowerInvariant();
            p[8].Value = (object?)(entry.Title ?? string.Empty).Trim() ?? DBNull.Value;  // p_title
            p[9].Value = ParseTime(entry.HalfDayEnd);                                   // p_half_day_end

            return await RunWriteAsync(p, "Calendar updated.");
        }

        public async Task<SchoolCalendarSaveResult> DeleteEntryAsync(
            int calendarId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || calendarId <= 0)
                return new SchoolCalendarSaveResult { Message = "Invalid entry." };

            var p = Params("DeleteEntry", tenantId, schoolId, actionUserId);
            p[4].Value = calendarId;    // p_calendar_id

            return await RunWriteAsync(p, "Entry removed.");
        }

        public async Task<SchoolCalendarSaveResult> SaveWeeklyOffAsync(
            List<int> weeklyOffDays, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new SchoolCalendarSaveResult { Message = "Invalid school context." };

            var csv = string.Join(",", (weeklyOffDays ?? new List<int>())
                .Where(d => d is >= 0 and <= 6).Distinct().OrderBy(d => d));

            var p = Params("SaveWeeklyOff", tenantId, schoolId, actionUserId);
            p[10].Value = csv;          // p_weekly_off ('' = never closed weekly)

            return await RunWriteAsync(p, "Weekly offs saved.");
        }

        private async Task<SchoolCalendarSaveResult> RunWriteAsync(NpgsqlParameter[] p, string fallbackMessage)
        {
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new SchoolCalendarSaveResult { Message = "Nothing changed." };

                var row = ds.Tables[0].Rows[0];
                return new SchoolCalendarSaveResult
                {
                    Success = Has(row, "success") && row["success"] != DBNull.Value && Convert.ToBoolean(row["success"]),
                    Message = string.IsNullOrEmpty(Str(row, "message")) ? fallbackMessage : Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                // Proc RAISE (e.g. a half day with no closing time) — surface the friendly text.
                return new SchoolCalendarSaveResult { Message = ex.MessageText };
            }
        }

        private static SchoolCalendarEntry ReadEntry(DataRow row) => new()
        {
            CalendarId = IntVal(row, "calendar_id"),
            Date       = Str(row, "calendar_date"),
            DayType    = Str(row, "day_type"),
            Title      = Str(row, "title"),
            HalfDayEnd = NullStr(row, "half_day_end")
        };

        private static List<int> ParseDays(string csv) =>
            (csv ?? string.Empty)
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(s => int.TryParse(s, out var d) ? d : -1)
                .Where(d => d is >= 0 and <= 6)
                .Distinct()
                .OrderBy(d => d)
                .ToList();

        private static object ParseTime(string? hhmm) =>
            !string.IsNullOrWhiteSpace(hhmm) && TimeOnly.TryParseExact(hhmm, "HH\\:mm",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out var t)
                ? t : DBNull.Value;

        // Fixed positional layout matching sp_school_admin_calendar_manage.
        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Varchar) { Value = operation },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_calendar_id",    NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_date",           NpgsqlDbType.Date)    { Value = DBNull.Value },
                new("p_to_date",        NpgsqlDbType.Date)    { Value = DBNull.Value },
                new("p_day_type",       NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_title",          NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_half_day_end",   NpgsqlDbType.Time)    { Value = DBNull.Value },
                new("p_weekly_off",     NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_result",  NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "calendar_cursor" },
                new("p_result2", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "calendar_cursor2" }
            };
        }

        private static bool Has(DataRow r, string col) => r.Table.Columns.Contains(col);
        private static int     IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static string  Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString() : null;
    }
}
