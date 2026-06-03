using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace EduCoreDataAccessLayer.Models.Admin
{
    public class RolePermissionDto
    {
        public int PermissionId { get; set; }
        public string PermissionKey { get; set; } = "";
        public string PermissionName { get; set; } = "";
        public string ModuleName { get; set; } = "";
        public bool IsSelected { get; set; }
    }
}
