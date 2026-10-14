using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>Front office: core.sp_front_office_manage.</summary>
    public class FrontOfficeService : ProcRowsService, IFrontOfficeService
    {
        private const string Sp = "core.sp_front_office_manage";
        private static readonly string[] Lists  = { "Summary", "Visitors", "Calls", "Complaints" };
        private static readonly string[] Writes = { "VisitorSave", "VisitorOut", "CallSave", "CallDone", "ComplaintSave", "ComplaintStatus" };

        public FrontOfficeService(PgExec db, ILogger<FrontOfficeService> logger) : base(db, logger) { }

        // in the procedure's parameter order
        private static List<NpgsqlParameter> P(string op, int t, int s, int u, FrontOfficeEntry e, string? from = null, string? to = null)
        {
            var p = Head(op, t, s, u);
            p.Add(Int("p_id", e.Id)); p.Add(Date("p_from", from)); p.Add(Date("p_to", to));
            p.Add(Text("p_name", e.Name)); p.Add(Text("p_mobile", e.Mobile)); p.Add(Text("p_purpose", e.Purpose));
            p.Add(Text("p_to_meet", e.ToMeet)); p.Add(Int("p_persons", e.Persons)); p.Add(Text("p_id_proof", e.IdProof));
            p.Add(Text("p_note", e.Note)); p.Add(Text("p_direction", e.Direction)); p.Add(Date("p_follow_up", e.FollowUp));
            p.Add(Text("p_student", e.Student)); p.Add(Text("p_status", e.Status));
            p.Add(Cursor());
            return p;
        }

        public Task<List<Dictionary<string, object?>>> ListAsync(string operation, string? from, string? to, string? status, int t, int s, int u)
            => Lists.Contains(operation)
                ? RowsAsync(Sp, P(operation, t, s, u, new FrontOfficeEntry { Status = status }, from, to), t, s)
                : Task.FromResult(new List<Dictionary<string, object?>>());

        public Task<(bool Success, string Message)> SaveAsync(string operation, FrontOfficeEntry e, int t, int s, int u)
            => Writes.Contains(operation)
                ? WriteAsync(Sp, P(operation, t, s, u, e), t, s)
                : Task.FromResult((false, "Unknown action."));
    }
}
