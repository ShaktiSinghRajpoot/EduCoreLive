using EduCoreDataAccessLayer.Models.Admin;

namespace EduCoreDataAccessLayer.Services.Contract.Admin
{
    /// <summary>
    /// Transport configuration: routes (+ per-stop fares), vehicles, and assigning a
    /// student to a stop. Assigning snapshots the stop's fare and generates monthly
    /// "Transport Fee" dues so the Fee Collection counter bills bus fee automatically.
    /// </summary>
    public interface ITransportService
    {
        // Routes + stops
        Task<List<TransportRoute>> GetRoutesAsync(int tenantId, int schoolId, int actionUserId);
        Task<List<TransportStop>>  GetStopsAsync(int routeId, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message, int RouteId)> SaveRouteAsync(TransportRoute route, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> DeleteRouteAsync(int routeId, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> ToggleRouteStatusAsync(int routeId, int tenantId, int schoolId, int actionUserId);

        // Vehicles
        Task<List<TransportVehicle>> GetVehiclesAsync(int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> SaveVehicleAsync(TransportVehicle vehicle, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> DeleteVehicleAsync(int vehicleId, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> ToggleVehicleStatusAsync(int vehicleId, int tenantId, int schoolId, int actionUserId);

        // Assignment
        Task<List<TransportRouteOption>> GetRoutesDropdownAsync(int tenantId, int schoolId, int actionUserId);
        Task<StudentTransportAssignment?> GetAssignmentAsync(int studentId, int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message, decimal MonthlyFare, int MonthsGenerated)> SaveAssignmentAsync(
            int studentId, int routeId, int stopId, string? academicYear, DateOnly? startDate, int months,
            int tenantId, int schoolId, int actionUserId);
        Task<(bool Success, string Message)> RemoveAssignmentAsync(int studentId, int tenantId, int schoolId, int actionUserId);
    }
}
