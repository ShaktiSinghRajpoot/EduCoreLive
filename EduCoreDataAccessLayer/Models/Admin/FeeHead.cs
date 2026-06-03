using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace EduCoreDataAccessLayer.Models.Admin
{
    public class FeeHead
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

        public int DisplayOrder { get; set; }
        public bool IsActive { get; set; } = true;
    }
}
