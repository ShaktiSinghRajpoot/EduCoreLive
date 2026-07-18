using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace EduCoreDataAccessLayer.Models.ERP
{
    // ONE model drives the whole Fee Head screen:
    //   • form binding  → the fields below (add / edit)
    //   • listing       → Items (the grid rows)
    //   • filter/paging → Search, Page, SortColumn... (from ListModelBase)
    // ListModelBase lives in the parent namespace (EduCoreDataAccessLayer.Models),
    // so it resolves without an extra using.
    public class FeeHead : ListModelBase
    {
        public string Operation { get; set; } = string.Empty;

        public int TenantId { get; set; }
        public int SchoolId { get; set; }

        public int FeeHeadId { get; set; }
        public string FeeHeadName { get; set; } = string.Empty;
        public string Frequency { get; set; } = string.Empty;
        public decimal DefaultAmount { get; set; }
        public string FeeType { get; set; } = string.Empty;
        public string FeeGroup { get; set; } = "Academic";

        /// <summary>
        /// When this charge is first due in the student lifecycle:
        /// "Registration" (pre-admission), "Admission" (one-time on joining), or
        /// "Recurring" (collected ongoing in the Fee module). Drives where the
        /// head is collected; independent of <see cref="Frequency"/> (the billing cycle).
        /// </summary>
        public string CollectionPoint { get; set; } = "Recurring";

        /// <summary>True for refundable charges such as a security deposit / caution money.</summary>
        public bool IsRefundable { get; set; }

        public int DisplayOrder { get; set; }
        public bool IsActive { get; set; } = true;

        // ── Listing ──────────────────────────────────────────────
        /// <summary>The current page's rows (server-side paged + sorted + filtered).</summary>
        public List<FeeHead> Items { get; set; } = new();

        // ── Summary tiles (proc window counts over the FULL filtered set) ──
        // TotalCount comes from ListModelBase; these two mirror it for the
        // Mandatory / Optional tiles so they don't shrink to the current page.
        public int MandatoryCount { get; set; }
        public int OptionalCount { get; set; }

        // ── List filters ─────────────────────────────────────────
        // Kept separate from the form's Frequency field above: this one filters
        // the grid by billing cycle, it is NOT the new head's cycle.
        public string? FilterFrequency { get; set; }
    }
}
