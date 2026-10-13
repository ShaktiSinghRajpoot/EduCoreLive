using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Homework (homework.sql). canManage = the caller may manage academics.</summary>
    public interface IHomeworkService
    {
        /// <summary>from / to filter the day it was given (yyyy-MM-dd); mine = only the caller's homework.</summary>
        Task<List<Homework>> GetListAsync(int? sectionId, string? from, string? to, bool mine, bool canManage,
                                          int tenantId, int schoolId, int actionUserId);

        /// <summary>New when h.Id is 0, otherwise an edit.</summary>
        Task<(bool Success, string Message)> SaveAsync(Homework h, bool canManage, int tenantId, int schoolId, int actionUserId);

        Task<(bool Success, string Message)> DeleteAsync(int id, bool canManage, int tenantId, int schoolId, int actionUserId);

        Task<List<HomeworkStudent>> GetStudentsAsync(int id, bool canManage, int tenantId, int schoolId, int actionUserId);

        /// <summary>Save who did it. A blank status clears that student's mark.</summary>
        Task<(bool Success, string Message)> CheckAsync(int id, List<HomeworkStudent> marks, bool canManage,
                                                        int tenantId, int schoolId, int actionUserId);

        /// <summary>One student's homework of the last 30 days, with their status (Student Dashboard).</summary>
        Task<List<Homework>> GetForStudentAsync(int studentId, int tenantId, int schoolId, int actionUserId);
    }
}
