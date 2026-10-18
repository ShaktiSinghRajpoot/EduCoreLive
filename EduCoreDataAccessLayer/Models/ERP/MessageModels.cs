namespace EduCoreDataAccessLayer.Models.ERP
{
    // WhatsApp messages to parents (messaging.sql).

    /// <summary>One message to record, sent or not.</summary>
    public class MessageLogEntry
    {
        public string  AlertType   { get; set; } = string.Empty;   // Absent | FeeDue | Notice
        public int?    StudentId   { get; set; }
        public string? ToName      { get; set; }
        public string? ToPhone     { get; set; }
        public string? MessageText { get; set; }
        public string? Template    { get; set; }
        public string  Status      { get; set; } = "Test";          // Sent | Failed | Test | NoPhone
        public string? ProviderRef { get; set; }
        public string? Error       { get; set; }
    }

    public class MessageLogRow
    {
        public long    LogId       { get; set; }
        public string? SentAt      { get; set; }
        public string  AlertType   { get; set; } = string.Empty;
        public string? ToName      { get; set; }
        public string? ToPhone     { get; set; }
        public string? MessageText { get; set; }
        public string  Status      { get; set; } = string.Empty;
        public string? Error       { get; set; }
        public string? SentBy      { get; set; }
    }

    public class MessageSummary
    {
        public int Sent    { get; set; }
        public int Failed  { get; set; }
        public int Test    { get; set; }
        public int NoPhone { get; set; }
    }
}
