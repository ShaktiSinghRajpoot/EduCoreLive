namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Students › Data Checks (student_data_checks.sql).</summary>
    public interface IStudentDataCheckService
    {
        /// <summary>One row per check: issue, label, hint, severity, students, total.</summary>
        Task<List<Dictionary<string, object?>>> GetSummaryAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>The students failing one check.</summary>
        Task<List<Dictionary<string, object?>>> GetListAsync(string check, int tenantId, int schoolId, int actionUserId);

        /// <summary>mode "missing" fills students without a roll number; "all" renumbers the section by name.</summary>
        Task<(bool Success, string Message)> AssignRollsAsync(string className, string? section, string mode,
                                                              int tenantId, int schoolId, int actionUserId);
    }
}
