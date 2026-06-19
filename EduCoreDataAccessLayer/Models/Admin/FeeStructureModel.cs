namespace EduCoreDataAccessLayer.Models.Admin
{
    public class FeeStructureModel
    {
        public string Operation { get; set; } = string.Empty;
        public int TenantId { get; set; }
        public int SchoolId { get; set; }
        public int FeeStructureId { get; set; }
        public string ClassName { get; set; } = string.Empty;
        public string AcademicYear { get; set; } = string.Empty;
        public decimal OneTimeTotal { get; set; }
        public decimal MonthlyTotal { get; set; }
        public decimal YearlyTotal { get; set; }
        public decimal AnnualTotal { get; set; }
        public bool IsActive { get; set; } = true;
        public string FeeHeadNames { get; set; } = string.Empty;
        public int CreatedBy { get; set; }
        public int UpdatedBy { get; set; }
        public DateTime? UpdatedAt { get; set; }

        public List<string> SelectedClasses { get; set; } = new List<string>();
        public List<FeeStructureDetailModel> FeeHeads { get; set; } = new List<FeeStructureDetailModel>();

        // Page-level data (GET only, not posted back)
        public List<string> AvailableClasses { get; set; } = new List<string>();
        public List<string> AcademicYears { get; set; } = new List<string>();
        public List<FeeStructureModel> ExistingStructures { get; set; } = new List<FeeStructureModel>();
    }

    public class FeeStructureDetailModel
    {
        public int FeeStructureDetailId { get; set; }
        public int TenantId { get; set; }
        public int SchoolId { get; set; }
        public int FeeStructureId { get; set; }
        public int FeeHeadId { get; set; }
        public string FeeHeadName { get; set; } = string.Empty;
        public string Frequency { get; set; } = string.Empty;
        public string FeeType { get; set; } = string.Empty;
        public string FeeGroup { get; set; } = string.Empty;
        public decimal Amount { get; set; }
        public bool IsSelected { get; set; }

        /// <summary>Lifecycle trigger inherited from the fee head master: Registration / Admission / Recurring.</summary>
        public string CollectionPoint { get; set; } = "Recurring";

        /// <summary>Refundable flag inherited from the fee head master (e.g. security deposit).</summary>
        public bool IsRefundable { get; set; }
    }
}