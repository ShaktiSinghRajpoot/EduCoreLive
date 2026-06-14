using System.Text.Json;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    public class AdmissionController : Controller 
    {
        private readonly IAdmissionService _admissionService;
        private readonly IEnquiryService _enquiryService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IAdmissionWorkflowService _admissionWorkflowService;
        private readonly IFeePaymentService _feePaymentService;
        private readonly IBaseService _baseService;

        public AdmissionController(IAdmissionService admissionService, IEnquiryService enquiryService, ISchoolSettingsService schoolSettingsService, IAdmissionWorkflowService admissionWorkflowService, IFeePaymentService feePaymentService, IBaseService baseService)
        {
            _admissionService = admissionService;
            _enquiryService = enquiryService;
            _schoolSettingsService = schoolSettingsService;
            _admissionWorkflowService = admissionWorkflowService;
            _feePaymentService = feePaymentService;
            _baseService = baseService;
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

            // ── Collect fee at admission (only when the school enables it) ──
            string? receiptNo = null;
            string? feeMessage = null;
            if (result.Success && result.StudentId > 0 && form.CollectFeeNow)
            {
                var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, userId);
                var payAmount = form.PaymentAmount ?? 0m;

                if (workflow.CollectFeeAtAdmission && payAmount > 0)
                {
                    var (paid, payMsg, rcp) = await _feePaymentService.RecordPaymentAsync(
                        result.StudentId, payAmount,
                        NullIfEmpty(form.PaymentMode) ?? "Cash",
                        NullIfEmpty(form.PaymentReference),
                        NullIfEmpty(form.PaymentRemarks),
                        model.AcademicYear,
                        tenantId, schoolId, userId);

                    receiptNo  = rcp;
                    feeMessage = paid ? $"Receipt {rcp} generated." : $"Admission saved, but payment failed: {payMsg}";
                }
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

            var details = await _schoolSettingsService.GetFeeStructureDetailsAsync(
                className, academicYear, TenantId(), SchoolId(), UserId());

            if (details == null || details.Count == 0)
                return Json(new { success = false, message = "No fee structure configured for this class and year. Configure it under School Settings → Fee Structure." });

            return Json(new
            {
                success = true,
                fees = details.Select(d => new
                {
                    feeHeadId   = d.FeeHeadId,
                    feeHeadName = d.FeeHeadName,
                    frequency   = string.IsNullOrWhiteSpace(d.Frequency) ? "Yearly" : d.Frequency,
                    amount      = d.Amount,
                    group       = GroupForFrequency(d.Frequency),
                    stage       = StageForFrequency(d.Frequency),
                    // All configured heads are part of the class structure → mandatory by default.
                    mandatory   = true
                })
            });
        }
        public IActionResult ManageAdmission()
        {
            return View();
        }
        private static string GroupForFrequency(string? freq) => freq switch
        {
            "One Time" => "One Time Payable Now",
            "Monthly"  => "Monthly Recurring",
            _          => "Yearly Charges"
        };

        private static string StageForFrequency(string? freq) => freq switch
        {
            "One Time" => "Admission",
            "Monthly"  => "Monthly",
            _          => "Yearly"
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

            // Whether the admission form may collect fee on the spot, and the
            // optional one-time security deposit configured for this school.
            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(TenantId(), SchoolId(), UserId());
            ViewBag.CollectFeeAtAdmission = workflow.CollectFeeAtAdmission;
            ViewBag.EnableSecurityFee = workflow.EnableSecurityFee;
            ViewBag.SecurityFeeAmount = workflow.SecurityFeeAmount;
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

                    // Admission-kit items become One Time fee heads on the ledger
                    if (root.TryGetProperty("selectedKitItems", out var kit) && kit.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var k in kit.EnumerateArray())
                        {
                            fees.Add(new StudentFeePlanItem
                            {
                                FeeHeadName = GetStr(k, "name") ?? "Kit Item",
                                Frequency   = "One Time",
                                Amount      = GetDec(k, "amount"),
                                IsOptional  = true
                            });
                        }
                    }

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

        private static string NormalizeFreq(string? f) => f switch
        {
            "Monthly"  => "Monthly",
            "One Time" => "One Time",
            "OneTime"  => "One Time",
            _          => "Yearly"
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
