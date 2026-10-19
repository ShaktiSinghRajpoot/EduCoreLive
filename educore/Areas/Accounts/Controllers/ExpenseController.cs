using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Accounts.Controllers
{
    /// <summary>
    /// Finance › Expenses (/accounts/expenses) and Finance › Cash Book (/accounts/cash-book).
    /// Seeing them needs expenses.view; adding / cancelling an expense, the categories
    /// and the opening balance need expenses.manage. See expense_cashbook.sql.
    /// </summary>
    [Area("Accounts")]
    [RequiresModule(SchoolModule.Accounts)]
    [HasPermission("expenses.view")]
    public class ExpenseController : Controller
    {
        private readonly IExpenseService _expenses;

        public ExpenseController(IExpenseService expenses)
        {
            _expenses = expenses;
        }

        [Route("accounts/expenses")]
        public async Task<IActionResult> Index()
        {
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "expenses.manage");
            ViewBag.Today = Dates.Today;
            return View();
        }

        [Route("accounts/cash-book")]
        public async Task<IActionResult> CashBook([FromServices] ISchoolSettingsService settings)
        {
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "expenses.manage");
            ViewBag.Today = Dates.Today;
            // the current session's first day, for the "This session" button
            try { ViewBag.SessionStart = (await settings.GetAcademicYearsAsync(TenantId(), SchoolId(), UserId())).FirstOrDefault(y => y.IsCurrent)?.StartDate; }
            catch { ViewBag.SessionStart = null; }
            return View();
        }

        // ── Categories ──────────────────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> Categories()
        {
            var list = await _expenses.GetCategoriesAsync(TenantId(), SchoolId(), UserId());
            return Json(list.Select(c => new { id = c.CategoryId, name = c.Name, active = c.IsActive, used = c.Used }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("expenses.manage")]
        public async Task<IActionResult> SaveCategory([FromBody] CategoryRequest req)
        {
            var res = await _expenses.SaveCategoryAsync(req?.Id, req?.Name ?? "", TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, id = res.Id });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("expenses.manage")]
        public async Task<IActionResult> SetCategoryActive([FromBody] CategoryRequest req)
        {
            var res = await _expenses.SetCategoryActiveAsync(req?.Id ?? 0, req?.Active ?? true, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // ── Expenses ────────────────────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> List(string? from, string? to, int? categoryId)
        {
            var rows = await _expenses.GetExpensesAsync(from ?? "", to ?? "", categoryId, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(x => new
            {
                id = x.ExpenseId, date = x.ExpenseDate, categoryId = x.CategoryId, category = x.Category, amount = x.Amount,
                mode = x.PaymentMode, paidTo = x.PaidTo ?? "", reference = x.ReferenceNo ?? "", remarks = x.Remarks ?? "",
                cancelled = x.IsCancelled, cancelReason = x.CancelReason ?? "", cancelledBy = x.CancelledBy ?? "", cancelledAt = x.CancelledAt ?? "",
                by = x.CreatedBy ?? "", at = x.CreatedAt ?? ""
            }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("expenses.manage")]
        public async Task<IActionResult> Save([FromBody] ExpenseInput input)
        {
            var res = await _expenses.SaveExpenseAsync(input, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message, id = res.Id });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("expenses.manage")]
        public async Task<IActionResult> Cancel([FromBody] CancelRequest req)
        {
            var res = await _expenses.CancelExpenseAsync(req?.Id ?? 0, req?.Reason ?? "", TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        // ── Cash Book ───────────────────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> CashBookData(string? from, string? to, string? book)
        {
            if (string.IsNullOrWhiteSpace(from) || string.IsNullOrWhiteSpace(to))
                return Json(new { success = false, message = "Choose the dates." });
            try
            {
                var cb = await _expenses.GetCashbookAsync(from, to, book ?? "All", TenantId(), SchoolId(), UserId());
                var opening = await _expenses.GetOpeningAsync(TenantId(), SchoolId(), UserId());
                return Json(new
                {
                    success = true,
                    bookFrom = cb.BookFrom, openingAsOn = cb.OpeningAsOn,
                    opening = cb.Opening, moneyIn = cb.MoneyIn, moneyOut = cb.MoneyOut, closing = cb.Closing,
                    openingSet = opening == null ? null : new { asOn = opening.AsOn, cash = opening.Cash, bank = opening.Bank, by = opening.UpdatedBy, at = opening.UpdatedAt },
                    lines  = cb.Lines.Select(l => new { date = l.LineDate, kind = l.Kind, reference = l.Ref ?? "", detail = l.Detail ?? "", category = l.Category, mode = l.Mode ?? "", moneyIn = l.MoneyIn, moneyOut = l.MoneyOut, balance = l.Balance }),
                    heads  = cb.Heads.Select(h => new { category = h.Category, moneyIn = h.MoneyIn, moneyOut = h.MoneyOut, entries = h.Entries }),
                    months = cb.Months.Select(m => new { month = m.Month, moneyIn = m.MoneyIn, moneyOut = m.MoneyOut, net = m.Net })
                });
            }
            catch (Npgsql.PostgresException ex)
            {
                return Json(new { success = false, message = ex.MessageText });
            }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("expenses.manage")]
        public async Task<IActionResult> SetOpening([FromBody] OpeningRequest req)
        {
            var res = await _expenses.SetOpeningAsync(req?.AsOn ?? "", req?.Cash ?? 0, req?.Bank ?? 0, TenantId(), SchoolId(), UserId());
            return Json(new { success = res.Success, message = res.Message });
        }

        public class CategoryRequest { public int? Id { get; set; } public string? Name { get; set; } public bool Active { get; set; } = true; }
        public class CancelRequest   { public int Id { get; set; } public string? Reason { get; set; } }
        public class OpeningRequest  { public string? AsOn { get; set; } public decimal Cash { get; set; } public decimal Bank { get; set; } }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
