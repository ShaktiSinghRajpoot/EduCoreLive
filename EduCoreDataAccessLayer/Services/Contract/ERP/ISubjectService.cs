using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>The school's subject master and which subjects each class studies.</summary>
    public interface ISubjectService
    {
        /// <summary>Classes of the current academic year, each with its subject count.</summary>
        Task<List<SubjectClassItem>> GetClassesAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Subjects mapped to one class, in display order.</summary>
        Task<List<SubjectItem>> GetClassSubjectsAsync(
            int academicClassId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Every subject the school uses — the timetable's dropdown source.</summary>
        Task<List<SubjectItem>> GetSubjectMasterAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Replace a class's subject list. Unknown names are added to the master.</summary>
        Task<SubjectSaveResult> SaveClassSubjectsAsync(
            int academicClassId, List<string> subjectNames, int tenantId, int schoolId, int actionUserId);
    }
}
