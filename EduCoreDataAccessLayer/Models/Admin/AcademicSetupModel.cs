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

        public List<string> Classes { get; set; } = new();

        public Dictionary<string, List<string>> ClassSections { get; set; } = new();
        //public List<DropdownItem> AcademicYear { get; set; } = new();
        public List<SelectListItem> AcademicYears { get; set; }
    }

    public class AcademicClassJsonModel
    {
        public string ClassName { get; set; } = string.Empty;
        public List<string> Sections { get; set; } = new();
    }
}