namespace EduCoreDataAccessLayer.Models.ERP
{
    // Books & uniform sold to a student (inventory_student_sale.sql).

    /// <summary>An item the store sells, with its stock and the class set's quantity.</summary>
    public class SaleItem
    {
        public int     ItemId       { get; set; }
        public string  ItemName     { get; set; } = string.Empty;
        public string  Category     { get; set; } = string.Empty;
        public string  UnitType     { get; set; } = "Piece";
        public decimal SellingPrice { get; set; }
        public decimal InStock      { get; set; }
        public decimal KitQty       { get; set; }   // 1 = can be ticked for the class (0 for an item sold in sizes)
        public string? ForClass     { get; set; }   // null = every class
    }

    /// <summary>The child's class in this session and any later one (promoted early).</summary>
    public class SaleSession
    {
        public string  AcademicYear { get; set; } = string.Empty;
        public string  ClassName    { get; set; } = string.Empty;
        public string? Section      { get; set; }
        public bool    IsCurrent    { get; set; }
    }

    public class SaleStudent
    {
        public int     StudentId   { get; set; }
        public string  StudentName { get; set; } = string.Empty;
        public string? AdmissionNo { get; set; }
        public List<SaleSession> Sessions { get; set; } = new();
    }

    public class SaleLineInput
    {
        public int     ItemId { get; set; }
        public decimal Qty    { get; set; }
    }

    /// <summary>What the store bought and sold of saleable items in a date range (sp_inventory_store_summary).</summary>
    public class StoreSummary
    {
        public decimal Bought     { get; set; }   // purchase bills, less supplier returns
        public decimal Sold       { get; set; }   // charged to students, not returned
        public decimal CostOfSold { get; set; }   // those items at the cost they left the shelf at
        public decimal Collected  { get; set; }   // paid so far of what was sold
        public decimal Unpaid     { get; set; }
        public decimal StockValue { get; set; }   // saleable stock on hand now, at cost
    }

    /// <summary>Books & Uniform Register: a class's children, the item columns, and who holds what.</summary>
    public class StoreRegister
    {
        public List<StoreRegisterStudent> Students { get; set; } = new();
        public List<SaleItem>             Items    { get; set; } = new();   // only ItemId / ItemName / Category filled
        public List<StoreRegisterHeld>    Held     { get; set; } = new();
    }

    public class StoreRegisterStudent
    {
        public int     StudentId   { get; set; }
        public string  StudentName { get; set; } = string.Empty;
        public string? AdmissionNo { get; set; }
        public string? Section     { get; set; }
        public string? RollNo      { get; set; }
    }

    public class StoreRegisterHeld
    {
        public int     StudentId { get; set; }
        public int     ItemId    { get; set; }
        public decimal Quantity  { get; set; }   // sold minus returned, this session
        public decimal Unpaid    { get; set; }
    }

    /// <summary>One line of a sale, for the sales list (paid or not, returned or not).</summary>
    public class StudentSaleRow
    {
        public int     LineId       { get; set; }
        public int     SaleId       { get; set; }
        public string? SaleDate     { get; set; }
        public int     StudentId    { get; set; }
        public string  StudentName  { get; set; } = string.Empty;
        public string? AdmissionNo  { get; set; }
        public string? ClassName    { get; set; }
        public string? AcademicYear { get; set; }
        public string  ItemName     { get; set; } = string.Empty;
        public decimal Quantity     { get; set; }
        public decimal Amount       { get; set; }
        public decimal Paid         { get; set; }
        public decimal OpenAmount   { get; set; }
        public bool    Returned     { get; set; }
        public string? ReturnReason { get; set; }
        public string? SoldBy       { get; set; }
    }
}
