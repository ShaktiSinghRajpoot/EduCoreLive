using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Assign a class teacher to each section; also gates who may mark attendance.</summary>
    public interface IClassTeacherService
    {
        /// <summary>All class-sections for the current year with teacher + load.</summary>
        Task<List<ClassTeacherSection>> GetGridAsync(int tenantId, int schoolId, int actionUserId);

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
