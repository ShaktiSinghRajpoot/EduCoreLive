using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Parent module, Phase 1 (view only). Procs in Database/parent_module.sql.
    /// A parent has no user id: the parent calls are keyed on the mobile, and every
    /// child's data is read with that child's own tenant and school ids.
    /// </summary>
    public interface IParentService
    {
        /// <summary>The children this mobile may see right now (empty = none).</summary>
        Task<List<ParentChild>> GetChildrenAsync(string mobile);

        /// <summary>Store a new code (hash) for the mobile. Status OK or LOCKED.</summary>
        Task<ParentCodeResult> IssueCodeAsync(string mobile, string codeHash);

        /// <summary>Check a code: OK / INVALID / EXPIRED / LOCKED.</summary>
        Task<ParentCodeResult> VerifyCodeAsync(string mobile, string codeHash);

        /// <summary>Audit row: LOGIN / RECEIPT_VIEW / REPORT_CARD_VIEW.</summary>
        Task LogAsync(int tenantId, int schoolId, int studentId, string mobile, string action, string? detail);

        /// <summary>Notices for parents: to everyone, to parents, or to the child's class.</summary>
        Task<List<ParentNotice>> GetNoticesAsync(int tenantId, int schoolId, string? className);

        // ── school staff ──
        Task<List<ParentAccessMobile>> GetAccessAsync(int studentId, int tenantId, int schoolId, int actionUserId);
        Task<List<ParentAccessMobile>> SetBlockedAsync(int studentId, string mobile, bool block, int tenantId, int schoolId, int actionUserId);
        Task<ParentLoginReport> GetLoginReportAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Modules &amp; Workflow: the school's Parent App switch and parent screens.</summary>
        Task SaveSchoolSettingsAsync(AdmissionWorkflowModel model, int tenantId, int schoolId, int actionUserId);

        // ── Super Admin ──
        Task<(bool Allow, bool Enable)> GetPlatformAsync(int schoolId, int actionUserId);
        Task SavePlatformAsync(int schoolId, bool allow, int actionUserId);
    }
}
