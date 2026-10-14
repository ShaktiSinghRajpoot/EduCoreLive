namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>School Setup › Rooms (rooms.sql).</summary>
    public interface IRoomService
    {
        Task<List<Dictionary<string, object?>>> ListAsync(int tenantId, int schoolId, int actionUserId);
        /// <summary>Booked periods of one room (by name), or of every room when roomName is empty.</summary>
        Task<List<Dictionary<string, object?>>> UsageAsync(string? roomName, int tenantId, int schoolId, int actionUserId);
        /// <summary>Rooms the timetable uses that are not in the list.</summary>
        Task<List<Dictionary<string, object?>>> UnknownAsync(int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> SaveAsync(int? roomId, string? name, string? type, int? capacity, string? building, string? notes,
                                                       int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> DeleteAsync(int roomId, int tenantId, int schoolId, int actionUserId);
    }
}
