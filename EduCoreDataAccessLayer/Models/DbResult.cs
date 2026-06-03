namespace educore.Models
{
    public class DbResult
    {
        public bool Success { get; set; }
        public string Message { get; set; } = "";
        public int? SchoolId { get; set; }
    }
}
