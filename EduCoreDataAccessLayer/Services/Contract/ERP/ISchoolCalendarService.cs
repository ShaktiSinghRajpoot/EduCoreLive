using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// The school's working-day calendar: a weekly off pattern plus dated overrides.
    /// The Smart Bell reads <see cref="GetDayStatusAsync"/> to decide whether to ring.
    /// </summary>
    public interface ISchoolCalendarService
    {
        /// <summary>Weekly offs + every dated entry between the two dates (inclusive).</summary>
        Task<SchoolCalendarData> GetCalendarAsync(
            DateTime from, DateTime to, int tenantId, int schoolId, int actionUserId);

        /// <summary>One day resolved: is the school open, and if so until when.</summary>
        Task<SchoolDayStatus> GetDayStatusAsync(
            DateTime date, int tenantId, int schoolId, int actionUserId);

        /// <summary>Add or replace the override on one date.</summary>
        Task<SchoolCalendarSaveResult> SaveEntryAsync(
            SchoolCalendarEntry entry, int tenantId, int schoolId, int actionUserId);

        /// <summary>Drop the override on a date, putting it back on the weekly pattern.</summary>
        Task<SchoolCalendarSaveResult> DeleteEntryAsync(
            int calendarId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Replace the weekly off pattern (0 = Sunday … 6 = Saturday).</summary>
        Task<SchoolCalendarSaveResult> SaveWeeklyOffAsync(
            List<int> weeklyOffDays, int tenantId, int schoolId, int actionUserId);
    }
}
