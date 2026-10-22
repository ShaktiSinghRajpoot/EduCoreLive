using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.School.Controllers
{
    /// <summary>
    /// Fee receipts: print one, cancel one, and the school's receipt format.
    ///
    /// Not part of the Fees module on purpose. Admission, Registration, Enquiry and
    /// the student profile print and cancel receipts too (registration fee, fee at
    /// admission), and they must keep working for a school that has not bought Fees.
    /// Moved here out of FeeController; the permissions are the ones they had there.
    /// </summary>
    [Area("School")]
    [HasPermission("fees.view")]
    public class ReceiptController : Controller
    {
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IFeePaymentService _feePaymentService;

        public ReceiptController(ISchoolSettingsService schoolSettingsService, IFeePaymentService feePaymentService)
        {
            _schoolSettingsService = schoolSettingsService;
            _feePaymentService = feePaymentService;
        }

        // ── GET: /school/receipt/getreceipt ─────────────────────────────
        // One full receipt (header + lines + school identity) for re-printing.
        [HttpGet]
        public async Task<IActionResult> GetReceipt(string receiptNo)
        {
            var r = await _feePaymentService.GetReceiptAsync(receiptNo, TenantId(), SchoolId(), UserId());
            if (r == null) return Json((object?)null);

            var school = await GetSchoolHeaderAsync();

            // Build display lines. Registration receipts carry no detail rows, so
            // synthesize a single line from the header amount.
            var lines = r.Lines.Select(l => new
            {
                label      = (string.IsNullOrWhiteSpace(l.InstallmentLabel) ? l.FeeHeadName : $"{l.FeeHeadName} — {l.InstallmentLabel}")
                             + LineSession(l.AcademicYear, l.CarriedFrom, r.Session),
                amount     = l.Amount,
                concession = l.Concession,
                lineType   = l.LineType
            }).ToList();

            // The line is the fee this receipt settled (cash + any registration
            // discount); the discount is then printed as its own deduction, so
            // "Total Paid" is the cash alone.
            if (lines.Count == 0)
                lines.Add(new { label = r.PaymentType == "Registration" ? "Registration Fee" : "Fee", amount = r.Amount + r.DiscountAmount, concession = 0m, lineType = "Due" });

            // A registration fee can be paid in parts, and a slip saying only "900"
            // tells the family nothing about the 100 still owed. Print the fee, what
            // had already been received, and what was left AFTER this receipt.
            //
            // As of this receipt, not as of now. The first version asked for the
            // current balance, which meant collecting the final 100 quietly erased
            // the "Balance payable 100" line from the earlier 900 receipt — a
            // document that changes after it is handed over is not a receipt.
            object? registration = null;
            if (string.Equals(r.PaymentType, "Registration", StringComparison.OrdinalIgnoreCase) && r.EnquiryId > 0)
            {
                var (fee, paidBefore, _, balanceAfter) =
                    await _feePaymentService.GetRegistrationReceiptContextAsync(r.ReceiptNo, TenantId(), SchoolId(), UserId());

                // Only worth printing when this receipt is not the whole story:
                // either something came before it, or something is still owed.
                // "Paid on this receipt" is the CASH on it; a discount is shown
                // beside it, not added into it.
                if (fee > 0 && (paidBefore > 0 || balanceAfter > 0))
                    registration = new { fee, paidBefore, thisReceipt = r.Amount, discount = r.DiscountAmount, balance = balanceAfter };
            }

            // A student fee receipt gets the outstanding too -- a parent paying 4,000 of
            // 10,000 at admission should not have to ask what is left.
            //
            // Dated, and deliberately NOT a snapshot like the registration one. A
            // registration fee is a fixed agreed figure, so "the balance when this
            // receipt was written" is a real thing. A student's dues keep being
            // generated all year, so there is no honest fixed balance to freeze --
            // what there is, is what they owe today, and the receipt says so in as
            // many words rather than implying otherwise.
            object? dues = null;
            if (!string.Equals(r.PaymentType, "Registration", StringComparison.OrdinalIgnoreCase) && r.StudentId > 0)
            {
                var open = await _feePaymentService.GetStudentDuesAsync(r.StudentId, TenantId(), SchoolId(), UserId());

                // Only what has actually fallen due. Summing every open row put the
                // whole year's unbilled monthly installments on the slip -- a parent
                // settling 4,000 of the 10,000 owed at admission would read
                // "Outstanding 4,35,000" and reasonably panic. A receipt states what
                // is owed now; the year ahead is a fee structure, not a debt.
                string today = Dates.Today;
                var dueNow = open.Where(d => string.IsNullOrWhiteSpace(d.DueDate)
                                          || string.CompareOrdinal(d.DueDate, today) <= 0).ToList();
                decimal outstanding = dueNow.Sum(d => d.Outstanding);
                // of which an older session's (or carried forward by Year-End), as the
                // profile and Collect Fees show it
                decimal previous = dueNow.Where(d => !string.IsNullOrWhiteSpace(d.CarriedFrom)
                                                  || (!string.IsNullOrWhiteSpace(d.AcademicYear) && !string.IsNullOrWhiteSpace(r.Session)
                                                      && string.CompareOrdinal(d.AcademicYear, r.Session) < 0))
                                         .Sum(d => d.Outstanding);

                if (outstanding > 0)
                    dues = new { outstanding, previous, asOn = today };
            }

            // The school's chosen print format drives which template renders.
            var format = await _schoolSettingsService.GetReceiptFormatAsync(TenantId(), SchoolId(), UserId());

            return Json(new
            {
                school,
                format,
                receiptNo   = r.ReceiptNo,
                date        = r.PaymentDate,
                amount      = r.Amount,
                concession  = r.ConcessionTotal,
                mode        = r.PaymentMode,
                reference   = r.ReferenceNo,
                remarks     = r.Remarks,
                paymentType = r.PaymentType,
                discountType   = r.DiscountType,
                discountValue  = r.DiscountValue,
                discountReason = r.DiscountReason,
                advanceUsed    = r.AdvanceUsed,
                advanceCredit  = r.AdvanceCredit,
                discountAmount = r.DiscountAmount,
                discountApprovedBy = r.DiscountApprovedBy,
                collectedBy    = r.CollectedBy,
                tenders        = r.Tenders.Select(t => new { mode = t.Mode, amount = t.Amount, reference = t.Reference }),
                // A voided receipt prints as CANCELLED, with who/when/why.
                isCancelled    = r.IsCancelled,
                cancelReason   = r.CancelReason,
                cancelledBy    = r.CancelledByName,
                cancelledAt    = r.CancelledAt?.ToString("yyyy-MM-dd HH:mm"),
                cancelAuthorisedBy = r.CancelAuthorizedBy,
                student     = new { name = r.StudentName, admNo = r.AdmissionNo, className = r.ClassName, section = r.Section, roll = r.RollNo, session = r.Session },
                registration,
                dues,
                lines
            });
        }

        // " (2027-28)" after a receipt line of another session, " (Dues of 2025-26)" after
        // one Year-End carried forward; nothing for a fee of the receipt's own session.
        private static string LineSession(string? year, string? carriedFrom, string? receiptSession)
        {
            if (!string.IsNullOrWhiteSpace(carriedFrom) && !string.Equals(carriedFrom, receiptSession, StringComparison.OrdinalIgnoreCase))
                return $" (Dues of {carriedFrom})";
            if (!string.IsNullOrWhiteSpace(year) && !string.IsNullOrWhiteSpace(receiptSession)
                && !string.Equals(year, receiptSession, StringComparison.OrdinalIgnoreCase))
                return $" ({year})";
            return "";
        }

        // ── GET: /school/receipt/getschoolheader ────────────────────────
        // School name + address for the receipt header (fetched once on load).
        [HttpGet]
        public async Task<IActionResult> GetSchoolHeader() => Json(await GetSchoolHeaderAsync());

        private async Task<object> GetSchoolHeaderAsync()
        {
            var profile = await _schoolSettingsService.GetBasicProfileAsync(TenantId(), SchoolId(), UserId());
            var addressParts = new[] { profile?.AddressLine1, profile?.City, profile?.State }
                .Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => p!.Trim());

            // The receipt prints from a blank popup window, where a relative path like
            // "/uploads/..." cannot resolve — so hand the client an ABSOLUTE url or the
            // letterhead logo silently breaks on every print.
            string? logo = null;
            var stored = profile?.LogoUrl;
            if (!string.IsNullOrWhiteSpace(stored))
            {
                logo = stored!.StartsWith("http", StringComparison.OrdinalIgnoreCase)
                    ? stored
                    : $"{Request.Scheme}://{Request.Host}{(stored.StartsWith('/') ? "" : "/")}{stored}";
            }

            return new
            {
                name    = string.IsNullOrWhiteSpace(profile?.SchoolName) ? "Your School" : profile!.SchoolName.Trim(),
                address = string.Join(", ", addressParts),
                logo
            };
        }

        // ── POST: /school/receipt/cancelreceipt ─────────────────────────
        // Voids a receipt: reverses its ledger allocation (re-opens the dues) and
        // marks it Cancelled with reason + authoriser. The receipt is kept on record.
        [HttpPost]
        [HasPermission("fees.cancel")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CancelReceipt([FromBody] CancelReceiptRequest req)
        {
            if (req == null || string.IsNullOrWhiteSpace(req.ReceiptNo))
                return Json(new { success = false, message = "Receipt number is required." });
            if (string.IsNullOrWhiteSpace(req.Reason))
                return Json(new { success = false, message = "A reason is required to cancel a receipt." });
            // The authoriser is the signed-in person, who holds fees.cancel. It used to be
            // picked from a list, so any cashier could write "Principal" (QA BUG-063).
            var (ok, msg) = await _feePaymentService.CancelReceiptAsync(
                req.ReceiptNo.Trim(), req.Reason.Trim(), CurrentUserName(),
                TenantId(), SchoolId(), UserId());

            return Json(new { success = ok, message = msg });
        }

        public class CancelReceiptRequest
        {
            public string? ReceiptNo    { get; set; }
            public string? Reason       { get; set; }
            public string? AuthorizedBy { get; set; }
        }

        // ── POST: /school/receipt/savereceiptformat (AJAX) ──────────────
        // The school picks how receipts print: A4 (letterhead) / A5 (compact) /
        // Thermal (80mm counter roll). Stored per school, applied to every receipt.
        [HttpPost]
        [HasPermission("settings.manage")]   // a school-wide setting, not a cashier's choice
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveReceiptFormat([FromBody] ReceiptFormatRequest req)
        {
            if (req == null || string.IsNullOrWhiteSpace(req.Format))
                return Json(new { success = false, message = "Choose a format." });

            var ok = await _schoolSettingsService.SaveReceiptFormatAsync(
                req.Format!.Trim(), TenantId(), SchoolId(), UserId());

            return Json(new { success = ok, message = ok ? "Receipt format saved." : "Could not save the format." });
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private string CurrentUserName() => User.FindFirst(Common.SK_UserName)?.Value ?? User.Identity?.Name ?? "User #" + UserId();
    }

    public class ReceiptFormatRequest
    {
        public string? Format { get; set; }   // A4 | A5 | Thermal
    }
}
