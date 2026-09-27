using educore.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EduCoreDataAccessLayer.Models.ERP
{
    public class AcademicSetupModel
    {
        public string Operation { get; set; } = string.Empty;

        public int TenantId { get; set; }
        public int SchoolId { get; set; }

        public int AcademicYearId { get; set; }
        public string AcademicYearName { get; set; } = string.Empty;

        // ISO "yyyy-MM-dd" text, like every other date in the app. See Helpers/Dates.
        public string? StartDate { get; set; }
        public string? EndDate { get; set; }

        public bool IsCurrent { get; set; }

        // Kept for existing callers (FeeStructure, Admission) that only need names.
        public List<string> Classes { get; set; } = new();
        public Dictionary<string, List<string>> ClassSections { get; set; } = new();

        // Full per-class / per-section detail used by the Classes & Sections page.
        public List<AcademicClassDetail> ClassDetails { get; set; } = new();

        //public List<DropdownItem> AcademicYear { get; set; } = new();
        public List<SelectListItem> AcademicYears { get; set; }
    }

    public class AcademicClassDetail
    {
        public int AcademicClassId { get; set; }
        public string ClassName { get; set; } = string.Empty;
        public int DisplayOrder { get; set; }
        public string? Stream { get; set; }
        public string? Coordinator { get; set; }
        public int?    CoordinatorStaffId { get; set; }
        public List<AcademicSectionDetail> Sections { get; set; } = new();
    }

    public class AcademicSectionDetail
    {
        public int AcademicClassSectionId { get; set; }
        public string SectionName { get; set; } = string.Empty;
        public int DisplayOrder { get; set; }
        public int? Capacity { get; set; }
        public string? RoomNo { get; set; }
        public int Strength { get; set; }
        // Section-level class teacher (assigned on the Assign Class Teacher page).
        public int?    ClassTeacherStaffId { get; set; }
        public string? ClassTeacher        { get; set; }
    }

    public class AcademicClassJsonModel
    {
        public string ClassName { get; set; } = string.Empty;
        public List<string> Sections { get; set; } = new();
    }

    public class AcademicYearModel
    {
        public int AcademicYearId { get; set; }
        public string AcademicYearName { get; set; } = string.Empty;
        public string? StartDate { get; set; }
        public string? EndDate { get; set; }
        public bool IsCurrent { get; set; }

        /// <summary>
        /// When recurring (monthly / quarterly) fees start for a mid-session joiner:
        /// "AdmissionMonth" (default, real-world norm — only enrolled months) or
        /// "SessionStart" (the full session from April). It belongs to the session
        /// rather than the school: a student's fee plan is generated once, at
        /// admission, so a later change must not silently re-describe a session
        /// that was already billed the other way.
        /// </summary>
        public string ChargeFeesFrom { get; set; } = "AdmissionMonth";

        public int ClassCount { get; set; }
        public int StudentCount { get; set; }
    }
}