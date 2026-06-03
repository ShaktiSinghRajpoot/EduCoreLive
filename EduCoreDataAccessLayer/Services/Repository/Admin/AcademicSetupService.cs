using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Configuration;
using NpgsqlTypes;
using System.Data;
using System.Text.Json;

namespace eduCore.Services
{
    public class AcademicSetupService : IAcademicSetupService
    {
        private readonly string _connectionString;
        private const string SpAcademicSetupManage = "academic.sp_school_admin_academic_setup_manage";

        public AcademicSetupService(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
        }
    }
}