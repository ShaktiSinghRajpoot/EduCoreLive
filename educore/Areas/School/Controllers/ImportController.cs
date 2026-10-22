using System.Globalization;
using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.School.Controllers
{
    /// <summary>
    /// School > Import Data (/school/import): a new school's records from Excel.
    ///
    /// The office downloads a template, fills it in Excel (or exports it from the old
    /// software), saves it as CSV and uploads it. Every row is checked first and the
    /// problems are shown against the row; nothing is saved until the office presses
    /// Import. Then each good row goes through the normal save -- the admission of a
    /// student, the Add Staff save, the previous-dues line -- so an imported record is
    /// the same as one typed in at the counter, with the same rules.
    ///
    /// Three kinds: students, staff, previous dues (what families still owed in the old
    /// software; imported after the students).
    /// </summary>
    [Area("School")]
    [HasPermission("settings.manage")]
    public class ImportController : Controller
    {
        private const int MaxRows = 3000;

        private readonly IAdmissionService _admission;
        private readonly IStaffService _staff;
        private readonly ISchoolSettingsService _settings;
        private readonly IAdmissionWorkflowService _workflow;
        private readonly IDataImportService _import;

        public ImportController(IAdmissionService admission, IStaffService staff, ISchoolSettingsService settings,
                                IAdmissionWorkflowService workflow, IDataImportService import)
        {
            _admission = admission;
            _staff = staff;
            _settings = settings;
            _workflow = workflow;
            _import = import;
        }

        // ── the three templates: column, required?, hint, example ──────────
        private static readonly (string Name, bool Required, string Hint, string Example)[] StudentColumns =
        {
            ("Admission No", false, "Leave blank to number automatically", "APS/2022/045"),
            ("Student Name", true, "", "Aarav Sharma"),
            ("Gender", true, "Male / Female", "Male"),
            ("Date of Birth", false, "DD-MM-YYYY", "14-08-2016"),
            ("Class", true, "As in School > Classes", "Class 4"),
            ("Section", true, "", "A"),
            ("Roll No", false, "", "12"),
            ("Admission Date", false, "DD-MM-YYYY, blank = today", "05-04-2022"),
            ("Father Name", true, "", "Rajesh Sharma"),
            ("Mother Name", false, "", "Sunita Sharma"),
            ("Mobile", true, "10 digits", "9876543210"),
            ("Alternate Mobile", false, "", ""),
            ("Address", false, "", "H.No. 12, Sant Nagar, Burari, Delhi"),
            ("Category", false, "General / OBC / SC / ST / EWS", "General"),
            ("Religion", false, "", "Hindu"),
            ("Blood Group", false, "", "B+"),
            ("Aadhaar No", false, "", ""),
            ("Old Student", false, "Yes = already studying here (no admission fee)", "Yes"),
        };
        private static readonly (string Name, bool Required, string Hint, string Example)[] StaffColumns =
        {
            ("Name", true, "", "Kavita Negi"),
            ("Gender", false, "Male / Female", "Female"),
            ("Date of Birth", false, "DD-MM-YYYY", "10-07-1990"),
            ("Mobile", true, "10 digits", "9876500011"),
            ("Email", false, "", ""),
            ("Designation", true, "As in Staff > Departments & Designations", "PRT"),
            ("Department", false, "Blank = the designation's own", ""),
            ("Joining Date", false, "DD-MM-YYYY", "01-07-2014"),
            ("Qualification", false, "", "B.Sc., B.Ed."),
            ("Experience Years", false, "", "8"),
            ("Monthly Salary", false, "", "19000"),
            ("Bank Account No", false, "", ""),
            ("IFSC", false, "", ""),
            ("PAN", false, "", ""),
            ("Aadhaar No", false, "", ""),
        };
        private static readonly (string Name, bool Required, string Hint, string Example)[] DuesColumns =
        {
            ("Admission No", true, "Of a student already in the app", "APS/2022/045"),
            ("Amount", true, "What the family still owes", "4500"),
            ("Note", false, "Shown on the fee counter", "Dues of 2025-26 (old software)"),
            ("From Session", false, "Blank = the session before the current one", "2025-26"),
        };

        private static (string Name, bool Required, string Hint, string Example)[] ColumnsOf(string kind) => kind switch
        {
            "staff" => StaffColumns,
            "dues" => DuesColumns,
            _ => StudentColumns
        };

        // ── pages ────────────────────────────────────────────────────────────
        [Route("school/import")]
        public async Task<IActionResult> Index()
        {
            var year = await CurrentYearAsync();
            ViewBag.Session = year?.AcademicYearName;
            ViewBag.Columns = new Dictionary<string, object>
            {
                ["students"] = StudentColumns.Select(c => new { c.Name, c.Required, c.Hint }),
                ["staff"] = StaffColumns.Select(c => new { c.Name, c.Required, c.Hint }),
                ["dues"] = DuesColumns.Select(c => new { c.Name, c.Required, c.Hint }),
            };
            return View();
        }

        [HttpGet]
        public IActionResult Template(string kind)
        {
            kind = Norm(kind);
            var cols = ColumnsOf(kind);
            var bytes = CsvFile.Write(cols.Select(c => c.Name), new[] { cols.Select(c => c.Example) });
            return File(bytes, "text/csv", "import-" + kind + ".csv");
        }

        // ── 1. check the file: nothing is saved ─────────────────────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        [RequestSizeLimit(5_000_000)]
        public async Task<IActionResult> Check(string kind, IFormFile? file)
        {
            kind = Norm(kind);
            if (file == null || file.Length == 0)
                return Json(new { success = false, message = "Choose the CSV file first." });
            if (!file.FileName.EndsWith(".csv", StringComparison.OrdinalIgnoreCase))
                return Json(new { success = false, message = "Save the sheet as \"CSV UTF-8\" in Excel and upload that file." });

            string text;
            using (var reader = new StreamReader(file.OpenReadStream()))
                text = await reader.ReadToEndAsync();
            var rows = CsvFile.Read(text);
            if (rows.Count == 0)
                return Json(new { success = false, message = "The file has no rows under the header line." });
            if (rows.Count > MaxRows)
                return Json(new { success = false, message = $"At most {MaxRows} rows at a time. Split the file." });

            var missing = ColumnsOf(kind).Where(c => c.Required && !rows[0].ContainsKey(CsvFile.Key(c.Name))).Select(c => c.Name).ToList();
            if (missing.Count > 0)
                return Json(new { success = false, message = "These columns are missing: " + string.Join(", ", missing) + ". Use the template." });

            var ctx = await ContextAsync(kind);
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var checkedRows = rows.Select((r, i) =>
            {
                var errors = Validate(kind, r, ctx, seen);
                return new { line = i + 2, cells = r, errors };
            }).ToList();

            return Json(new
            {
                success = true,
                columns = ColumnsOf(kind).Select(c => c.Name),
                keys = ColumnsOf(kind).Select(c => CsvFile.Key(c.Name)),
                total = checkedRows.Count,
                good = checkedRows.Count(x => x.errors.Count == 0),
                rows = checkedRows
            });
        }

        // ── 2. import the good rows (the page sends them in small batches) ──
        public class SaveRequest
        {
            public string? Kind { get; set; }
            public List<SaveRow>? Rows { get; set; }
        }
        public class SaveRow
        {
            public int Line { get; set; }
            public Dictionary<string, string>? Cells { get; set; }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save([FromBody] SaveRequest req)
        {
            var kind = Norm(req?.Kind);
            var rows = req?.Rows ?? new List<SaveRow>();
            if (rows.Count == 0 || rows.Count > 50)
                return Json(new { success = false, message = "Send between 1 and 50 rows." });

            // old dues are money owed: settings.manage alone may not add them
            if (kind == "dues" && !await HasPermissionAttribute.UserHasAsync(this, "fees.manage"))
                return Json(new { success = false, message = "Importing dues needs the fees.manage permission." });
            // salary and bank columns are kept only for someone with payroll.manage
            bool payOk = kind == "staff" && await HasPermissionAttribute.UserHasAsync(this, "payroll.manage");

            var ctx = await ContextAsync(kind);
            var results = new List<object>();
            foreach (var row in rows)
            {
                var cells = row.Cells ?? new Dictionary<string, string>();
                // checked again here: the page could have been changed in between
                var errors = Validate(kind, cells, ctx, new HashSet<string>());
                if (errors.Count > 0)
                {
                    results.Add(new { line = row.Line, success = false, message = string.Join(" ", errors) });
                    continue;
                }
                var (ok, message) = kind switch
                {
                    "staff" => await SaveStaffAsync(cells, ctx, payOk),
                    "dues" => await _import.AddOpeningDueAsync(V(cells, "Admission No"), Money(V(cells, "Amount")) ?? 0,
                                                               V(cells, "Note"), V(cells, "From Session"), TenantId(), SchoolId(), UserId()),
                    _ => await SaveStudentAsync(cells, ctx)
                };
                results.Add(new { line = row.Line, success = ok, message });
            }
            return Json(new { success = true, results });
        }

        // ── checks ───────────────────────────────────────────────────────────
        private sealed class Context
        {
            public AcademicYearModel? Year;
            public Dictionary<string, List<string>> Sections = new(StringComparer.OrdinalIgnoreCase);   // class -> sections
            public Dictionary<string, List<FeeStructureDetailModel>> Fees = new(StringComparer.OrdinalIgnoreCase);
            public bool SecurityFee;
            public Dictionary<string, DesignationOption> Designations = new(StringComparer.OrdinalIgnoreCase);
        }

        private async Task<Context> ContextAsync(string kind)
        {
            var ctx = new Context { Year = await CurrentYearAsync() };
            if (kind == "students" && ctx.Year != null)
            {
                var setup = await _settings.GetAcademicSetupAsync(TenantId(), SchoolId(), ctx.Year.AcademicYearId, UserId());
                foreach (var kv in setup?.ClassSections ?? new Dictionary<string, List<string>>())
                    ctx.Sections[kv.Key] = kv.Value;
                foreach (var cls in ctx.Sections.Keys)
                    ctx.Fees[cls] = await _settings.GetFeeStructureDetailsAsync(cls, ctx.Year.AcademicYearName, TenantId(), SchoolId(), UserId())
                                    ?? new List<FeeStructureDetailModel>();
                ctx.SecurityFee = (await _workflow.GetAdmissionWorkflowAsync(TenantId(), SchoolId(), UserId())).EnableSecurityFee;
            }
            if (kind == "staff")
            {
                var dd = await _staff.GetDropdownsAsync(TenantId(), SchoolId());
                foreach (var d in dd.Designations)
                    ctx.Designations[d.Name] = d;
            }
            return ctx;
        }

        private static List<string> Validate(string kind, Dictionary<string, string> r, Context ctx, HashSet<string> seen)
        {
            var e = new List<string>();
            foreach (var c in ColumnsOf(kind).Where(c => c.Required))
                if (string.IsNullOrWhiteSpace(V(r, c.Name)))
                    e.Add(c.Name + " is required.");

            if (kind == "students")
            {
                if (ctx.Year == null) { e.Add("Set a current session first."); return e; }
                var cls = V(r, "Class");
                if (cls.Length > 0 && !ctx.Sections.ContainsKey(cls))
                    e.Add($"\"{cls}\" is not a class in {ctx.Year.AcademicYearName}.");
                else if (cls.Length > 0)
                {
                    var sec = V(r, "Section");
                    if (sec.Length > 0 && !ctx.Sections[cls].Any(s => s.Equals(sec, StringComparison.OrdinalIgnoreCase)))
                        e.Add($"{cls} has no section \"{sec}\".");
                    if (ctx.Fees.TryGetValue(cls, out var f) && f.Count == 0)
                        e.Add($"{cls} has no fee structure yet (Fees > Fee Structure).");
                }
                if (Gender(V(r, "Gender")) == null && V(r, "Gender").Length > 0) e.Add("Gender must be Male or Female.");
                if (V(r, "Mobile").Length > 0 && Mobile(V(r, "Mobile")) == null) e.Add("Mobile must be 10 digits.");
                if (V(r, "Alternate Mobile").Length > 0 && Mobile(V(r, "Alternate Mobile")) == null) e.Add("Alternate mobile must be 10 digits.");
                CheckDate(r, "Date of Birth", e, past: true);
                CheckDate(r, "Admission Date", e, past: true);
                var adm = V(r, "Admission No");
                if (adm.Length > 0 && !seen.Add(adm)) e.Add($"Admission no {adm} is twice in the file.");
            }
            else if (kind == "staff")
            {
                var des = V(r, "Designation");
                if (des.Length > 0 && !ctx.Designations.ContainsKey(des))
                    e.Add($"\"{des}\" is not a designation (add it under Staff > Departments & Designations).");
                if (V(r, "Gender").Length > 0 && Gender(V(r, "Gender")) == null) e.Add("Gender must be Male or Female.");
                if (V(r, "Mobile").Length > 0 && Mobile(V(r, "Mobile")) == null) e.Add("Mobile must be 10 digits.");
                CheckDate(r, "Date of Birth", e, past: true);
                CheckDate(r, "Joining Date", e, past: true);
                if (V(r, "Monthly Salary").Length > 0 && Money(V(r, "Monthly Salary")) == null) e.Add("Monthly salary must be a number.");
                if (V(r, "Experience Years").Length > 0 && !int.TryParse(V(r, "Experience Years"), out _)) e.Add("Experience must be a whole number.");
                var mob = Mobile(V(r, "Mobile"));
                if (mob != null && !seen.Add(mob)) e.Add($"Mobile {mob} is twice in the file.");
            }
            else
            {
                var amt = Money(V(r, "Amount"));
                if (V(r, "Amount").Length > 0 && (amt == null || amt <= 0)) e.Add("Amount must be a number above 0.");
                var adm = V(r, "Admission No");
                if (adm.Length > 0 && !seen.Add(adm)) e.Add($"Admission no {adm} is twice in the file.");
            }
            return e;
        }

        // ── saves ────────────────────────────────────────────────────────────
        private async Task<(bool, string)> SaveStudentAsync(Dictionary<string, string> r, Context ctx)
        {
            var cls = ctx.Sections.Keys.First(k => k.Equals(V(r, "Class"), StringComparison.OrdinalIgnoreCase));
            var sec = ctx.Sections[cls].First(s => s.Equals(V(r, "Section"), StringComparison.OrdinalIgnoreCase));
            bool old = V(r, "Old Student").StartsWith("y", StringComparison.OrdinalIgnoreCase);

            // the class's fee structure, the way the admission form builds it: no
            // registration head, a deposit only when the school takes one, and an old
            // student does not pay the one-time admission charges again
            var plan = ctx.Fees[cls]
                .Where(d => d.IsActive
                         && !d.CollectionPoint.Equals("Registration", StringComparison.OrdinalIgnoreCase)
                         && !(d.CollectionPoint.Equals("Admission", StringComparison.OrdinalIgnoreCase) && (old || (d.IsRefundable && !ctx.SecurityFee))))
                .Select(d => new StudentFeePlanItem { FeeHeadId = d.FeeHeadId, FeeHeadName = d.FeeHeadName, Frequency = d.Frequency, Amount = d.Amount })
                .ToList();

            var model = new AdmissionModel
            {
                AdmissionNo = NullIf(V(r, "Admission No")),
                RollNo = NullIf(V(r, "Roll No")),
                StudentName = V(r, "Student Name"),
                Gender = Gender(V(r, "Gender")),
                DateOfBirth = Date(V(r, "Date of Birth")),
                ClassName = cls,
                Section = sec,
                AcademicYear = ctx.Year!.AcademicYearName,
                AdmissionDate = Date(V(r, "Admission Date")) ?? Dates.Today,
                GuardianName = V(r, "Father Name"),
                MotherName = NullIf(V(r, "Mother Name")),
                MobileNumber = Mobile(V(r, "Mobile")),
                AlternateMobile = Mobile(V(r, "Alternate Mobile")),
                Address = NullIf(V(r, "Address")),
                Category = NullIf(V(r, "Category")),
                Religion = NullIf(V(r, "Religion")),
                BloodGroup = NullIf(V(r, "Blood Group")),
                IdProofNo = NullIf(V(r, "Aadhaar No")),
                Nationality = "Indian",
                FeePlan = plan,
                MonthlyTotal = plan.Where(p => p.Frequency == "Monthly").Sum(p => p.Amount),
                YearlyTotal = plan.Where(p => p.Frequency == "Yearly").Sum(p => p.Amount),
                PayTodayTotal = plan.Where(p => p.Frequency == "One Time").Sum(p => p.Amount),
            };
            var res = await _admission.SaveAdmissionAsync(model, TenantId(), SchoolId(), UserId());
            return (res.Success, res.Success ? $"{model.StudentName} admitted ({res.AdmissionNo})." : res.Message);
        }

        private async Task<(bool, string)> SaveStaffAsync(Dictionary<string, string> r, Context ctx, bool payOk)
        {
            var des = ctx.Designations[V(r, "Designation")];
            var model = new StaffModel
            {
                FullName = V(r, "Name"),
                Gender = Gender(V(r, "Gender")),
                DateOfBirth = Date(V(r, "Date of Birth")),
                Mobile = Mobile(V(r, "Mobile")),
                Email = NullIf(V(r, "Email")),
                Designation = des.Name,
                StaffType = des.StaffType,
                Department = NullIf(V(r, "Department")) ?? NullIf(des.DefaultDepartment),
                JoiningDate = Date(V(r, "Joining Date")),
                Qualification = NullIf(V(r, "Qualification")),
                ExperienceYears = int.TryParse(V(r, "Experience Years"), out var y) ? y : null,
                MonthlySalary = payOk ? Money(V(r, "Monthly Salary")) : null,
                BankAccountNo = payOk ? NullIf(V(r, "Bank Account No")) : null,
                IfscCode = payOk ? NullIf(V(r, "IFSC")) : null,
                Pan = payOk ? NullIf(V(r, "PAN")) : null,
                Aadhaar = NullIf(V(r, "Aadhaar No")),
                Status = "Active",
                CreateLogin = false
            };
            var (id, message) = await _staff.SaveStaffAsync(model, "INSERT", null, TenantId(), SchoolId(), UserId());
            return (id > 0, id > 0 ? $"{model.FullName} added." : message);
        }

        // ── small helpers ────────────────────────────────────────────────────
        private async Task<AcademicYearModel?> CurrentYearAsync() =>
            (await _settings.GetAcademicYearsAsync(TenantId(), SchoolId(), UserId())).FirstOrDefault(y => y.IsCurrent);

        private static string Norm(string? kind) => kind?.ToLowerInvariant() switch { "staff" => "staff", "dues" => "dues", _ => "students" };

        private static string V(Dictionary<string, string> r, string column) =>
            r.TryGetValue(CsvFile.Key(column), out var v) ? (v ?? string.Empty).Trim() : string.Empty;

        private static string? NullIf(string s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

        private static string? Gender(string s) =>
            s.StartsWith("m", StringComparison.OrdinalIgnoreCase) ? "Male" :
            s.StartsWith("f", StringComparison.OrdinalIgnoreCase) ? "Female" : null;

        /// <summary>10 digits, with a +91 / 0 in front taken off; null when it is not a mobile.</summary>
        private static string? Mobile(string s)
        {
            var d = new string((s ?? string.Empty).Where(char.IsDigit).ToArray());
            if (d.Length == 12 && d.StartsWith("91")) d = d[2..];
            if (d.Length == 11 && d.StartsWith("0")) d = d[1..];
            return d.Length == 10 ? d : null;
        }

        private static decimal? Money(string s) =>
            decimal.TryParse((s ?? string.Empty).Replace(",", "").Replace("₹", "").Trim(), NumberStyles.Number, CultureInfo.InvariantCulture, out var v) ? v : null;

        private static readonly string[] DateFormats = { "dd-MM-yyyy", "d-M-yyyy", "dd/MM/yyyy", "d/M/yyyy", "dd.MM.yyyy", "yyyy-MM-dd" };

        /// <summary>yyyy-MM-dd, or null when blank or not a date.</summary>
        private static string? Date(string s) =>
            DateTime.TryParseExact((s ?? string.Empty).Trim(), DateFormats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
                ? d.ToString("yyyy-MM-dd") : null;

        private static void CheckDate(Dictionary<string, string> r, string column, List<string> e, bool past)
        {
            var raw = V(r, column);
            if (raw.Length == 0) return;
            var d = Date(raw);
            if (d == null) e.Add($"{column} \"{raw}\" is not a date (use DD-MM-YYYY).");
            else if (past && string.CompareOrdinal(d, Dates.Today) > 0) e.Add($"{column} cannot be in the future.");
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId() => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
