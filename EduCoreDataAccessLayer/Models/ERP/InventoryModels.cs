namespace EduCoreDataAccessLayer.Models.ERP
{
    // ── Items ───────────────────────────────────────────────────────────────
    public class InventoryItem
    {
        public int     ItemId       { get; set; }
        public string  ItemName     { get; set; } = string.Empty;
        public string  Sku          { get; set; } = string.Empty;
        public string  Category     { get; set; } = string.Empty;
        public string  SubCategory  { get; set; } = string.Empty;
        public string  ItemType     { get; set; } = "Consumable";
        public string  UnitType     { get; set; } = "Piece";
        public decimal CurrentStock { get; set; }
        public decimal MinStock     { get; set; }
        public decimal CostPrice    { get; set; }
        public decimal SellingPrice { get; set; }
        public string  Brand        { get; set; } = string.Empty;
        public string  Model        { get; set; } = string.Empty;
        public string  Description  { get; set; } = string.Empty;

        /// CurrentStock x CostPrice, computed in the proc.
        public decimal StockValue   { get; set; }

        /// Derived in the proc from CurrentStock against MinStock, never stored —
        /// so it can never disagree with the quantity shown beside it.
        public string  StockStatus  { get; set; } = string.Empty;
        public bool    IsActive     { get; set; }
    }

    /// What the Add/Edit item form posts.
    public class InventoryItemInput
    {
        public int     ItemId       { get; set; }
        public string  ItemName     { get; set; } = string.Empty;
        public string? Sku          { get; set; }
        public string? Category     { get; set; }
        public string? SubCategory  { get; set; }
        public string  ItemType     { get; set; } = "Consumable";
        public string  UnitType     { get; set; } = "Piece";

        /// Only used when creating. An edit never moves stock — that goes through
        /// a movement, so an edit screen cannot silently invent inventory.
        public decimal OpeningStock { get; set; }
        public decimal MinStock     { get; set; }
        public decimal CostPrice    { get; set; }
        public decimal SellingPrice { get; set; }
        public string? Brand        { get; set; }
        public string? Model        { get; set; }
        public string? Description  { get; set; }
        public bool    IsActive     { get; set; } = true;
    }

    // ── Stock movement ──────────────────────────────────────────────────────
    public class StockMovement
    {
        public int      MovementId   { get; set; }
        public DateOnly MovementDate { get; set; }
        public string   MovementType { get; set; } = string.Empty;

        /// Signed: positive came in, negative went out.
        public decimal  Quantity     { get; set; }
        public decimal  BalanceAfter { get; set; }
        public string   IssuedTo     { get; set; } = string.Empty;
        public string   Remarks      { get; set; } = string.Empty;
        public int      ReferenceId  { get; set; }
    }

    public class StockMovementInput
    {
        public int     ItemId       { get; set; }
        public string  MovementType { get; set; } = string.Empty;   // Issue|Return|Damage|Adjustment
        public decimal Quantity     { get; set; }
        public string? IssuedTo     { get; set; }
        public string? Remarks      { get; set; }
    }

    // ── Suppliers ───────────────────────────────────────────────────────────
    public class InventorySupplier
    {
        public int     SupplierId    { get; set; }
        public string  SupplierName  { get; set; } = string.Empty;
        public string  ContactPerson { get; set; } = string.Empty;
        public string  Mobile        { get; set; } = string.Empty;
        public string  Email         { get; set; } = string.Empty;
        public string  Address       { get; set; } = string.Empty;
        public string  Gstin         { get; set; } = string.Empty;
        public bool    IsActive      { get; set; }
    }

    // ── Purchases ───────────────────────────────────────────────────────────
    public class PurchaseListItem
    {
        public int      PurchaseId   { get; set; }
        public DateOnly PurchaseDate { get; set; }
        public string   SupplierName { get; set; } = string.Empty;
        public string   InvoiceNo    { get; set; } = string.Empty;
        public string   PaymentMode  { get; set; } = string.Empty;
        public decimal  SubTotal     { get; set; }
        public decimal  TaxTotal     { get; set; }
        public decimal  GrandTotal   { get; set; }
        public bool     IsCancelled  { get; set; }
        public int      LineCount    { get; set; }
    }

    public class PurchaseLine
    {
        public int     ItemId     { get; set; }
        public string  ItemName   { get; set; } = string.Empty;
        public decimal Quantity   { get; set; }
        public decimal UnitPrice  { get; set; }
        public decimal TaxPercent { get; set; }
        public decimal LineTotal  { get; set; }
    }

    public class PurchaseDetail
    {
        public int      PurchaseId   { get; set; }
        public DateOnly PurchaseDate { get; set; }
        public int?     SupplierId   { get; set; }
        public string   SupplierName { get; set; } = string.Empty;
        public string   InvoiceNo    { get; set; } = string.Empty;
        public string   PaymentMode  { get; set; } = string.Empty;
        public string   Remarks      { get; set; } = string.Empty;
        public decimal  SubTotal     { get; set; }
        public decimal  TaxTotal     { get; set; }
        public decimal  GrandTotal   { get; set; }
        public bool     IsCancelled  { get; set; }
        public string   CancelReason { get; set; } = string.Empty;
        public List<PurchaseLine> Lines { get; set; } = new();
    }

    /// What the purchase form posts.
    public class PurchaseInput
    {
        public int?      SupplierId   { get; set; }
        public DateOnly? PurchaseDate { get; set; }
        public string?   InvoiceNo    { get; set; }
        public string?   PaymentMode  { get; set; }
        public string?   Remarks      { get; set; }
        public List<PurchaseLineInput> Items { get; set; } = new();
    }

    public class PurchaseLineInput
    {
        public int     ItemId     { get; set; }
        public decimal Quantity   { get; set; }
        public decimal UnitPrice  { get; set; }
        public decimal TaxPercent { get; set; }
    }

    // ── Shared ──────────────────────────────────────────────────────────────
    public class InventoryResult
    {
        public bool    Success      { get; set; }
        public string  Message      { get; set; } = string.Empty;
        public int     Id           { get; set; }
        public decimal CurrentStock { get; set; }
        public decimal GrandTotal   { get; set; }
    }

}
