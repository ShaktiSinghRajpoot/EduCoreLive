namespace EduCoreDataAccessLayer.Services.Contract.Admin
{
    /// <summary>
    /// Records fee payments and issues receipts, allocating the amount across the
    /// student's outstanding ledger dues. Used by admission "collect now" and,
    /// later, by the Fee module's Collect Fees screen.
    /// </summary>
    public interface IFeePaymentService
    {
        Task<(bool Success, string Message, string? ReceiptNo)> RecordPaymentAsync(
            int      studentId,
            decimal  amount,
            string   paymentMode,
            string?  referenceNo,
            string?  remarks,
            string?  finYear,
            int      tenantId,
            int      schoolId,
            int      actionUserId);
    }
}
