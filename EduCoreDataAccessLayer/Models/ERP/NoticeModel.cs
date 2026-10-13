namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One announcement on the Notice Board (core.sp_announcement_manage).</summary>
    public class Notice
    {
        public int       Id          { get; set; }
        public string    Title       { get; set; } = string.Empty;
        public string    Body        { get; set; } = string.Empty;
        /// <summary>General, Circular, Holiday, Event, PTM, Exam, Fee.</summary>
        public string    Category    { get; set; } = "General";
        /// <summary>Everyone, Staff, Parents or Classes (then ClassNames lists them).</summary>
        public string    Audience    { get; set; } = "Everyone";
        public string?   ClassNames  { get; set; }
        public bool      IsPinned    { get; set; }
        /// <summary>yyyy-MM-dd; after it the notice leaves the board.</summary>
        public string?   ShowUntil   { get; set; }
        public DateTime? CreatedAt   { get; set; }
        public string?   PostedBy    { get; set; }
        public bool      IsRead      { get; set; }
        public int       SeenCount   { get; set; }
        public int       StaffCount  { get; set; }

        /// <summary>"Everyone", "Staff", "All parents" or "Parents of Class 5, 6".</summary>
        public string AudienceText => Audience switch
        {
            "Staff"   => "Staff",
            "Parents" => "All parents",
            "Classes" => "Parents of Class " + (ClassNames ?? "").Replace(",", ", "),
            _         => "Everyone"
        };
    }

    public class NoticeReader
    {
        public string    Name   { get; set; } = string.Empty;
        public DateTime? ReadAt { get; set; }
    }
}
