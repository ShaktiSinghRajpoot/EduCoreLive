using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>School Setup › Rooms: academic.sp_room_manage.</summary>
    public class RoomService : ProcRowsService, IRoomService
    {
        private const string Sp = "academic.sp_room_manage";

        public RoomService(PgExec db, ILogger<RoomService> logger) : base(db, logger) { }

        // p_room_id, p_room_name, p_room_type, p_capacity, p_building, p_notes, p_result — in the procedure's order
        private static List<NpgsqlParameter> P(string op, int t, int s, int u, int? id = null, string? name = null, string? type = null,
                                               int? capacity = null, string? building = null, string? notes = null)
        {
            var p = Head(op, t, s, u);
            p.Add(Int("p_room_id", id)); p.Add(Text("p_room_name", name)); p.Add(Text("p_room_type", type));
            p.Add(Int("p_capacity", capacity)); p.Add(Text("p_building", building)); p.Add(Text("p_notes", notes));
            p.Add(Cursor());
            return p;
        }

        public Task<List<Dictionary<string, object?>>> ListAsync(int t, int s, int u) => RowsAsync(Sp, P("List", t, s, u), t, s);
        public Task<List<Dictionary<string, object?>>> UsageAsync(string? roomName, int t, int s, int u) => RowsAsync(Sp, P("Usage", t, s, u, name: roomName), t, s);
        public Task<List<Dictionary<string, object?>>> UnknownAsync(int t, int s, int u) => RowsAsync(Sp, P("Unknown", t, s, u), t, s);

        public Task<(bool Success, string Message)> SaveAsync(int? roomId, string? name, string? type, int? capacity, string? building, string? notes,
                                                              int t, int s, int u)
            => WriteAsync(Sp, P("Save", t, s, u, roomId, name, type, capacity, building, notes), t, s);

        public Task<(bool Success, string Message)> DeleteAsync(int roomId, int t, int s, int u)
            => WriteAsync(Sp, P("Delete", t, s, u, roomId), t, s);
    }
}
