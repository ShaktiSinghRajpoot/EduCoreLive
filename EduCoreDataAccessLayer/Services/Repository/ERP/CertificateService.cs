using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>
    /// Bonafide / Character certificates (core.sp_certificate_manage) and the
    /// extra student data a report card prints (core.sp_report_card_extras).
    /// </summary>
    public class CertificateService : ICertificateService
    {
        private const string Sp       = "core.sp_certificate_manage";
        private const string SpExtras = "core.sp_report_card_extras";
        private readonly PgExec _db;
        private readonly ILogger<CertificateService> _logger;

        public CertificateService(PgExec db, ILogger<CertificateService> logger)
        {
            _db = db;
            _logger = logger;
        }

        private static bool InScope(int tenantId, int schoolId) => tenantId > 1 && schoolId > 0;

        public async Task<List<CertificateStudentHit>> SearchStudentsAsync(string q, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<CertificateStudentHit>();
            if (!InScope(tenantId, schoolId) || string.IsNullOrWhiteSpace(q)) return list;

            var p = Params("Search", tenantId, schoolId, actionUserId);
            p[10].Value = q.Trim();
            await _db.ExecuteCursorsAsync(Sp, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new CertificateStudentHit
                    {
                        StudentId    = DbRead.Int(reader, cols, "student_id"),
                        StudentName  = DbRead.Str(reader, cols, "student_name"),
                        AdmissionNo  = DbRead.NStr(reader, cols, "admission_no"),
                        ClassName    = DbRead.NStr(reader, cols, "class_name"),
                        Section      = DbRead.NStr(reader, cols, "section"),
                        GuardianName = DbRead.NStr(reader, cols, "guardian_name"),
                        Mobile       = DbRead.NStr(reader, cols, "mobile"),
                        IsCurrent    = DbRead.Bool(reader, cols, "is_current"),
                        Status       = DbRead.NStr(reader, cols, "status")
                    });
            });
            return list;
        }

        public async Task<(bool Success, string Message, int CertId)> IssueAsync(int studentId, string type, string? purpose, string? conduct,
                                                                                 string? remarks, int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId)) return (false, "Invalid request.", 0);

            var p = Params("Issue", tenantId, schoolId, actionUserId);
            p[5].Value = studentId;
            p[6].Value = type;
            p[7].Value = (object?)purpose ?? DBNull.Value;
            p[8].Value = (object?)conduct ?? DBNull.Value;
            p[9].Value = (object?)remarks ?? DBNull.Value;
            try
            {
                string msg = "Issued."; int id = 0;
                await _db.ExecuteCursorsAsync(Sp, p, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        id  = DbRead.Int(reader, cols, "cert_id");
                        msg = DbRead.NStr(reader, cols, "message") ?? msg;
                    }
                });
                return (id > 0, msg, id);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Certificate issue rejected for school {SchoolId}. SqlState {SqlState}", schoolId, pex.SqlState);
                return (false, pex.MessageText, 0);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error issuing a certificate for school {SchoolId}.", schoolId);
                return (false, "Could not issue. Please try again.", 0);
            }
        }

        public async Task<Certificate?> GetAsync(int certId, int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId) || certId <= 0) return null;
            var p = Params("Get", tenantId, schoolId, actionUserId);
            p[4].Value = certId;
            var list = await ReadAsync(p);
            return list.FirstOrDefault();
        }

        public Task<List<Certificate>> GetListAsync(string? type, string? search, int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId)) return Task.FromResult(new List<Certificate>());
            var p = Params("List", tenantId, schoolId, actionUserId);
            p[6].Value  = (object?)type ?? DBNull.Value;
            p[10].Value = (object?)search ?? DBNull.Value;
            return ReadAsync(p);
        }

        private async Task<List<Certificate>> ReadAsync(NpgsqlParameter[] p)
        {
            var list = new List<Certificate>();
            await _db.ExecuteCursorsAsync(Sp, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(new Certificate
                    {
                        CertId        = DbRead.Int(reader, cols, "cert_id"),
                        CertNo        = DbRead.Str(reader, cols, "cert_no"),
                        CertType      = DbRead.Str(reader, cols, "cert_type"),
                        StudentId     = DbRead.Int(reader, cols, "student_id"),
                        StudentName   = DbRead.Str(reader, cols, "student_name"),
                        Gender        = DbRead.NStr(reader, cols, "gender"),
                        FatherName    = DbRead.NStr(reader, cols, "father_name"),
                        MotherName    = DbRead.NStr(reader, cols, "mother_name"),
                        Dob           = DbRead.NStr(reader, cols, "dob"),
                        AdmissionNo   = DbRead.NStr(reader, cols, "admission_no"),
                        AdmissionDate = DbRead.NStr(reader, cols, "admission_date"),
                        ClassName     = DbRead.NStr(reader, cols, "class_name"),
                        Section       = DbRead.NStr(reader, cols, "section"),
                        AcademicYear  = DbRead.NStr(reader, cols, "academic_year"),
                        IsCurrent     = DbRead.Bool(reader, cols, "is_current"),
                        DateOfLeaving = DbRead.NStr(reader, cols, "date_of_leaving"),
                        Purpose       = DbRead.NStr(reader, cols, "purpose"),
                        Conduct       = DbRead.NStr(reader, cols, "conduct"),
                        Remarks       = DbRead.NStr(reader, cols, "remarks"),
                        IssueDate     = DbRead.Str(reader, cols, "issue_date"),
                        IsVoid        = DbRead.Bool(reader, cols, "is_void"),
                        VoidReason    = DbRead.NStr(reader, cols, "void_reason")
                    });
            });
            return list;
        }

        public async Task<(bool Success, string Message)> VoidAsync(int certId, string reason, int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId)) return (false, "Invalid request.");
            var p = Params("Void", tenantId, schoolId, actionUserId);
            p[4].Value = certId;
            p[9].Value = reason;
            try
            {
                string msg = "Voided.";
                await _db.ExecuteCursorsAsync(Sp, p, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync()) msg = DbRead.NStr(reader, cols, "message") ?? msg;
                });
                return (true, msg);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Certificate void rejected for school {SchoolId}. SqlState {SqlState}", schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
        }

        public async Task<Dictionary<int, ReportCardExtra>> GetReportCardExtrasAsync(IEnumerable<int> studentIds, string academicYear,
                                                                                     int tenantId, int schoolId, int actionUserId)
        {
            var map = new Dictionary<int, ReportCardExtra>();
            var ids = studentIds.ToArray();
            if (!InScope(tenantId, schoolId) || ids.Length == 0) return map;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_ids", NpgsqlDbType.Array | NpgsqlDbType.Integer) { Value = ids },
                new("p_academic_year",  NpgsqlDbType.Text)    { Value = academicYear },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "report_card_cursor" }
            };
            await _db.ExecuteCursorsAsync(SpExtras, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                {
                    var x = new ReportCardExtra
                    {
                        StudentId  = DbRead.Int(reader, cols, "student_id"),
                        MotherName = DbRead.NStr(reader, cols, "mother_name"),
                        SchoolDays = DbRead.Int(reader, cols, "school_days"),
                        Present    = DbRead.Int(reader, cols, "present")
                    };
                    if (cols.Contains("percent") && reader["percent"] != DBNull.Value) x.Percent = Convert.ToDecimal(reader["percent"]);
                    map[x.StudentId] = x;
                }
            });
            return map;
        }

        // Positions match the procedure's parameters; callers fill what they need.
        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },     // 0
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },      // 1
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },      // 2
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },  // 3
            new("p_cert_id",        NpgsqlDbType.Integer) { Value = DBNull.Value },  // 4
            new("p_student_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },  // 5
            new("p_cert_type",      NpgsqlDbType.Text)    { Value = DBNull.Value },  // 6
            new("p_purpose",        NpgsqlDbType.Text)    { Value = DBNull.Value },  // 7
            new("p_conduct",        NpgsqlDbType.Text)    { Value = DBNull.Value },  // 8
            new("p_remarks",        NpgsqlDbType.Text)    { Value = DBNull.Value },  // 9
            new("p_search",         NpgsqlDbType.Text)    { Value = DBNull.Value },  // 10
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "certificate_cursor" }
        };
    }
}
