using System.Data;
using Npgsql;

namespace EduCoreDataAccessLayer.Helpers
{
    /// <summary>
    /// Safe, null-aware column readers for <see cref="NpgsqlDataReader"/>.
    ///
    /// WHY: when we read with a DataReader (instead of DataSet) we lose DataRow's
    /// <c>Table.Columns.Contains(...)</c> convenience. These helpers take a pre-built set of the
    /// reader's column names (see <see cref="Columns"/>) so a missing OR null column both fall back
    /// to a safe default — exactly the behaviour the old DataRow mapping had, but allocation-free
    /// per row (the column set is built once per cursor).
    /// </summary>
    public static class DbRead
    {
        /// <summary>Build the case-insensitive set of column names for the current result set. Call once per cursor.</summary>
        public static HashSet<string> Columns(this NpgsqlDataReader r)
        {
            var set = new HashSet<string>(r.FieldCount, StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < r.FieldCount; i++)
                set.Add(r.GetName(i));
            return set;
        }

        public static bool Has(HashSet<string> cols, string c) => cols.Contains(c);

        public static int Int(NpgsqlDataReader r, HashSet<string> cols, string c)
            => cols.Contains(c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;

        public static int? IntN(NpgsqlDataReader r, HashSet<string> cols, string c)
            => cols.Contains(c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : null;

        public static decimal Dec(NpgsqlDataReader r, HashSet<string> cols, string c)
            => cols.Contains(c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : 0m;

        public static bool Bool(NpgsqlDataReader r, HashSet<string> cols, string c)
            => cols.Contains(c) && r[c] != DBNull.Value && Convert.ToBoolean(r[c]);

        /// <summary>Non-null string ("" when missing/null).</summary>
        public static string Str(NpgsqlDataReader r, HashSet<string> cols, string c)
            => cols.Contains(c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;

        /// <summary>Nullable string (null when missing/null).</summary>
        public static string? NStr(NpgsqlDataReader r, HashSet<string> cols, string c)
            => cols.Contains(c) && r[c] != DBNull.Value ? r[c].ToString() : null;


        public static DateTime? DateTimeN(NpgsqlDataReader r, HashSet<string> cols, string c)
            => cols.Contains(c) && r[c] != DBNull.Value ? Convert.ToDateTime(r[c]) : null;

        // ── DataRow overloads ────────────────────────────────────────────────
        // Dates are stored as ISO text (YYYY-MM-DD), so they are read as text —
        // there is no date reader here any more. Every service used to carry its
        // own private DateVal built on Convert.ToDateTime(row[col]), which THROWS
        // when the driver hands back a DateOnly. Reading the string ends that
        // whole class of error. DateTimeN stays for the real timestamp columns
        // (created_at, paid_at, …), which are still timestamps.

        /// <summary>Non-null string ("" when missing/null).</summary>
        public static string Str(DataRow r, string c)
            => r.Table.Columns.Contains(c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;

        /// <summary>Nullable string (null when missing/null).</summary>
        public static string? NStr(DataRow r, string c)
            => r.Table.Columns.Contains(c) && r[c] != DBNull.Value ? r[c].ToString() : null;


        /// <summary>A timestamp column. Same tolerance; keeps the time of day.</summary>
        public static DateTime? DateTimeN(DataRow r, string c)
        {
            if (!r.Table.Columns.Contains(c) || r[c] == DBNull.Value) return null;
            var v = r[c];
            if (v is DateTime dt) return dt;
            return DateTime.TryParse(v.ToString(), out var p) ? p : null;
        }
    }
}
