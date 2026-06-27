using EduCoreDataAccessLayer.Models;

namespace EduCoreDataAccessLayer.Services.Contract.Admin
{
    public interface IStaffService
    {
        Task<List<StaffListItem>> GetStaffAsync(
            int tenantId, int schoolId, int actionUserId,
            string? search = null, string? statusFilter = null);

        Task<StaffModel?> GetStaffByIdAsync(int staffId, int tenantId, int schoolId, int actionUserId);

        /// <summary>INSERT or UPDATE. <paramref name="passwordHash"/> is the BCrypt hash of
        /// the new login's password (only when model.CreateLogin); pass null otherwise.</summary>
        Task<(int StaffId, string Message)> SaveStaffAsync(
            StaffModel model, string operation, string? passwordHash,
            int tenantId, int schoolId, int actionUserId);

        Task<(int StaffId, string Message)> DeactivateAsync(int staffId, int tenantId, int schoolId, int actionUserId);
        Task<(int StaffId, string Message)> ReactivateAsync(int staffId, int tenantId, int schoolId, int actionUserId);

        Task<StaffDropdowns> GetDropdownsAsync(int tenantId, int schoolId);
    }
}
