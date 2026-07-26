using educore.Models;

namespace EduCoreDataAccessLayer.Services.Contract.SuperAdmin
{
    public interface ISchoolService
    {
        Task<(List<SchoolListModel> Rows, int TotalCount, int ActiveCount)> GetSchoolsAsync(
            int tenantId, int actionUserId,
            string? search, string? city, string? state,
            int? statusId, int? boardId, int? schoolTypeId,
            DateTime? fromDate, DateTime? toDate,
            int pageNo, int pageSize);
        Task<int> CreateSchoolAsync(SchoolManageModel model, int tenantId, int actionUserId);
        Task<int> SaveSchoolAsync(SchoolManageModel model, int tenantId, int actionUserId);
        Task<SchoolManageModel?> GetSchoolByIdAsync(int schoolId, int tenantId, int actionUserId);
        // DeleteSchoolAsync (soft delete) removed — it stranded schools: is_deleted hid
        // them from the list and from Edit, so they could never be Closed or Purged.
        // Ending a school is now status = Closed; Purge removes it permanently.
        Task<SchoolDropdownModel> GetSchoolDropdownsAsync();

        /// <summary>
        /// True when the email already belongs to an active login user. Backed by the same
        /// guard the save path uses (core.fn_user_email_taken), so the wizard's live hint and
        /// the eventual save can never disagree.
        /// <paramref name="excludeUserId"/> is the admin being edited, who must not clash
        /// with themselves.
        /// </summary>
        Task<bool> IsEmailTakenAsync(string email, int? excludeUserId = null);

        /// <summary>
        /// Everything stored for a school, as JSON. READ-ONLY — call this before
        /// <see cref="PurgeSchoolAsync"/> and write the result to disk; the purge is
        /// irreversible, so the archive must exist first.
        /// </summary>
        Task<SchoolArchiveModel?> ArchiveSchoolAsync(int schoolId, int tenantId);

        /// <summary>
        /// Permanently deletes a school and every row belonging to it, in one transaction.
        /// The proc refuses unless the caller is the platform admin, the school is already
        /// Closed, and <paramref name="confirmName"/> matches the school name exactly.
        /// There is no undo.
        /// </summary>
        Task PurgeSchoolAsync(int schoolId, int tenantId, int actionUserId, string confirmName);
    }
}
