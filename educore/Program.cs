using educore.Services;
using educore.Services.Notifications;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using EduCoreDataAccessLayer.Services.Contract.SuperAdmin;
using EduCoreDataAccessLayer.Services.Repository.Admin;
using EduCoreDataAccessLayer.Services.Repository.SuperAdmin;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.RateLimiting;
using Npgsql;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);

// WHY: single switch for all HTTPS-only hardening. Default false so plain-HTTP hosting still
// works (Secure cookies are dropped over HTTP → users couldn't log in). Flip on once TLS exists.
bool requireHttps = builder.Configuration.GetValue<bool>("Security:RequireHttps");

// WHY: pick the cookie policy ONCE so the auth cookie and the session cookie always agree.
// Always = only sent over HTTPS (safe); SameAsRequest = sent over whatever the request used.
var cookieSecurePolicy = requireHttps
    ? CookieSecurePolicy.Always
    : CookieSecurePolicy.SameAsRequest;


// ADD THIS LINE 👇
builder.WebHost.UseUrls($"http://0.0.0.0:{Environment.GetEnvironmentVariable("PORT") ?? "8080"}");

var mvcBuilder = builder.Services
    .AddControllersWithViews()
    .AddSessionStateTempDataProvider();

if (builder.Environment.IsDevelopment())
{
    mvcBuilder.AddRazorRuntimeCompilation();
}

builder.Services.AddRazorPages();
builder.Services.AddHttpContextAccessor();

builder.Services.AddSession(options =>
{
    options.IdleTimeout = TimeSpan.FromHours(8);
    options.Cookie.HttpOnly = true;
    options.Cookie.IsEssential = true;
    options.Cookie.SameSite = SameSiteMode.Lax;
    options.Cookie.SecurePolicy = cookieSecurePolicy;   // WHY: HTTPS-only when RequireHttps=true
});

builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.LoginPath = "/Account/Login";
        options.LogoutPath = "/Account/Logout";
        options.AccessDeniedPath = "/Account/AccessDenied";

        options.Cookie.Name = "EduCore.Auth";
        options.Cookie.HttpOnly = true;
        options.Cookie.SameSite = SameSiteMode.Lax;

        // WHY: HTTPS-only auth cookie when RequireHttps=true; SameAsRequest for plain-HTTP hosting.
        options.Cookie.SecurePolicy = cookieSecurePolicy;

        options.SlidingExpiration = true;
        options.ExpireTimeSpan = TimeSpan.FromHours(8);
        options.ReturnUrlParameter = "returnUrl";
    });

builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("SuperAdminOnly", policy =>
    {
        policy.RequireAuthenticatedUser();
        policy.RequireRole("SUPER_ADMIN");
        policy.RequireClaim(Common.SK_TenantId);
    });

    options.AddPolicy("SchoolAdminOnly", policy =>
    {
        policy.RequireAuthenticatedUser();
        policy.RequireRole("SCHOOL_ADMIN");
        policy.RequireClaim(Common.SK_TenantId);
        policy.RequireClaim(Common.SK_SchoolId);
    });

    options.AddPolicy("SchoolUserOnly", policy =>
    {
        policy.RequireAuthenticatedUser();
        policy.RequireClaim(Common.SK_TenantId);
        policy.RequireClaim(Common.SK_SchoolId);
    });
});

// WHY: throttle login attempts to blunt brute-force / credential-stuffing. We partition by
// client IP so one attacker's IP gets blocked without affecting other users. The "login"
// policy is applied only to the login POST via [EnableRateLimiting("login")] on the action.
builder.Services.AddRateLimiter(options =>
{
    options.AddPolicy("login", httpContext =>
        RateLimitPartition.GetFixedWindowLimiter(
            partitionKey: httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            factory: _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 5,                       // 5 attempts...
                Window = TimeSpan.FromMinutes(5),      // ...per 5 minutes per IP
                QueueLimit = 0                          // excess attempts are rejected, not queued
            }));

    // WHY: return a clean 429; the status-code-pages middleware re-executes to /Account/Error.
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
});

// WHY (Fix #7): build ONE NpgsqlDataSource for the whole app, registered as a singleton.
// It owns the connection pool and prepared-statement cache — far better than building a new
// connection string per call. This is also the single place to tune pooling later (Fix #3
// note): e.g. append ";Maximum Pool Size=100" to the connection string.
builder.Services.AddSingleton(_ =>
{
    var connString = builder.Configuration.GetConnectionString("DefaultConnection")
        ?? throw new InvalidOperationException(
            "DefaultConnection is not configured. Set it in appsettings.Development.json (local) " +
            "or the ConnectionStrings__DefaultConnection environment variable (production).");
    return new NpgsqlDataSourceBuilder(connString).Build();
});

// WHY (Fix #2): the async, reader-based DAL. Stateless over the singleton data source, so singleton.
builder.Services.AddSingleton<PgExec>();

// WHY (Fix #6): in-memory cache for read-mostly reference data (fee heads, dropdowns).
// Per-instance cache is the right fit for our single-instance target.
builder.Services.AddMemoryCache();
builder.Services.AddSingleton<AppCache>();

