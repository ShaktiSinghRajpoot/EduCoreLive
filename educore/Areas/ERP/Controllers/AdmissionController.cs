using System.Text.Json;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
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

        private readonly IWebHostEnvironment _env;
        private readonly IConfiguration _config;

        public AdmissionController(IAdmissionService admissionService, IEnquiryService enquiryService, ISchoolSettingsService schoolSettingsService, IAdmissionWorkflowService admissionWorkflowService, IFeePaymentService feePaymentService, IBaseService baseService, ITransportService transportService, IWebHostEnvironment env, IConfiguration config)
        {
            _env = env;
            _config = config;
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
            // No routes to offer when the school has switched Transport off.
            var wf = await _admissionWorkflowService.GetAdmissionWorkflowAsync(TenantId(), SchoolId(), UserId());
            if (!wf.EnableTransport) return Json(Array.Empty<object>());

            var rows = await _transportService.GetRoutesDropdownAsync(TenantId(), SchoolId(), UserId());
            var routes = rows.GroupBy(r => new { r.RouteId, r.RouteName }).Select(g => new
            {
                    routeId   = g.Key.RouteId,
                    routeName = g.Key.RouteName,
                    stops     = g.Select(s => new { stopId = s.StopId, stopName = s.StopName, fare = s.MonthlyFare })
                });
            return Json(routes);
        }

        // Registration gate: when the school requires registration before admission,
        // an enquiry must be "Registration Done" before it can be converted.
        // True when the workflow makes registration MANDATORY before any admission.
        private async Task<bool> RegistrationRequiredAsync(int tenantId, int schoolId, int userId)
        {
            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, userId);
            return workflow.EnableRegistration && workflow.RegistrationRequiredBeforeAdmission;
        }

        // True when this admission satisfies the registration policy. When
        // registration is mandatory EVERY student must be registered first, so a
        // direct/walk-in admission (no enquiry) never satisfies it — only an
        // enquiry that has completed registration does.
        private async Task<bool> RegistrationSatisfiedAsync(EnquiryModel? enquiry, int tenantId, int schoolId, int userId)
        {
            if (!await RegistrationRequiredAsync(tenantId, schoolId, userId))
                return true;
            return enquiry != null
                && string.Equals(enquiry.Status, "Registration Done", StringComparison.OrdinalIgnoreCase);
        }

        // ── Pages ────────────────────────────────────────────────
        // The student list is consolidated into a single page under the
        // Student controller. This old route redirects there so existing
        // links/bookmarks keep working.
        public IActionResult StudentList()
            => RedirectToAction("StudentList", "Student", new { area = "ERP" });

        // This used to render a mock student dashboard (random grades, a rank of
        // rand(1,40), made-up attendance) that looked like real data. The real
        // dashboard is per student (Student/Dashboard/{id}), reached from the list.
        public IActionResult Dashboard()
            => RedirectToAction("StudentList", "Student", new { area = "ERP" });

        // ── GET: /ERP/Admission/Create?enquiryId= ────────────────
        // Opens the admission page; when an enquiry id is supplied the
        // view pre-fills the modal from the enquiry record.
        [HttpGet]
        public async Task<IActionResult> Create(int? enquiryId)
        {
            // Direct / walk-in admission (no enquiry) is blocked when registration
            // is mandatory — every student must be registered first. Send them to
            // the Enquiry CRM where an enquiry is created and registered.
            if (enquiryId is not > 0 && await RegistrationRequiredAsync(TenantId(), SchoolId(), UserId()))
            {
                TempData["Result"] = "0";
                TempData["Message"] = "Registration is mandatory before admission. Create an enquiry and complete registration first.";
                return RedirectToAction("EnquiryCRM", "Enquiry", new { area = "ERP" });
            }

            await LoadDropdownsAsync();
            if (enquiryId is > 0)
            {
                var enquiry = await _enquiryService.GetEnquiryByIdAsync(enquiryId.Value, TenantId(), SchoolId(), UserId());
                if (enquiry != null)
                {
                    // Server-side registration gate (mirrors the CRM client-side check).
                    if (!await RegistrationSatisfiedAsync(enquiry, TenantId(), SchoolId(), UserId()))
                    {
                        TempData["Result"] = "0";
                        TempData["Message"] = "Complete registration before converting this enquiry to admission.";
                        return RedirectToAction("EnquiryCRM", "Enquiry", new { area = "ERP" });
                    }

                    // Prefill values rendered straight into the form fields (normal
                    // binding) — no JSON blob for the client to parse.
                    //
                    // The enquiry already asked the family most of this. Carrying
                    // over only six of the answers meant the office retyped the
                    // rest at the desk, including the date of birth and address,
                    // which the admission form makes mandatory. Anything the
                    // enquiry holds and this form asks for is now carried.
                    ViewBag.PrefillEnquiryId = enquiry.EnquiryId;
                    ViewBag.PreStudentName   = enquiry.StudentName;
                    ViewBag.PreGender        = enquiry.Gender;
                    ViewBag.PreDob           = enquiry.Dob;
                    ViewBag.PreClassName     = enquiry.ClassName;
                    ViewBag.PreAcademicYear  = enquiry.Session;

                    ViewBag.PreGuardianName  = enquiry.FatherName ?? enquiry.MotherName;
                    ViewBag.PreMotherName    = enquiry.MotherName;

                    // The enquiry keeps a primary number plus the parents' own.
                    // Prefer the primary for the main field and offer whichever
                    // other number is not already showing as the alternate.
                    ViewBag.PreMobile        = enquiry.Mobile ?? enquiry.FatherMobile ?? enquiry.MotherMobile;
                    ViewBag.PreAltMobile     = FirstDifferent(
                        (string?)ViewBag.PreMobile,
                        enquiry.AltMobile, enquiry.FatherMobile,
                        enquiry.MotherMobile, enquiry.WhatsAppNumber);

                    ViewBag.PreFatherEmail   = enquiry.ParentEmail;

                    // City and locality are two boxes on the enquiry and one on
                    // the admission form; join them rather than dropping one.
                    ViewBag.PreAddress       = JoinParts(enquiry.AreaLocality, enquiry.City);

                    ViewBag.PrePrevSchool    = enquiry.CurrentSchool;
                    ViewBag.PrePrevClass     = enquiry.CurrentClass;
                    ViewBag.PreTransport     = enquiry.TransportRequired;
                }
            }
            return View("Create");
        }

        // Stores an admission-time photo under the same folder and the same
        // constraints as Student/UploadPhoto, so the directory avatar and the ID
        // card find it in the one place they already look. Returns quietly on a
        // bad file — see the call site for why that is deliberate.
        private async Task SaveStudentPhotoAsync(
            int studentId, IFormFile photo, int tenantId, int schoolId, int userId)
        {
            var ext = Path.GetExtension(photo.FileName).ToLowerInvariant();
            string[] allowed = { ".jpg", ".jpeg", ".png", ".webp" };
            if (!allowed.Contains(ext) || photo.Length > 2 * 1024 * 1024) return;

            var folder = UploadPaths.FolderFor(_config, _env, "students", tenantId, schoolId);

            var fileName = $"student_{studentId}_{Dates.Now:yyyyMMddHHmmssfff}{ext}";
            var fullPath = Path.Combine(folder, fileName);
            using (var stream = new FileStream(fullPath, FileMode.Create))
                await photo.CopyToAsync(stream);

            var url = UploadPaths.UrlFor("students", tenantId, schoolId, fileName);
            var (ok, _, _) = await _admissionService.SetStudentPhotoAsync(
                studentId, url, tenantId, schoolId, userId);

            // Don't leave an orphan file if the row never took the URL.
            if (!ok) { try { System.IO.File.Delete(fullPath); } catch { } }
        }

        // ── POST: /ERP/Admission/SaveAdmission ───────────────────
        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveAdmission(AdmissionFormModel form, IFormFile? photo)
        {
            int tenantId = TenantId(), schoolId = SchoolId(), userId = UserId();

            // ── Server-side validation ──
            // Every field the form marks with a * is re-checked here. The browser's
            // own `required` only protects a user with JavaScript on and the form
            // rendered — it is a courtesy, not a guarantee. Three of these ten were
            // checked before; the other seven could be posted blank.
            var errors = new List<string>();
            var today  = Dates.Today;

            if (string.IsNullOrWhiteSpace(form.StudentName))  errors.Add("Student name is required.");
            if (string.IsNullOrWhiteSpace(form.AcademicYear)) errors.Add("Academic year is required.");
            if (string.IsNullOrWhiteSpace(form.ClassName))    errors.Add("Class is required.");
            if (string.IsNullOrWhiteSpace(form.Section))      errors.Add("Section is required.");
            if (string.IsNullOrWhiteSpace(form.Gender))       errors.Add("Gender is required.");
            if (string.IsNullOrWhiteSpace(form.GuardianName)) errors.Add("Father / guardian name is required.");
            if (string.IsNullOrWhiteSpace(form.Address))      errors.Add("Address is required.");

            // A school with no way to reach the parent has a record, not a contact.
            // This used to check the format only when a number was supplied, so a
            // blank mobile passed the server even though the form demands one.
            if (string.IsNullOrWhiteSpace(form.MobileNumber))
                errors.Add("Mobile number is required.");
            else if (!System.Text.RegularExpressions.Regex.IsMatch(form.MobileNumber, @"^\d{10}$"))
                errors.Add("Mobile number must be 10 digits.");

            if (!string.IsNullOrWhiteSpace(form.AlternateMobile) &&
                !System.Text.RegularExpressions.Regex.IsMatch(form.AlternateMobile, @"^\d{10}$"))
                errors.Add("Alternate mobile must be 10 digits.");

            // Dates arrive as text and are normalised to ISO here, so a value the
            // browser never validated is caught before it reaches the database.
            var dob = Dates.Norm(form.DateOfBirth);
            if (string.IsNullOrWhiteSpace(form.DateOfBirth))
                errors.Add("Date of birth is required.");
            else if (dob == null)
                errors.Add("Date of birth is not a valid date.");
            else if (string.CompareOrdinal(dob, today) > 0)
                errors.Add("Date of birth cannot be in the future.");

            // The Admission Date field was removed from the form: an admission is
            // dated by the database on the day it is entered
            // (sp_admission_manage falls back to CURRENT_DATE). It is still
            // checked when something else supplies one.
            var admission = Dates.Norm(form.AdmissionDate);
            if (admission != null && string.CompareOrdinal(admission, today) > 0)
                errors.Add("Admission date cannot be in the future.");

            // Born after the day they joined is not a typo anyone should keep.
            // With no date posted, the joining day is today.
            var joined = admission ?? today;
            if (dob != null && string.CompareOrdinal(dob, joined) > 0)
                errors.Add("Date of birth cannot be after the admission date.");

            // The fee plan and every amount are built HERE from the school's fee
            // structure. They used to be read from the page's LedgerPreviewJson,
            // so the posted amounts, heads and totals were whatever the browser
            // sent. The page still chooses the concession type, value and target.
            List<AdmissionFee>? fees = null;
            if (!string.IsNullOrWhiteSpace(form.ClassName) && !string.IsNullOrWhiteSpace(form.AcademicYear))
            {
                var (built, feeError) = await BuildAdmissionFeesAsync(
                    form.ClassName.Trim(), form.AcademicYear.Trim(), tenantId, schoolId, userId);
                if (built == null) errors.Add(feeError!);
                fees = built;
            }

            var quote = fees == null
                ? new AdmissionQuote()
                : QuoteAdmission(fees,
                      await _admissionService.GetPlanInstalmentsAsync(form.AcademicYear!.Trim(), tenantId, schoolId, userId),
                      form.DiscountType, form.DiscountValue ?? 0m, form.DiscountApplyTo);

            if (quote.Concession > 0 && string.IsNullOrWhiteSpace(form.DiscountReason))
                errors.Add("A concession reason is required when a discount is applied.");

            // Overpay guard (mirrors the client): at admission you can collect at most the
            // amount due now. Advance / prepay must go through the Fee counter (ManageFee),
            // which has the advance-wallet support the admission screen intentionally omits.
            if (form.CollectFeeNow && (form.PaymentAmount ?? 0m) > quote.PayToday + 0.01m)
                errors.Add($"Amount to collect cannot exceed ₹{quote.PayToday:0} due now. Use the Fee counter for advance/prepay.");

            if (errors.Count > 0)
                return Json(new { success = false, message = string.Join(" ", errors) });

            // Admitting is students.manage; taking money or giving a concession at the
            // same time is fee work. Checked before anything is saved.
            if (form.CollectFeeNow && (form.PaymentAmount ?? 0m) > 0
                && !await HasPermissionAttribute.UserHasAsync(this, "fees.collect"))
                return Json(new { success = false, message = "You do not have permission to collect fees. Admit without collecting, and collect at the Fee counter." });
            if (quote.Concession > 0 && !await HasPermissionAttribute.UserHasAsync(this, "fees.concession"))
                return Json(new { success = false, message = "You do not have permission to give a concession." });

            // Registration gate — enforce on the actual mutation, not just the UI.
            // Covers BOTH paths: an enquiry that hasn't completed registration, and
            // a direct/walk-in admission (no enquiry) when registration is mandatory.
            {
                var enquiry = form.EnquiryId is > 0
                    ? await _enquiryService.GetEnquiryByIdAsync(form.EnquiryId.Value, tenantId, schoolId, userId)
                    : null;
                if (!await RegistrationSatisfiedAsync(enquiry, tenantId, schoolId, userId))
                    return Json(new { success = false, message = "Registration is mandatory before admission. Please register the student first." });
            }

            var model = new AdmissionModel
            {
                AdmissionNo      = NullIfEmpty(form.AdmissionNo),
                StudentName      = form.StudentName!.Trim(),
                Gender           = NullIfEmpty(form.Gender),
                DateOfBirth      = Dates.Norm(form.DateOfBirth),
                ClassName        = form.ClassName!.Trim(),
                Section          = NullIfEmpty(form.Section),
                AcademicYear     = form.AcademicYear!.Trim(),
                AdmissionDate    = Dates.Norm(form.AdmissionDate) ?? Dates.Today,
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
                PayTodayTotal    = quote.PayToday,
                MonthlyTotal     = quote.Monthly,
                YearlyTotal      = quote.Yearly,
                AnnualTotal      = quote.Annual,
                ConcessionType   = quote.Concession > 0 ? NullIfEmpty(form.DiscountType) : null,
                ConcessionValue  = quote.Concession > 0 ? (form.DiscountValue ?? 0m) : 0m,
                ConcessionAmount = quote.Concession,
                ConcessionReason = NullIfEmpty(form.DiscountReason),
                FeePlan          = (fees ?? new List<AdmissionFee>()).Select(f => new StudentFeePlanItem
                {
                    FeeHeadId   = f.FeeHeadId > 0 ? f.FeeHeadId : null,
                    FeeHeadName = f.FeeHeadName,
                    Frequency   = f.Frequency,
                    Amount      = f.Amount,
                    IsOptional  = false
                }).ToList(),
                EnquiryId        = form.EnquiryId is > 0 ? form.EnquiryId : null
            };

            var result = await _admissionService.SaveAdmissionAsync(model, tenantId, schoolId, userId);

            // The photo can only be filed once the student has an id, so it is
            // saved after the admission, with the same rules as the profile-page
            // uploader. A photo that fails never fails the admission: the child is
            // admitted and the office can add the picture from the profile.
            if (result.Success && result.StudentId > 0 && photo is { Length: > 0 })
                await SaveStudentPhotoAsync(result.StudentId, photo, tenantId, schoolId, userId);

            // ── Record concession + collect fee at admission ──
            // Both the cash collected now AND any admission-time concession are pushed
            // through the shared fee engine (CollectPaymentAsync), so core.student_ledger
            // stays the single source of truth. A discount on its own — even when no cash
            // is taken — still writes a concession voucher onto the ledger.
            //
            // The admission, the receipt and the bus assignment are three separate
            // database calls. Whatever happens to the receipt or the bus is therefore
            // reported back (feeMessage / feeFailed / transportMessage) and the page
            // shows it: a failed receipt used to be reported here and then never shown.
            string? receiptNo = null;
            string? feeMessage = null;
            bool feeFailed = false;
            string? transportMessage = null;
            if (result.Success && result.StudentId > 0)
            {
                var workflow   = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, userId);
                var payAmount  = (form.CollectFeeNow && workflow.CollectFeeAtAdmission) ? (form.PaymentAmount ?? 0m) : 0m;

                // A concession above the approval limit is recorded on the admission
                // as Pending Approval (sp_admission_manage) and NOT written onto the
                // ledger: it used to be applied at once, so the approval meant nothing.
                var concAmount = quote.Concession > ConcessionCap ? 0m : quote.Concession;
                string pendingNote = quote.Concession > ConcessionCap
                    ? $" The concession of ₹{quote.Concession:N0} is above the approval limit of ₹{ConcessionCap:N0} and was not applied — apply it from Fee → Collect Fees once approved."
                    : string.Empty;

                if (payAmount > 0 || concAmount > 0)
                {
                    var dues = await _feePaymentService.GetStudentDuesAsync(result.StudentId, tenantId, schoolId, userId);

                    // Refundable deposit heads — the discount must skip these. Taken from
                    // the same list the plan was built from, so the fallback deposit
                    // (named after its real fee head now) is included.
                    var refundableHeads = (fees ?? new List<AdmissionFee>())
                        .Where(f => f.IsRefundable)
                        .Select(f => f.FeeHeadName)
                        .ToHashSet(StringComparer.OrdinalIgnoreCase);

                    bool spreadOverYear = IsAnnual(form.DiscountApplyTo);
                    var items = AllocateAdmissionPayment(dues, payAmount, concAmount, spreadOverYear, refundableHeads);

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
                            discountValue:  form.DiscountValue ?? 0m,
                            discountReason: NullIfEmpty(form.DiscountReason));

                        receiptNo = res.Success ? res.ReceiptNo : null;

                        // What is still due on the one-time charges after this cash and
                        // concession, worked out from the real ledger rows.
                        var admissionRows = dues.Where(d => IsAdmissionLabel(d.InstallmentLabel)).Select(d => d.LedgerId).ToHashSet();
                        decimal stillDue = dues.Where(d => admissionRows.Contains(d.LedgerId)).Sum(d => d.Outstanding)
                                         - items.Where(i => admissionRows.Contains(i.LedgerId)).Sum(i => i.Amount + i.Concession);
                        string balance = stillDue > 0.005m
                            ? $" ₹{stillDue:N0} is still due — collect it from Fee → Collect Fees."
                            : string.Empty;

                        if (!res.Success)
                        {
                            feeFailed  = true;
                            feeMessage = $"Admission saved, but the payment was NOT recorded: {res.Message} No receipt was issued — do not keep the cash; collect it again from Fee → Collect Fees.";
                        }
                        else
                        {
                            feeMessage = (payAmount > 0 ? $"Receipt {res.ReceiptNo} generated."
                                                        : $"Concession recorded (receipt {res.ReceiptNo}).") + balance;
                        }
                    }
                    else if (payAmount > 0)
                    {
                        feeFailed  = true;
                        feeMessage = "Admission saved, but no outstanding dues were found to collect against. No receipt was issued.";
                    }
                }

                if (pendingNote.Length > 0)
                    feeMessage = (feeMessage ?? "Admission saved.") + pendingNote;
            }

            // ── Assign transport (optional) ── generates monthly bus-fee dues
            // through the end of the session; the proc reads the session's real
            // end date, so no month count is worked out here any more.
            // Never when the Transport module is switched off: the form hides the
            // panel, but a stale page or a crafted post still sent a route, and the
            // bus was assigned and billed for a school that runs no buses (SEC-20).
            bool transportOn = form.TransportRouteId is > 0 && form.TransportStopId is > 0
                && (await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, userId)).EnableTransport;
            if (result.Success && result.StudentId > 0 && form.TransportRouteId is > 0 && form.TransportStopId is > 0 && !transportOn)
                transportMessage = "Admission saved. The bus was not assigned because the Transport module is turned off.";
            if (result.Success && result.StudentId > 0 && transportOn)
            {
                var (busOk, busMsg, _, _) = await _transportService.SaveAssignmentAsync(
                    result.StudentId, form.TransportRouteId.Value, form.TransportStopId.Value,
                    model.AcademicYear, model.AdmissionDate ?? Dates.Today, 12,
                    tenantId, schoolId, userId);
                if (!busOk)
                    transportMessage = $"Admission saved, but the bus was NOT assigned: {busMsg} Assign it from Transport → Assign.";
            }

            return Json(new
            {
                success    = result.Success,
                message    = result.Message,
                admissionNo = result.AdmissionNo,
                studentId  = result.StudentId,
                receiptNo,
                feeMessage,
                feeFailed,
                transportMessage
            });
        }

        // ── GET: /ERP/Admission/GetStudentsData (AJAX) ───────────
        [HttpGet]
        public async Task<IActionResult> GetStudentsData(
            int page = 1, int pageSize = 10, string? search = null,
            string? className = null, string? section = null, string? gender = null,
            string? year = null, string? status = null, string? fee = null)
        {
            var (rows, totalCount) = await _admissionService.GetStudentsAsync(
                TenantId(), SchoolId(), UserId(), page, pageSize,
                NullIfEmpty(search), NullIfEmpty(className), NullIfEmpty(section),
                NullIfEmpty(gender), NullIfEmpty(year), NullIfEmpty(status));

            // Fee status (Paid / Partial / Pending) is computed per row by the
            // proc, so the directory's Fee filter is applied here. The CSV export
            // used to ignore it and export everyone.
            if (!string.IsNullOrWhiteSpace(fee))
            {
                rows = rows.Where(s => string.Equals(s.FeeStatus, fee.Trim(), StringComparison.OrdinalIgnoreCase)).ToList();
                totalCount = rows.Count;
            }

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
                    admissionDate = s.AdmissionDate,
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
        // grouped for the admission fee preview, plus how many instalments
        // each billing cycle produces for someone joining today (so the annual
        // estimate matches what the ledger will actually bill).
        [HttpGet]
        public async Task<IActionResult> GetFeeStructure(string className, string academicYear)
        {
            if (string.IsNullOrWhiteSpace(className) || string.IsNullOrWhiteSpace(academicYear))
                return Json(new { success = false, message = "Class and academic year are required." });

            int tenantId = TenantId(), schoolId = SchoolId(), userId = UserId();

            var (built, error) = await BuildAdmissionFeesAsync(className.Trim(), academicYear.Trim(), tenantId, schoolId, userId);
            if (built == null)
                return Json(new { success = false, message = error });

            var instalments = await _admissionService.GetPlanInstalmentsAsync(academicYear.Trim(), tenantId, schoolId, userId);

            var fees = built.Select(f => new
            {
                feeHeadId       = f.FeeHeadId,
                feeHeadName     = f.FeeHeadName,
                frequency       = f.Frequency,
                amount          = f.Amount,
                collectionPoint = f.CollectionPoint,
                isRefundable    = f.IsRefundable,
                group           = f.IsAdmissionPoint ? "One Time Payable Now" : GroupForFrequency(f.Frequency),
                // Due-now vs scheduled is driven by the Collection Point, not the billing cycle.
                stage           = f.IsAdmissionPoint ? "Admission" : StageForFrequency(f.Frequency),
                // All configured heads are part of the class structure → mandatory.
                mandatory       = true,
                instalments     = f.IsAdmissionPoint ? 1 : InstalmentsFor(instalments, f.Frequency)
            }).ToList();

            return Json(new { success = true, fees });
        }

        // One fee line the admission will charge.
        private sealed class AdmissionFee
        {
            public int     FeeHeadId       { get; set; }
            public string  FeeHeadName     { get; set; } = string.Empty;
            public string  Frequency       { get; set; } = "Yearly";
            public decimal Amount          { get; set; }
            public string  CollectionPoint { get; set; } = "Recurring";
            public bool    IsRefundable    { get; set; }
            public bool    IsAdmissionPoint => string.Equals(CollectionPoint, "Admission", StringComparison.OrdinalIgnoreCase);
        }

        // What an admission costs, worked out on the server.
        private sealed class AdmissionQuote
        {
            public decimal PayToday   { get; set; }   // one-time charges due now, after their share of concession
            public decimal Monthly    { get; set; }
            public decimal Yearly     { get; set; }
            public decimal Annual     { get; set; }   // what the session will bill, after concession
            public decimal Concession { get; set; }
        }

        // The fee lines for a class + session, the one list both the preview and
        // the save use.
        //   * Registration-point heads are never charged here (taken at registration).
        //   * A head switched off in the Fee Head master is not charged.
        //   * A refundable Admission head (the security deposit) only when the school
        //     enables the security deposit in Workflow Settings.
        //   * Deposit enabled but the class structure has none: each active refundable
        //     Admission head from the master is added under its OWN id and name. It
        //     used to be added as one line called "Security Deposit", a name no fee
        //     head has, so the refund screen could not tell it was refundable and
        //     the admission concession could land on it.
        private async Task<(List<AdmissionFee>? Fees, string? Error)> BuildAdmissionFeesAsync(
            string className, string academicYear, int tenantId, int schoolId, int userId)
        {
            var details = await _schoolSettingsService.GetFeeStructureDetailsAsync(
                className, academicYear, tenantId, schoolId, userId);

            if (details == null || details.Count == 0)
                return (null, "No fee structure configured for this class and year. Configure it under School Settings → Fee Structure.");

            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, userId);

            var fees = details
                .Where(d => d.IsActive &&
                            !string.Equals(d.CollectionPoint, "Registration", StringComparison.OrdinalIgnoreCase) &&
                            (!(IsAdmissionPoint(d.CollectionPoint) && d.IsRefundable) || workflow.EnableSecurityFee))
                .Select(d => new AdmissionFee
                {
                    FeeHeadId       = d.FeeHeadId,
                    FeeHeadName     = (d.FeeHeadName ?? string.Empty).Trim(),
                    Frequency       = string.IsNullOrWhiteSpace(d.Frequency) ? "Yearly" : d.Frequency,
                    Amount          = d.Amount,
                    CollectionPoint = string.IsNullOrWhiteSpace(d.CollectionPoint) ? "Recurring" : d.CollectionPoint,
                    IsRefundable    = d.IsRefundable
                })
                .ToList();

            if (workflow.EnableSecurityFee && !fees.Any(f => f.IsAdmissionPoint && f.IsRefundable))
            {
                var heads = await _schoolSettingsService.GetFeeHeadAsync(tenantId, schoolId, userId);
                foreach (var h in heads.Where(h => h.IsActive && h.IsRefundable && h.DefaultAmount > 0 &&
                                                   IsAdmissionPoint(h.CollectionPoint)))
                {
                    if (fees.Any(f => string.Equals(f.FeeHeadName, h.FeeHeadName.Trim(), StringComparison.OrdinalIgnoreCase)))
                        continue;
                    fees.Add(new AdmissionFee
                    {
                        FeeHeadId       = h.FeeHeadId,
                        FeeHeadName     = h.FeeHeadName.Trim(),
                        Frequency       = "One Time",
                        Amount          = h.DefaultAmount,
                        CollectionPoint = "Admission",
                        IsRefundable    = true
                    });
                }
            }

            return (fees, null);
        }

        // Totals and concession for a fee list. The concession never touches a
        // refundable deposit. "Estimated annual" uses the instalments the session
        // will really bill (a student joining in October pays six months, not twelve).
        private static AdmissionQuote QuoteAdmission(
            List<AdmissionFee> fees, Dictionary<string, int> instalments,
            string? discountType, decimal discountValue, string? applyTo)
        {
            var q = new AdmissionQuote();
            decimal discountableNow = 0, discountableAnnual = 0;

            foreach (var f in fees)
            {
                int n = f.IsAdmissionPoint ? 1 : InstalmentsFor(instalments, f.Frequency);
                decimal yearAmount = f.Amount * n;
                q.Annual += yearAmount;
                if (!f.IsRefundable) discountableAnnual += yearAmount;

                if (f.IsAdmissionPoint)
                {
                    q.PayToday += f.Amount;
                    if (!f.IsRefundable) discountableNow += f.Amount;
                }
                else if (string.Equals(f.Frequency, "Monthly", StringComparison.OrdinalIgnoreCase)) q.Monthly += f.Amount;
                else if (string.Equals(f.Frequency, "Yearly", StringComparison.OrdinalIgnoreCase))  q.Yearly  += f.Amount;
            }

            bool annual = IsAnnual(applyTo);
            decimal discBase = annual ? discountableAnnual : discountableNow;
            if (discountValue > 0 && discBase > 0)
            {
                q.Concession = string.Equals(discountType, "percentage", StringComparison.OrdinalIgnoreCase)
                    ? Math.Round(discBase * Math.Min(discountValue, 100m) / 100m, 0, MidpointRounding.AwayFromZero)
                    : Math.Min(discountValue, discBase);
            }

            // The share of the concession that lands on today's one-time charges.
            decimal nowShare = !annual ? q.Concession
                             : discountableAnnual > 0 ? Math.Round(q.Concession * discountableNow / discountableAnnual, 2)
                             : 0m;
            if (q.Concession > ConcessionCap) nowShare = 0m;   // not applied until approved

            q.PayToday -= nowShare;
            q.Annual   -= q.Concession > ConcessionCap ? 0m : q.Concession;
            return q;
        }

        private static int InstalmentsFor(Dictionary<string, int> instalments, string? frequency) =>
            instalments.TryGetValue(string.IsNullOrWhiteSpace(frequency) ? "Yearly" : frequency, out var n) && n > 0 ? n : 1;

        private static bool IsAnnual(string? applyTo) =>
            string.Equals(applyTo, "annual", StringComparison.OrdinalIgnoreCase);

        private static bool IsAdmissionLabel(string? label) =>
            string.Equals(label, "Admission", StringComparison.OrdinalIgnoreCase);

        // Above this the concession waits for approval (matches sp_admission_manage's default cap).
        private const decimal ConcessionCap = 100000m;

        private static bool IsAdmissionPoint(string? collectionPoint) =>
            string.Equals(collectionPoint, "Admission", StringComparison.OrdinalIgnoreCase);
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
        // The first value that is present and is not the one already shown, so the
        // alternate-mobile box never repeats the main number.
        private static string? FirstDifferent(string? already, params string?[] options)
        {
            foreach (var o in options)
            {
                var v = o?.Trim();
                if (!string.IsNullOrEmpty(v) &&
                    !string.Equals(v, already?.Trim(), StringComparison.OrdinalIgnoreCase))
                    return v;
            }
            return null;
        }

        // Joins the parts of an address that were filled in, skipping the blanks.
        private static string? JoinParts(params string?[] parts)
        {
            var kept = parts.Select(p => p?.Trim())
                            .Where(p => !string.IsNullOrEmpty(p))
                            .ToList();
            return kept.Count == 0 ? null : string.Join(", ", kept);
        }

        // The number the next admission WOULD get, for the form to show as a hint.
        // It reads the counter without touching it, so this is a preview and not
        // a reservation: two clerks with the form open both see the same number
        // and whoever saves first takes it. The box therefore stays empty and
        // this goes in the placeholder — a filled-in value would look promised.
        [HttpGet]
        public async Task<IActionResult> NextAdmissionNo(string? academicYear)
        {
            if (string.IsNullOrWhiteSpace(academicYear))
                return Json(new { success = false });

            var next = await _admissionService.PeekNextAdmissionNoAsync(
                academicYear, TenantId(), SchoolId(), UserId());

            return Json(new { success = !string.IsNullOrEmpty(next), admissionNo = next });
        }

        // Classes belong to a session. config.sp_dropdown_common deliberately
        // returns every class name the school has EVER used, collapsed across
        // sessions, which is right for a filter but wrong for this form: it
        // offered classes that do not exist in the year being admitted into, and
        // the section list then came back empty with no explanation. Sections
        // were already year-aware; the class list now is too.
        [HttpGet]
        public async Task<IActionResult> GetClasses(int academicYearId)
        {
            if (academicYearId <= 0)
                return Json(new { success = false, classes = Array.Empty<string>() });

            var setup = await _schoolSettingsService.GetAcademicSetupAsync(
                TenantId(), SchoolId(), academicYearId, UserId());

            // ClassSections is keyed by class name and already ordered by the
            // ladder, so its keys are this session's classes in teaching order.
            var classes = setup?.ClassSections?.Keys.ToList() ?? new List<string>();
            return Json(new { success = true, classes });
        }

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
            try { ViewBag.Classes = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.Classes = new List<SelectListItem>(); }

            try { ViewBag.Sessions = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString()); }
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

        // Spreads the lump "collect at admission" cash AND any concession across the
        // student's freshly created dues, so the receipt is itemised and the discount is
        // recorded as real concession on each ledger row.
        //
        // Concession: shared out IN PROPORTION across the dues it applies to — the
        // one-time charges for "Pay Today", every due of the session for "Estimated
        // annual" — never a refundable deposit, never a carried registration balance.
        // It used to be written off from the first rows onwards, so an annual
        // discount wiped the admission fee and the cash then spilled into tuition.
        //
        // Cash: admission-point charges first (that is what is being collected now),
        // then the earliest remaining dues. Every line is capped at its outstanding,
        // so a row is never over-allocated and no money is dropped.
        private static List<FeeCollectItem> AllocateAdmissionPayment(
            List<StudentDueItem> dues, decimal cash, decimal concession, bool spreadOverYear,
            HashSet<string> refundableHeads)
        {
            var ordered = dues
                .Where(d => d.Outstanding > 0)
                .OrderByDescending(d => IsAdmissionLabel(d.InstallmentLabel))
                .ThenBy(d => d.DueDate ?? "9999-12-31")
                .ThenBy(d => d.LedgerId)
                .ToList();

            var concByLedger = new Dictionary<int, decimal>();
            var cashByLedger = new Dictionary<int, decimal>();

            var eligible = ordered
                .Where(d => !refundableHeads.Contains(d.FeeHeadName)
                         && !string.Equals(d.InstallmentLabel, "Registration", StringComparison.OrdinalIgnoreCase)
                         && (spreadOverYear || IsAdmissionLabel(d.InstallmentLabel)))
                .ToList();
            decimal baseSum = eligible.Sum(d => d.Outstanding);
            decimal concLeft = Math.Min(concession, baseSum);

            for (int i = 0; i < eligible.Count && concLeft > 0; i++)
            {
                var d = eligible[i];
                decimal take = i == eligible.Count - 1
                    ? concLeft
                    : Math.Round(concession * d.Outstanding / baseSum, 2);
                take = Math.Min(Math.Min(take, d.Outstanding), concLeft);
                if (take <= 0) continue;
                concByLedger[d.LedgerId] = take;
                concLeft -= take;
            }

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
