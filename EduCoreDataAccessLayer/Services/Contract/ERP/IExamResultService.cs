using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Exam results: the school's grade scale, publishing an exam's results (which
    /// locks its marks), and the class result sheet with grades and ranks.
    /// Marks themselves are entered through <see cref="IExamService"/>.
    /// </summary>
    public interface IExamResultService
    {
        /// <summary>The school's grade bands, or the CBSE default when it has none.</summary>
        Task<GradeScale> GetGradeScaleAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Replace the school's grade bands (must cover 0-100, no overlap, unique labels).</summary>
        Task<ExamResultActionResult> SaveGradeScaleAsync(
            GradeScaleSaveRequest request, int tenantId, int schoolId, int actionUserId);

        /// <summary>Drop the school's own bands, back to the CBSE default.</summary>
        Task<ExamResultActionResult> ResetGradeScaleAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Published or not, the sheets still to finalise, and the publish log. Null if not found.</summary>
        Task<ExamResultStatus?> GetResultStatusAsync(int examId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Publish an exam's results. Refused while any mark sheet is not finalised.</summary>
        Task<ExamResultActionResult> PublishResultsAsync(int examId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Pull published results back (a reason is required and logged).</summary>
        Task<ExamResultActionResult> UnpublishResultsAsync(
            int examId, string? reason, int tenantId, int schoolId, int actionUserId);

        /// <summary>One exam, one class (optionally one section): marks, totals, grades, ranks.</summary>
        Task<ClassResultSheet?> GetClassResultAsync(
            int examId, int academicClassId, string? section, int tenantId, int schoolId, int actionUserId);
    }
}
