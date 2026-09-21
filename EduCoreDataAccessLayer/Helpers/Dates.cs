using System.Globalization;

namespace EduCoreDataAccessLayer.Helpers
{
    /// <summary>
    /// Dates are stored and carried as ISO text ("yyyy-MM-dd").
    ///
    /// WHY: every date column is varchar now, so nothing in the app converts a
    /// date on the way in or out. That removes the conversion that used to throw
    /// (Convert.ToDateTime on a value the driver had already handed back as a
    /// DateOnly). ISO text also sorts and compares in date order, so lists and
    /// BETWEEN filters keep working on the plain string.
    ///
    /// This class is the ONE place a date is still parsed: where text from a
    /// browser becomes storage text (Norm), and the few spots that do real
    /// arithmetic such as counting months (Parse). Everywhere else passes the
    /// string straight through.
    /// </summary>
    public static class Dates
    {
        public const string Iso = "yyyy-MM-dd";

        /// <summary>Today as ISO text.</summary>
        public static string Today => DateTime.Today.ToString(Iso, CultureInfo.InvariantCulture);

        /// <summary>
        /// Whatever the browser sent, normalised to ISO text. Null when it is
        /// blank or not a date — so a bad value is dropped here instead of
        /// reaching the database.
        /// </summary>
        public static string? Norm(string? s)
            => DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
                   ? d.ToString(Iso, CultureInfo.InvariantCulture)
                   : null;

        /// <summary>Stored ISO text back to a real date, for arithmetic only.</summary>
        public static DateTime? Parse(string? s)
            => DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
                   ? d
                   : null;

        /// <summary>ISO text formatted for display. Empty when there is no date.</summary>
        public static string Show(string? s, string format = "dd MMM yyyy")
            => DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
                   ? d.ToString(format, CultureInfo.InvariantCulture)
                   : string.Empty;

        /// <summary>ISO text N months on, still ISO text.</summary>
        public static string? AddMonths(string? s, int months)
        {
            var d = Parse(s);
            return d?.AddMonths(months).ToString(Iso, CultureInfo.InvariantCulture);
        }
    }
}
