using EduCoreDataAccessLayer.Models;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    public interface IStaffService
    {
        Task<List<StaffListItem>> GetStaffAsync(
            int tenantId, int schoolId, int actionUserId,
            string? search = null, string? statusFilter = null);

        // Fat-model list page: one StaffListItem carries filters/sort/page in and
        // is filled with Items + TotalCount. Backs Staff/StaffList (server-side).
        Task<StaffListItem> GetStaffListPageAsync(
            StaffListItem query, int tenantId, int schoolId, int actionUserId);

        Task<StaffModel?> GetStaffByIdAsync(int staffId, int tenantId, int schoolId, int actionUserId);

        /// <summary>INSERT or UPDATE. <paramref name="passwordHash"/> is the BCrypt hash of
        /// the new login's password (only when model.CreateLogin); pass null otherwise.</summary>
        Task<(int StaffId, string Message)> SaveStaffAsync(
            StaffModel model, string operation, string? passwordHash,
            int tenantId, int schoolId, int actionUserId);

        Task<(int StaffId, string Message)> DeactivateAsync(int staffId, int tenantId, int schoolId, int actionUserId);
        Task<(int StaffId, string Message)> ReactivateAsync(int staffId, int tenantId, int schoolId, int actionUserId);

        Task<StaffDropdowns> GetDropdownsAsync(int tenantId, int schoolId);

        // ── Staff reference masters (Departments + Designations) ──
        Task<StaffMasters> GetMastersAsync(int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> SaveDepartmentAsync(DepartmentMaster dept, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> SaveDesignationAsync(DesignationMaster desig, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> DeleteMasterAsync(string kind, int id, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> ToggleMasterAsync(string kind, int id, int tenantId, int schoolId, int actionUserId);
    }
}
