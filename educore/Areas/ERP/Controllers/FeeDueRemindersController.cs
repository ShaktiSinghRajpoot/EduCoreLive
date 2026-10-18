using System.Text;
using educore.Helpers;
using educore.Services;
using educore.Services.Notifications;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    //[Authorize(Roles = AppRoles.SchoolAdmin)]
    [HasPermission("fees.view")]
    public class FeeDueRemindersController : Controller
    {
        private const int HistoryTake = 10;

        private readonly IFeePaymentService _feePaymentService;
        private readonly IBaseService _baseService;
        private readonly INotificationService _notifications;
        private readonly ISchoolSettingsService _schoolSettingsService;

        public FeeDueRemindersController(
            IFeePaymentService feePaymentService,
            IBaseService baseService,
            INotificationService notifications,
            ISchoolSettingsService schoolSettingsService)
        {
            _feePaymentService = feePaymentService;
            _baseService = baseService;
            _notifications = notifications;
            _schoolSettingsService = schoolSettingsService;
        }

        // ── GET: /ERP/FeeDueReminders ────────────────────────────
        // One FeeDueItem does it all: filters/sort/page bind in from the query
        // string, the service fills Items + TotalCount + SumOutstanding. Tenant/
        // school/user come from CLAIMS only (never model-bound).
        [HttpGet]
        public async Task<IActionResult> Index(FeeDueItem query)
        {
            // Class filter shares the same source as Admission / Student screens.
            try
            {
                query.ClassList = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString());
            }
            catch {
                query.ClassList = new();
            }
            await _feePaymentService.GetFeeDueListAsync(query, TenantId(), SchoolId(), UserId());

            var (history, sentToday) = await _feePaymentService.GetFeeReminderHistoryAsync(
                HistoryTake, TenantId(), SchoolId(), UserId());
            query.History = history;
            query.SentToday = sentToday;

            // Drives the {school_name} tag in the composer preview.
            try { ViewBag.SchoolName = (await _schoolSettingsService.GetBasicProfileAsync(TenantId(), SchoolId(), UserId()))?.SchoolName ?? ""; }
            catch { ViewBag.SchoolName = ""; }

            return View(query);
        }

        // ── POST: /ERP/FeeDueReminders/SendReminders (AJAX) ──────
        // Sends the composed message to the selected students and RECORDS every
        // attempt. The amount + recipient come from the server's own due list —
        // never from the client — so a tampered payload can't change what is owed
        // or who gets messaged. Channels with no provider wired (SMS/WhatsApp)
        // report as not delivered rather than pretending to send.
        [HttpPost]
        [HasPermission("fees.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SendReminders([FromBody] SendRemindersRequest req, [FromServices] SchoolMessenger messenger)
        {
            int tenantId = TenantId(), schoolId = SchoolId(), userId = UserId();

            if (req == null || req.StudentIds == null || req.StudentIds.Count == 0)
                return Json(new { success = false, message = "Select at least one student." });
            if (string.IsNullOrWhiteSpace(req.Message))
                return Json(new { success = false, message = "Message cannot be empty." });

            var channels = ParseChannels(req.Channels);
            if (channels == NotificationChannels.None)
                return Json(new { success = false, message = "Select at least one channel." });

            // Re-read the dues server-side for exactly these students: the outstanding
            // amount and contact details must come from our data, not the request.
            // The WHOLE list is read: a first-page window (biggest dues first) used
            // to drop any selected student who owed less than the top of the list.
            var everyone = await LoadAllDuesAsync(new FeeDueItem(), tenantId, schoolId, userId);
            var wanted = everyone.Where(i => req.StudentIds.Contains(i.StudentId)).ToList();

            if (wanted.Count == 0)
                return Json(new { success = false, message = "None of the selected students have dues." });

            // School name for the {school_name} tag (resolved once, not per student).
            string schoolName = "";
            try { schoolName = (await _schoolSettingsService.GetBasicProfileAsync(tenantId, schoolId, userId))?.SchoolName ?? ""; }
            catch { /* the tag simply resolves to empty */ }

            // WhatsApp goes as the approved fee template (WhatsApp's rule for a school writing
            // first), through SchoolMessenger, which records each message in the message log.
            bool whatsApp = channels.HasFlag(NotificationChannels.WhatsApp) && await messenger.IsOnAsync(tenantId, schoolId);
            int delivered = 0, failed = 0, waTest = 0;
            foreach (var s in wanted)
            {
                var text = FillTokens(req.Message!, s, schoolName);

                var msg = new NotificationMessage
                {
                    ToEmail   = s.ParentEmail,
                    ToPhone   = s.Mobile,
                    ToName    = s.StudentName,
                    Subject   = "Fee reminder",
                    PlainText = text,
                    HtmlBody  = System.Net.WebUtility.HtmlEncode(text).Replace("\n", "<br/>"),
                    Channels  = channels
                };

                NotificationChannels sent;
                try { sent = await _notifications.SendAsync(msg); }
                catch { sent = NotificationChannels.None; }

                if (whatsApp)
                {
                    var wa = await messenger.SendAsync(tenantId, schoolId, userId, SchoolMessenger.FeeDue, s.StudentId, s.StudentName, s.Mobile,
                        new[] { s.TotalOutstanding.ToString("N2"), s.StudentName, schoolName });
                    if (wa == "Sent") sent |= NotificationChannels.WhatsApp;
                    else if (wa == "Test") waTest++;
                }

                bool any = sent != NotificationChannels.None;
                string status = !any ? "Failed" : (sent == channels ? "Sent" : "Partial");
                if (any) delivered++; else failed++;

                await _feePaymentService.RecordFeeReminderAsync(
                    s.StudentId, channels.ToString(), sent == NotificationChannels.None ? "" : sent.ToString(),
                    s.ParentEmail, s.Mobile, text, s.TotalOutstanding, status,
                    tenantId, schoolId, userId);
            }

            var (history, sentToday) = await _feePaymentService.GetFeeReminderHistoryAsync(
                HistoryTake, tenantId, schoolId, userId);

            string summary = delivered > 0
                ? $"{delivered} reminder(s) sent." + (failed > 0 ? $" {failed} could not be delivered." : "")
                : "No reminder could be delivered — the selected channel has no provider configured yet.";
            if (waTest > 0)
                summary += $" WhatsApp: {waTest} message(s) recorded in test mode (the WhatsApp account is not connected yet) — see Message Log.";
            else if (channels.HasFlag(NotificationChannels.WhatsApp) && !whatsApp)
                summary += " WhatsApp is not switched on for this school.";

            return Json(new
            {
                success = delivered > 0,
                message = summary,
                delivered,
                failed,
                sentToday,
                history = history.Select(h => new
                {
                    studentName = h.StudentName,
                    className   = h.ClassName,
                    channels    = string.IsNullOrWhiteSpace(h.ChannelsDelivered) ? h.ChannelsRequested : h.ChannelsDelivered,
                    status      = h.Status,
                    outstanding = h.Outstanding,
                    sentAt      = h.SentAt.HasValue ? h.SentAt.Value.ToString("dd MMM, hh:mm tt") : ""
                })
            });
        }

        // ── GET: /ERP/FeeDueReminders/Export ─────────────────────
        // CSV of the CURRENT filter (not just the visible page).
        [HttpGet]
        public async Task<IActionResult> Export(FeeDueItem query)
        {
            // The whole filtered set, page by page (PageSize is capped at 200 by
            // ListModelBase, so a single big page silently stopped at 200 rows).
            var rows = await LoadAllDuesAsync(query, TenantId(), SchoolId(), UserId());

            var sb = new StringBuilder();
            sb.AppendLine("Student,Admission No,Class,Section,Status,Mobile,Outstanding,Overdue Days,Bucket,Last Reminder");
            foreach (var d in rows)
            {
                sb.AppendLine(string.Join(',', new[]
                {
                    Csv(d.StudentName), Csv(d.AdmissionNo), Csv(d.ClassName), Csv(d.Section), Csv(d.StudentStatus), Csv(d.Mobile),
                    d.TotalOutstanding.ToString("0.00"), d.OverdueDays.ToString(), Csv(d.Bucket),
                    Csv(d.LastReminderAt?.ToString("dd MMM yyyy") ?? "Never")
                }));
            }

            var bytes = Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(sb.ToString())).ToArray();
            return File(bytes, "text/csv", $"fee_dues_{Dates.Today}.csv");
        }

        // ── helpers ──────────────────────────────────────────────

        // Every row of the due list for the given filters, read 200 at a time.
        private async Task<List<FeeDueItem>> LoadAllDuesAsync(FeeDueItem filter, int tenantId, int schoolId, int userId)
        {
            var all = new List<FeeDueItem>();
            int page = 1;
            while (true)
            {
                var q = new FeeDueItem
                {
                    Page         = page,
                    PageSize     = 200,
                    Search       = filter.Search,
                    FilterClass  = filter.FilterClass,
                    FilterBucket = filter.FilterBucket,
                    SortColumn   = filter.SortColumn,
                    SortDir      = filter.SortDir
                };
                await _feePaymentService.GetFeeDueListAsync(q, tenantId, schoolId, userId);
                all.AddRange(q.Items);
                if (q.Items.Count == 0 || all.Count >= q.TotalCount) break;
                page++;
            }
            return all;
        }

        private static string Csv(string? v) => "\"" + (v ?? "").Replace("\"", "\"\"") + "\"";

        // Merge tags the composer offers ({student_name}, {class}, {due_amount},
        // {days}, {school_name}) — per-student values are filled from OUR data, never
        // from the request, so the amount in the message always matches the ledger.
        private static string FillTokens(string template, FeeDueItem s, string schoolName) => template
            .Replace("{student_name}", s.StudentName ?? "")
            .Replace("{class}",        s.ClassName ?? "")
            .Replace("{due_amount}",   s.TotalOutstanding.ToString("N0"))
            .Replace("{days}",         s.OverdueDays.ToString())
            .Replace("{school_name}",  schoolName ?? "");

        private static NotificationChannels ParseChannels(List<string>? names)
        {
            var result = NotificationChannels.None;
            if (names == null) return result;
            foreach (var n in names)
            {
                switch ((n ?? "").Trim().ToLowerInvariant())
                {
                    case "email":    result |= NotificationChannels.Email; break;
                    case "sms":      result |= NotificationChannels.Sms; break;
                    case "whatsapp": result |= NotificationChannels.WhatsApp; break;
                }
            }
            return result;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }

    public class SendRemindersRequest
    {
        public List<int>?    StudentIds { get; set; }
        public List<string>? Channels   { get; set; }   // Email | Sms | WhatsApp
        public string?       Message    { get; set; }
    }
}
