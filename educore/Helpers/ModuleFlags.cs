using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;

namespace educore.Helpers
{
    /// <summary>
    /// Which optional modules are ON for the signed-in user's school (given by the
    /// Super Admin AND switched on by the school). Read once per request.
    ///
    /// Use it wherever a page shows something of a module outside the module's own
    /// pages -- a field, a column, a card, a link -- so a module that is off never
    /// shows up anywhere:
    ///     in a view:        @inject educore.Helpers.ModuleFlags Modules
    ///                       @if (await Modules.TransportOn()) { ... }
    ///     in a controller:  inject ModuleFlags and call the same methods.
    /// </summary>
    public sealed class ModuleFlags
    {
        private readonly IAdmissionWorkflowService _workflow;
        private readonly IHttpContextAccessor _http;
        private AdmissionWorkflowModel? _settings;

        public ModuleFlags(IAdmissionWorkflowService workflow, IHttpContextAccessor http)
        {
            _workflow = workflow;
            _http = http;
        }

        public async Task<AdmissionWorkflowModel> GetAsync()
        {
            if (_settings != null)
                return _settings;

            var user = _http.HttpContext?.User;
            int tenantId = ClaimInt(user, Common.SK_TenantId);
            int schoolId = ClaimInt(user, Common.SK_SchoolId);
            int userId   = ClaimInt(user, Common.SK_UserId);

            // No school (Super Admin) or the settings cannot be read: everything stays
            // visible, as before the switches existed.
            _settings = new AdmissionWorkflowModel();
            if (tenantId > 1 && schoolId > 0)
            {
                try { _settings = await _workflow.GetAdmissionWorkflowAsync(tenantId, schoolId, userId); }
                catch { /* keep the defaults */ }
            }
            return _settings;
        }

        public async Task<bool> TransportOn() => (await GetAsync()).EnableTransport;
        public async Task<bool> ExamsOn()     => (await GetAsync()).EnableExams;
        public async Task<bool> InventoryOn() => (await GetAsync()).EnableInventory;
        public async Task<bool> PayrollOn()   => (await GetAsync()).EnablePayroll;
        public async Task<bool> AttendanceOn() => (await GetAsync()).EnableAttendance;
        public async Task<bool> AcademicsOn()  => (await GetAsync()).EnableAcademics;
        public async Task<bool> FeesOn()       => (await GetAsync()).EnableFees;
        public async Task<bool> AccountsOn()   => (await GetAsync()).EnableAccounts;

        private static int ClaimInt(System.Security.Claims.ClaimsPrincipal? u, string type) =>
            int.TryParse(u?.FindFirst(type)?.Value, out var v) ? v : 0;
    }
}
