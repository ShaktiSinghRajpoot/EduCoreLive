using EduCoreDataAccessLayer.Models.Admin;

namespace EduCoreDataAccessLayer.Services.Contract.Admin
{
    /// <summary>
    /// Records fee payments and issues receipts, allocating the amount across the
    /// student's outstanding ledger dues. Used by admission "collect now" and,
    /// later, by the Fee module's Collect Fees screen.
    /// </summary>
    public interface IFeePaymentService
    {
        /// <summary>
        /// Records a registration fee against an enquiry (there is no student yet) and
        /// issues a receipt. No ledger allocation is done — registration fees are not
        /// part of the student fee schedule.
        /// </summary>
        Task<(bool Success, string Message, string? ReceiptNo)> RecordRegistrationPaymentAsync(
            int      enquiryId,
            decimal  amount,
            string   paymentMode,
            string?  referenceNo,
            string?  remarks,
            string?  finYear,
            int      tenantId,
            int      schoolId,
            int      actionUserId);

        /// <summary>A student's outstanding ledger installments (amount due &gt; amount paid + concession).</summary>
        Task<List<StudentDueItem>> GetStudentDuesAsync(
            int studentId, int tenantId, int schoolId, int actionUserId);

        /// <summary>
        /// Collects a payment against the specific dues the cashier picked (each with
        /// its own cash amount and optional concession), issues a receipt, and stores
        /// the receipt's line items. This is the Fee Collection counter's collect path.
        /// </summary>
        Task<FeeCollectResult> CollectPaymentAsync(
            int                  studentId,
            List<FeeCollectItem> items,
            List<FeeExtraItem>   extras,
            string               paymentMode,
            string?              referenceNo,
            string?              remarks,
            string?              finYear,
            int                  tenantId,
            int                  schoolId,
            int                  actionUserId,
            string?              discountType   = null,   // 'Flat' | 'Percent'
            decimal              discountValue  = 0,      // entered ₹ or %
            string?              discountReason = null,
            List<FeeTenderItem>? tenders        = null,   // split payment modes
            decimal              advanceUsed    = 0);     // drawn from the wallet

        /// <summary>The student's current advance / credit balance.</summary>
        Task<decimal> GetStudentAdvanceAsync(
            int studentId, int tenantId, int schoolId, int actionUserId);

        /// <summary>Every receipt issued for a student, newest first.</summary>
        Task<List<FeePaymentHistoryItem>> GetPaymentHistoryAsync(
            int studentId, int tenantId, int schoolId, int actionUserId);

        /// <summary>A single receipt (header + lines) for re-printing.</summary>
        Task<FeeReceipt?> GetReceiptAsync(
            string receiptNo, int tenantId, int schoolId, int actionUserId);

        /// <summary>
        /// Cancels (voids) a receipt: reverses its ledger allocation so the paid dues
        /// re-open, and marks the receipt Cancelled (kept on record) with reason and
        /// authoriser. The receipt is never deleted.
        /// </summary>
        Task<(bool Success, string Message)> CancelReceiptAsync(
            string  receiptNo,
            string  reason,
            string? authorizedBy,
            int     tenantId,
            int     schoolId,
            int     actionUserId);

        /// <summary>Paid ledger rows that still have cash retained (refundable), deposits first.</summary>
        Task<List<RefundableItem>> GetRefundablesAsync(
            int studentId, int tenantId, int schoolId, int actionUserId);

        /// <summary>
        /// Records a refund (money out) against a paid charge: writes a refund voucher
        /// and increments the charge's refunded amount so it can't be refunded twice.
        /// </summary>
        Task<(bool Success, string Message, string? RefundNo)> RecordRefundAsync(
            int     studentId,
            int     ledgerId,
            decimal amount,
            string  mode,
            string  reason,
            string? authorizedBy,
            int     tenantId,
            int     schoolId,
            int     actionUserId);

        /// <summary>The logged-in cashier's collection for a day (mode-wise) for reconciliation.</summary>
        Task<DayCollection> GetDayCollectionAsync(
            DateOnly? date, int tenantId, int schoolId, int actionUserId);

        /// <summary>Closes the cashier's day: records counted cash vs expected and the difference.</summary>
        Task<(bool Success, string Message, decimal ExpectedCash, decimal Difference)> CloseDayAsync(
            DateOnly? date, decimal countedCash, string? remarks,
            int tenantId, int schoolId, int actionUserId);

        /// <summary>Collection register for a date range (receipts + mode + head totals), school-wide.</summary>
        Task<CollectionRegister> GetCollectionRegisterAsync(
            DateOnly? from, DateOnly? to, int tenantId, int schoolId, int actionUserId);

        /// <summary>Students who still owe, with class-wise aging (optionally filtered by class/section).</summary>
        Task<List<DefaulterRow>> GetDefaultersAsync(
            string? className, string? section, int tenantId, int schoolId, int actionUserId);

        /// <summary>Audit register: concessions given + receipts cancelled, in a date range.</summary>
        Task<(List<ConcessionRow> Concessions, List<CancellationRow> Cancellations)> GetConcessionCancelRegisterAsync(
            DateOnly? from, DateOnly? to, int tenantId, int schoolId, int actionUserId);
    }
}