// WHY: SMTP sender for transactional mail (e.g. new-school-admin welcome credentials).
// Stateless over the bound EmailSettings, so singleton. Settings come from the "Email"
// config section; secrets live in appsettings.Development.json / Email__* env vars.
builder.Services.Configure<EmailSettings>(builder.Configuration.GetSection("Email"));
builder.Services.AddSingleton<IEmailService, EmailService>();

// WHY: channel-agnostic notifications. INotificationService fans a message out to every enabled
// channel (Email now; SMS/WhatsApp log until a provider is wired). Adding a provider later touches
// only the channel adapter, not the controllers. Settings come from the "Notifications" section.
builder.Services.Configure<SmsSettings>(builder.Configuration.GetSection("Notifications:Sms"));
builder.Services.Configure<WhatsAppSettings>(builder.Configuration.GetSection("Notifications:WhatsApp"));
builder.Services.AddSingleton<INotificationChannel, EmailChannel>();
builder.Services.AddSingleton<INotificationChannel, SmsChannel>();
builder.Services.AddSingleton<INotificationChannel, WhatsAppChannel>();
builder.Services.AddSingleton<INotificationService, NotificationService>();

builder.Services.AddScoped<IBaseService, BaseService>();
builder.Services.AddScoped<ILoginService, LoginService>();
builder.Services.AddScoped<ISchoolSettingsService, SchoolSettingsService>();
builder.Services.AddScoped<ISchoolService, SchoolService>();
builder.Services.AddScoped<IEnquiryService, EnquiryService>();
builder.Services.AddScoped<IAdmissionService, AdmissionService>();
builder.Services.AddScoped<IAdmissionWorkflowService, AdmissionWorkflowService>();
builder.Services.AddScoped<IRegistrationService, RegistrationService>();
builder.Services.AddScoped<IFeePaymentService, FeePaymentService>();
builder.Services.AddScoped<ITransportService, TransportService>();
builder.Services.AddScoped<IStaffService, StaffService>();
builder.Services.AddScoped<IRbacService, RbacService>();
builder.Services.AddScoped<IPermissionService, PermissionService>();

builder.Logging.AddConsole();

var app = builder.Build();

app.UseForwardedHeaders(new ForwardedHeadersOptions
{
    ForwardedHeaders =
        ForwardedHeaders.XForwardedFor |
        ForwardedHeaders.XForwardedProto
});

if (app.Environment.IsDevelopment())
{
    app.UseDeveloperExceptionPage();
}
else
{
    app.UseExceptionHandler("/Account/Error");

    // WHY: HSTS tells browsers "always use HTTPS for this site". Only valid when actually
    // serving HTTPS — enabling it on HTTP would lock users out. Gated on RequireHttps.
    if (requireHttps)
        app.UseHsts();
}

app.UseStatusCodePagesWithReExecute("/Account/Error");

app.Use(async (context, next) =>
{
    context.Response.Headers["X-Frame-Options"] = "DENY";
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    context.Response.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin";

    await next();
});

// WHY: redirect HTTP→HTTPS only when we actually have an HTTPS binding/cert (RequireHttps=true).
// Enabling this on plain-HTTP hosting would break every request.
if (requireHttps)
    app.UseHttpsRedirection();

app.UseStaticFiles();

app.UseRouting();

// WHY: must sit after UseRouting so endpoint-specific policies (the "login" policy) resolve.
app.UseRateLimiter();

app.UseSession();

app.UseAuthentication();

app.Use(async (context, next) =>
{
    if (context.User.Identity?.IsAuthenticated == true)
    {
        var tenantId = context.User.FindFirst(Common.SK_TenantId)?.Value;

        if (string.IsNullOrEmpty(tenantId) || tenantId == "0")
        {
            await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            context.Response.Redirect("/Account/Login");
            return;
        }
    }

    await next();
});

// WHY: forced first-login reset. A user whose must_change_password claim is true is
// confined to the Change Password page until they reset it — typing any other URL just
// bounces back here. The allowlist keeps them from being trapped (they can still submit
// the form, sign out, or hit error/access-denied pages). Static files are already served
// above (UseStaticFiles), so they don't reach this middleware.
app.Use(async (context, next) =>
{
    if (context.User.Identity?.IsAuthenticated == true &&
        string.Equals(context.User.FindFirst("must_change_password")?.Value, "True", StringComparison.OrdinalIgnoreCase))
    {
        var path = context.Request.Path.Value ?? string.Empty;
        bool allowed =
            path.StartsWith("/Account/ChangePassword", StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith("/Account/Logout", StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith("/Account/AccessDenied", StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith("/Account/Error", StringComparison.OrdinalIgnoreCase);

        if (!allowed)
        {
            context.Response.Redirect("/Account/ChangePassword");
            return;
        }
    }

    await next();
});

app.UseAuthorization();

app.MapControllerRoute(
    name: "areaRoute",
    pattern: "{area:exists}/{controller=Dashboards}/{action=Index}/{id?}"
);

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Account}/{action=Login}/{id?}"
);

app.MapRazorPages();

app.Run();