using Microsoft.AspNetCore.Mvc.Rendering;

namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>
    /// ONE model drives the Fee Due Reminders screen: the defaulter rows (Items),
    /// the filter/paging/sort state (from ListModelBase) and the KPI totals.
    /// Backed by core.sp_fee_due_list — filtering, paging and sorting are all
    /// server-side, so the page never loads the whole school's dues.
    /// </summary>
    public class FeeDueItem : ListModelBase
    {
        // ── Row ──────────────────────────────────────────────────
        public int      StudentId        { get; set; }
        public string   StudentName      { get; set; } = string.Empty;
        public string?  AdmissionNo      { get; set; }
        public string?  ClassName        { get; set; }
        public string?  Section          { get; set; }
        public string?  RollNo           { get; set; }
        public string?  Mobile           { get; set; }

        /// <summary>Parent email (father, else mother) — the Email reminder channel needs it.</summary>
        public string?  ParentEmail      { get; set; }

        /// <summary>Amount still owed (due − paid − concession) across all unpaid installments.</summary>
        public decimal  TotalOutstanding { get; set; }

        /// <summary>Days the OLDEST unpaid installment is past its due date. 0 = nothing overdue yet.</summary>
        public int      OverdueDays      { get; set; }

        /// <summary>Ageing bucket derived from OverdueDays: NotDue / 0-30 / 31-60 / 60+.</summary>
        public string   Bucket           { get; set; } = "NotDue";

        /// <summary>When a reminder was last DELIVERED to this student (null = never).</summary>
        public DateTime? LastReminderAt  { get; set; }

        // ── Listing ──────────────────────────────────────────────
        public List<FeeDueItem> Items { get; set; } = new();

        // ── Filters (kept separate from the row fields above) ────
        public string? FilterClass  { get; set; }
        public string? FilterBucket { get; set; }

        // ── KPI totals (window aggregates over the FULL filtered set) ──
        /// <summary>Total outstanding across every matching student, not just this page.</summary>
        public decimal SumOutstanding { get; set; }

        /// <summary>Students with dues = TotalCount (from ListModelBase); average is derived.</summary>
        public decimal AvgPerStudent => TotalCount > 0 ? SumOutstanding / TotalCount : 0m;

        // ── Reminder panel ───────────────────────────────────────
        /// <summary>Reminders that actually delivered today (drives the "Sent Today" KPI).</summary>
        public int SentToday { get; set; }

        /// <summary>Most recent reminder attempts, for the history panel.</summary>
        public List<FeeReminderLogItem> History { get; set; } = new();

        // ── Dropdown source ──────────────────────────────────────
        public List<SelectListItem> ClassList { get; set; } = new();
    }

    /// <summary>
    /// One recorded reminder attempt. `ChannelsDelivered` is empty when nothing was
    /// actually sent (e.g. SMS/WhatsApp have no provider wired yet) — the screen
    /// shows that honestly instead of implying delivery.
    /// </summary>
    public class FeeReminderLogItem
    {
        public int       ReminderId        { get; set; }
        public int       StudentId         { get; set; }
        public string?   StudentName       { get; set; }
        public string?   ClassName         { get; set; }
        public string?   ChannelsRequested { get; set; }
        public string?   ChannelsDelivered { get; set; }
        public string?   ToEmail           { get; set; }
        public string?   ToPhone           { get; set; }
        public decimal   Outstanding       { get; set; }
        public string?   Status            { get; set; }   // Sent | Partial | Failed
        public DateTime? SentAt            { get; set; }
    }
}
