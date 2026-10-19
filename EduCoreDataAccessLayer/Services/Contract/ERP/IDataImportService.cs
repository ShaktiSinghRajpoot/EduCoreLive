namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// What School > Import Data needs beyond the normal admission and staff saves
    /// (data_import.sql): a child's balance from the school's old software.
    /// </summary>
    public interface IDataImportService
    {
        /// <summary>One "Previous Dues" line on the child with this admission number.</summary>
        Task<(bool Success, string Message)> AddOpeningDueAsync(string admissionNo, decimal amount, string? note,
                                                                 string? fromSession, int tenantId, int schoolId, int actionUserId);
    }
}
