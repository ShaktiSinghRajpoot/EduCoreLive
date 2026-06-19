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

        /// <summary>A student's outstanding ledger installments (amount due &gt; amount paid).</summary>
        Task<List<StudentDueItem>> GetStudentDuesAsync(
            int studentId, int tenantId, int schoolId, int actionUserId);
    }
}
