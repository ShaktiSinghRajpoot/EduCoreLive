using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Live bus tracking (transport_live_tracking.sql). The driver's phone posts GPS
    /// points for a trip; staff see running trips on a map and replay past trips;
    /// parents open a per-route share link with no login.
    /// </summary>
    public interface ITransportTrackingService
    {
        // Driver (the signed-in user must be the bus's assigned driver)
        Task<List<MyBusVehicle>> GetMyBusesAsync(int tenantId, int schoolId, int actionUserId);
        Task<bool> IsDriverAsync(int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message, int TripId)> StartTripAsync(int vehicleId, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> EndTripAsync(int tripId, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, bool Accepted, string Message)> AddPointAsync(TripPointRequest point, int tenantId, int schoolId, int actionUserId);

        // Staff
        Task<List<LiveTrip>> GetLiveTripsAsync(int tenantId, int schoolId, int actionUserId);
        Task<List<TripHistoryRow>> GetTripHistoryAsync(int? vehicleId, string? fromDate, string? toDate, int tenantId, int schoolId, int actionUserId);
        Task<List<TripPoint>> GetTripPointsAsync(int tripId, int tenantId, int schoolId, int actionUserId);

        // Parent share links (one per route; only the token's hash is stored)
        Task<Dictionary<int, string>> GetShareLinksAsync(int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message, string? Token)> CreateShareLinkAsync(int routeId, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> RevokeShareLinkAsync(int routeId, int tenantId, int schoolId, int actionUserId);

        /// <summary>The parent page. Null = unknown, revoked or malformed link.</summary>
        Task<PublicTrack?> GetPublicTrackAsync(string? token);
    }
}
