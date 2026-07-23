using educore.Models;
using EduCoreDataAccessLayer.Models.ERP;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    public interface ISchoolSettingsService
    {
        #region School Basic Profile
        Task<SchoolManageModel?> GetBasicProfileAsync(int tenantId, int schoolId, int actionUserId);
        Task<int> SaveBasicProfileAsync(SchoolManageModel model, int tenantId, int schoolId, int actionUserId);
        Task<SchoolDropdownModel> GetBasicProfileDropdownsAsync(int tenantId, int schoolId);
        #endregion

        #region Academic Setup
        Task<AcademicSetupModel?> GetAcademicSetupAsync(int tenantId, int schoolId, int academicYearId, int actionUserId);
        Task<int> SaveAcademicSetupAsync(AcademicSetupModel model, int tenantId, int schoolId, int actionUserId);
        #endregion

        #region Academic Year
        Task<List<AcademicYearModel>> GetAcademicYearsAsync(int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message, int Id)> SaveAcademicYearAsync(AcademicYearModel model, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> SetCurrentAcademicYearAsync(int academicYearId, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> DeleteAcademicYearAsync(int academicYearId, int tenantId, int schoolId, int actionUserId);
        #endregion

        #region Fee Head
        Task<List<FeeHead>> GetFeeHeadAsync(int tenantId, int schoolId, int actionUserId);
        // Server-side paged + sorted + searched listing. Takes the page model (Page,
        // PageSize, SortColumn, Search, FilterFrequency) and returns it with Items +
        // TotalCount filled — the "one model does everything" master pattern.
        Task<FeeHead> GetFeeHeadPageAsync(FeeHead query, int tenantId, int schoolId, int actionUserId);
        Task<FeeHead?> GetFeeHeadByIdAsync(int feeHeadId, int tenantId, int schoolId, int actionUserId);
        Task<int> SaveFeeHeadAsync(FeeHead model, int tenantId, int schoolId, int actionUserId);
        Task<int> DeleteFeeHeadAsync(int feeHeadId, int tenantId, int schoolId, int actionUserId);
        Task<int> ToggleFeeHeadStatusAsync(int feeHeadId, int tenantId, int schoolId, int actionUserId);
        #endregion

        #region MyRegion
        Task<List<FeeStructureModel>> GetFeeStructureAsync(
            int tenantId,
            int schoolId,
            int actionUserId
        );

        Task<FeeStructureModel?> GetFeeStructureByClassAsync(
            string className,
            string academicYear,
            int tenantId,
            int schoolId,
            int actionUserId
        );

        Task<List<FeeStructureDetailModel>> GetFeeStructureDetailsAsync(
            string className,
            string academicYear,
            int tenantId,
            int schoolId,
            int actionUserId
        );

        /// <summary>
        /// Sum of the configured fee-structure amounts for a class/year whose fee head
        /// Collection Point matches (e.g. "Registration" → the registration fee,
        /// "Admission" → one-time admission charges). Returns 0 when none configured.
        /// </summary>
        Task<decimal> GetCollectionPointTotalAsync(
            string className,
            string academicYear,
            string collectionPoint,
            int tenantId,
            int schoolId,
            int actionUserId
        );

        /// <summary>
        /// Total for a one-time collection point (Registration / Admission deposit),
        /// resolved for real use: a class-wise amount from the Fee Structure if the
        /// class defines one, else the flat fee-head DefaultAmount (how the simple /
        /// Workflow-Settings inline setup configures these). Registration especially is
        /// usually a flat school-level charge, set before a class is even final.
        /// </summary>
        /// <summary>
        /// The school's fee-receipt print format: "A4" (full page + letterhead),
        /// "A5" (compact, two per sheet) or "Thermal" (80mm counter printer).
        /// Defaults to A4 when never set.
        /// </summary>
        Task<string> GetReceiptFormatAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Saves the school's fee-receipt print format.</summary>
        Task<bool> SaveReceiptFormatAsync(string format, int tenantId, int schoolId, int actionUserId);

        /// <summary>The school's default Transfer Certificate format: "Standard" or
        /// "Simple". Defaults to Standard when never set.</summary>
        Task<string> GetTcFormatAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Saves the school's default Transfer Certificate format.</summary>
        Task<bool> SaveTcFormatAsync(string format, int tenantId, int schoolId, int actionUserId);

        /// <summary>The school's default student ID-card layout: "Portrait" or
        /// "Landscape". Defaults to Portrait when never set.</summary>
        Task<string> GetIdCardFormatAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Saves the school's default student ID-card layout.</summary>
        Task<bool> SaveIdCardFormatAsync(string format, int tenantId, int schoolId, int actionUserId);

        Task<decimal> GetCollectionPointResolvedTotalAsync(
            string className,
            string academicYear,
            string collectionPoint,
            int tenantId,
            int schoolId,
            int actionUserId,
            bool refundableOnly = false
        );

        Task<int> SaveFeeStructureAsync(
            FeeStructureModel model,
            int tenantId,
            int schoolId,
            int actionUserId
        );

        Task<int> DeleteFeeStructureAsync(
            int feeStructureId,
            int tenantId,
            int schoolId,
            int actionUserId
        );
        #endregion
    }
}
