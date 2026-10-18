namespace EduCoreDataAccessLayer.Models.ERP
{
    // Expenses and the Cash Book (expense_cashbook.sql).

    public class ExpenseCategory
    {
        public int    CategoryId { get; set; }
        public string Name       { get; set; } = string.Empty;
        public bool   IsActive   { get; set; }
        public int    Used       { get; set; }   // expenses under it (not cancelled)
    }

    public class ExpenseRow
    {
        public int      ExpenseId    { get; set; }
        public string   ExpenseDate  { get; set; } = string.Empty;   // yyyy-MM-dd
        public int      CategoryId   { get; set; }
        public string   Category     { get; set; } = string.Empty;
        public decimal  Amount       { get; set; }
        public string   PaymentMode  { get; set; } = "Cash";
        public string?  PaidTo       { get; set; }
        public string?  ReferenceNo  { get; set; }
        public string?  Remarks      { get; set; }
        public bool     IsCancelled  { get; set; }
        public string?  CancelReason { get; set; }
        public string?  CancelledBy  { get; set; }
        public string?  CancelledAt  { get; set; }
        public string?  CreatedBy    { get; set; }
        public string?  CreatedAt    { get; set; }
    }

    public class ExpenseInput
    {
        public string  ExpenseDate { get; set; } = string.Empty;   // yyyy-MM-dd
        public int     CategoryId  { get; set; }
        public decimal Amount      { get; set; }
        public string? PaymentMode { get; set; }
        public string? PaidTo      { get; set; }
        public string? ReferenceNo { get; set; }
        public string? Remarks     { get; set; }
    }

    public class CashbookOpening
    {
        public string? AsOn      { get; set; }
        public decimal Cash      { get; set; }
        public decimal Bank      { get; set; }
        public string? UpdatedBy { get; set; }
        public string? UpdatedAt { get; set; }
    }

    public class CashbookLine
    {
        public string  LineDate { get; set; } = string.Empty;
        public string  Kind     { get; set; } = string.Empty;   // Fee receipt | Refund | Salary | Purchase | Expense ...
        public string? Ref      { get; set; }
        public string? Detail   { get; set; }
        public string  Category { get; set; } = string.Empty;
        public string? Mode     { get; set; }
        public decimal MoneyIn  { get; set; }
        public decimal MoneyOut { get; set; }
        public decimal Balance  { get; set; }
    }

    public class CashbookHead
    {
        public string  Category { get; set; } = string.Empty;
        public decimal MoneyIn  { get; set; }
        public decimal MoneyOut { get; set; }
        public int     Entries  { get; set; }
    }

    public class CashbookMonth
    {
        public string  Month    { get; set; } = string.Empty;   // yyyy-MM
        public decimal MoneyIn  { get; set; }
        public decimal MoneyOut { get; set; }
        public decimal Net      { get; set; }
    }

    public class Cashbook
    {
        public string?  BookFrom    { get; set; }   // the range's start, or the opening date when later
        public string?  OpeningAsOn { get; set; }
        public decimal  Opening     { get; set; }
        public decimal  MoneyIn     { get; set; }
        public decimal  MoneyOut    { get; set; }
        public decimal  Closing     { get; set; }
        public List<CashbookLine>  Lines  { get; set; } = new();
        public List<CashbookHead>  Heads  { get; set; } = new();
        public List<CashbookMonth> Months { get; set; } = new();
    }

    public class ExpenseResult
    {
        public bool   Success { get; set; }
        public string Message { get; set; } = string.Empty;
        public int    Id      { get; set; }
    }
}
