using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// The weekly timetable grid. Periods come from the bell schedule, day columns
    /// from the school calendar's weekly offs, and the proc rejects any save that
    /// would put one teacher in two rooms at once.
    /// </summary>
    public interface ITimetableService
    {
        /// <summary>
        /// Periods, sections, teachers and day columns — one call on page load.
        /// academicYearId 0 = the current session. Sections are per session, so a
        /// past year must be asked for explicitly.
        /// </summary>
        Task<TimetableSetup> GetSetupAsync(
            int tenantId, int schoolId, int actionUserId, int academicYearId = 0);

        /// <summary>One section's week, plus other sections' bookings and the class's subjects.</summary>
        Task<TimetableGrid> GetGridAsync(int sectionId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Read-only view of one teacher's week.</summary>
        Task<List<TimetableTeacherEntry>> GetTeacherGridAsync(
            int staffId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Assign (or reassign) one slot. Fails if the teacher is already booked.</summary>
        Task<TimetableSaveResult> SaveCellAsync(
            int sectionId, int day, int periodSeq, int subjectId, int? staffId, string? roomNo,
            int tenantId, int schoolId, int actionUserId);

        /// <summary>Empty one slot.</summary>
        Task<TimetableSaveResult> ClearCellAsync(
            int sectionId, int day, int periodSeq, int tenantId, int schoolId, int actionUserId);

        /// <summary>Copy one day across the rest of the working week, skipping clashes.</summary>
        Task<TimetableSaveResult> CopyDayAsync(
            int sectionId, int fromDay, int tenantId, int schoolId, int actionUserId);
    }
}
