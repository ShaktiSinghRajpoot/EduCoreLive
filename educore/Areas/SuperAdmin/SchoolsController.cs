using educore.Models;
using educore.Services;
using educore.Services.Notifications;
using EduCoreDataAccessLayer.Extensions;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.SuperAdmin;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using System.Security.Cryptography;
using System.Text;

namespace educore.Areas.SuperAdmin.Controllers
{
    [Area("SuperAdmin")]
    [Authorize(Roles = AppRoles.SuperAdmin)]
    public class SchoolsController : Controller
    {
        private readonly ISchoolService _schoolService;
        private readonly INotificationService _notificationService;
        public SchoolsController(ISchoolService schoolService, INotificationService notificationService)
        {
            _schoolService = schoolService;
            _notificationService = notificationService;
        }

        [HttpGet]
        public async Task<IActionResult> SchoolList(
            string? search, string? city, string? state,
            int? statusId, int? boardId, int? schoolTypeId,
            DateTime? fromDate, DateTime? toDate,
            int page = 1, int pageSize = 10)
        {
            var userId = User.Identity.GetUserId();
            var tenantId = User.Identity.GetTenantId();

            if (page < 1) page = 1;
            if (pageSize < 1) pageSize = 10;

            var (rows, total, active) = await _schoolService.GetSchoolsAsync(
                tenantId, userId,
                Trim(search), Trim(city), Trim(state),
                statusId, boardId, schoolTypeId,
                fromDate, toDate, page, pageSize);

            int totalPages = total > 0 ? (int)Math.Ceiling((double)total / pageSize) : 1;

            // Filter dropdowns (pre-select the current choice)
            var d = await _schoolService.GetSchoolDropdownsAsync();
            ViewBag.Statuses = ToSelectList(d.Statuses, statusId);
            ViewBag.Boards = ToSelectList(d.Boards, boardId);
            ViewBag.SchoolTypes = ToSelectList(d.SchoolTypes, schoolTypeId);

            // Current filter values — repopulate the form and build page links.
            ViewBag.Search = search;
            ViewBag.City = city;
            ViewBag.State = state;
            ViewBag.StatusId = statusId;
            ViewBag.BoardId = boardId;
            ViewBag.SchoolTypeId = schoolTypeId;
            ViewBag.FromDate = fromDate?.ToString("yyyy-MM-dd");
            ViewBag.ToDate = toDate?.ToString("yyyy-MM-dd");

            // Paging
            ViewBag.Page = page;
            ViewBag.PageSize = pageSize;
            ViewBag.TotalRecords = total;
            ViewBag.ActiveRecords = active;
            ViewBag.InactiveRecords = total - active;
            ViewBag.TotalPages = totalPages;
            ViewBag.FromRecord = total == 0 ? 0 : (page - 1) * pageSize + 1;
            ViewBag.ToRecord = Math.Min(page * pageSize, total);

            return View(rows);
        }

        private static string? Trim(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

        private static List<SelectListItem> ToSelectList(IEnumerable<DropdownItem> items, int? selected) =>
            items.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name,
                Selected = selected.HasValue && selected.Value == x.Id
            }).ToList();

