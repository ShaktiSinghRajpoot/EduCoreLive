using System.Data;

namespace EduCoreDataAccessLayer.Helpers
{
    /// <summary>
    /// Turns a cursor's DataTable into plain rows (column -> value) for pages that only
    /// draw what a read-only procedure returns (dashboards, check lists). Timestamps are
    /// put on the school's clock; procedures that care format them as text themselves,
    /// because a DataTable can drop the UTC tag.
    /// </summary>
    public static class CursorRows
    {
        public static List<Dictionary<string, object?>> From(DataTable? table)
        {
            var rows = new List<Dictionary<string, object?>>();
            if (table == null) return rows;
            foreach (DataRow r in table.Rows)
            {
                var row = new Dictionary<string, object?>();
                foreach (DataColumn col in table.Columns)
                {
                    var v = r[col];
                    row[col.ColumnName] = v == DBNull.Value ? null
                                        : v is DateTime dt ? Dates.ToSchool(dt).ToString("dd MMM, hh:mm tt")
                                        : v;
                }
                rows.Add(row);
            }
            return rows;
        }

        /// <summary>The DataSet's tables in cursor order, keyed by the names given.</summary>
        public static Dictionary<string, List<Dictionary<string, object?>>> From(DataSet ds, params string[] names)
        {
            var result = new Dictionary<string, List<Dictionary<string, object?>>>();
            for (int i = 0; i < names.Length; i++)
                result[names[i]] = From(i < ds.Tables.Count ? ds.Tables[i] : null);
            return result;
        }
    }
}
