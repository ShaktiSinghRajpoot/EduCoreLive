using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.Fees.Controllers
{
    [Area("Fees")]
    [RequiresModule(SchoolModule.Fees)]
    // Fee counter + day-close + reports. Inventory now lives in its own
    // InventoryController (see Controllers/InventoryController.cs).
    [HasPermission("fees.view")]
    public class FeeController : Controller
    {
        private readonly IBaseService _baseService;
        private readonly IAdmissionService _admissionService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IFeePaymentService _feePaymentService;
        private readonly ICertificateService _certificates;

        public FeeController(
            IBaseService baseService,
            IAdmissionService admissionService,
            ISchoolSettingsService schoolSettingsService,
            IFeePaymentService feePaymentService,
            ICertificateService certificates)
        {
            _certificates = certificates;
            _baseService = baseService;
            _admissionService = admissionService;
            _schoolSettingsService = schoolSettingsService;
            _feePaymentService = feePaymentService;
        }

        // ── Pages ────────────────────────────────────────────────
        [Route("fees/collect")]
        public IActionResult ManageFee()
        {
            ViewBag.UserName = CurrentUserName();   // shown as "Approved by" on a discount
            return View();
        }
        // Day Close moved to its own page so everyone who takes cash can close
        // their counter (QA BUG-099); old links still land there.
        public IActionResult DayClose() => RedirectToAction("Index", "DayClose", new { area = "Fees" });
        // The Defaulters tab opens on the current session (sp_dropdown_common marks it).
        [Route("fees/reports")]
        public async Task<IActionResult> Reports()
        {
            try
            {
                ViewBag.Sessions = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString());
            }
            catch { ViewBag.Sessions = new List<SelectListItem>(); }
            return View();
        }

        // ── GET: /fees/fee/GetSessions ────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetSessions()
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString());
            return Json(items.Select(x => x.Text).ToList());
        }

        // ── GET: /fees/fee/GetClasses ─────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetClasses(string? session = null)
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString());
            return Json(items.Select(x => x.Text).ToList());
        }

        // ── GET: /fees/fee/GetSections ────────────────────────────
        // Sections are configured per class + year in Academic Setup.
        [HttpGet]
        public async Task<IActionResult> GetSections(string session, string className)
        {
            if (string.IsNullOrWhiteSpace(session) || string.IsNullOrWhiteSpace(className))
                return Json(Array.Empty<string>());

            int ayId = await ResolveAcademicYearIdAsync(session);
            if (ayId <= 0) return Json(Array.Empty<string>());

            var setup = await _schoolSettingsService.GetAcademicSetupAsync(TenantId(), SchoolId(), ayId, UserId());

            var sections = new List<string>();
            if (setup?.ClassSections != null)
            {
                var key = setup.ClassSections.Keys.FirstOrDefault(
                    k => k.Equals(className.Trim(), StringComparison.OrdinalIgnoreCase));
                if (key != null) sections = setup.ClassSections[key];
            }

            return Json(sections);
        }

        // ── GET: /fees/fee/GetStudents ────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetStudents(string session, string className, string section)
        {
            if (string.IsNullOrWhiteSpace(className) || string.IsNullOrWhiteSpace(section))
                return Json(Array.Empty<object>());

            var (rows, _) = await _admissionService.GetStudentsAsync(
                TenantId(), SchoolId(), UserId(),
                pageNumber: 1, pageSize: 500,
                filterClass: className.Trim(),
                filterSection: section.Trim(),
                filterYear: NullIfEmpty(session));

            return Json(rows.Select(s => new
            {
                id    = s.StudentId,
                admNo = s.AdmissionNo,
                name  = s.StudentName,
                roll  = s.RollNo
            }));
        }

        // ── GET: /fees/fee/FindByAdmission ────────────────────────
        [HttpGet]
        public async Task<IActionResult> FindByAdmission(string session, string admissionNo)
        {
            if (string.IsNullOrWhiteSpace(admissionNo))
                return Json((object?)null);

            var (rows, _) = await _admissionService.GetStudentsAsync(
                TenantId(), SchoolId(), UserId(),
                pageNumber: 1, pageSize: 50,
                search: admissionNo.Trim(),
                filterYear: NullIfEmpty(session));

            var match = rows.FirstOrDefault(s =>
                string.Equals(s.AdmissionNo, admissionNo.Trim(), StringComparison.OrdinalIgnoreCase));

            if (match == null)
                return Json((object?)null);

            return Json(new
            {
                student   = new { id = match.StudentId, admNo = match.AdmissionNo, name = match.StudentName, roll = match.RollNo },
                className = match.ClassName,
                section   = match.Section
            });
        }

        // ── GET: /fees/fee/SearchStudents ─────────────────────────
        // A parent at the counter often does not know the class or section. The
        // student list search already matches the student's name, admission no,
        // father / guardian name and mobile, so the counter uses it as is.
        [HttpGet]
        public async Task<IActionResult> SearchStudents(string? session, string? q)
        {
            if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2)
                return Json(Array.Empty<object>());

            var (rows, _) = await _admissionService.GetStudentsAsync(
                TenantId(), SchoolId(), UserId(),
                pageNumber: 1, pageSize: 20,
                search: q.Trim(),
                filterYear: NullIfEmpty(session));

            var list = rows.Select(s => new
            {
                id       = s.StudentId,
                admNo    = s.AdmissionNo,
                name     = s.StudentName,
                cls      = s.ClassName,
                sec      = s.Section,
                guardian = s.GuardianName,
                mobile   = s.Mobile,
                left     = false
            }).ToList();

            // Students who have LEFT may still owe fees (and need them cleared for a TC), so
            // the counter finds them too, marked "Left" (QA BUG-082). The certificate search
            // already covers former students.
            var former = await _certificates.SearchStudentsAsync(q.Trim(), TenantId(), SchoolId(), UserId());
            list.AddRange(former.Where(f => !f.IsCurrent).Select(f => new
            {
                id = f.StudentId, admNo = f.AdmissionNo ?? "", name = f.StudentName, cls = f.ClassName, sec = f.Section,
                guardian = f.GuardianName, mobile = f.Mobile, left = true
            }));
            return Json(list);
        }

        // ── GET: /fees/fee/GetAdvance ─────────────────────────────
        // The student's current advance / credit balance.
        [HttpGet]
        public async Task<IActionResult> GetAdvance(int studentId)
        {
            var balance = await _feePaymentService.GetStudentAdvanceAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(new { balance });
        }

        // ── GET: /fees/fee/GetStudentDues ─────────────────────────
        // Returns the student's outstanding dues grouped into the counter's cycle
        // tabs (Monthly / Quarterly / Yearly). Reads core.student_ledger.
        [HttpGet]
        public async Task<IActionResult> GetStudentDues(int studentId)
        {
            var dues = await _feePaymentService.GetStudentDuesAsync(studentId, TenantId(), SchoolId(), UserId());
            var today = Dates.Today;

            object Map(IEnumerable<EduCoreDataAccessLayer.Models.ERP.StudentDueItem> items) =>
                items.Select(d => new
                {
                    id       = d.LedgerId,
                    label    = string.IsNullOrWhiteSpace(d.InstallmentLabel)
                                 ? d.FeeHeadName
                                 : $"{d.FeeHeadName} — {d.InstallmentLabel}",
                    dueDate  = d.DueDate,
                    amount   = d.Outstanding,           // payable now (due − paid − concession)
                    refundable = d.IsRefundable,
                    session  = d.AcademicYear ?? "",      // the page splits what is owed by session
                    carriedFrom = d.CarriedFrom ?? "",    // Year-End moved it here from this older session
                    overdue  = d.DueDate != null && string.CompareOrdinal(d.DueDate, today) < 0
                }).ToList();

            // Monthly / Quarterly buckets keep their cycle; everything else (Yearly,
            // Half Yearly, One Time, Annual) collapses into the Yearly tab.
            return Json(new
            {
                Monthly   = Map(dues.Where(d => Cycle(d.Frequency) == "Monthly")),
                Quarterly = Map(dues.Where(d => Cycle(d.Frequency) == "Quarterly")),
                Yearly    = Map(dues.Where(d => Cycle(d.Frequency) == "Yearly"))
            });
        }

        // ── POST: /fees/fee/Collect ───────────────────────────────
        // Collects payment against the exact dues the cashier picked. Each item
        // carries its own cash amount and optional concession (waiver).
        [HttpPost]
        [HasPermission("fees.collect")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Collect([FromBody] CollectRequest req)
        {
            // Giving a concession is its own permission, so a cashier can take money
            // without being able to waive it.
            if (req?.Items != null && req.Items.Any(i => i.Concession > 0)
                && !await HasPermissionAttribute.UserHasAsync(this, "fees.concession"))
                return Json(new { success = false, message = "You do not have permission to give a concession." });

            // No dues is fine when there is an extra charge (a lost ID card, a fine):
            // the check below refuses only a request with neither.
            if (req == null || req.StudentId <= 0)
                return Json(new { success = false, message = "Select at least one due to collect." });

            var items = (req.Items ?? new List<CollectItem>())
                .Where(i => i.LedgerId > 0 && (i.Amount > 0 || i.Concession > 0))
                .Select(i => new EduCoreDataAccessLayer.Models.ERP.FeeCollectItem
                {
                    LedgerId   = i.LedgerId,
                    Amount     = i.Amount,
                    Concession = i.Concession
                }).ToList();

            var extras = (req.Extras ?? new List<ExtraCharge>())
                .Where(e => e.Amount > 0 && !string.IsNullOrWhiteSpace(e.Label))
                .Select(e => new EduCoreDataAccessLayer.Models.ERP.FeeExtraItem
                {
                    Label  = e.Label!.Trim(),
                    Amount = e.Amount,
                    Note   = NullIfEmpty(e.Note)
                }).ToList();

            if (items.Count == 0 && extras.Count == 0)
                return Json(new { success = false, message = "Enter an amount/concession on a due, or add an extra charge." });

            // The page spreads the discount over the picked dues, and used to cap it
            // there: a 2,000 discount on a 1,500 due quietly became a full waiver.
            // A flat discount must land in full, and a percentage cannot pass 100.
            bool percent = string.Equals(req.DiscountType, "Percent", StringComparison.OrdinalIgnoreCase);
            if ((percent && req.DiscountValue > 100m)
                || (!percent && req.DiscountValue > 0 && req.DiscountValue > items.Sum(i => i.Concession) + 0.01m))
                return Json(new { success = false, message = "Discount cannot exceed the payable amount." });

            var tenders = (req.Tenders ?? new List<TenderLine>())
                .Where(t => t.Amount > 0)
                .Select(t => new EduCoreDataAccessLayer.Models.ERP.FeeTenderItem
                {
                    Mode      = NullIfEmpty(t.Mode) ?? "Cash",
                    Amount    = t.Amount,
                    Reference = NullIfEmpty(t.Reference)
                }).ToList();

            var result = await _feePaymentService.CollectPaymentAsync(
                req.StudentId, items, extras,
                NullIfEmpty(req.Mode) ?? "Cash",
                NullIfEmpty(req.Reference),
                NullIfEmpty(req.Remarks),
                NullIfEmpty(req.Session),
                TenantId(), SchoolId(), UserId(),
                NullIfEmpty(req.DiscountType), req.DiscountValue, NullIfEmpty(req.DiscountReason),
                tenders.Count > 0 ? tenders : null, req.AdvanceUsed,
                // The person who gives a discount is the signed-in user (their fees.concession
                // key is what allows it); a name picked from a list proved nothing (QA BUG-063).
                NullIfEmpty(req.ClientRef), req.DiscountValue > 0 ? CurrentUserName() : null);

            return Json(new
            {
                success         = result.Success,
                message         = result.Message,
                receiptNo       = result.ReceiptNo,
                amount          = result.Amount,
                concessionTotal = result.ConcessionTotal,
                paymentDate     = result.PaymentDate
            });
        }

        public class CollectRequest
        {
            public int    StudentId { get; set; }
            public string? Mode      { get; set; }
            public string? Reference { get; set; }
            public string? Remarks   { get; set; }
            public string? Session   { get; set; }
            public List<CollectItem>  Items  { get; set; } = new();
            public List<ExtraCharge>  Extras { get; set; } = new();
            public string?  DiscountType   { get; set; }   // Flat | Percent
            public decimal  DiscountValue  { get; set; }
            public string?  DiscountReason { get; set; }
            public string?  DiscountApprovedBy { get; set; }
            public List<TenderLine> Tenders { get; set; } = new();
            public decimal AdvanceUsed { get; set; }
            // One id per settlement on the counter; a retried POST with the same id
            // returns the first receipt instead of taking the money again.
            public string? ClientRef { get; set; }
        }

        public class TenderLine
        {
            public string?  Mode      { get; set; }
            public decimal  Amount    { get; set; }
            public string?  Reference { get; set; }
        }

        public class CollectItem
        {
            public int     LedgerId   { get; set; }
            public decimal Amount     { get; set; }
            public decimal Concession { get; set; }
        }

        public class ExtraCharge
        {
            public string? Label  { get; set; }
            public decimal Amount { get; set; }
            public string? Note   { get; set; }
        }

        // ── GET: /fees/fee/GetHistory ─────────────────────────────
        // Every receipt issued for a student AND every refund voucher, so the
        // History tab shows money in and money out (for review + re-print).
        [HttpGet]
        public async Task<IActionResult> GetHistory(int studentId)
        {
            var history = await _feePaymentService.GetPaymentHistoryAsync(studentId, TenantId(), SchoolId(), UserId());
            var refunds = await _feePaymentService.GetRefundHistoryAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                receipts = history.Select(h => new
                {
                    receiptNo     = h.ReceiptNo,
                    date          = h.PaymentDate,
                    amount        = h.Amount,
                    concession    = h.ConcessionTotal,
                    mode          = h.PaymentMode,
                    reference     = h.ReferenceNo,
                    type          = h.PaymentType,
                    advanceUsed   = h.AdvanceUsed,
                    advanceCredit = h.AdvanceCredit,
                    collectedBy   = h.CollectedBy,
                    isCancelled   = h.IsCancelled,
                    cancelReason  = h.CancelReason,
                    cancelledBy   = h.CancelledByName,
                    cancelledAt   = h.CancelledAt?.ToString("yyyy-MM-dd HH:mm"),
                    authorisedBy  = h.CancelAuthorizedBy
                }),
                refunds = refunds.Select(r => new
                {
                    refundNo   = r.RefundNo,
                    date       = r.RefundDate,
                    amount     = r.Amount,
                    mode       = r.Mode,
                    reason     = r.Reason,
                    authorised = r.AuthorizedBy,
                    refundedBy = r.RefundedBy,
                    against    = r.Against
                })
            });
        }

        // ── GET: /fees/fee/GetRefundables ─────────────────────────
        // Paid charges that still have cash retained and can be refunded (deposits
        // first), plus the advance wallet as ledgerId 0 when it holds money.
        [HttpGet]
        public async Task<IActionResult> GetRefundables(int studentId)
        {
            var rows = await _feePaymentService.GetRefundablesAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(r => new
            {
                ledgerId     = r.LedgerId,   // 0 = advance (wallet) balance
                label        = string.IsNullOrWhiteSpace(r.InstallmentLabel) ? r.FeeHeadName : $"{r.FeeHeadName} — {r.InstallmentLabel}",
                refundable   = r.Refundable,
                paid         = r.AmountPaid,
                refunded     = r.Refunded,
                isRefundable = r.IsRefundable
            }));
        }

        // ── POST: /fees/fee/Refund ────────────────────────────────
        // Returns money against a paid charge (refundable deposit / overpayment),
        // or — with LedgerId 0 — the student's advance (wallet) balance at exit.
        [HttpPost]
        [HasPermission("fees.refund")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Refund([FromBody] RefundRequest req)
        {
            if (req == null || req.StudentId <= 0 || req.LedgerId < 0)
                return Json(new { success = false, message = "Pick a charge to refund." });
            if (req.Amount <= 0)
                return Json(new { success = false, message = "Enter a refund amount." });
            if (string.IsNullOrWhiteSpace(req.Reason))
                return Json(new { success = false, message = "A reason is required to refund." });
            // authorised by the signed-in person, who holds fees.refund (QA BUG-063)
            var (ok, msg, refundNo) = await _feePaymentService.RecordRefundAsync(
                req.StudentId, req.LedgerId, req.Amount,
                NullIfEmpty(req.Mode) ?? "Cash", req.Reason!.Trim(), CurrentUserName(),
                TenantId(), SchoolId(), UserId());

            return Json(new { success = ok, message = msg, refundNo });
        }

        public class RefundRequest
        {
            public int     StudentId    { get; set; }
            public int     LedgerId     { get; set; }
            public decimal Amount       { get; set; }
            public string? Mode         { get; set; }
            public string? Reason       { get; set; }
            public string? AuthorizedBy { get; set; }
        }

        // ── Year-End closure: /fees/year-end ───────────────────
        // Unpaid dues of a session, each carried forward or written off before
        // the session is closed. Seeing it needs fees.view; acting needs fees.manage.
        [Route("fees/year-end")]
        public async Task<IActionResult> YearEnd()
        {
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "fees.manage");
            // Writing dues off is for the head of school (QA BUG-091), not the fee counter.
            ViewBag.CanWriteOff = await HasPermissionAttribute.UserHasAsync(this, "fees.writeoff");
            List<SelectListItem> sessions;
            try
            {
                sessions = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString());
            }
            catch { sessions = new List<SelectListItem>(); }

            // Year-End closes the session that has just ENDED: once the new one is current,
            // open on the latest earlier session ("2026-27" before "2027-28" by name) while it
            // is not closed and still has lines to decide. Otherwise stay on the current one.
            var current = sessions.FirstOrDefault(x => x.Selected)?.Text;
            var previous = sessions.Select(x => x.Text)
                .Where(t => current != null && string.CompareOrdinal(t, current) < 0)
                .OrderByDescending(t => t, StringComparer.Ordinal)
                .FirstOrDefault();
            var prevStatus = previous == null ? null
                           : await _feePaymentService.GetYearEndStatusAsync(previous, TenantId(), SchoolId(), UserId());
            if (prevStatus != null && prevStatus.ClosedAt == null && prevStatus.OpenLines > 0)
            {
                foreach (var x in sessions) x.Selected = x.Text == previous;
            }
            ViewBag.Sessions = sessions;
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> GetYearEndLines(string? session)
        {
            if (string.IsNullOrWhiteSpace(session))
                return Json(Array.Empty<object>());

            var rows = await _feePaymentService.GetYearEndLinesAsync(session.Trim(), TenantId(), SchoolId(), UserId());
            return Json(rows.Select(r => new
            {
                id       = r.LedgerId,
                sid      = r.StudentId,
                name     = r.StudentName,
                adm      = r.AdmissionNo,
                cls      = r.ClassName,
                sec      = r.Section,
                guardian = r.GuardianName,
                mobile   = r.Mobile,
                head     = r.FeeHead,
                inst     = r.Installment,
                due      = r.DueDate,
                amount   = r.Amount,
                state    = r.State,
                notDue   = r.NotDue,
                next     = r.NextSession,
                reason   = r.Reason,
                decided  = r.DecidedAt?.ToString("dd MMM yyyy")
            }));
        }

        // The session as a whole: is there a next session, is it closed, what is left.
        [HttpGet]
        public async Task<IActionResult> GetYearEndStatus(string? session)
        {
            if (string.IsNullOrWhiteSpace(session)) return Json(new { });
            var st = await _feePaymentService.GetYearEndStatusAsync(session.Trim(), TenantId(), SchoolId(), UserId());
            return Json(new
            {
                next     = st.NextSession,
                closedAt = st.ClosedAt?.ToString("dd MMM yyyy"),
                closedBy = st.ClosedBy,
                open     = st.OpenLines,
                notDue   = st.NotDueLines
            });
        }

        [HttpPost]
        [HasPermission("fees.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> YearEndAction([FromBody] YearEndRequest req)
        {
            var allowed = new[] { "Carry", "WriteOff", "Undo", "CarryAll", "Close", "Reopen" };
            if (req == null || string.IsNullOrWhiteSpace(req.Session) || !allowed.Contains(req.Operation))
                return Json(new { success = false, message = "Invalid request." });
            if (req.Operation == "WriteOff" && !await HasPermissionAttribute.UserHasAsync(this, "fees.writeoff"))
                return Json(new { success = false, message = "Writing dues off needs the school admin or principal." });
            // Opening a closed session again is the head of school's call, like a write-off.
            if (req.Operation == "Reopen" && !await HasPermissionAttribute.UserHasAsync(this, "fees.writeoff"))
                return Json(new { success = false, message = "Re-opening a closed session needs the school admin or principal." });

            var (ok, msg) = await _feePaymentService.YearEndActionAsync(
                req.Operation!, req.Session!.Trim(), req.LedgerId, req.StudentId, NullIfEmpty(req.Reason),
                TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        public class YearEndRequest
        {
            public string? Operation { get; set; }   // Carry | WriteOff | Undo | CarryAll | Close | Reopen
            public string? Session   { get; set; }
            public int?    LedgerId  { get; set; }
            public int?    StudentId { get; set; }
            public string? Reason    { get; set; }
        }

        // ── GET: /fees/fee/GetCollectionRegister ──────────────────
        [HttpGet]
        public async Task<IActionResult> GetCollectionRegister(string? from = null, string? to = null,
                                                               string? className = null, string? section = null)
        {
            var f = Dates.Norm(from);
            var t = Dates.Norm(to);
            var reg = await _feePaymentService.GetCollectionRegisterAsync(f, t, TenantId(), SchoolId(), UserId(),
                NullIfEmpty(className), NullIfEmpty(section));

            // Money OUT for the same range. A register that only counts money in
            // overstates what the school actually holds, so report NET as well.
            var refunds = await _feePaymentService.GetRefundRegisterAsync(f, t, TenantId(), SchoolId(), UserId());

            return Json(new
            {
                from  = reg.From,
                to    = reg.To,
                total = reg.Total,
                refundTotal = refunds.Total,
                net         = reg.Total - refunds.Total,
                refunds = refunds.Rows.Select(r => new
                {
                    refundNo   = r.RefundNo,
                    date       = r.RefundedAt?.ToString("dd MMM yyyy, hh:mm tt"),
                    student    = r.StudentName,
                    admNo      = r.AdmissionNo,
                    cls        = string.IsNullOrWhiteSpace(r.ClassName) ? "" : $"{r.ClassName}{(string.IsNullOrWhiteSpace(r.Section) ? "" : " - " + r.Section)}",
                    against    = string.IsNullOrWhiteSpace(r.FeeHeadName) ? "—" : $"{r.FeeHeadName}{(string.IsNullOrWhiteSpace(r.InstallmentLabel) ? "" : " (" + r.InstallmentLabel + ")")}",
                    mode       = r.Mode,
                    reason     = r.Reason,
                    authorised = r.AuthorizedBy,
                    by         = r.RefundedByName,
                    amount     = r.Amount
                }),
                refundModes = refunds.Modes.Select(m => new { mode = m.Mode, count = m.Count, amount = m.Amount }),
                // A cancellation is its own negative line on the day it was cancelled;
                // the receipt itself stays on its own day (flagged "cancelled").
                receiptCount = reg.Receipts.Count(r => r.Entry == "Receipt"),
                receipts = reg.Receipts.Select(r => new
                {
                    entry     = r.Entry,
                    lineDate  = Dates.Show(r.LineDate),   // "12 Oct 2026", like the refund rows (QA BUG-096)
                    cancelled = r.IsCancelled,
                    cancelReason = r.CancelReason,
                    cashier   = r.CashierName,
                    receiptNo = r.ReceiptNo,
                    date      = Dates.Show(r.Date),
                    student   = r.StudentName,
                    admNo     = r.AdmissionNo,
                    cls       = string.IsNullOrWhiteSpace(r.ClassName) ? "" : $"{r.ClassName}{(string.IsNullOrWhiteSpace(r.Section) ? "" : " - " + r.Section)}",
                    mode      = r.Mode,
                    type      = r.PaymentType,
                    heads     = r.FeeHeads,
                    reference = r.ReferenceNo,
                    discount  = r.DiscountTotal,
                    amount    = r.Amount
                }),
                modes = reg.Modes.Select(m => new { mode = m.Mode, count = m.Count, amount = m.Amount }),
                heads = reg.Heads.Select(h => new { head = h.Head, count = h.Count, amount = h.Amount })
            });
        }

        // ── GET: /fees/fee/GetConcessionCancelRegister ───────────
        [HttpGet]
        public async Task<IActionResult> GetConcessionCancelRegister(string? from = null, string? to = null)
        {
            var f = Dates.Norm(from);
            var t = Dates.Norm(to);
            var (concessions, cancels) = await _feePaymentService.GetConcessionCancelRegisterAsync(f, t, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                concessions = concessions.Select(c => new
                {
                    receiptNo = c.ReceiptNo,
                    date      = c.Date,
                    student   = c.Student,
                    admNo     = c.AdmNo,
                    amount    = c.Concession,
                    type      = c.PaymentType,
                    cancelled = c.IsCancelled,
                    givenBy   = c.GivenBy,
                    approvedBy = c.ApprovedBy,
                    kind      = c.DiscountType == "Percent" ? $"{c.DiscountValue}%" : (c.DiscountType ?? ""),
                    reason    = c.Reason
                }),
                cancels = cancels.Select(c => new
                {
                    receiptNo = c.ReceiptNo,
                    date      = c.Date,
                    student   = c.Student,
                    admNo     = c.AdmNo,
                    amount    = c.Amount,
                    cancelledAt = c.CancelledAt?.ToString("dd MMM yyyy, hh:mm tt"),
                    cancelledBy = c.CancelledBy,
                    collectedBy = c.CollectedBy,
                    authorisedBy = c.AuthorizedBy,
                    reason    = c.Reason
                })
            });
        }

        // ── GET: /fees/fee/GetDefaulters ──────────────────────────
        [HttpGet]
        // session blank = all sessions.
        public async Task<IActionResult> GetDefaulters(string? className = null, string? section = null, string? session = null)
        {
            var rows = await _feePaymentService.GetDefaultersAsync(
                NullIfEmpty(className), NullIfEmpty(section), TenantId(), SchoolId(), UserId(), NullIfEmpty(session));
            return Json(rows.Select(d => new
            {
                entry       = d.Entry,          // Student | Registration (not admitted yet)
                status      = d.StudentStatus,  // Active | Transfer | Passout ... | Registered
                student     = d.StudentName,
                admNo       = d.AdmissionNo,
                cls         = string.IsNullOrWhiteSpace(d.ClassName) ? "" : $"{d.ClassName}{(string.IsNullOrWhiteSpace(d.Section) ? "" : " - " + d.Section)}",
                roll        = d.RollNo,
                outstanding = d.TotalOutstanding,
                notDue      = d.NotDue,
                d0_30       = d.D0_30,
                d31_60      = d.D31_60,
                d60plus     = d.D60Plus
            }));
        }

        // ── Helpers ──────────────────────────────────────────────
        private static string Cycle(string? frequency) => frequency switch
        {
            "Monthly"   => "Monthly",
            "Quarterly" => "Quarterly",
            _           => "Yearly"
        };

        private async Task<int> ResolveAcademicYearIdAsync(string session)
        {
            var ayItems = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString());
            var ay = ayItems.FirstOrDefault(x => string.Equals(x.Text, session, StringComparison.OrdinalIgnoreCase));
            return ay != null && int.TryParse(ay.Value, out var id) ? id : 0;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
        private string CurrentUserName() => User.FindFirst(Common.SK_UserName)?.Value ?? User.Identity?.Name ?? "User #" + UserId();
    }
}
