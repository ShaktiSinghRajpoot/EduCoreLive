namespace EduCoreDataAccessLayer.Models.Admin
{
    /// <summary>A bus route. Money lives on its stops (per-stop monthly fare).</summary>
    public class TransportRoute
    {
        public int      RouteId     { get; set; }
        public string   RouteName   { get; set; } = string.Empty;
        public string?  Description { get; set; }
        public bool     IsActive    { get; set; } = true;
        public int      StopCount   { get; set; }
        public decimal? MinFare     { get; set; }
        public decimal? MaxFare     { get; set; }
        public List<TransportStop> Stops { get; set; } = new();
    }

    /// <summary>One boarding point on a route, with its own monthly fare.</summary>
    public class TransportStop
    {
        public int     StopId       { get; set; }
        public int     RouteId      { get; set; }
        public string  StopName     { get; set; } = string.Empty;
        public decimal MonthlyFare  { get; set; }
        public int     DisplayOrder { get; set; }
    }

    /// <summary>A bus, optionally attached to a route.</summary>
    public class TransportVehicle
    {
        public int     VehicleId   { get; set; }
        public string  VehicleNo   { get; set; } = string.Empty;
        public int?    Capacity    { get; set; }
        public string? DriverName  { get; set; }
        public string? DriverPhone { get; set; }
        public int?    RouteId     { get; set; }
        public string? RouteName   { get; set; }
        public bool    IsActive    { get; set; } = true;
    }

    /// <summary>A student's current transport assignment (route + stop + snapshot fare).</summary>
    public class StudentTransportAssignment
    {
        public int       AssignmentId { get; set; }
        public int       RouteId      { get; set; }
        public int       StopId       { get; set; }
        public decimal   MonthlyFare  { get; set; }
        public DateOnly? StartDate    { get; set; }
        public string?   RouteName    { get; set; }
        public string?   StopName     { get; set; }
    }

    /// <summary>Flat route+stop row used to build the cascading route → stop dropdown.</summary>
    public class TransportRouteOption
    {
        public int     RouteId     { get; set; }
        public string  RouteName   { get; set; } = string.Empty;
        public int     StopId      { get; set; }
        public string  StopName    { get; set; } = string.Empty;
        public decimal MonthlyFare { get; set; }
    }
}
