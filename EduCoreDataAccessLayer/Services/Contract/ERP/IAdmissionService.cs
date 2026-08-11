using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    public interface IAdmissionService
    {
        // Save a new admission. Freezes the fee plan, generates the ledger,
        // writes audit, and (when EnquiryId is set) links + closes the enquiry.
        Task<AdmissionSaveResult> SaveAdmissionAsync(
            AdmissionModel model, int tenantId, int schoolId, int actionUserId,
            decimal concessionCap = 100000m);

        // Server-side filtered + paginated student list.
        Task<(List<StudentListModel> Items, int TotalCount)> GetStudentsAsync(
            int     tenantId,
            int     schoolId,
            int     actionUserId,
            int     pageNumber    = 1,
            int     pageSize      = 10,
            string? search        = null,
            string? filterClass   = null,
            string? filterSection = null,
            string? filterGender  = null,
            string? filterYear    = null,
            string? filterStatus  = null);

        // Fat-model list page: one StudentListModel carries the filters/sort/page
        // in and is filled with Items + TotalCount + summary tile counts. Backs
        // Student/StudentList (server-side paging + whitelisted sorting).
        Task<StudentListModel> GetStudentListPageAsync(
            StudentListModel query, int tenantId, int schoolId, int actionUserId);

        Task<AdmissionModel?> GetStudentByIdAsync(int studentId, int tenantId, int schoolId, int actionUserId);

        Task<int> DeleteStudentAsync(int studentId, int tenantId, int schoolId, int actionUserId);

        // ── Student exit (backs Student/Inactive, and the TC module on top of it) ──

        /// <summary>Marks a student as having left. Dues do not block it — they are reported.</summary>
        Task<StudentExitResult> ExitStudentAsync(
            StudentExitRequest request, int tenantId, int schoolId, int actionUserId);

        /// <summary>Undoes an exit and puts the student back on the active roll.</summary>
        Task<StudentExitResult> UndoStudentExitAsync(
            int studentId, int tenantId, int schoolId, int actionUserId);

        Task<StudentExitListModel> GetStudentExitListAsync(
            StudentExitListModel query, int tenantId, int schoolId, int actionUserId);

        /// <summary>Sets (or clears) a student's photo URL after the file is saved.</summary>
        Task<(bool Success, string Message, string? PhotoUrl)> SetStudentPhotoAsync(
            int studentId, string? photoUrl, int tenantId, int schoolId, int actionUserId);

        /// <summary>Sections that have active students in a class (for cascading dropdowns).</summary>
        Task<List<string>> GetClassSectionsAsync(string className, int tenantId, int schoolId, int actionUserId);

        // ── Promotion (backs Student/Promotion) ──

        /// <summary>The school's classes in teaching order — the ladder promotion walks up.</summary>
        Task<List<string>> GetClassLadderAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Bulk promote/retain/pass out. Students that cannot move are reported, not fatal.</summary>
        Task<StudentPromotionResult> PromoteStudentsAsync(
            StudentPromotionRequest request, int tenantId, int schoolId, int actionUserId);
    }
}
