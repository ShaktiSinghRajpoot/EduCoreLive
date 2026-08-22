using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Exam schedules and marks. An exam is school-wide for one academic year; the
    /// classes sitting it — and each class's subjects, dates and marks scale — live
    /// on the datesheet. Subjects come from Subject Management, so read them
    /// through <see cref="ISubjectService"/>.
    /// </summary>
    public interface IExamService
    {
        /// <summary>This year's exams, plus the academic year they belong to.</summary>
        Task<ExamListData> GetExamsAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>One exam with every class's datesheet — the edit form. Null if not found.</summary>
        Task<ExamDetail?> GetExamAsync(int examId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Create (ExamId 0) or update an exam. Replaces each class's datesheet.</summary>
        Task<ExamSaveResult> SaveExamAsync(ExamSaveRequest request, int tenantId, int schoolId, int actionUserId);

        /// <summary>Soft-delete an exam.</summary>
        Task<ExamSaveResult> DeleteExamAsync(int examId, int tenantId, int schoolId, int actionUserId);

        /// <summary>What each class sits and when, in date order. classId/examId 0 = all.</summary>
        Task<ExamDatesheetData> GetDatesheetAsync(
            int academicClassId, int examId, int tenantId, int schoolId, int actionUserId);

        // ── Marks Entry: a SHEET is one (exam, class, section, subject) ──

        /// <summary>The classes an exam covers — the Class dropdown.</summary>
        Task<List<ExamClassOption>> GetExamClassesAsync(
            int examId, int tenantId, int schoolId, int actionUserId);

        /// <summary>That class's datesheet plus the sections that have students.</summary>
        Task<ExamSheetSetup> GetClassSetupAsync(
            int examId, int academicClassId, int tenantId, int schoolId, int actionUserId);

        /// <summary>One sheet's roster, marks so far, scale and lock state. Null if not found.</summary>
        Task<ExamSheet?> GetSheetAsync(
            int examId, int academicClassId, int subjectId, string? section,
            int tenantId, int schoolId, int actionUserId);

        /// <summary>Save a sheet as draft, or finalize it (unmarked students become Absent).</summary>
        Task<ExamMarksSaveResult> SaveMarksAsync(
            ExamMarksSaveRequest request, int tenantId, int schoolId, int actionUserId);

        /// <summary>Unlock a finalized sheet. Callers must restrict this to school admins.</summary>
        Task<ExamMarksSaveResult> ReopenSheetAsync(
            int examId, int academicClassId, int subjectId, string? section,
            int tenantId, int schoolId, int actionUserId);
    }
}
