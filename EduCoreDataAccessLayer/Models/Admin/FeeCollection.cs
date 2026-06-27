namespace EduCoreDataAccessLayer.Models.Admin
{
    /// <summary>
    /// One due the cashier chose to collect on the Fee Collection counter:
    /// how much cash to take and how much (if any) to waive as concession.
    /// </summary>
    public class FeeCollectItem
    {
        public int     LedgerId   { get; set; }
        public decimal Amount     { get; set; }   // cash collected for this due
        public decimal Concession { get; set; }   // waiver granted on this due
    }

    /// <summary>An ad-hoc extra charge typed at the counter (e.g. a late fine), not tied to a ledger due.</summary>
    public class FeeExtraItem
    {
        public string  Label  { get; set; } = string.Empty;
        public decimal Amount { get; set; }
    }

    /// <summary>One payment mode + amount in a split-tender collection.</summary>
    public class FeeTenderItem
    {
        public string  Mode      { get; set; } = "Cash";
        public decimal Amount    { get; set; }
        public string? Reference { get; set; }
    }

    /// <summary>The result of collecting a payment — used to render the receipt.</summary>
    public class FeeCollectResult
    {
        public bool    Success         { get; set; }
        public string  Message         { get; set; } = string.Empty;
        public string? ReceiptNo       { get; set; }
        public decimal Amount          { get; set; }
        public decimal ConcessionTotal { get; set; }
        public DateOnly? PaymentDate   { get; set; }
    }

    /// <summary>One receipt in a student's payment history.</summary>
    public class FeePaymentHistoryItem
    {
        public string    ReceiptNo       { get; set; } = string.Empty;
        public DateOnly? PaymentDate     { get; set; }
        public decimal   Amount          { get; set; }
        public decimal   ConcessionTotal { get; set; }
        public string    PaymentMode     { get; set; } = string.Empty;
        public string?   ReferenceNo     { get; set; }
        public bool      IsCancelled     { get; set; }
        public string?   CancelReason    { get; set; }
    }

    /// <summary>A cashier's day collection summary + mode-wise breakup for reconciliation.</summary>
    public class DayCollection
    {
        public DateOnly         Date           { get; set; }
        public decimal          TotalCollected { get; set; }
        public int              ReceiptCount   { get; set; }
        public int              CancelledCount { get; set; }
        public decimal          CashCollected  { get; set; }
        public decimal          TotalRefunded  { get; set; }
        public decimal          CashRefunded   { get; set; }
        public decimal          ExpectedCash   { get; set; }   // cash collected − cash refunded
        public bool             IsClosed       { get; set; }
        public decimal          CountedCash    { get; set; }
        public decimal          Difference     { get; set; }
        public string?          CloseRemarks   { get; set; }
        public List<DayModeRow> Modes          { get; set; } = new();
    }

    public class DayModeRow
    {
        public string  Mode   { get; set; } = string.Empty;
        public decimal Amount { get; set; }
        public int     Count  { get; set; }
    }

    /// <summary>Collection register for a date range: receipts + mode + head summaries.</summary>
    public class CollectionRegister
    {
        public DateOnly                 From     { get; set; }
        public DateOnly                 To       { get; set; }
        public List<RegisterReceipt>    Receipts { get; set; } = new();
        public List<DayModeRow>         Modes    { get; set; } = new();
        public List<HeadCollectRow>     Heads    { get; set; } = new();
        public decimal Total => Receipts.Sum(r => r.Amount);
    }

    public class RegisterReceipt
    {
        public string    ReceiptNo   { get; set; } = string.Empty;
        public DateOnly? Date        { get; set; }
        public decimal   Amount      { get; set; }
        public string    Mode        { get; set; } = string.Empty;
        public string    StudentName { get; set; } = string.Empty;
        public string    AdmissionNo { get; set; } = string.Empty;
        public string?   ClassName   { get; set; }
        public string?   Section     { get; set; }
    }

    public class HeadCollectRow
    {
        public string  Head   { get; set; } = string.Empty;
        public int     Count  { get; set; }
        public decimal Amount { get; set; }
    }

    /// <summary>A student who still owes, with class-wise aging of the outstanding.</summary>
    public class DefaulterRow
    {
        public int      StudentId        { get; set; }
        public string   StudentName      { get; set; } = string.Empty;
        public string   AdmissionNo      { get; set; } = string.Empty;
        public string?  ClassName        { get; set; }
        public string?  Section          { get; set; }
        public string?  RollNo           { get; set; }
        public decimal  TotalOutstanding { get; set; }
        public decimal  NotDue           { get; set; }
        public decimal  D0_30            { get; set; }
        public decimal  D31_60           { get; set; }
        public decimal  D60Plus          { get; set; }
    }

    /// <summary>One concession/discount given (audit register).</summary>
    public class ConcessionRow
    {
        public string    ReceiptNo     { get; set; } = string.Empty;
        public DateOnly? Date          { get; set; }
        public decimal   Concession    { get; set; }
        public string?   DiscountType  { get; set; }
        public decimal   DiscountValue { get; set; }
        public string?   Reason        { get; set; }
        public string    Student       { get; set; } = string.Empty;
        public string    AdmNo         { get; set; } = string.Empty;
    }

    /// <summary>One cancelled receipt (audit register).</summary>
    public class CancellationRow
    {
        public string     ReceiptNo    { get; set; } = string.Empty;
        public DateOnly?   Date         { get; set; }
        public decimal     Amount       { get; set; }
        public string?     Reason       { get; set; }
        public string?     AuthorizedBy { get; set; }
        public DateTime?   CancelledAt  { get; set; }
        public string      Student      { get; set; } = string.Empty;
        public string      AdmNo        { get; set; } = string.Empty;
    }

    /// <summary>A paid ledger row with cash still retained that can be refunded.</summary>
    public class RefundableItem
    {
        public int      LedgerId         { get; set; }
        public string   FeeHeadName      { get; set; } = string.Empty;
        public string?  InstallmentLabel { get; set; }
        public decimal  AmountPaid       { get; set; }
        public decimal  Refunded         { get; set; }
        public decimal  Refundable       { get; set; }
        public bool     IsRefundable     { get; set; }   // head flagged refundable (deposit)
    }

    /// <summary>A full receipt (header + lines) for re-printing.</summary>
    public class FeeReceipt
    {
        public string    ReceiptNo       { get; set; } = string.Empty;
        public DateOnly? PaymentDate     { get; set; }
        public decimal   Amount          { get; set; }
        public decimal   ConcessionTotal { get; set; }
        public string    PaymentMode     { get; set; } = string.Empty;
        public string?   ReferenceNo     { get; set; }
        public string?   Remarks         { get; set; }
        public string    PaymentType     { get; set; } = "Fee";   // Fee | Registration
        public string?   DiscountType    { get; set; }            // Flat | Percent
        public decimal   DiscountValue   { get; set; }            // entered ₹ or %
        public string?   DiscountReason  { get; set; }
        public decimal   AdvanceUsed     { get; set; }            // drawn from wallet
        public decimal   AdvanceCredit   { get; set; }            // surplus saved to wallet
        public string    StudentName     { get; set; } = string.Empty;
        public string    AdmissionNo     { get; set; } = string.Empty;
        public string    ClassName       { get; set; } = string.Empty;
        public string?   Section         { get; set; }
        public string?   RollNo          { get; set; }
        public List<FeeReceiptLine> Lines { get; set; } = new();
    }

    /// <summary>One line on a printed receipt.</summary>
    public class FeeReceiptLine
    {
        public string  FeeHeadName      { get; set; } = string.Empty;
        public string? InstallmentLabel { get; set; }
        public decimal Amount           { get; set; }
        public decimal Concession       { get; set; }
        public string  LineType         { get; set; } = "Due";   // Due | Extra
    }
}
