namespace EduCoreDataAccessLayer.Models.ERP
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
        public string? Note   { get; set; }   // cashier's note, kept on the receipt line
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
        public string? PaymentDate   { get; set; }
    }

    /// <summary>One receipt in a student's payment history.</summary>
    public class FeePaymentHistoryItem
    {
        public string    ReceiptNo       { get; set; } = string.Empty;
        public string? PaymentDate     { get; set; }
        public decimal   Amount          { get; set; }
        public decimal   ConcessionTotal { get; set; }
        public string    PaymentMode     { get; set; } = string.Empty;
        public string?   ReferenceNo     { get; set; }
        public bool      IsCancelled     { get; set; }
        public string?   CancelReason    { get; set; }
        public string    PaymentType     { get; set; } = "Fee";
        public decimal   AdvanceUsed     { get; set; }
        public decimal   AdvanceCredit   { get; set; }
        /// <summary>Who took the money, and when it was entered.</summary>
        public string?   CollectedBy     { get; set; }
        public DateTime? CreatedAt       { get; set; }
        /// <summary>Who voided it, when, and who authorised that.</summary>
        public string?   CancelledByName { get; set; }
        public DateTime? CancelledAt     { get; set; }
        public string?   CancelAuthorizedBy { get; set; }
    }

    /// <summary>One refund voucher in a student's payment history.</summary>
    public class FeeRefundHistoryItem
    {
        public string    RefundNo       { get; set; } = string.Empty;
        public string?   RefundDate     { get; set; }
        public decimal   Amount         { get; set; }
        public string    Mode           { get; set; } = string.Empty;
        public string?   Reason         { get; set; }
        public string?   AuthorizedBy   { get; set; }
        public string?   RefundedBy     { get; set; }
        /// <summary>The charge refunded, or "Advance balance" for a wallet refund.</summary>
        public string?   Against        { get; set; }
    }

    /// <summary>A cashier's day collection summary + mode-wise breakup for reconciliation.</summary>
    public class DayCollection
    {
        public string         Date           { get; set; }
        /// <summary>Receipts issued this day minus cancellations made this day.</summary>
        public decimal          TotalCollected { get; set; }
        /// <summary>Receipts issued this day (a later cancel does not remove one).</summary>
        public int              ReceiptCount   { get; set; }
        /// <summary>Cancellations made this day, by this cashier.</summary>
        public int              CancelledCount { get; set; }
        public decimal          CancelledAmount { get; set; }
        public decimal          CashCollected  { get; set; }
        public decimal          TotalRefunded  { get; set; }
        public decimal          CashRefunded   { get; set; }
        public decimal          ExpectedCash   { get; set; }   // cash collected − cash refunded
        public bool             IsClosed       { get; set; }
        public decimal          CountedCash    { get; set; }
        public decimal          Difference     { get; set; }
        public string?          CloseRemarks   { get; set; }
        public DateTime?        ClosedAt       { get; set; }
        public decimal          ClosedTotalCollected { get; set; }
        public decimal          ClosedExpectedCash   { get; set; }
        public DateTime?        ReopenedAt     { get; set; }
        public string?          ReopenReason   { get; set; }

        /// <summary>Every close and re-open of this drawer for the day, newest first.</summary>
        public List<DayCloseLogRow> History    { get; set; } = new();

        // The same day across every cashier. Only used to explain a zero -- see
        // the note on the DayClose page. It is not part of the reconciliation.
        public decimal          SchoolCollected { get; set; }
        public int              SchoolReceipts  { get; set; }

        public List<DayModeRow> Modes          { get; set; } = new();
    }

    /// <summary>One close or re-open of a cashier's day (never overwritten).</summary>
    public class DayCloseLogRow
    {
        public string    Action         { get; set; } = string.Empty;   // Close | Reopen
        public DateTime? ActionAt       { get; set; }
        public string?   ActionBy       { get; set; }
        public decimal   TotalCollected { get; set; }
        public decimal   ExpectedCash   { get; set; }
        public decimal   CountedCash    { get; set; }
        public decimal   Difference     { get; set; }
        public string?   Note           { get; set; }
    }

    /// <summary>One cashier's close row for a date (core.sp_fee_day_close_list).
    /// Lets an admin find and re-open another counter's closed day.</summary>
    public class DayCloseCounterRow
    {
        public int       CashierId      { get; set; }
        public string?   CashierName    { get; set; }
        public DateTime? ClosedAt       { get; set; }
        public decimal   TotalCollected { get; set; }
        public decimal   ExpectedCash   { get; set; }
        public decimal   CountedCash    { get; set; }
        public decimal   Difference     { get; set; }
        public bool      IsClosed       { get; set; }
        public DateTime? ReopenedAt     { get; set; }
        public string?   ReopenedBy     { get; set; }
        public string?   ReopenReason   { get; set; }
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
        public string                 From     { get; set; }
        public string                 To       { get; set; }
        public List<RegisterReceipt>    Receipts { get; set; } = new();
        public List<DayModeRow>         Modes    { get; set; } = new();
        public List<HeadCollectRow>     Heads    { get; set; } = new();
        public decimal Total => Receipts.Sum(r => r.Amount);
    }

    public class RegisterReceipt
    {
        /// <summary>"Receipt" (+, on its issue day) or "Cancellation" (-, on the cancel day).</summary>
        public string    Entry       { get; set; } = "Receipt";
        /// <summary>The day this line counts on: issue day, or cancel day for a cancellation.</summary>
        public string?   LineDate    { get; set; }
        public bool      IsCancelled { get; set; }
        public DateTime? CancelledAt { get; set; }
        public string?   CancelReason { get; set; }
        public string?   CashierName { get; set; }
        public string    ReceiptNo   { get; set; } = string.Empty;
        public string? Date        { get; set; }
        public decimal   Amount      { get; set; }
        public string    Mode        { get; set; } = string.Empty;
        public string    StudentName { get; set; } = string.Empty;
        public string    AdmissionNo { get; set; } = string.Empty;
        public string?   ClassName   { get; set; }
        public string?   Section     { get; set; }

        /// <summary>"Registration" (taken against an enquiry) or "Fee" (against a student).</summary>
        public string    PaymentType { get; set; } = "Fee";

        /// <summary>Which fee heads this receipt covered — what the money was actually for.</summary>
        public string?   FeeHeads    { get; set; }

        /// <summary>Cheque / UPI reference, needed for bank reconciliation.</summary>
        public string?   ReferenceNo { get; set; }

        /// <summary>Concession + discount granted on this receipt.</summary>
        public decimal   DiscountTotal { get; set; }
    }

    /// <summary>
    /// One refund (money OUT). Reported alongside collections so the screen can show
    /// a NET figure — a register that only counts money in overstates what the school
    /// actually holds.
    /// </summary>
    public class RefundRegisterRow
    {
        public string    RefundNo         { get; set; } = string.Empty;
        public DateTime? RefundedAt       { get; set; }
        public decimal   Amount           { get; set; }
        public string?   Mode             { get; set; }
        public string?   Reason           { get; set; }
        public string?   AuthorizedBy     { get; set; }
        /// <summary>The user who recorded the refund (AuthorizedBy is free text).</summary>
        public string?   RefundedByName   { get; set; }
        public string    StudentName      { get; set; } = string.Empty;
        public string    AdmissionNo      { get; set; } = string.Empty;
        public string?   ClassName        { get; set; }
        public string?   Section          { get; set; }
        public string?   FeeHeadName      { get; set; }
        public string?   InstallmentLabel { get; set; }
    }

    public class RefundRegister
    {
        public List<RefundRegisterRow> Rows  { get; set; } = new();
        public List<DayModeRow>        Modes { get; set; } = new();
        public decimal Total => Rows.Sum(r => r.Amount);
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
        /// <summary>"Student", or "Registration" for a fee part-paid before admission.</summary>
        public string   Entry            { get; set; } = "Student";
        /// <summary>Active, or how the student left (Transfer, Passout ...), or Registered.</summary>
        public string?  StudentStatus    { get; set; }
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

    /// <summary>One unpaid fee line on the Year-End closure screen.</summary>
    public class YearEndLine
    {
        public int       LedgerId     { get; set; }
        public int       StudentId    { get; set; }
        public string    StudentName  { get; set; } = string.Empty;
        public string    AdmissionNo  { get; set; } = string.Empty;
        public string?   ClassName    { get; set; }
        public string?   Section      { get; set; }
        public string?   GuardianName { get; set; }
        public string?   Mobile       { get; set; }
        public string    FeeHead      { get; set; } = string.Empty;
        public string?   Installment  { get; set; }
        public string?   DueDate      { get; set; }
        /// <summary>Still owed (Open / Carried), or the amount written off.</summary>
        public decimal   Amount       { get; set; }
        /// <summary>Open, Carried or WrittenOff.</summary>
        public string    State        { get; set; } = "Open";
        public string?   Reason       { get; set; }
        public DateTime? DecidedAt    { get; set; }
    }

    /// <summary>One concession/discount given (audit register).</summary>
    public class ConcessionRow
    {
        public string    ReceiptNo     { get; set; } = string.Empty;
        public string? Date          { get; set; }
        /// <summary>Concession + discount on the receipt (incl. a registration discount).</summary>
        public decimal   Concession    { get; set; }
        public string?   PaymentType   { get; set; }
        public bool      IsCancelled   { get; set; }
        public string?   GivenBy       { get; set; }
        /// <summary>Approver picked from a list by the cashier (not verified); GivenBy is the real user.</summary>
        public string?   ApprovedBy    { get; set; }
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
        public string?   Date         { get; set; }
        public decimal     Amount       { get; set; }
        public string?     Reason       { get; set; }
        public string?     AuthorizedBy { get; set; }
        public DateTime?   CancelledAt  { get; set; }
        /// <summary>The user who cancelled it, and the one who had collected it.</summary>
        public string?     CancelledBy  { get; set; }
        public string?     CollectedBy  { get; set; }
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
        public string? PaymentDate     { get; set; }
        public decimal   Amount          { get; set; }
        public decimal   ConcessionTotal { get; set; }
        public string    PaymentMode     { get; set; } = string.Empty;
        public string?   ReferenceNo     { get; set; }
        public string?   Remarks         { get; set; }
        public string    PaymentType     { get; set; } = "Fee";   // Fee | Registration
        /// <summary>Set on a Registration receipt: there is no student yet, only an enquiry.</summary>
        public int       EnquiryId       { get; set; }
        /// <summary>Set on a student fee receipt; 0 on a registration one.</summary>
        public int       StudentId       { get; set; }
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
        /// <summary>Registration-fee discount (registration receipts carry it on the header).</summary>
        public decimal   DiscountAmount  { get; set; }
        public string?   DiscountApprovedBy { get; set; }
        public string?   CollectedBy     { get; set; }
        /// <summary>A voided receipt must print as CANCELLED.</summary>
        public bool      IsCancelled     { get; set; }
        public string?   CancelReason    { get; set; }
        public string?   CancelAuthorizedBy { get; set; }
        public DateTime? CancelledAt     { get; set; }
        public string?   CancelledByName { get; set; }
        /// <summary>How it was paid, mode by mode (cheque no / UPI ref in Reference).</summary>
        public List<FeeTenderItem> Tenders { get; set; } = new();
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
