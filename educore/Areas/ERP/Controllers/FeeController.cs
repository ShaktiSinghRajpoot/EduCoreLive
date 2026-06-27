using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    // Fee counter + day-close + reports. The two Inventory stub pages
    // (InventoryItem/PurchaseEntry) also live here for now, so the whole
    // controller is gated by fees.view until Inventory gets its own module.
    [HasPermission("fees.view")]
    public class FeeController : Controller
    {
        private readonly IBaseService _baseService;
        private readonly IAdmissionService _admissionService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IFeePaymentService _feePaymentService;

        public FeeController(
            IBaseService baseService,
            IAdmissionService admissionService,
            ISchoolSettingsService schoolSettingsService,
            IFeePaymentService feePaymentService)
        {
            _baseService = baseService;
            _admissionService = admissionService;
            _schoolSettingsService = schoolSettingsService;
            _feePaymentService = feePaymentService;
        }

        // ── Pages ────────────────────────────────────────────────
        public IActionResult ManageFee() => View();
        public IActionResult DayClose() => View();
        public IActionResult Reports() => View();
        public IActionResult InventoryItem() => View();
        public IActionResult PurchaseEntry() => View();

        // ── GET: /ERP/Fee/GetSessions ────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetSessions()
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            return Json(items.Select(x => x.Text).ToList());
        }

        // ── GET: /ERP/Fee/GetClasses ─────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetClasses(string? session = null)
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class");
            return Json(items.Select(x => x.Text).ToList());
        }

        // ── GET: /ERP/Fee/GetSections ────────────────────────────
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

        // ── GET: /ERP/Fee/GetStudents ────────────────────────────
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

        // ── GET: /ERP/Fee/FindByAdmission ────────────────────────
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

        // ── GET: /ERP/Fee/GetAdvance ─────────────────────────────
        // The student's current advance / credit balance.
        [HttpGet]
        public async Task<IActionResult> GetAdvance(int studentId)
        {
            var balance = await _feePaymentService.GetStudentAdvanceAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(new { balance });
        }

        // ── GET: /ERP/Fee/GetStudentDues ─────────────────────────
        // Returns the student's outstanding dues grouped into the counter's cycle
        // tabs (Monthly / Quarterly / Yearly). Reads core.student_ledger.
        [HttpGet]
        public async Task<IActionResult> GetStudentDues(int studentId)
        {
            var dues = await _feePaymentService.GetStudentDuesAsync(studentId, TenantId(), SchoolId(), UserId());
            var today = DateOnly.FromDateTime(DateTime.Today);

            object Map(IEnumerable<EduCoreDataAccessLayer.Models.Admin.StudentDueItem> items) =>
                items.Select(d => new
                {
                    id       = d.LedgerId,
                    label    = string.IsNullOrWhiteSpace(d.InstallmentLabel)
                                 ? d.FeeHeadName
                                 : $"{d.FeeHeadName} — {d.InstallmentLabel}",
                    dueDate  = d.DueDate?.ToString("yyyy-MM-dd"),
                    amount   = d.Outstanding,           // payable now (due − paid − concession)
                    overdue  = d.DueDate.HasValue && d.DueDate.Value < today
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

        // ── POST: /ERP/Fee/Collect ───────────────────────────────
        // Collects payment against the exact dues the cashier picked. Each item
        // carries its own cash amount and optional concession (waiver).
        [HttpPost]
        [HasPermission("fees.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Collect([FromBody] CollectRequest req)
        {
            if (req == null || req.StudentId <= 0 || req.Items == null || req.Items.Count == 0)
                return Json(new { success = false, message = "Select at least one due to collect." });

            var items = req.Items
                .Where(i => i.LedgerId > 0 && (i.Amount > 0 || i.Concession > 0))
                .Select(i => new EduCoreDataAccessLayer.Models.Admin.FeeCollectItem
                {
                    LedgerId   = i.LedgerId,
                    Amount     = i.Amount,
                    Concession = i.Concession
                }).ToList();

            var extras = (req.Extras ?? new List<ExtraCharge>())
                .Where(e => e.Amount > 0 && !string.IsNullOrWhiteSpace(e.Label))
                .Select(e => new EduCoreDataAccessLayer.Models.Admin.FeeExtraItem
                {
                    Label  = e.Label!.Trim(),
                    Amount = e.Amount
                }).ToList();

            if (items.Count == 0 && extras.Count == 0)
                return Json(new { success = false, message = "Enter an amount/concession on a due, or add an extra charge." });

            var tenders = (req.Tenders ?? new List<TenderLine>())
                .Where(t => t.Amount > 0)
                .Select(t => new EduCoreDataAccessLayer.Models.Admin.FeeTenderItem
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
                tenders.Count > 0 ? tenders : null, req.AdvanceUsed);

            return Json(new
            {
                success         = result.Success,
                message         = result.Message,
                receiptNo       = result.ReceiptNo,
                amount          = result.Amount,
                concessionTotal = result.ConcessionTotal,
                paymentDate     = result.PaymentDate?.ToString("yyyy-MM-dd")
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
            public List<TenderLine> Tenders { get; set; } = new();
            public decimal AdvanceUsed { get; set; }
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
        }

        // ── GET: /ERP/Fee/GetHistory ─────────────────────────────
        // Every receipt issued for a student (for the History tab + re-print).
        [HttpGet]
        public async Task<IActionResult> GetHistory(int studentId)
        {
            var history = await _feePaymentService.GetPaymentHistoryAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(history.Select(h => new
            {
                receiptNo    = h.ReceiptNo,
                date         = h.PaymentDate?.ToString("yyyy-MM-dd"),
                amount       = h.Amount,
                concession   = h.ConcessionTotal,
                mode         = h.PaymentMode,
                reference    = h.ReferenceNo,
                isCancelled  = h.IsCancelled,
                cancelReason = h.CancelReason
            }));
        }

        // ── POST: /ERP/Fee/CancelReceipt ─────────────────────────
        // Voids a receipt: reverses its ledger allocation (re-opens the dues) and
        // marks it Cancelled with reason + authoriser. The receipt is kept on record.
        [HttpPost]
        [HasPermission("fees.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CancelReceipt([FromBody] CancelReceiptRequest req)
        {
            if (req == null || string.IsNullOrWhiteSpace(req.ReceiptNo))
                return Json(new { success = false, message = "Receipt number is required." });
            if (string.IsNullOrWhiteSpace(req.Reason))
                return Json(new { success = false, message = "A reason is required to cancel a receipt." });

            var (ok, msg) = await _feePaymentService.CancelReceiptAsync(
                req.ReceiptNo.Trim(), req.Reason.Trim(), NullIfEmpty(req.AuthorizedBy),
                TenantId(), SchoolId(), UserId());

            return Json(new { success = ok, message = msg });
        }

        public class CancelReceiptRequest
        {
            public string? ReceiptNo    { get; set; }
            public string? Reason       { get; set; }
            public string? AuthorizedBy { get; set; }
        }

        // ── GET: /ERP/Fee/GetRefundables ─────────────────────────
        // Paid charges that still have cash retained and can be refunded (deposits first).
        [HttpGet]
        public async Task<IActionResult> GetRefundables(int studentId)
        {
            var rows = await _feePaymentService.GetRefundablesAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(r => new
            {
                ledgerId     = r.LedgerId,
                label        = string.IsNullOrWhiteSpace(r.InstallmentLabel) ? r.FeeHeadName : $"{r.FeeHeadName} — {r.InstallmentLabel}",
                refundable   = r.Refundable,
                paid         = r.AmountPaid,
                refunded     = r.Refunded,
                isRefundable = r.IsRefundable
            }));
        }

        // ── POST: /ERP/Fee/Refund ────────────────────────────────
        // Returns money against a paid charge (refundable deposit / overpayment).
        [HttpPost]
        [HasPermission("fees.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Refund([FromBody] RefundRequest req)
        {
            if (req == null || req.StudentId <= 0 || req.LedgerId <= 0)
                return Json(new { success = false, message = "Pick a charge to refund." });
            if (req.Amount <= 0)
                return Json(new { success = false, message = "Enter a refund amount." });
            if (string.IsNullOrWhiteSpace(req.Reason))
                return Json(new { success = false, message = "A reason is required to refund." });

            var (ok, msg, refundNo) = await _feePaymentService.RecordRefundAsync(
                req.StudentId, req.LedgerId, req.Amount,
                NullIfEmpty(req.Mode) ?? "Cash", req.Reason!.Trim(), NullIfEmpty(req.AuthorizedBy),
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

        // ── GET: /ERP/Fee/GetDayCollection ───────────────────────
        // The logged-in cashier's collection for a day, mode-wise, for reconciliation.
        [HttpGet]
        public async Task<IActionResult> GetDayCollection(string? date = null)
        {
            DateOnly? d = DateOnly.TryParse(date, out var parsed) ? parsed : null;
            var day = await _feePaymentService.GetDayCollectionAsync(d, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                date           = day.Date.ToString("yyyy-MM-dd"),
                totalCollected = day.TotalCollected,
                receiptCount   = day.ReceiptCount,
                cancelledCount = day.CancelledCount,
                cashCollected  = day.CashCollected,
                totalRefunded  = day.TotalRefunded,
                cashRefunded   = day.CashRefunded,
                expectedCash   = day.ExpectedCash,
                isClosed       = day.IsClosed,
                countedCash    = day.CountedCash,
                difference     = day.Difference,
                closeRemarks   = day.CloseRemarks,
                modes          = day.Modes.Select(m => new { mode = m.Mode, amount = m.Amount, count = m.Count })
            });
        }

        // ── POST: /ERP/Fee/CloseDay ──────────────────────────────
        [HttpPost]
        [HasPermission("fees.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CloseDay([FromBody] CloseDayRequest req)
        {
            if (req == null)
                return Json(new { success = false, message = "Invalid request." });

            DateOnly? d = DateOnly.TryParse(req.Date, out var parsed) ? parsed : null;
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

        // ── GET: /ERP/Fee/GetCollectionRegister ──────────────────
        [HttpGet]
        public async Task<IActionResult> GetCollectionRegister(string? from = null, string? to = null)
        {
            DateOnly? f = DateOnly.TryParse(from, out var pf) ? pf : null;
            DateOnly? t = DateOnly.TryParse(to,   out var pt) ? pt : null;
            var reg = await _feePaymentService.GetCollectionRegisterAsync(f, t, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                from  = reg.From.ToString("yyyy-MM-dd"),
                to    = reg.To.ToString("yyyy-MM-dd"),
                total = reg.Total,
                receipts = reg.Receipts.Select(r => new
                {
                    receiptNo = r.ReceiptNo,
                    date      = r.Date?.ToString("yyyy-MM-dd"),
                    student   = r.StudentName,
                    admNo     = r.AdmissionNo,
                    cls       = string.IsNullOrWhiteSpace(r.ClassName) ? "" : $"{r.ClassName}{(string.IsNullOrWhiteSpace(r.Section) ? "" : " - " + r.Section)}",
                    mode      = r.Mode,
                    amount    = r.Amount
                }),
                modes = reg.Modes.Select(m => new { mode = m.Mode, count = m.Count, amount = m.Amount }),
                heads = reg.Heads.Select(h => new { head = h.Head, count = h.Count, amount = h.Amount })
            });
        }

        // ── GET: /ERP/Fee/GetConcessionCancelRegister ───────────
        [HttpGet]
        public async Task<IActionResult> GetConcessionCancelRegister(string? from = null, string? to = null)
        {
            DateOnly? f = DateOnly.TryParse(from, out var pf) ? pf : null;
            DateOnly? t = DateOnly.TryParse(to,   out var pt) ? pt : null;
            var (concessions, cancels) = await _feePaymentService.GetConcessionCancelRegisterAsync(f, t, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                concessions = concessions.Select(c => new
                {
                    receiptNo = c.ReceiptNo,
                    date      = c.Date?.ToString("yyyy-MM-dd"),
                    student   = c.Student,
                    admNo     = c.AdmNo,
                    amount    = c.Concession,
                    kind      = c.DiscountType == "Percent" ? $"{c.DiscountValue}%" : (c.DiscountType ?? ""),
                    reason    = c.Reason
                }),
                cancels = cancels.Select(c => new
                {
                    receiptNo = c.ReceiptNo,
                    date      = c.Date?.ToString("yyyy-MM-dd"),
                    student   = c.Student,
                    admNo     = c.AdmNo,
                    amount    = c.Amount,
                    cancelledAt = c.CancelledAt?.ToString("yyyy-MM-dd"),
                    authorisedBy = c.AuthorizedBy,
                    reason    = c.Reason
                })
            });
        }

        // ── GET: /ERP/Fee/GetDefaulters ──────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetDefaulters(string? className = null, string? section = null)
        {
            var rows = await _feePaymentService.GetDefaultersAsync(
                NullIfEmpty(className), NullIfEmpty(section), TenantId(), SchoolId(), UserId());
            return Json(rows.Select(d => new
            {
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

        // ── GET: /ERP/Fee/GetReceipt ─────────────────────────────
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
                label      = string.IsNullOrWhiteSpace(l.InstallmentLabel) ? l.FeeHeadName : $"{l.FeeHeadName} — {l.InstallmentLabel}",
                amount     = l.Amount,
                concession = l.Concession,
                lineType   = l.LineType
            }).ToList();

            if (lines.Count == 0)
                lines.Add(new { label = r.PaymentType == "Registration" ? "Registration Fee" : "Fee", amount = r.Amount, concession = 0m, lineType = "Due" });

            return Json(new
            {
                school,
                receiptNo   = r.ReceiptNo,
                date        = r.PaymentDate?.ToString("yyyy-MM-dd"),
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
                student     = new { name = r.StudentName, admNo = r.AdmissionNo, className = r.ClassName, section = r.Section, roll = r.RollNo },
                lines
            });
        }

        // ── GET: /ERP/Fee/GetSchoolHeader ────────────────────────
        // School name + address for the receipt header (fetched once on load).
        [HttpGet]
        public async Task<IActionResult> GetSchoolHeader() => Json(await GetSchoolHeaderAsync());

        private async Task<object> GetSchoolHeaderAsync()
        {
            var profile = await _schoolSettingsService.GetBasicProfileAsync(TenantId(), SchoolId(), UserId());
            var addressParts = new[] { profile?.AddressLine1, profile?.City, profile?.State }
                .Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => p!.Trim());
            return new
            {
                name    = string.IsNullOrWhiteSpace(profile?.SchoolName) ? "Your School" : profile!.SchoolName.Trim(),
                address = string.Join(", ", addressParts)
            };
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
            var ayItems = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            var ay = ayItems.FirstOrDefault(x => string.Equals(x.Text, session, StringComparison.OrdinalIgnoreCase));
            return ay != null && int.TryParse(ay.Value, out var id) ? id : 0;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    }
}
