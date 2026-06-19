using educore.Models;
using EduCoreDataAccessLayer.Models.Admin;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace EduCoreDataAccessLayer.Services.Contract.Admin
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
