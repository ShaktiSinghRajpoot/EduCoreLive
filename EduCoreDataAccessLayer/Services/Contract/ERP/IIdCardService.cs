using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Reads the students that go onto an ID-card sheet (live, not frozen).</summary>
    public interface IIdCardService
    {
        /// <summary>Active students of a class (section optional) for the bulk card sheet.</summary>
        Task<List<IdCardStudent>> GetClassCardsAsync(
            string className, string? section, string? academicYear,
            int tenantId, int schoolId, int actionUserId);

        /// <summary>A single student's card data (from the directory / dashboard).</summary>
        Task<IdCardStudent?> GetOneAsync(int studentId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Sections that actually have active students in a class — feeds the
        /// chooser's Section dropdown.</summary>
        Task<List<string>> GetClassSectionsAsync(
            string className, string? academicYear, int tenantId, int schoolId, int actionUserId);
    }
}
