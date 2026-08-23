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
    }
}
