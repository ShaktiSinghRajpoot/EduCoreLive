using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using System.Globalization;
using System.Text;

namespace educore.Areas.Exams.Controllers
{
    [Area("Exams")]
    [HasPermission("exams.view")]
    [RequiresModule(SchoolModule.Exams)]
    public class ExamController : Controller
    {
        private readonly IExamService _exam;
        private readonly IExamResultService _results;
        private readonly ISubjectService _subject;
        private readonly IReferenceDataService _referenceData;
        private readonly EduCoreDataAccessLayer.Services.IPermissionService _permission;
        private readonly IBaseService _baseService;

        public ExamController(
            IExamService exam,
            IExamResultService results,
            ISubjectService subject,
            IReferenceDataService referenceData,
            EduCoreDataAccessLayer.Services.IPermissionService permission,
            IBaseService baseService)
        {
            _exam = exam;
            _results = results;
            _subject = subject;
            _referenceData = referenceData;
            _permission = permission;
            _baseService = baseService;
        }

        // The school's sessions for the picker. config.sp_dropdown_common already
        // flags the current one as IsSelected, so the page needs no extra call.
        private async Task<List<SelectListItem>> SessionsAsync()
        {
            try
            {
                return await _baseService.GetSelectListAsync(
                    "config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString());
            }
            catch { return new List<SelectListItem>(); }
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        private async Task<bool> IsAdminAsync()
        {
            var (isAdmin, _) = await _permission.GetUserAccessAsync(TenantId(), SchoolId(), UserId());
            return isAdmin;
        }

        // Entering marks needs exams.marks; exams.manage includes it.
        private async Task<bool> CanEnterMarksAsync()
        {
            return await HasPermissionAttribute.UserHasAsync(this, "exams.marks")
                || await HasPermissionAttribute.UserHasAsync(this, "exams.manage");
        }

        // A teacher with exams.marks but not exams.manage enters marks only for the
        // sheets they teach: sections they are class teacher of, and subjects the
        // timetable gives them. Null = not restricted (school admin / exams.manage).
        private async Task<List<ExamMarkScope>?> MarkScopeAsync(int examId)
        {
            if (await HasPermissionAttribute.UserHasAsync(this, "exams.manage")) return null;
            return await _exam.GetMarkScopeAsync(examId, TenantId(), SchoolId(), UserId());
        }

        private static bool SameSection(string? a, string? b) =>
            string.Equals((a ?? "").Trim(), (b ?? "").Trim(), StringComparison.OrdinalIgnoreCase);

        private static bool InScope(List<ExamMarkScope>? scope, int classId, string? section, int subjectId) =>
            scope == null || scope.Any(x => x.AcademicClassId == classId
                                         && x.SubjectId == subjectId
                                         && SameSection(x.Section, section));

        // ── Exam Schedule ──
        // An exam is school-wide; each class it covers gets its own datesheet.

        [HttpGet("exams/schedule")]
        public async Task<IActionResult> CreateExam(int sessionId = 0)
        {
            var sessions = await SessionsAsync();
            ViewBag.Sessions = sessions;
            ViewBag.SessionId = sessionId > 0 ? sessionId : CurrentSessionId(sessions);

            ViewBag.Classes = await _subject.GetClassesAsync(
                TenantId(), SchoolId(), UserId(), (int)ViewBag.SessionId);

            // Create / edit / publish / delete buttons are shown only with exams.manage.
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "exams.manage");

            try { ViewBag.ExamTypes = await _referenceData.GetOptionsAsync("ExamType", TenantId(), SchoolId()); }
            catch { ViewBag.ExamTypes = new List<SelectListItem>(); }

            var list = await _exam.GetExamsAsync(TenantId(), SchoolId(), UserId(), (int)ViewBag.SessionId);
            ViewBag.AcademicYearName = list.AcademicYearName;

            return View();
        }

        // The session flagged current by config.sp_dropdown_common.
        private static int CurrentSessionId(List<SelectListItem> sessions)
        {
            var cur = sessions.FirstOrDefault(x => x.Selected) ?? sessions.FirstOrDefault();
            return cur != null && int.TryParse(cur.Value, out var id) ? id : 0;
        }

        // Subjects the class studies — the datesheet rows. Reads Subject Management.
        [HttpGet]
        public async Task<IActionResult> Subjects(int classId, int sessionId = 0)
        {
            var subjects = await _subject.GetClassSubjectsAsync(
                classId, TenantId(), SchoolId(), UserId(), sessionId);
            return Json(subjects.Select(s => new { id = s.SubjectId, name = s.SubjectName }));
        }

        // This year's exams — also refreshes the list after a save or delete.
        [HttpGet]
        public async Task<IActionResult> Exams(int sessionId = 0)
        {
            var data = await _exam.GetExamsAsync(TenantId(), SchoolId(), UserId(), sessionId);
            return Json(new
            {
                academicYear = data.AcademicYearName,
                exams = data.Exams.Select(e => new
                {
                    id           = e.ExamId,
                    name         = e.ExamName,
                    type         = e.ExamType,
                    typeLabel    = e.TypeLabel,
                    startDate    = e.StartDate,
                    endDate      = e.EndDate,
                    classCount   = e.ClassCount,
                    subjectCount = e.SubjectCount,
                    classNames   = e.ClassNames
                })
            });
        }

        // One exam with every class's datesheet — loads the form for edit.
        [HttpGet]
        public async Task<IActionResult> Exam(int id)
        {
            var exam = await _exam.GetExamAsync(id, TenantId(), SchoolId(), UserId());
            if (exam == null) return Json(new { success = false, message = "That exam was not found." });

            return Json(new
            {
                success = true,
                exam = new
                {
                    id        = exam.ExamId,
                    name      = exam.ExamName,
                    type      = exam.ExamType,
                    startDate = exam.StartDate,
                    endDate   = exam.EndDate,
                    classes   = exam.Classes.Select(c => new
                    {
                        classId   = c.AcademicClassId,
                        className = c.ClassName,
                        sections  = c.Sections,
                        subjects  = c.Subjects.Select(s => new
                        {
                            id        = s.SubjectId,
                            name      = s.SubjectName,
                            date      = s.ExamDate,
                            startTime = s.StartTime,
                            endTime   = s.EndTime,
                            maxMarks  = s.MaxMarks,
                            passMarks = s.PassMarks
                        })
                    })
                }
            });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveExam([FromBody] ExamSaveRequest request)
        {
            var result = await _exam.SaveExamAsync(request, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message, examId = result.ExamId });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteExam(int id)
        {
            var result = await _exam.DeleteExamAsync(id, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        // The class-wise list: one row per class, or per section when the exam
        // targets specific sections. Drafts are included here (and only here).
        [HttpGet]
        public async Task<IActionResult> ExamList(int sessionId = 0)
        {
            var rows = await _exam.GetExamListAsync(TenantId(), SchoolId(), UserId(), sessionId);
            return Json(rows.Select(r => new
            {
                examId       = r.ExamId,
                examName     = r.ExamName,
                typeLabel    = r.TypeLabel,
                academicYear = r.AcademicYearName,
                classId      = r.AcademicClassId,
                className    = r.ClassName,
                section      = r.Section,
                startDate    = r.StartDate,
                endDate      = r.EndDate,
                status       = r.Status,
                subjectCount = r.SubjectCount
            }));
        }

        // Sections of a class that have students — the optional section chooser.
        [HttpGet]
        public async Task<IActionResult> ClassSections(int classId, int sessionId = 0)
        {
            var rows = await _exam.GetClassSectionsAsync(
                classId, TenantId(), SchoolId(), UserId(), sessionId);
            return Json(rows.Select(r => new { name = r.Section, students = r.StudentCount }));
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SetExamStatus(int id, string status)
        {
            var result = await _exam.SetExamStatusAsync(id, status, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        // -- Datesheet --
        // "What is 1st class sitting, and on which date" — the printable view.

        [HttpGet("exams/datesheet")]
        public async Task<IActionResult> Datesheet(int sessionId = 0)
        {
            var sessions = await SessionsAsync();
            ViewBag.Sessions = sessions;
            ViewBag.SessionId = sessionId > 0 ? sessionId : CurrentSessionId(sessions);

            ViewBag.Classes = await _subject.GetClassesAsync(
                TenantId(), SchoolId(), UserId(), (int)ViewBag.SessionId);

            var list = await _exam.GetExamsAsync(TenantId(), SchoolId(), UserId(), (int)ViewBag.SessionId);
            ViewBag.Exams            = list.Exams.Where(e => e.Status == "Published").ToList();
            ViewBag.AcademicYearName = list.AcademicYearName;

            return View();
        }

        [HttpGet]
        public async Task<IActionResult> DatesheetRows(int classId, int examId, int sessionId = 0)
        {
            var data = await _exam.GetDatesheetAsync(
                classId, examId, TenantId(), SchoolId(), UserId(), sessionId);
            return Json(new
            {
                academicYear = data.AcademicYearName,
                rows = data.Rows.Select(r => new
                {
                    date      = r.ExamDate,
                    startTime = r.StartTime,
                    endTime   = r.EndTime,
                    classId   = r.AcademicClassId,
                    className = r.ClassName,
                    sections  = r.SectionList,
                    subject   = r.SubjectName,
                    maxMarks  = r.MaxMarks,
                    passMarks = r.PassMarks,
                    examId    = r.ExamId,
                    examName  = r.ExamName,
                    typeLabel = r.TypeLabel,
                    clash     = r.HasClash
                })
            });
        }

        // ── Marks Entry ──
        // A SHEET is one (exam, class, section, subject): Exam -> Class -> Section -> Subject.

        // Every session's PUBLISHED exams, grouped by session — the exam dropdown of
        // Marks Entry and the Result Sheet. Marks can be entered for ANY session's
        // exam (results are often finalised after the year rolls over), and the
        // exam already determines the session, so there is no session picker.
        private async Task<List<ExamSessionGroup>> PublishedExamGroupsAsync()
        {
            var sessions = await SessionsAsync();
            var current  = CurrentSessionId(sessions);
            var groups   = new List<ExamSessionGroup>();

            foreach (var sn in sessions)
            {
                if (!int.TryParse(sn.Value, out var yearId)) continue;

                var data = await _exam.GetExamsAsync(TenantId(), SchoolId(), UserId(), yearId);
                // A draft datesheet is still being built, so marks cannot be
                // entered against it. GetDatesheet enforces the same rule proc-side.
                var published = data.Exams.Where(e => e.Status == "Published").ToList();
                if (published.Count == 0) continue;          // no empty headings

                groups.Add(new ExamSessionGroup
                {
                    AcademicYearId = yearId,
                    SessionName    = string.IsNullOrWhiteSpace(data.AcademicYearName)
                                        ? sn.Text : data.AcademicYearName,
                    IsCurrent      = yearId == current,
                    Exams          = published
                });
            }

            return groups
                .OrderByDescending(g => g.IsCurrent)
                .ThenByDescending(g => g.AcademicYearId)
                .ToList();
        }

        [HttpGet("exams/marks")]
        public async Task<IActionResult> MarkEntry(int examId = 0)
        {
            var groups = await PublishedExamGroupsAsync();
            ViewBag.ExamGroups       = groups;
            ViewBag.AcademicYearName = groups.FirstOrDefault(g => g.IsCurrent)?.SessionName ?? string.Empty;
            ViewBag.SelectedExamId   = examId;

            // Only a school admin may reopen a finalized sheet.
            ViewBag.IsAdmin   = await IsAdminAsync();
            ViewBag.CanEnterMarks = await CanEnterMarksAsync();

            return View();
        }

        // The classes this exam covers — the Class dropdown.
        [HttpGet]
        public async Task<IActionResult> ExamClasses(int examId)
        {
            var classes = await _exam.GetExamClassesAsync(examId, TenantId(), SchoolId(), UserId());
            var scope   = await MarkScopeAsync(examId);
            if (scope != null)
                classes = classes.Where(c => scope.Any(x => x.AcademicClassId == c.AcademicClassId)).ToList();
            return Json(classes.Select(c => new
            {
                id       = c.AcademicClassId,
                name     = c.ClassName,
                subjects = c.SubjectCount
            }));
        }

        // That class's datesheet + the sections that actually have students.
        [HttpGet]
        public async Task<IActionResult> ClassSetup(int examId, int classId)
        {
            var setup = await _exam.GetClassSetupAsync(examId, classId, TenantId(), SchoolId(), UserId());

            // A restricted teacher sees only their sections and subjects; the page
            // narrows the subjects per section with the scope list.
            var scope = await MarkScopeAsync(examId);
            List<ExamMarkScope>? mine = null;
            if (scope != null)
            {
                var own = scope.Where(x => x.AcademicClassId == classId).ToList();
                setup.Sections = setup.Sections.Where(s => own.Any(x => SameSection(x.Section, s.Section))).ToList();
                setup.Subjects = setup.Subjects.Where(s => own.Any(x => x.SubjectId == s.SubjectId)).ToList();
                mine = own;
            }

            return Json(new
            {
                scope = mine?.Select(x => new { section = x.Section.Trim(), subjectId = x.SubjectId }),
                subjects = setup.Subjects.Select(s => new
                {
                    id        = s.SubjectId,
                    name      = s.SubjectName,
                    date      = s.ExamDate,
                    maxMarks  = s.MaxMarks,
                    passMarks = s.PassMarks
                }),
                sections = setup.Sections.Select(s => new { name = s.Section, students = s.StudentCount })
            });
        }

        // One sheet: roster, marks so far, scale and lock state.
        [HttpGet]
        public async Task<IActionResult> Sheet(int examId, int classId, int subjectId, string? section)
        {
            if (!InScope(await MarkScopeAsync(examId), classId, section, subjectId))
                return Json(new { success = false, message = "You can enter marks only for the classes and subjects you teach." });

            var sheet = await _exam.GetSheetAsync(
                examId, classId, subjectId, section, TenantId(), SchoolId(), UserId());
            if (sheet == null) return Json(new { success = false, message = "That sheet was not found." });

            return Json(new
            {
                success     = true,
                maxMarks    = sheet.MaxMarks,
                passMarks   = sheet.PassMarks,
                examDate    = sheet.ExamDate,
                subjectName = sheet.SubjectName,
                isFinalized = sheet.IsFinalized,
                finalizedAt = sheet.FinalizedAt,
                // Published results lock every sheet of the exam.
                resultsPublished = sheet.ResultsPublished,
                students    = sheet.Students.Select(s => new
                {
                    id      = s.StudentId,
                    roll    = s.RollNo,
                    name    = s.StudentName,
                    gender  = s.Gender,
                    marks   = s.Marks,
                    absent  = s.IsAbsent,
                    hasMark = s.HasMark
                })
            });
        }

        // Saving and finalising marks: exams.marks or exams.manage (checked in the action
        // because the attribute can only require one key).
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveMarks([FromBody] ExamMarksSaveRequest request)
        {
            if (!await CanEnterMarksAsync())
                return StatusCode(StatusCodes.Status403Forbidden);

            // Only the sheets this teacher teaches (unless exams.manage / admin).
            if (request == null
                || !InScope(await MarkScopeAsync(request.ExamId), request.AcademicClassId, request.Section, request.SubjectId))
                return Json(new { success = false, message = "You can enter marks only for the classes and subjects you teach." });

            var result = await _exam.SaveMarksAsync(request, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success      = result.Success,
                message      = result.Message,
                saved        = result.Saved,
                markedAbsent = result.MarkedAbsent,
                isFinalized  = result.IsFinalized
            });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ReopenSheet(int examId, int classId, int subjectId, string? section)
        {
            // exams.manage alone is not enough here — the page tells teachers to ask
            // an admin, so the server has to hold that line.
            if (!await IsAdminAsync())
                return Json(new { success = false, message = "Only a school admin can reopen a finalized sheet." });

            var result = await _exam.ReopenSheetAsync(
                examId, classId, subjectId, section, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        // ── Grade Scale ──
        // The school's grade bands. No saved bands = the CBSE 8-point default.

        [HttpGet("exams/grades")]
        public async Task<IActionResult> GradeScale()
        {
            ViewBag.CanManage = await _permission.HasPermissionAsync(
                TenantId(), SchoolId(), UserId(), "exams.manage");
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> GradeScaleData()
        {
            var scale = await _results.GetGradeScaleAsync(TenantId(), SchoolId(), UserId());
            return Json(new
            {
                isDefault = scale.IsDefault,
                bands = scale.Bands.Select(b => new
                {
                    label  = b.Label,
                    min    = b.MinPercent,
                    max    = b.MaxPercent,
                    point  = b.GradePoint,
                    remark = b.Remark ?? ""
                })
            });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveGradeScale([FromBody] GradeScaleSaveRequest request)
        {
            var result = await _results.SaveGradeScaleAsync(request, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ResetGradeScale()
        {
            var result = await _results.ResetGradeScaleAsync(TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        // ── Result Sheet ──
        // One exam, one class: students x subjects with total, %, grade and rank.
        // Also where an exam's results are published and unpublished.

        [HttpGet("exams/results")]
        public async Task<IActionResult> ResultSheet(int examId = 0)
        {
            var groups = await PublishedExamGroupsAsync();
            ViewBag.ExamGroups     = groups;
            ViewBag.SelectedExamId = examId;
            ViewBag.CanManage      = await _permission.HasPermissionAsync(
                TenantId(), SchoolId(), UserId(), "exams.manage");
            return View();
        }

        // Published or not, the sheets still to finalise, and the publish log.
        [HttpGet]
        public async Task<IActionResult> ResultStatus(int examId)
        {
            var s = await _results.GetResultStatusAsync(examId, TenantId(), SchoolId(), UserId());
            if (s == null) return Json(new { success = false, message = "That exam was not found." });

            return Json(new
            {
                success       = true,
                examName      = s.ExamName,
                status        = s.Status,
                resultsStatus = s.ResultsStatus,
                publishedAt   = s.PublishedAt,
                publishedBy   = s.PublishedBy,
                sheetCount    = s.SheetCount,
                pendingCount  = s.PendingCount,
                pending = s.Pending.Select(x => new { className = x.ClassName, section = x.Section, subject = x.SubjectName }),
                log     = s.Log.Select(x => new { action = x.Action, reason = x.Reason, by = x.DoneBy, at = x.DoneAt })
            });
        }

        [HttpGet]
        public async Task<IActionResult> ClassResult(int examId, int classId, string? section)
        {
            var sheet = await _results.GetClassResultAsync(examId, classId, section, TenantId(), SchoolId(), UserId());
            if (sheet == null) return Json(new { success = false, message = "Could not load the result for that class." });

            return Json(new
            {
                success       = true,
                examName      = sheet.ExamName,
                className     = sheet.ClassName,
                section       = sheet.Section,
                academicYear  = sheet.AcademicYearName,
                resultsStatus = sheet.ResultsStatus,
                publishedAt   = sheet.PublishedAt,
                pendingCount  = sheet.PendingCount,
                subjects = sheet.Subjects.Select(x => new { id = x.SubjectId, name = x.SubjectName, max = x.MaxMarks, pass = x.PassMarks }),
                students = sheet.Students.Select(x => new
                {
                    id          = x.StudentId,
                    roll        = x.RollNo,
                    admNo       = x.AdmissionNo,
                    name        = x.StudentName,
                    section     = x.Section,
                    obtained    = x.Obtained,
                    total       = x.Total,
                    percent     = x.Percent,       // null = absent from every paper
                    grade       = x.Grade,
                    absent      = x.AbsentCount,
                    failed      = x.FailedCount,
                    classRank   = x.ClassRank,
                    sectionRank = x.SectionRank,
                    classSize   = x.ClassSize,
                    sectionSize = x.SectionSize,
                    cells = x.Cells.Select(c => new
                    {
                        subjectId = c.SubjectId,
                        marks     = c.Marks,
                        absent    = c.IsAbsent,
                        grade     = c.Grade,
                        passed    = c.Passed
                    })
                })
            });
        }

        // The same sheet as a CSV file.
        [HttpGet]
        public async Task<IActionResult> ClassResultCsv(int examId, int classId, string? section)
        {
            var sheet = await _results.GetClassResultAsync(examId, classId, section, TenantId(), SchoolId(), UserId());
            if (sheet == null) return NotFound();

            var sb = new StringBuilder();
            var head = new List<string> { "Roll No", "Admission No", "Student", "Section" };
            head.AddRange(sheet.Subjects.Select(s => s.SubjectName + " (/" + Num(s.MaxMarks) + ")"));
            head.AddRange(new[] { "Total", "Out of", "Percent", "Grade", "Class Rank", "Section Rank", "Result Status" });
            sb.AppendLine(string.Join(',', head.Select(Csv)));

            foreach (var st in sheet.Students)
            {
                var row = new List<string> { st.RollNo, st.AdmissionNo, st.StudentName, st.Section };
                foreach (var sub in sheet.Subjects)
                {
                    var cell = st.Cells.FirstOrDefault(c => c.SubjectId == sub.SubjectId);
                    row.Add(cell == null ? "" : cell.IsAbsent ? "AB" : cell.Marks.HasValue ? Num(cell.Marks.Value) : "");
                }
                row.Add(Num(st.Obtained));
                row.Add(Num(st.Total));
                row.Add(st.Percent.HasValue ? st.Percent.Value.ToString("0.00", CultureInfo.InvariantCulture) : "");
                row.Add(st.Grade ?? "");
                row.Add(st.ClassRank?.ToString() ?? "");
                row.Add(st.SectionRank?.ToString() ?? "");
                row.Add(sheet.ResultsStatus);
                sb.AppendLine(string.Join(',', row.Select(Csv)));
            }

            var bytes = Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(sb.ToString())).ToArray();
            return File(bytes, "text/csv", $"result_sheet_{examId}_{classId}_{Dates.Today}.csv");
        }

        // 90.00 -> "90", 33.50 -> "33.5"
        private static string Num(decimal v) => v.ToString("0.##", CultureInfo.InvariantCulture);

        // Quote every field, and defuse anything a spreadsheet would run as a
        // formula (=, +, -, @, tab, CR at the start): a student or subject name
        // like "=HYPERLINK(...)" must stay text when the file is opened.
        private static string Csv(string? v)
        {
            var s = v ?? string.Empty;
            if (s.Length > 0 && "=+-@\t\r".IndexOf(s[0]) >= 0) s = "'" + s;
            return "\"" + s.Replace("\"", "\"\"") + "\"";
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> PublishResults(int examId)
        {
            var result = await _results.PublishResultsAsync(examId, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> UnpublishResults(int examId, string? reason)
        {
            var result = await _results.UnpublishResultsAsync(examId, reason, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }
    }
}
