using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Assign a class teacher to each section; also gates who may mark attendance.</summary>
    public interface IClassTeacherService
    {
        /// <summary>
        /// All class-sections of one session with teacher + load.
        /// academicYearId 0 = the current session.
        /// </summary>
        Task<List<ClassTeacherSection>> GetGridAsync(
            int tenantId, int schoolId, int actionUserId, int academicYearId = 0);

        /// <summary>Staff who can be class teachers.</summary>
        Task<List<ClassTeacherOption>> GetTeachersAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Assign (or clear, staffId 0/null) a section's class teacher.</summary>
        Task<(bool Success, string Message)> AssignAsync(
            int sectionId, int? staffId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Is this user the class teacher of the given class-section?</summary>
        Task<bool> IsClassTeacherAsync(
            string className, string? section, int tenantId, int schoolId, int userId);

        /// <summary>
        /// Is this user standing in for the section's class teacher on that date?
        /// True when the class teacher is away and the user takes a period there that
        /// day (timetable or substitute). ClassTeacher is the absent teacher's name.
        /// </summary>
        Task<(bool IsActing, string? ClassTeacher)> IsActingClassTeacherAsync(
            string className, string? section, string date, int tenantId, int schoolId, int userId);

        /// <summary>
        /// Sections someone is the class teacher of in the current session.
        /// staffId null = the signed-in user's own staff record. cached = true for the
        /// profile menu (5 min); the dashboard reads it fresh (today's attendance).
        /// </summary>
        Task<List<MyClassSection>> GetClassesOfAsync(int tenantId, int schoolId, int userId,
                                                     int? staffId = null, bool cached = false);
    }
}
