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
        public decimal KitQty       { get; set; }   // 0 = not in the chosen class's set
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
