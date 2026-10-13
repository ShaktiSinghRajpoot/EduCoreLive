namespace educore.Helpers
{
    /// <summary>
    /// Starting permission sets offered when a new role is created on the Roles page
    /// ("Start from template"). This list is the only place they are defined. The
    /// server ticks these keys right after the role is created; keys missing from
    /// config.permissions are skipped, and the school can change the ticks afterwards.
    ///
    /// "*.view" means every view key in the catalog.
    /// The Teacher / Accountant / Receptionist sets match the built-in role defaults
    /// in Database/builtin_role_defaults.sql -- keep them in step.
    /// </summary>
    public static class RoleTemplates
    {
        public class RoleTemplate
        {
            public string Name { get; set; } = string.Empty;
            public string[] Keys { get; set; } = Array.Empty<string>();
            public string? Hint { get; set; }   // shown under the select when chosen
        }

        public static readonly List<RoleTemplate> All = new()
        {
            new RoleTemplate
            {
                Name = "Principal",
                Keys = new[] { "*.view", "staff.manage", "exams.manage", "exams.marks", "fees.reopen", "reports.view", "notices.manage" },
                Hint = "Sees every module, approves leave, manages exams, posts notices and can re-open a closed fee day. No settings or roles."
            },
            new RoleTemplate { Name = "Transport In-charge", Keys = new[] { "transport.view", "transport.manage" } },
            new RoleTemplate
            {
                Name = "Driver",
                Keys = Array.Empty<string>(),
                Hint = "No permissions. A driver's My Bus page comes from Transport → Vehicles → Driver."
            },
            new RoleTemplate { Name = "Store Keeper", Keys = new[] { "inventory.view", "inventory.manage" } },
            new RoleTemplate { Name = "HR / Office", Keys = new[] { "staff.view", "staff.manage", "payroll.view", "payroll.manage" } },
            new RoleTemplate { Name = "Cashier", Keys = new[] { "fees.view", "fees.collect" } },
            new RoleTemplate
            {
                Name = "Teacher-like",
                Keys = new[] { "students.view", "attendance.view", "attendance.manage", "exams.view", "exams.marks", "academics.view" }
            },
            new RoleTemplate
            {
                Name = "Accountant-like",
                Keys = new[] { "fees.view", "fees.manage", "fees.collect", "fees.cancel", "fees.refund", "fees.concession", "reports.view", "inventory.view" }
            },
            new RoleTemplate
            {
                Name = "Receptionist-like",
                Keys = new[] { "enquiry.view", "enquiry.manage", "registration.view", "registration.manage", "students.view", "fees.collect" }
            },
        };

        public static RoleTemplate? Find(string? name) =>
            All.FirstOrDefault(t => string.Equals(t.Name, name, StringComparison.OrdinalIgnoreCase));

        /// <summary>True when the template grants this catalog key.</summary>
        public static bool Grants(RoleTemplate template, string permissionKey) =>
            template.Keys.Contains(permissionKey) ||
            (template.Keys.Contains("*.view") && permissionKey.EndsWith(".view"));
    }
}
