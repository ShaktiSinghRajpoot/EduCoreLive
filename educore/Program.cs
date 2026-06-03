using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using EduCoreDataAccessLayer.Services.Contract.SuperAdmin;
using EduCoreDataAccessLayer.Services.Repository.Admin;
using EduCoreDataAccessLayer.Services.Repository.SuperAdmin;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.HttpOverrides;

var builder = WebApplication.CreateBuilder(args);

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
    options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
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

        // IMPORTANT:
        // For HTTP server like http://192.168.1.40:8080
        options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;

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

builder.Services.AddScoped<IBaseService, BaseService>();
builder.Services.AddScoped<ILoginService, LoginService>();
builder.Services.AddScoped<ISchoolSettingsService, SchoolSettingsService>();
builder.Services.AddScoped<ISchoolService, SchoolService>();
builder.Services.AddScoped<IEnquiryService, EnquiryService>();
builder.Services.AddScoped<IAdmissionService, AdmissionService>();

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

    // Use HSTS only when production is HTTPS.
    // app.UseHsts();
}

app.UseStatusCodePagesWithReExecute("/Account/Error");

app.Use(async (context, next) =>
{
    context.Response.Headers["X-Frame-Options"] = "DENY";
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    context.Response.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin";

    await next();
});

// IMPORTANT:
// Disable HTTPS redirection for HTTP production.
// Enable only when you have a valid HTTPS binding/certificate.
// app.UseHttpsRedirection();

app.UseStaticFiles();

app.UseRouting();

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