namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One line of the order list (sizes together): what a session still needs.</summary>
    public class OrderLine
    {
        public string  Item      { get; set; } = string.Empty;
        public string  Category  { get; set; } = string.Empty;
        public string  Unit      { get; set; } = string.Empty;
        public string  Classes   { get; set; } = string.Empty;   // "" = every class
        public int     Children  { get; set; }                   // enrolled in those classes
        public int     Have      { get; set; }                   // already given (not returned)
        public int     StillNeed { get; set; }
        public decimal InStock   { get; set; }
        public decimal ToOrder   { get; set; }
        public string  Sizes     { get; set; } = string.Empty;   // "24: 8 · 28: 9"
    }

    /// <summary>A payment to a supplier against credit bills.</summary>
    public class SupplierPayment
    {
        public int     PaymentId    { get; set; }
        public string? PayDate      { get; set; }
        public decimal Amount       { get; set; }
        public string  PaymentMode  { get; set; } = string.Empty;
        public string  ReferenceNo  { get; set; } = string.Empty;
        public string  Remarks      { get; set; } = string.Empty;
        public bool    IsCancelled  { get; set; }
        public string  CancelReason { get; set; } = string.Empty;
        public string? PaidBy       { get; set; }
    }
}
