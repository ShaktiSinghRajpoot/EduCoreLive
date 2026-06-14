using educore.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EduCoreDataAccessLayer.Models.Admin
{
    public class AcademicSetupModel
    {
        public string Operation { get; set; } = string.Empty;

        public int TenantId { get; set; }
        public int SchoolId { get; set; }

        public int AcademicYearId { get; set; }
        public string AcademicYearName { get; set; } = string.Empty;

        public DateTime? StartDate { get; set; }
        public DateTime? EndDate { get; set; }

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
        public DateTime? StartDate { get; set; }
        public DateTime? EndDate { get; set; }
        public bool IsCurrent { get; set; }
        public int ClassCount { get; set; }
        public int StudentCount { get; set; }
    }
}