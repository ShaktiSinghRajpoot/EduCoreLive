using System.Text.Json;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("students.view")]
    public class AdmissionController : Controller
    {
        private readonly IAdmissionService _admissionService;
        private readonly IEnquiryService _enquiryService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IAdmissionWorkflowService _admissionWorkflowService;
        private readonly IFeePaymentService _feePaymentService;
        private readonly IBaseService _baseService;
        private readonly ITransportService _transportService;

        public AdmissionController(IAdmissionService admissionService, IEnquiryService enquiryService, ISchoolSettingsService schoolSettingsService, IAdmissionWorkflowService admissionWorkflowService, IFeePaymentService feePaymentService, IBaseService baseService, ITransportService transportService)
        {
            _admissionService = admissionService;
            _enquiryService = enquiryService;
            _schoolSettingsService = schoolSettingsService;
            _admissionWorkflowService = admissionWorkflowService;
            _feePaymentService = feePaymentService;
            _baseService = baseService;
            _transportService = transportService;
        }

        // ── GET: /ERP/Admission/GetTransportRoutes (AJAX) ────────
        // Routes + stops for the optional "uses transport" panel on the form.
        [HttpGet]
        public async Task<IActionResult> GetTransportRoutes()
        {
            var rows = await _transportService.GetRoutesDropdownAsync(TenantId(), SchoolId(), UserId());
            var routes = rows.GroupBy(r => new { r.RouteId, r.RouteName })
                .Select(g => new
                {
                    routeId   = g.Key.RouteId,
                    routeName = g.Key.RouteName,
                    stops     = g.Select(s => new { stopId = s.StopId, stopName = s.StopName, fare = s.MonthlyFare })
                });
            return Json(routes);
        }

        // Registration gate: when the school requires registration before admission,
        // an enquiry must be "Registration Done" before it can be converted.
        private async Task<bool> RegistrationSatisfiedAsync(EnquiryModel enquiry, int tenantId, int schoolId, int userId)
        {
            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, userId);
            if (!workflow.EnableRegistration || !workflow.RegistrationRequiredBeforeAdmission)
                return true;
            return string.Equals(enquiry.Status, "Registration Done", StringComparison.OrdinalIgnoreCase);
        }

        // ── Pages ────────────────────────────────────────────────
        // The student list is consolidated into a single page under the
        // Student controller. This old route redirects there so existing
        // links/bookmarks keep working.
        public IActionResult StudentList()
            => RedirectToAction("StudentList", "Student", new { area = "ERP" });

        public IActionResult Dashboard() => View();

        // ── GET: /ERP/Admission/Create?enquiryId= ────────────────
        // Opens the admission page; when an enquiry id is supplied the
        // view pre-fills the modal from the enquiry record.
        [HttpGet]
        public async Task<IActionResult> Create(int? enquiryId)
        {
            await LoadDropdownsAsync();
            if (enquiryId is > 0)
            {
                var enquiry = await _enquiryService.GetEnquiryByIdAsync(
                    enquiryId.Value, TenantId(), SchoolId(), UserId());

                if (enquiry != null)
                {
                    // Server-side registration gate (mirrors the CRM client-side check).
                    if (!await RegistrationSatisfiedAsync(enquiry, TenantId(), SchoolId(), UserId()))
                    {
                        TempData["Result"] = "0";
                        TempData["Message"] = "Complete registration before converting this enquiry to admission.";
                        return RedirectToAction("EnquiryCRM", "Enquiry", new { area = "Admin" });
                    }

                    ViewBag.PrefillEnquiryId = enquiry.EnquiryId;
                    ViewBag.PrefillJson = JsonSerializer.Serialize(new
                    {
                        enquiryId    = enquiry.EnquiryId,
                        studentName  = enquiry.StudentName,
                        gender       = enquiry.Gender,
                        className    = enquiry.ClassName,
                        academicYear = enquiry.Session,
                        guardianName = enquiry.FatherName ?? enquiry.ParentName,
                        motherName   = enquiry.MotherName,
                        mobile       = enquiry.Mobile,
                        altMobile    = enquiry.AltMobile
                    });
                }
            }
            return View("Create");
        }

        // ── POST: /ERP/Admission/SaveAdmission ───────────────────
        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveAdmission(AdmissionFormModel form)
        {
            int tenantId = TenantId(), schoolId = SchoolId(), userId = UserId();

            // ── Server-side validation ──
            var errors = new List<string>();
            if (string.IsNullOrWhiteSpace(form.StudentName)) errors.Add("Student name is required.");
            if (string.IsNullOrWhiteSpace(form.ClassName))   errors.Add("Class is required.");
            if (string.IsNullOrWhiteSpace(form.AcademicYear))errors.Add("Academic year is required.");
            if (!string.IsNullOrWhiteSpace(form.MobileNumber) &&
                !System.Text.RegularExpressions.Regex.IsMatch(form.MobileNumber, @"^\d{10}$"))
                errors.Add("Mobile number must be 10 digits.");
            if (form.DateOfBirth.HasValue && form.DateOfBirth.Value > DateOnly.FromDateTime(DateTime.Today))
                errors.Add("Date of birth cannot be in the future.");

            var (feePlan, totals, concession) = ParseLedger(form);

            if (concession.Amount > 0 && string.IsNullOrWhiteSpace(form.DiscountReason))
                errors.Add("A concession reason is required when a discount is applied.");

            // Overpay guard (mirrors the client): at admission you can collect at most the
            // amount due now. Advance / prepay must go through the Fee counter (ManageFee),
            // which has the advance-wallet support the admission screen intentionally omits.
            // This stops cash beyond the dues being silently dropped by the allocation.
            if (form.CollectFeeNow && (form.PaymentAmount ?? 0m) > totals.PayToday + 0.01m)
                errors.Add($"Amount to collect cannot exceed ₹{totals.PayToday:0} due now. Use the Fee counter for advance/prepay.");

            if (errors.Count > 0)
                return Json(new { success = false, message = string.Join(" ", errors) });

            // Registration gate — enforce on the actual mutation, not just the UI.
            if (form.EnquiryId is > 0)
            {
                var enquiry = await _enquiryService.GetEnquiryByIdAsync(form.EnquiryId.Value, tenantId, schoolId, userId);
                if (enquiry != null && !await RegistrationSatisfiedAsync(enquiry, tenantId, schoolId, userId))
                    return Json(new { success = false, message = "Complete registration before admitting this enquiry." });
            }

            var model = new AdmissionModel
            {
                AdmissionNo      = NullIfEmpty(form.AdmissionNo),
                RollNo           = NullIfEmpty(form.RollNo),
                StudentName      = form.StudentName!.Trim(),
                Gender           = NullIfEmpty(form.Gender),
                DateOfBirth      = form.DateOfBirth,
                ClassName        = form.ClassName!.Trim(),
                Section          = NullIfEmpty(form.Section),
                AcademicYear     = form.AcademicYear!.Trim(),
                AdmissionDate    = form.AdmissionDate ?? DateOnly.FromDateTime(DateTime.Today),
                GuardianName     = NullIfEmpty(form.GuardianName),
                MotherName       = NullIfEmpty(form.MotherName),
                MobileNumber     = NullIfEmpty(form.MobileNumber),
                AlternateMobile  = NullIfEmpty(form.AlternateMobile),
                Address          = NullIfEmpty(form.Address),
                BloodGroup          = NullIfEmpty(form.BloodGroup),
                Religion            = NullIfEmpty(form.Religion),
                Category            = NullIfEmpty(form.Category),
                Nationality         = NullIfEmpty(form.Nationality),
                MotherTongue        = NullIfEmpty(form.MotherTongue),
                IdProofNo           = NullIfEmpty(form.IdProofNo),
                ApaarId             = NullIfEmpty(form.ApaarId),
                UdiseStudentId      = NullIfEmpty(form.UdiseStudentId),
                PrevSchoolName      = NullIfEmpty(form.PrevSchoolName),
                PrevBoard           = NullIfEmpty(form.PrevBoard),
                PrevClass           = NullIfEmpty(form.PrevClass),
                PrevTcNo            = NullIfEmpty(form.PrevTcNo),
                FatherOccupation    = NullIfEmpty(form.FatherOccupation),
                FatherQualification = NullIfEmpty(form.FatherQualification),
                FatherEmail         = NullIfEmpty(form.FatherEmail),
                MotherOccupation    = NullIfEmpty(form.MotherOccupation),
                MotherQualification = NullIfEmpty(form.MotherQualification),
                MotherEmail         = NullIfEmpty(form.MotherEmail),
                AnnualIncome        = form.AnnualIncome,
                DocumentsJson       = NormalizeJsonArray(form.DocumentsJson),
                PayTodayTotal    = totals.PayToday,
                MonthlyTotal     = totals.Monthly,
                YearlyTotal      = totals.Yearly,
                AnnualTotal      = totals.Annual,
                ConcessionType   = NullIfEmpty(form.DiscountType),
                ConcessionValue  = concession.Value,
                ConcessionAmount = concession.Amount,
                ConcessionReason = NullIfEmpty(form.DiscountReason),
                FeePlan          = feePlan,
                EnquiryId        = form.EnquiryId is > 0 ? form.EnquiryId : null
            };

            var result = await _admissionService.SaveAdmissionAsync(model, tenantId, schoolId, userId);

            // ── Record concession + collect fee at admission ──
            // Both the cash collected now AND any admission-time concession are pushed
            // through the shared fee engine (CollectPaymentAsync), so core.student_ledger
            // stays the single source of truth. A discount on its own — even when no cash
            // is taken (school doesn't collect at admission, or the cashier unticked
            // "Collect Fee Now") — still writes a concession voucher onto the ledger.
            // Otherwise the discounted portion would linger forever as a phantom due.
            string? receiptNo = null;
            string? feeMessage = null;
            if (result.Success && result.StudentId > 0)
            {
                var workflow   = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, userId);
                var payAmount  = (form.CollectFeeNow && workflow.CollectFeeAtAdmission) ? (form.PaymentAmount ?? 0m) : 0m;
                var concAmount = concession.Amount;

                if (payAmount > 0 || concAmount > 0)
                {
                    // Itemise the lump cash + concession across the just-created dues so the
                    // receipt lists each charge (admission fee, security, …) instead of one
                    // opaque line, and the concession is recorded as real concession on each
                    // ledger row. Admission-point charges are settled first (that's what the
                    // cashier is collecting now), then the earliest scheduled dues — never
                    // over-allocating a row and never dropping cash.
                    var dues  = await _feePaymentService.GetStudentDuesAsync(result.StudentId, tenantId, schoolId, userId);

                    // Refundable deposit heads (Caution Money etc.) — the discount must skip
                    // these. The ledger doesn't carry the flag, so read it from the structure.
                    var structure = await _schoolSettingsService.GetFeeStructureDetailsAsync(
                        model.ClassName, model.AcademicYear, tenantId, schoolId, userId);
                    var refundableHeads = (structure ?? new List<FeeStructureDetailModel>())
                        .Where(s => s.IsRefundable)
                        .Select(s => s.FeeHeadName)
                        .ToHashSet(StringComparer.OrdinalIgnoreCase);

                    var items = AllocateAdmissionPayment(dues, payAmount, concAmount, refundableHeads);

                    if (items.Count > 0)
                    {
                        var res = await _feePaymentService.CollectPaymentAsync(
                            result.StudentId, items, new List<FeeExtraItem>(),
                            NullIfEmpty(form.PaymentMode) ?? "Cash",
                            NullIfEmpty(form.PaymentReference),
                            NullIfEmpty(form.PaymentRemarks),
                            model.AcademicYear,
                            tenantId, schoolId, userId,
                            discountType:   MapDiscountType(form.DiscountType),
                            discountValue:  concession.Value,
                            discountReason: NullIfEmpty(form.DiscountReason));

                        receiptNo  = res.ReceiptNo;
                        feeMessage = !res.Success
                            ? $"Admission saved, but payment failed: {res.Message}"
                            : (payAmount > 0 ? $"Receipt {res.ReceiptNo} generated."
                                             : $"Concession recorded (receipt {res.ReceiptNo}).");
                    }
                    else if (payAmount > 0)
                    {
                        feeMessage = "Admission saved, but no outstanding dues were found to collect against.";
                    }
                }
            }

            // ── Assign transport (optional) ── generates monthly bus-fee dues
            // through the end of the academic year, just like the mid-year Assign page.
            if (result.Success && result.StudentId > 0 && form.TransportRouteId is > 0 && form.TransportStopId is > 0)
            {
                var admDate = model.AdmissionDate ?? DateOnly.FromDateTime(DateTime.Today);
                int months = MonthsToYearEnd(model.AcademicYear, admDate);
                await _transportService.SaveAssignmentAsync(
                    result.StudentId, form.TransportRouteId.Value, form.TransportStopId.Value,
                    model.AcademicYear, admDate, months,
                    tenantId, schoolId, userId);
            }

            return Json(new
            {
                success    = result.Success,
                message    = result.Message,
                admissionNo = result.AdmissionNo,
                studentId  = result.StudentId,
                receiptNo,
                feeMessage
            });
        }

        // ── GET: /ERP/Admission/GetStudentsData (AJAX) ───────────
        [HttpGet]
        public async Task<IActionResult> GetStudentsData(
            int page = 1, int pageSize = 10, string? search = null,
            string? className = null, string? section = null, string? gender = null,
            string? year = null, string? status = null)
        {
            var (rows, totalCount) = await _admissionService.GetStudentsAsync(
                TenantId(), SchoolId(), UserId(), page, pageSize,
                NullIfEmpty(search), NullIfEmpty(className), NullIfEmpty(section),
                NullIfEmpty(gender), NullIfEmpty(year), NullIfEmpty(status));

            int totalPages = totalCount > 0 ? (int)Math.Ceiling((double)totalCount / pageSize) : 1;

            return Json(new
            {
                success = true,
                page,
                pageSize,
                totalCount,
                totalPages,
                rows = rows.Select(s => new
                {
                    studentId    = s.StudentId,
                    admissionNo  = s.AdmissionNo,
                    rollNo       = s.RollNo,
                    studentName  = s.StudentName,
                    gender       = s.Gender,
                    className    = s.ClassName,
                    section      = s.Section,
                    academicYear = s.AcademicYear,
                    admissionDate = s.AdmissionDate?.ToString("yyyy-MM-dd"),
                    guardianName = s.GuardianName,
                    mobile       = s.Mobile,
                    annualTotal  = s.AnnualTotal,
                    status       = s.Status,
                    approvalStatus = s.ApprovalStatus,
                    feeStatus    = s.FeeStatus,
                    feeDue       = s.FeeDue
                })
            });
        }

        // ── GET: /ERP/Admission/GetFeeStructure (AJAX) ───────────
        // Returns the real, DB-configured fee heads for a class + year,
        // grouped for the admission fee preview. Replaces the old
        // hardcoded JS fee table.
        [HttpGet]
        public async Task<IActionResult> GetFeeStructure(string className, string academicYear)
        {
            if (string.IsNullOrWhiteSpace(className) || string.IsNullOrWhiteSpace(academicYear))
                return Json(new { success = false, message = "Class and academic year are required." });

            int tenantId = TenantId(), schoolId = SchoolId(), userId = UserId();

            var details = await _schoolSettingsService.GetFeeStructureDetailsAsync(
                className, academicYear, tenantId, schoolId, userId);

            if (details == null || details.Count == 0)
                return Json(new { success = false, message = "No fee structure configured for this class and year. Configure it under School Settings → Fee Structure." });

            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, userId);

            // Admission collects Admission-point heads (admission fee, security deposit)
            // as "due now", and Recurring heads as "scheduled / billed later". It never
            // collects Registration-point heads (those are taken at the registration step).
            // A refundable Admission head (the security deposit) is only charged when the
            // school enables the security deposit toggle in Workflow Settings.
            var visible = details.Where(d =>
                !string.Equals(d.CollectionPoint, "Registration", StringComparison.OrdinalIgnoreCase) &&
                (!(IsAdmissionPoint(d.CollectionPoint) && d.IsRefundable) || workflow.EnableSecurityFee));

            return Json(new
            {
                success = true,
                fees = visible.Select(d => new
                {
                    feeHeadId       = d.FeeHeadId,
                    feeHeadName     = d.FeeHeadName,
                    frequency       = string.IsNullOrWhiteSpace(d.Frequency) ? "Yearly" : d.Frequency,
                    amount          = d.Amount,
                    collectionPoint = string.IsNullOrWhiteSpace(d.CollectionPoint) ? "Recurring" : d.CollectionPoint,
                    isRefundable    = d.IsRefundable,
                    group           = IsAdmissionPoint(d.CollectionPoint) ? "One Time Payable Now" : GroupForFrequency(d.Frequency),
                    // Due-now vs scheduled is driven by the Collection Point, not the billing cycle.
                    stage           = IsAdmissionPoint(d.CollectionPoint) ? "Admission" : StageForFrequency(d.Frequency),
                    // All configured heads are part of the class structure → mandatory by default.
                    mandatory       = true
                })
            });
        }

        private static bool IsAdmissionPoint(string? collectionPoint) =>
            string.Equals(collectionPoint, "Admission", StringComparison.OrdinalIgnoreCase);
        public IActionResult ManageAdmission()
        {
            return View();
        }
        private static string GroupForFrequency(string? freq) => freq switch
        {
            "One Time"    => "One Time Payable Now",
            "Monthly"     => "Monthly Recurring",
            "Quarterly"   => "Quarterly Recurring",
            "Half Yearly" => "Half-Yearly Charges",
            _             => "Yearly Charges"
        };

        private static string StageForFrequency(string? freq) => freq switch
        {
            "One Time"    => "Admission",
            "Monthly"     => "Monthly",
            "Quarterly"   => "Quarterly",
            "Half Yearly" => "HalfYearly",
            _             => "Yearly"
        };

        // ── GET: /ERP/Admission/GetSections (AJAX) ───────────────
        // Sections are configured per-class, per-year in Academic Setup.
        // Returns the sections for the chosen academic year + class.
        [HttpGet]
        public async Task<IActionResult> GetSections(int academicYearId, string className)
        {
            if (academicYearId <= 0 || string.IsNullOrWhiteSpace(className))
                return Json(new { success = false, sections = Array.Empty<string>() });

            var setup = await _schoolSettingsService.GetAcademicSetupAsync(
                TenantId(), SchoolId(), academicYearId, UserId());

            var sections = new List<string>();
            if (setup?.ClassSections != null)
            {
                var key = setup.ClassSections.Keys.FirstOrDefault(
                    k => k.Equals(className.Trim(), StringComparison.OrdinalIgnoreCase));
                if (key != null) sections = setup.ClassSections[key];
            }

            return Json(new { success = true, sections });
        }

        // ── Dropdowns from Academic Setup (same source as Enquiry) ─
        private async Task LoadDropdownsAsync()
        {
            try { ViewBag.Classes = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class"); }
            catch { ViewBag.Classes = new List<SelectListItem>(); }

            try { ViewBag.Sessions = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear"); }
            catch { ViewBag.Sessions = new List<SelectListItem>(); }
            // Sections are class-dependent → loaded dynamically via GetSections.

            // Whether the admission form may collect fee on the spot. The security
            // deposit (and every other charge) is now a Fee Head pulled via the fee
            // structure, so no amount is read from the workflow settings here.
            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(TenantId(), SchoolId(), UserId());
            ViewBag.CollectFeeAtAdmission = workflow.CollectFeeAtAdmission;
            // Hide the admission Transport panel for schools that don't run buses.
            ViewBag.EnableTransport = workflow.EnableTransport;
        }

        // ── Ledger JSON parsing ──────────────────────────────────
        private static (List<StudentFeePlanItem> Fees,
                        (decimal PayToday, decimal Monthly, decimal Yearly, decimal Annual) Totals,
                        (decimal Value, decimal Amount) Concession)
            ParseLedger(AdmissionFormModel form)
        {
            var fees = new List<StudentFeePlanItem>();
            decimal payToday = 0, monthly = 0, yearly = 0, annual = 0, concValue = 0, concAmount = 0;

            if (!string.IsNullOrWhiteSpace(form.LedgerPreviewJson))
            {
                try
                {
                    using var doc = JsonDocument.Parse(form.LedgerPreviewJson);
                    var root = doc.RootElement;

                    if (root.TryGetProperty("selectedFees", out var sel) && sel.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var f in sel.EnumerateArray())
                        {
                            fees.Add(new StudentFeePlanItem
                            {
                                FeeHeadId   = GetInt(f, "feeHeadId") is int id and > 0 ? id : (GetInt(f, "id") is int id2 and > 0 ? id2 : null),
                                FeeHeadName = GetStr(f, "feeHeadName") ?? GetStr(f, "name") ?? "Fee",
                                Frequency   = NormalizeFreq(GetStr(f, "frequency") ?? GetStr(f, "cycle")),
                                Amount      = GetDec(f, "amount"),
                                IsOptional  = f.TryGetProperty("mandatory", out var m) && m.ValueKind == JsonValueKind.False
                            });
                        }
                    }

                    // NOTE: store add-ons (uniform/tie/belt/books) are deliberately NOT
                    // booked here. They are store/inventory sales, not school fees — mixing
                    // them into the fee ledger pollutes fee revenue and there is no inventory
                    // backend to track stock. The admission panel keeps them as a handover
                    // checklist only; selling them belongs in a dedicated Store module.

                    if (root.TryGetProperty("summary", out var sum))
                    {
                        payToday = GetDec(sum, "payToday");
                        monthly  = GetDec(sum, "monthlyRecurring");
                        yearly   = GetDec(sum, "yearlyScheduled");
                        annual   = GetDec(sum, "estimatedAnnual");
                    }

                    if (root.TryGetProperty("concession", out var con))
                    {
                        concValue  = GetDec(con, "value");
                        concAmount = GetDec(con, "calculatedAmount");
                    }
                }
                catch (JsonException) { /* malformed payload → treated as empty plan; validation still guards required fields */ }
            }

            return (fees, (payToday, monthly, yearly, annual), (concValue, concAmount));
        }

        // Bill transport from the admission month through the end of the academic
        // year (Indian April–March), capped at 12. Falls back to 12 if unparsable.
        private static int MonthsToYearEnd(string? academicYear, DateOnly start)
        {
            int endYear;
            if (!string.IsNullOrWhiteSpace(academicYear) && academicYear.Length >= 4 &&
                int.TryParse(academicYear.Substring(0, 4), out var firstYear))
                endYear = firstYear + 1;
            else
                endYear = start.Month >= 4 ? start.Year + 1 : start.Year;

            var yearEnd = new DateOnly(endYear, 3, 31);
            if (yearEnd < start) return 1;
            int months = (yearEnd.Year - start.Year) * 12 + (yearEnd.Month - start.Month) + 1;
            return Math.Clamp(months, 1, 12);
        }

        // Spreads the lump "collect at admission" cash AND any concession across the
        // student's freshly created dues, so the receipt is itemised and the discount is
        // recorded as real concession on each ledger row (not a phantom unpaid balance).
        // Admission-point charges (ledger label 'Admission') are settled first, then the
        // earliest remaining dues by due date. The concession is written off first so each
        // due's payable balance shrinks before cash is applied; every line is capped at its
        // outstanding so a row is never over-allocated and no money is dropped.
        private static List<FeeCollectItem> AllocateAdmissionPayment(
            List<StudentDueItem> dues, decimal cash, decimal concession, HashSet<string> refundableHeads)
        {
            var ordered = dues
                .Where(d => d.Outstanding > 0)
                .OrderByDescending(d => string.Equals(d.InstallmentLabel, "Admission", StringComparison.OrdinalIgnoreCase))
                .ThenBy(d => d.DueDate ?? DateOnly.MaxValue)
                .ThenBy(d => d.LedgerId)
                .ToList();

            var concByLedger = new Dictionary<int, decimal>();
            var cashByLedger = new Dictionary<int, decimal>();

            // 1) Write off the concession first so each due's payable balance shrinks —
            //    but NEVER against a refundable deposit (e.g. Caution Money). A discount
            //    applies to income heads only; a deposit is a liability the school returns,
            //    so it must always be collected in full. Cash (step 2) still fills it.
            decimal concLeft = concession;
            foreach (var d in ordered)
            {
                if (concLeft <= 0) break;
                if (refundableHeads.Contains(d.FeeHeadName)) continue;
                decimal take = Math.Min(concLeft, d.Outstanding);
                concByLedger[d.LedgerId] = take;
                concLeft -= take;
            }

            // 2) Apply cash to whatever each due still owes after concession.
            decimal cashLeft = cash;
            foreach (var d in ordered)
            {
                if (cashLeft <= 0) break;
                decimal payable = d.Outstanding - concByLedger.GetValueOrDefault(d.LedgerId);
                if (payable <= 0) continue;
                decimal take = Math.Min(cashLeft, payable);
                cashByLedger[d.LedgerId] = take;
                cashLeft -= take;
            }

            return ordered
                .Where(d => cashByLedger.ContainsKey(d.LedgerId) || concByLedger.ContainsKey(d.LedgerId))
                .Select(d => new FeeCollectItem
                {
                    LedgerId   = d.LedgerId,
                    Amount     = cashByLedger.GetValueOrDefault(d.LedgerId),
                    Concession = concByLedger.GetValueOrDefault(d.LedgerId)
                })
                .ToList();
        }

        // The admission form sends the discount type as 'fixed' / 'percentage'; the fee
        // engine stores it as 'Flat' / 'Percent' on the receipt header.
        private static string? MapDiscountType(string? t) =>
            string.Equals(t, "percentage", StringComparison.OrdinalIgnoreCase) ? "Percent"
            : string.Equals(t, "fixed", StringComparison.OrdinalIgnoreCase)     ? "Flat"
            : null;

        private static string NormalizeFreq(string? f) => f switch
        {
            "Monthly"     => "Monthly",
            "Quarterly"   => "Quarterly",
            "Half Yearly" => "Half Yearly",
            "HalfYearly"  => "Half Yearly",
            "One Time"    => "One Time",
            "OneTime"     => "One Time",
            _             => "Yearly"
        };

        private static int?    GetInt(JsonElement e, string p) => e.TryGetProperty(p, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;
        private static decimal GetDec(JsonElement e, string p) => e.TryGetProperty(p, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : 0m;
        private static string? GetStr(JsonElement e, string p) => e.TryGetProperty(p, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

        // ── Claims helpers ───────────────────────────────────────
        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

        // Pass-through for the documents checklist only if it is a valid JSON array; otherwise null.
        private static string? NormalizeJsonArray(string? json)
        {
            if (string.IsNullOrWhiteSpace(json)) return null;
            try
            {
                using var doc = JsonDocument.Parse(json);
                return doc.RootElement.ValueKind == JsonValueKind.Array ? json : null;
            }
            catch (JsonException) { return null; }
        }
    }
}
