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

        /// How many locations hold some of it.
        public int     LocationsHeld { get; set; }

        /// Opening stock entered with the item (no supplier, no bill).
        public decimal OpeningQty   { get; set; }
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

        /// Where the opening stock goes. Null = the default location.
        public int?    LocationId   { get; set; }

        /// Saleable items: which class it is for (null / "All" = every class).
        public string? ForClass     { get; set; }

        /// New saleable item only: "24, 28, 32" makes one item per size,
        /// named "<ItemName> - <size>", each with the opening stock above.
        public string? Sizes        { get; set; }
    }

    // ── Stock movement ──────────────────────────────────────────────────────
    public class StockMovement
    {
        public int      MovementId   { get; set; }
        public string MovementDate { get; set; }
        public string   MovementType { get; set; } = string.Empty;

        /// Signed: positive came in, negative went out.
        public decimal  Quantity     { get; set; }

        /// Stock at the moment this row was entered.
        public decimal  BalanceAfter { get; set; }

        /// Running total in the order the history is shown (date, then entry),
        /// so the column reads cleanly even around a back-dated bill.
        public decimal  Balance      { get; set; }

        /// What the movement is valued at: the bill's rate for a purchase, the
        /// item's cost price otherwise. Null on rows written before it was kept.
        public decimal? UnitRate     { get; set; }
        public string   CreatedBy    { get; set; } = string.Empty;
        public string   InvoiceNo    { get; set; } = string.Empty;
        public string   IssuedTo     { get; set; } = string.Empty;
        public string   Remarks      { get; set; } = string.Empty;
        public int      ReferenceId  { get; set; }

        public string   LocationName    { get; set; } = string.Empty;

        /// Running total at this row's location, in the same order as Balance.
        public decimal  LocationBalance { get; set; }

        /// For a transfer row: the location on the other side.
        public string   TransferWith    { get; set; } = string.Empty;
    }

    public class StockMovementInput
    {
        public int     ItemId       { get; set; }
        public string  MovementType { get; set; } = string.Empty;   // Issue|Return|Damage|Adjustment|StockTake

        /// For a StockTake this is the quantity COUNTED, not the difference.
        public decimal Quantity     { get; set; }
        public string? IssuedTo     { get; set; }
        public string? Remarks      { get; set; }

        /// Where it happens. Null = the default location.
        public int?    LocationId   { get; set; }
    }

    // ── Locations and transfers ─────────────────────────────────────────────
    public class InventoryLocation
    {
        public int     LocationId   { get; set; }
        public string  LocationName { get; set; } = string.Empty;
        public bool    IsDefault    { get; set; }
        public bool    IsActive     { get; set; }
        public int     ItemCount    { get; set; }
        public decimal TotalQty     { get; set; }
        public decimal StockValue   { get; set; }
    }

    /// One item's stock at one location.
    public class ItemLocationStock
    {
        public int     LocationId   { get; set; }
        public string  LocationName { get; set; } = string.Empty;
        public bool    IsDefault    { get; set; }
        public bool    IsActive     { get; set; }
        public decimal Quantity     { get; set; }
    }

    public class StockTransferInput
    {
        public int     ItemId         { get; set; }
        public int?    FromLocationId { get; set; }
        public int     ToLocationId   { get; set; }
        public decimal Quantity       { get; set; }
        public string? Reason         { get; set; }
    }

    public class StockTransfer
    {
        public int     TransferId   { get; set; }
        public string  TransferDate { get; set; } = string.Empty;
        public int     ItemId       { get; set; }
        public string  ItemName     { get; set; } = string.Empty;
        public string  UnitType     { get; set; } = string.Empty;
        public string  FromLocation { get; set; } = string.Empty;
        public string  ToLocation   { get; set; } = string.Empty;
        public decimal Quantity     { get; set; }
        public string  Reason       { get; set; } = string.Empty;
        public string  CreatedBy    { get; set; } = string.Empty;
        public string  CreatedAt    { get; set; } = string.Empty;
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

        // Read-only figures for the supplier screen (live bills only).
        public int     BillCount     { get; set; }
        public decimal TotalBilled   { get; set; }
        public string  LastBillDate  { get; set; } = string.Empty;
    }

    // ── Purchases ───────────────────────────────────────────────────────────
    public class PurchaseListItem
    {
        public int      PurchaseId   { get; set; }
        public string PurchaseDate { get; set; }
        public string   SupplierName { get; set; } = string.Empty;
        public string   InvoiceNo    { get; set; } = string.Empty;
        public string   PaymentMode  { get; set; } = string.Empty;
        public decimal  SubTotal     { get; set; }
        public decimal  TaxTotal     { get; set; }
        public decimal  GrandTotal   { get; set; }
        public bool     IsCancelled  { get; set; }
        public int      LineCount    { get; set; }
        public decimal  ItemQty      { get; set; }
        public string   LocationName   { get; set; } = string.Empty;
        public decimal  ReturnedQty    { get; set; }
        public decimal  ReturnedAmount { get; set; }
    }

    public class PurchaseLine
    {
        public int     PurchaseItemId { get; set; }
        public int     ItemId     { get; set; }
        public string  ItemName   { get; set; } = string.Empty;
        public decimal Quantity   { get; set; }
        public decimal UnitPrice  { get; set; }
        public decimal TaxPercent { get; set; }
        public decimal LineTotal  { get; set; }
        public string  UnitType   { get; set; } = string.Empty;
        public decimal ReturnedQty    { get; set; }
        public decimal ReturnedAmount { get; set; }
    }

    /// One return-to-supplier row of a bill.
    public class PurchaseReturn
    {
        public int     ReturnId       { get; set; }
        public string  ReturnDate     { get; set; } = string.Empty;
        public int     PurchaseItemId { get; set; }
        public string  ItemName       { get; set; } = string.Empty;
        public decimal Quantity       { get; set; }
        public decimal UnitPrice      { get; set; }
        public decimal TaxPercent     { get; set; }
        public decimal Amount         { get; set; }
        public string  Reason         { get; set; } = string.Empty;
        public string  LocationName   { get; set; } = string.Empty;
        public string  CreatedBy      { get; set; } = string.Empty;
        public string  CreatedAt      { get; set; } = string.Empty;
    }

    /// What the "Return to supplier" form posts.
    public class PurchaseReturnInput
    {
        public int     PurchaseId { get; set; }
        public string? Reason     { get; set; }
        public List<PurchaseReturnLineInput> Lines { get; set; } = new();
    }

    public class PurchaseReturnLineInput
    {
        public int     PurchaseItemId { get; set; }
        public decimal Quantity       { get; set; }
    }

    public class PurchaseDetail
    {
        public int      PurchaseId   { get; set; }
        public string PurchaseDate { get; set; }
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
        public string   LocationName    { get; set; } = string.Empty;
        public string   CreatedBy       { get; set; } = string.Empty;
        public string   CreatedAt       { get; set; } = string.Empty;
        public string   CancelledBy     { get; set; } = string.Empty;
        public string   CancelledAt     { get; set; } = string.Empty;
        public decimal  ReturnedAmount  { get; set; }
        public List<PurchaseLine> Lines { get; set; } = new();
        public List<PurchaseReturn> Returns { get; set; } = new();
    }

    /// What the purchase form posts.
    public class PurchaseInput
    {
        public int?      SupplierId   { get; set; }
        public string? PurchaseDate { get; set; }
        public string?   InvoiceNo    { get; set; }
        public string?   PaymentMode  { get; set; }
        public string?   Remarks      { get; set; }

        /// Where the goods go. Null = the default location.
        public int?      LocationId   { get; set; }
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
