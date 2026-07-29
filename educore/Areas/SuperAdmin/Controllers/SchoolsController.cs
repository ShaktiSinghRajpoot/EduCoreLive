using educore.Models;
using educore.Services;
using educore.Services.Notifications;
using EduCoreDataAccessLayer.Extensions;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract;
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
        private readonly IGeoService _geoService;
        private readonly IWebHostEnvironment _env;
        public SchoolsController(ISchoolService schoolService, INotificationService notificationService, IGeoService geoService, IWebHostEnvironment env)
        {
            _schoolService = schoolService;
            _notificationService = notificationService;
            _geoService = geoService;
            _env = env;
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

        /// <summary>
        /// Live "is this email free?" for the wizard, so the super admin finds out on blur
        /// instead of after filling all four steps and hitting Save.
        ///
        /// Calls the SAME guard as the save path (core.fn_user_email_taken), so the hint and
        /// the actual result can never disagree. This is a convenience, not the enforcement —
        /// sp_school_manage and the uq_user_email_active index still decide.
        ///
        /// An "does this email exist?" endpoint is an enumeration vector, so it stays behind
        /// the controller's [Authorize(Roles = SuperAdmin)] — only platform admins can call it.
        /// </summary>
        [HttpGet]
        public async Task<IActionResult> CheckEmail(string? email, int? userId)
        {
            if (string.IsNullOrWhiteSpace(email))
                return Json(new { ok = true });

            var taken = await _schoolService.IsEmailTakenAsync(email, userId);

            return Json(new
            {
                ok = !taken,
                message = taken ? "This email is already registered to another user." : null
            });
        }

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
                ContactTypeId = 1,
                CountryId = await _geoService.GetDefaultCountryIdAsync()   // India
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
            await ValidateBoardStateAsync(model);

            if (!ModelState.IsValid)
            {
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
                $"Welcome to SmartSchoolWala ({model.SchoolName}). Login: {model.AdminEmail} | " +
                $"Temporary password: {tempPassword}. Please change it on first login. {loginUrl}";

            var delivered = await _notificationService.SendAsync(new NotificationMessage
            {
                ToEmail = model.AdminEmail,
                ToPhone = model.AdminPhone,
                ToName = model.AdminFullName,
                Channels = NotificationChannels.All,
                Subject = $"Welcome to SmartSchoolWala — {model.SchoolName}",
                HtmlBody = html,
                PlainText = plainText
            });

            if (delivered != NotificationChannels.None)
            {
                TempData["Success"] = $"School created. Login details sent to {model.AdminEmail} ({delivered}).";
            }
            else
            {
                // Nothing delivered (channels disabled/failed) — the temp password now exists
                // ONLY here. A toast auto-dismisses after 3.5s (see _Scripts.cshtml), which
                // loses it for good, so these go to a dedicated key that SchoolList renders as
                // a persistent, manually-dismissed alert.
                TempData["Success"] = "School created.";
                TempData["CredentialEmail"] = model.AdminEmail;
                TempData["CredentialPassword"] = tempPassword;
            }
        }

        // Temporary password for a brand-new school admin.
        //
        // Shape: 4 groups of 4 from a 30-char unambiguous alphabet — "K7MQ-P9XR-4TWH-3JNB".
        // WHY not the classic "aK7#mQ2$xP9!":
        //   * This password is routinely read down a phone or copied off a screen when email
        //     delivery fails, and symbols/lookalikes (l vs 1, O vs 0) are where that goes wrong.
        //   * Dropping symbols costs nothing here: 16 chars x log2(30) is ~78 bits, far beyond
        //     any brute-force reach, and login is rate-limited to 5 attempts / 5 min per IP.
        //   * It is single-use anyway — core.users.must_change_password is set TRUE by
        //     sp_school_manage, and the middleware in Program.cs pins the admin to
        //     /Account/ChangePassword until they pick their own.
        private static string GenerateTempPassword()
        {
            // No I, L, O, S, U, Z, 0, 1 — the characters people mis-hear or mis-read.
            const string alphabet = "ABCDEFGHJKMNPQRTVWXY23456789";
            const int groups = 4, groupSize = 4;

            var sb = new StringBuilder(groups * groupSize + groups - 1);
            for (int g = 0; g < groups; g++)
            {
                if (g > 0) sb.Append('-');
                for (int i = 0; i < groupSize; i++)
                    sb.Append(alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)]);
            }

            return sb.ToString();
        }

        private static string BuildWelcomeEmail(string? adminName, string? schoolName, string email, string tempPassword, string loginUrl)
        {
            string Enc(string? s) => System.Net.WebUtility.HtmlEncode(s ?? string.Empty);

            var sb = new StringBuilder();
            sb.Append("<div style=\"font-family:Segoe UI,Arial,sans-serif;max-width:560px;margin:auto;color:#2b1b12;\">");
            sb.Append($"<h2 style=\"color:#ff8a00;\">Welcome to SmartSchoolWala.com</h2>");
            sb.Append($"<p>Hi {Enc(adminName)},</p>");
            sb.Append($"<p>An administrator account has been created for <strong>{Enc(schoolName)}</strong>. Use the credentials below to sign in.</p>");
            sb.Append("<div style=\"background:#f7f6f4;border:1px solid #eee;border-radius:10px;padding:16px;margin:16px 0;\">");
            sb.Append($"<p style=\"margin:4px 0;\"><strong>Email:</strong> {Enc(email)}</p>");
            sb.Append($"<p style=\"margin:4px 0;\"><strong>Temporary password:</strong> {Enc(tempPassword)}</p>");
            sb.Append("</div>");
            sb.Append($"<p><a href=\"{Enc(loginUrl)}\" style=\"display:inline-block;background:#ff8a00;color:#fff;text-decoration:none;padding:10px 18px;border-radius:8px;\">Sign in to SmartSchoolWala</a></p>");
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
            await ValidateBoardStateAsync(model);

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

        // Delete (soft delete) removed. It set core.schools.is_deleted, which hid the
        // school from the list AND from Edit — so its status could never be changed and
        // it could never be purged. Seven schools were stranded that way, one holding
        // 10 students and 25 fee payments nobody could reach.
        //
        // Ending a school is now Edit -> Status -> Closed: blocks every login, stays
        // visible, and is reversible. Purge handles permanent removal.
        // Removed rather than left unused, because an unreferenced [HttpPost] endpoint
        // still accepts a request.

        // Boards flagged requires_state (State Board, Madrasah Board) must say WHICH state's
        // board. The proc enforces this too; doing it here turns a raw PostgresException into
        // a field-level error on the right control.
        private async Task ValidateBoardStateAsync(SchoolManageModel model)
        {
            if (!model.BoardId.HasValue)
                return;

            var d = await _schoolService.GetSchoolDropdownsAsync();

            if (d.BoardsRequiringState.Contains(model.BoardId.Value) &&
                !(model.BoardStateId > 0))
            {
                ModelState.AddModelError(nameof(model.BoardStateId),
                    "Please select which state's board this school follows.");
            }
        }

        /// <summary>
        /// Permanently deletes a school and everything belonging to it.
        ///
        /// ORDER MATTERS: archive first, write the file, and only then purge. The purge
        /// has no undo, so if the archive or the file write fails we stop with the data
        /// still intact. Doing it the other way round would mean a failed write leaves
        /// nothing to recover from.
        ///
        /// The proc independently re-checks all three guards (platform caller, school is
        /// Closed, name matches), so a hand-made POST cannot skip them.
        /// </summary>
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Purge(int id, string? confirmName)
        {
            var userId = User.Identity.GetUserId();
            var tenantId = User.Identity.GetTenantId();

            try
            {
                var archive = await _schoolService.ArchiveSchoolAsync(id, tenantId);

                if (archive == null)
                {
                    TempData["Error"] = "School not found.";
                    return RedirectToAction(nameof(SchoolList));
                }

                // Outside wwwroot on purpose — this file holds the school's entire data
                // set, including student and fee records. It must never be web-servable.
                var folder = Path.Combine(_env.ContentRootPath, "App_Data", "school-archives");
                Directory.CreateDirectory(folder);

                var path = Path.Combine(folder, archive.FileName);
                await System.IO.File.WriteAllTextAsync(path, archive.ArchiveJson);

                await _schoolService.PurgeSchoolAsync(id, tenantId, userId, confirmName ?? string.Empty);

                TempData["Success"] =
                    $"{archive.SchoolName} purged permanently. {archive.TotalRows:N0} rows archived to {archive.FileName}.";
            }
            catch (Exception ex)
            {
                // Reaches here with the school still intact: either a guard refused, or the
                // archive/file write failed before the purge ran.
                TempData["Error"] = ex.Message;
            }

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

            bool isEdit = model.Operation == "UPDATE";

            if (!isEdit)
            {
                // Create with manual entry — a password must be typed.
                if (!model.AutoGeneratePassword && string.IsNullOrWhiteSpace(model.Password))
                    ModelState.AddModelError(nameof(model.Password), "Password is required.");

                return;
            }

            // Edit against an EXISTING admin: password is optional (blank keeps the current one).
            if (model.AdminUserId.GetValueOrDefault() > 0)
                return;

            // Edit of a school that has no admin yet. sp_school_manage only creates one when a
            // password hash arrives, so without this the save "succeeds" and silently creates
            // nothing — the school stays admin-less with no error shown.
            if (string.IsNullOrWhiteSpace(model.Password))
                ModelState.AddModelError(nameof(model.Password),
                    "This school has no administrator yet — set a password to create one.");
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

            // "State Board" alone doesn't say which state's board, and MSBSHSE / UP Board /
            // RBSE share nothing but the label. Which boards need a state comes from
            // config.boards.requires_state, so the wizard never hardcodes a board id.
            model.BoardsRequiringState = d.BoardsRequiringState;
            model.BoardStateList = await _geoService.GetStatesAsync();

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