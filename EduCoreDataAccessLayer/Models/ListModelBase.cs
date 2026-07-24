namespace EduCoreDataAccessLayer.Models
{
    /// <summary>
    /// Shared base for every "master" screen model. A master model inherits this
    /// so ONE model can drive the whole page — listing, form binding, dropdowns —
    /// while pagination + sorting + search live here (written once, reused).
    ///
    /// tenantId / schoolId / actionUserId are NEVER here: they come from the
    /// authenticated user's claims (server-side), never from the client.
    /// SortColumn is a logical key the proc whitelists in its ORDER BY — it is
    /// never interpolated into SQL.
    /// </summary>
    public abstract class ListModelBase
    {
        private int _page = 1;
        private int _pageSize = 10;

        // --- paging (bound from the query string) ---
        public int Page
        {
            get => _page;
            set => _page = value < 1 ? 1 : value;
        }

        public int PageSize
        {
            get => _pageSize;
            set => _pageSize = value < 1 ? 10 : (value > 200 ? 200 : value);
        }

        // --- sorting ---
        public string? SortColumn { get; set; }
        public string? SortDir { get; set; } = "asc";

        // --- search ---
        public string? Search { get; set; }

        // --- filled by the proc (total rows of the full filtered set) ---
        public int TotalCount { get; set; }

        // --- derived helpers the view/pager use ---
        public int TotalPages => PageSize <= 0 ? 0 : (int)System.Math.Ceiling((double)TotalCount / PageSize);
        public int Offset => (Page - 1) * PageSize;
        public bool Desc => string.Equals(SortDir, "desc", System.StringComparison.OrdinalIgnoreCase);
        public string SortDirection => Desc ? "desc" : "asc";
        public bool HasPrev => Page > 1;
        public bool HasNext => Page < TotalPages;
        public int FirstRow => TotalCount == 0 ? 0 : (Page - 1) * PageSize + 1;
        public int LastRow => System.Math.Min(Page * PageSize, TotalCount);
    }
}