        [HttpGet]
        public async Task<IActionResult> Create()
        {
            var model = new SchoolManageModel
            {
                Operation = "INSERT",
                TenantMode = "existing",
                CreateSchoolAdmin = true,
                AutoGeneratePassword = true,
                EnableEmail = true,
                AddressTypeId = 1,
                ContactTypeId = 1
            };

            await FillDropdownsAsync(model);

            return View(model);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Create(SchoolManageModel model)
        {
            model.Operation = "INSERT";

            ValidateTenant(model);
            ValidateSchoolAdmin(model);

            if (!ModelState.IsValid)
            {
                var errors = ModelState
        .Where(x => x.Value.Errors.Count > 0)
        .Select(x => new
        {
            Field = x.Key,
            Errors = x.Value.Errors.Select(e => e.ErrorMessage)
        })
        .ToList();

                await FillDropdownsAsync(model);
                return View(model);
            }

            try
            {
                var userId = User.Identity.GetUserId();
                var tenantId = User.Identity.GetTenantId();

                // Resolve the admin's plaintext password (generated or typed), then store only
                // its BCrypt hash — login verifies with BCrypt.Verify, so a raw value never works.
                string? tempPassword = null;
                if (model.CreateSchoolAdmin)
                {
                    tempPassword = (model.AutoGeneratePassword || string.IsNullOrWhiteSpace(model.Password))
                        ? GenerateTempPassword() : model.Password!;


                    model.Password = BCrypt.Net.BCrypt.HashPassword(tempPassword);
                }

                await _schoolService.CreateSchoolAsync(model, tenantId, userId);

                await DeliverAdminCredentialsAsync(model, tempPassword);

                return RedirectToAction(nameof(SchoolList));
            }
            catch (Exception ex)
            {
                ModelState.AddModelError("", ex.Message);
                await FillDropdownsAsync(model);
                return View(model);
            }
        }

        // Emails the new school admin their login + temporary password. If the school had no
        // admin created, just confirms. If the email cannot be sent, falls back to surfacing the
        // credentials to the super admin so the admin is never silently locked out.
        private async Task DeliverAdminCredentialsAsync(SchoolManageModel model, string? tempPassword)
        {
            if (!model.CreateSchoolAdmin || string.IsNullOrWhiteSpace(model.AdminEmail) || string.IsNullOrWhiteSpace(tempPassword))
            {
                TempData["Success"] = "School created successfully.";
                return;
            }

            var loginUrl = Url.Action("Login", "Account", new { area = "" }, Request.Scheme) ?? "/Account/Login";
            var html = BuildWelcomeEmail(model.AdminFullName, model.SchoolName, model.AdminEmail!, tempPassword!, loginUrl);
            var plainText =
                $"Welcome to EduCore ({model.SchoolName}). Login: {model.AdminEmail} | " +
                $"Temporary password: {tempPassword}. Please change it on first login. {loginUrl}";

            var delivered = await _notificationService.SendAsync(new NotificationMessage
            {
                ToEmail = model.AdminEmail,
                ToPhone = model.AdminPhone,
                ToName = model.AdminFullName,
                Channels = NotificationChannels.All,
                Subject = $"Welcome to EduCore — {model.SchoolName}",
                HtmlBody = html,
                PlainText = plainText
            });

            if (delivered != NotificationChannels.None)
            {
                TempData["Success"] = $"School created. Login details sent to {model.AdminEmail} ({delivered}).";
            }
            else
            {
                // Nothing delivered (channels disabled/failed) — show the credentials once so they can be relayed manually.
                TempData["Warning"] =
                    $"School created, but the welcome message could not be sent. " +
                    $"Share these login details with the admin now — Email: {model.AdminEmail} | " +
                    $"Temporary password: {tempPassword}";
            }
        }

        // Generates a 12-char temporary password with at least one lower, upper, digit and symbol,
        // using a cryptographically secure RNG.
        private static string GenerateTempPassword()
        {
            const string lower = "abcdefghijkmnopqrstuvwxyz";
            const string upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
            const string digits = "23456789";
            const string symbols = "!@#$%*?";
            const string all = lower + upper + digits + symbols;

            var chars = new List<char>
            {
                lower[RandomNumberGenerator.GetInt32(lower.Length)],
                upper[RandomNumberGenerator.GetInt32(upper.Length)],
                digits[RandomNumberGenerator.GetInt32(digits.Length)],
                symbols[RandomNumberGenerator.GetInt32(symbols.Length)]
            };

            while (chars.Count < 12)
                chars.Add(all[RandomNumberGenerator.GetInt32(all.Length)]);

            // Shuffle so the guaranteed-class characters aren't always in front.
            for (int i = chars.Count - 1; i > 0; i--)
            {
                int j = RandomNumberGenerator.GetInt32(i + 1);
                (chars[i], chars[j]) = (chars[j], chars[i]);
            }

            return new string(chars.ToArray());
        }

        private static string BuildWelcomeEmail(string? adminName, string? schoolName, string email, string tempPassword, string loginUrl)
        {
            string Enc(string? s) => System.Net.WebUtility.HtmlEncode(s ?? string.Empty);

            var sb = new StringBuilder();
            sb.Append("<div style=\"font-family:Segoe UI,Arial,sans-serif;max-width:560px;margin:auto;color:#2b1b12;\">");
            sb.Append($"<h2 style=\"color:#ff8a00;\">Welcome to EduCore</h2>");
            sb.Append($"<p>Hi {Enc(adminName)},</p>");
            sb.Append($"<p>An administrator account has been created for <strong>{Enc(schoolName)}</strong>. Use the credentials below to sign in.</p>");
            sb.Append("<div style=\"background:#f7f6f4;border:1px solid #eee;border-radius:10px;padding:16px;margin:16px 0;\">");
            sb.Append($"<p style=\"margin:4px 0;\"><strong>Email:</strong> {Enc(email)}</p>");
            sb.Append($"<p style=\"margin:4px 0;\"><strong>Temporary password:</strong> {Enc(tempPassword)}</p>");
            sb.Append("</div>");
            sb.Append($"<p><a href=\"{Enc(loginUrl)}\" style=\"display:inline-block;background:#ff8a00;color:#fff;text-decoration:none;padding:10px 18px;border-radius:8px;\">Sign in to EduCore</a></p>");
            sb.Append("<p style=\"color:#9a938b;font-size:13px;\">For your security, please change this password after your first login.</p>");
            sb.Append("</div>");
            return sb.ToString();
        }

        [HttpGet]
        public async Task<IActionResult> Edit(int id)
        {
            var userId = User.Identity.GetUserId();
            var tenantId = User.Identity.GetTenantId();
            var model = await _schoolService.GetSchoolByIdAsync(id, tenantId, userId);

            if (model == null)
                return NotFound();

            model.Operation = "UPDATE";

            if (string.IsNullOrWhiteSpace(model.TenantMode))
                model.TenantMode = "existing";

            await FillDropdownsAsync(model);

            return View("Create", model);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Edit(SchoolManageModel model)
        {
            model.Operation = "UPDATE";

            ValidateTenant(model);
            ValidateSchoolAdmin(model);

            if (!ModelState.IsValid)
            {
                await FillDropdownsAsync(model);
                return View("Create", model);
            }

            try
            {
                var userId = User.Identity.GetUserId();
                var tenantId = User.Identity.GetTenantId();

                // On edit the password is optional (blank = keep current). Hash only when a
                // new one was typed — the proc leaves the stored hash untouched for blanks.
                if (model.CreateSchoolAdmin && !string.IsNullOrWhiteSpace(model.Password))
                    model.Password = BCrypt.Net.BCrypt.HashPassword(model.Password);

                await _schoolService.SaveSchoolAsync(model, tenantId, userId);

                TempData["Success"] = "School updated successfully.";
                return RedirectToAction(nameof(SchoolList));
            }
            catch (Exception ex)
            {
                ModelState.AddModelError("", ex.Message);
                await FillDropdownsAsync(model);
                return View("Create", model);
            }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Delete(int id)
        {
            var userId = User.Identity.GetUserId();
            var tenantId = User.Identity.GetTenantId();
            await _schoolService.DeleteSchoolAsync(id, tenantId, userId);

            TempData["Success"] = "School deactivated successfully.";
            return RedirectToAction(nameof(SchoolList));
        }

        private void ValidateTenant(SchoolManageModel model)
        {
            if (model.TenantMode == "existing")
            {
                if (!model.TenantId.HasValue || model.TenantId.Value <= 0)
                    ModelState.AddModelError(nameof(model.TenantId), "Please select tenant.");
            }
            else if (model.TenantMode == "new")
            {
                if (string.IsNullOrWhiteSpace(model.TenantName))
                    ModelState.AddModelError(nameof(model.TenantName), "Tenant name is required.");

                if (string.IsNullOrWhiteSpace(model.TenantCode))
                    ModelState.AddModelError(nameof(model.TenantCode), "Tenant code is required.");
            }
            else
            {
                ModelState.AddModelError(nameof(model.TenantMode), "Please select tenant option.");
            }
        }

        private void ValidateSchoolAdmin(SchoolManageModel model)
        {
            if (!model.CreateSchoolAdmin)
                return;

            if (string.IsNullOrWhiteSpace(model.AdminFullName))
                ModelState.AddModelError(nameof(model.AdminFullName), "Admin full name is required.");

            if (string.IsNullOrWhiteSpace(model.AdminEmail))
                ModelState.AddModelError(nameof(model.AdminEmail), "Admin email is required.");

            // Password is required only when creating (INSERT) with manual entry. On edit it is
            // optional — blank keeps the current password.
            bool isEdit = model.Operation == "UPDATE";
            if (!isEdit && !model.AutoGeneratePassword && string.IsNullOrWhiteSpace(model.Password))
                ModelState.AddModelError(nameof(model.Password), "Password is required.");
        }
        private async Task FillDropdownsAsync(SchoolManageModel model)
        {
            var d = await _schoolService.GetSchoolDropdownsAsync();

            model.StatusList = d.Statuses.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.BoardList = d.Boards.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.SchoolTypeList = d.SchoolTypes.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.OwnershipTypeList = d.OwnershipTypes.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.MediumList = d.Mediums.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.AddressTypeList = d.AddressTypes.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.ContactTypeList = d.ContactTypes.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.AcademicYearList = d.AcademicYears.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.DateFormatList = d.DateFormats.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.TimeFormatList = d.TimeFormats.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();

            model.TenantList = d.Tenants.Select(x => new SelectListItem
            {
                Value = x.Id.ToString(),
                Text = x.Name
            }).ToList();
        }
    }
}