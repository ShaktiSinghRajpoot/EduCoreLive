using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// Fees › Day Close (/ERP/DayClose): each cashier counts the cash they took in a day
    /// and closes their own counter. Open to everyone with fees.collect -- the fee
    /// counter AND the front desk that takes registration fees (QA BUG-099). Re-opening
    /// and the all-counters list need fees.reopen.
    /// </summary>
    [Area("ERP")]
    [HasPermission("fees.collect")]
    public class DayCloseController : Controller
    {
        private readonly IFeePaymentService _feePaymentService;

        public DayCloseController(IFeePaymentService feePaymentService)
        {
            _feePaymentService = feePaymentService;
        }

        public async Task<IActionResult> Index()
        {
            // The Re-open button shows only with fees.reopen (ReopenDay enforces it too).
            ViewBag.CanReopen = await HasPermissionAttribute.UserHasAsync(this, "fees.reopen");
            // The front desk has no Collect Fees page, so no "Counter" link for them.
            ViewBag.CanCounter = await HasPermissionAttribute.UserHasAsync(this, "fees.view");
            return View();
        }

        // ── GET: /ERP/DayClose/GetDayCollection ───────────────────────
        // The logged-in cashier's collection for a day, mode-wise, for reconciliation.
        [HttpGet]
        public async Task<IActionResult> GetDayCollection(string? date = null)
        {
            var d = Dates.Norm(date);
            var day = await _feePaymentService.GetDayCollectionAsync(d, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                date           = day.Date,
                totalCollected = day.TotalCollected,
                receiptCount   = day.ReceiptCount,
                cancelledCount = day.CancelledCount,
                cancelledAmount = day.CancelledAmount,
                cashCollected  = day.CashCollected,
                totalRefunded  = day.TotalRefunded,
                cashRefunded   = day.CashRefunded,
                expectedCash   = day.ExpectedCash,
                isClosed       = day.IsClosed,
                countedCash    = day.CountedCash,
                difference     = day.Difference,
                closeRemarks   = day.CloseRemarks,
                closedAt       = day.ClosedAt?.ToString("dd MMM yyyy, hh:mm tt"),
                reopenedAt     = day.ReopenedAt?.ToString("dd MMM yyyy, hh:mm tt"),
                reopenReason   = day.ReopenReason,
                schoolCollected = day.SchoolCollected,
                schoolReceipts  = day.SchoolReceipts,
                modes          = day.Modes.Select(m => new { mode = m.Mode, amount = m.Amount, count = m.Count }),
                history        = day.History.Select(h => new
                {
                    action   = h.Action,
                    at       = h.ActionAt?.ToString("dd MMM yyyy, hh:mm tt"),
                    by       = h.ActionBy,
                    expected = h.ExpectedCash,
                    counted  = h.CountedCash,
                    diff     = h.Difference,
                    note     = h.Note
                })
            });
        }

        // ── POST: /ERP/DayClose/ReopenDay ─────────────────────────────
        // Re-opens a closed day so a correction can be made and the day closed
        // again. A reason is required; the earlier count stays in the close history
        // and is never overwritten. Needs its own fees.reopen key so a school can
        // let a cashier close a day without letting them re-open it.
        // CashierId picks whose counter (from GetClosedCounters); without it the
        // caller's own counter is re-opened. Only rows of the caller's own
        // tenant/school can match, so another school's cashier can't be targeted.
        [HttpPost]
        [HasPermission("fees.reopen")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ReopenDay([FromBody] ReopenDayRequest req)
        {
            if (req == null || string.IsNullOrWhiteSpace(req.Reason))
                return Json(new { success = false, message = "A reason is required to re-open a closed day." });

            int cashierId = req.CashierId > 0 ? req.CashierId.Value : UserId();
            var (ok, msg) = await _feePaymentService.ReopenDayAsync(
                Dates.Norm(req.Date), cashierId, req.Reason!.Trim(), TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        public class ReopenDayRequest
        {
            public string? Date      { get; set; }
            public string? Reason    { get; set; }
            public int?    CashierId { get; set; }
        }

        // ── GET: /ERP/DayClose/GetClosedCounters ──────────────────────
        // Every counter closed on a date, for the admin's re-open list on Day Close.
        [HttpGet]
        [HasPermission("fees.reopen")]
        public async Task<IActionResult> GetClosedCounters(string? date = null)
        {
            var rows = await _feePaymentService.GetClosedCountersAsync(Dates.Norm(date), TenantId(), SchoolId(), UserId());
            return Json(rows.Select(r => new
            {
                cashierId  = r.CashierId,
                cashier    = r.CashierName,
                closedAt   = r.ClosedAt?.ToString("dd MMM yyyy, hh:mm tt"),
                collected  = r.TotalCollected,
                expected   = r.ExpectedCash,
                counted    = r.CountedCash,
                diff       = r.Difference,
                isClosed   = r.IsClosed,
                reopenedAt = r.ReopenedAt?.ToString("dd MMM yyyy, hh:mm tt"),
                reopenedBy = r.ReopenedBy,
                reason     = r.ReopenReason
            }));
        }

        // ── POST: /ERP/DayClose/CloseDay ──────────────────────────────
        // Anyone who takes cash closes their own counter (class-level fees.collect).
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CloseDay([FromBody] CloseDayRequest req)
        {
            if (req == null)
                return Json(new { success = false, message = "Invalid request." });

            var d = Dates.Norm(req.Date);
            var (ok, msg, expected, diff) = await _feePaymentService.CloseDayAsync(
                d, req.CountedCash, NullIfEmpty(req.Remarks), TenantId(), SchoolId(), UserId());

            return Json(new { success = ok, message = msg, expectedCash = expected, difference = diff });
        }

        public class CloseDayRequest
        {
            public string?  Date        { get; set; }
            public decimal  CountedCash { get; set; }
            public string?  Remarks     { get; set; }
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    }
}
