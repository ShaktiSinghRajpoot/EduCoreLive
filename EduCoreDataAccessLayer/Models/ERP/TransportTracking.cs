namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>A bus the signed-in user drives, with its running trip (if any).</summary>
    public class MyBusVehicle
    {
        public int     VehicleId   { get; set; }
        public string  VehicleNo   { get; set; } = string.Empty;
        public int?    RouteId     { get; set; }
        public string? RouteName   { get; set; }
        /// <summary>The running trip, or null when the bus is not on a trip.</summary>
        public int?    TripId      { get; set; }
        public string? StartedAt   { get; set; }
        public string? LastPointAt { get; set; }
        public int     PointCount  { get; set; }
    }

    /// <summary>One running trip on the staff live map (latest position only).</summary>
    public class LiveTrip
    {
        public int      TripId      { get; set; }
        public int      VehicleId   { get; set; }
        public string   VehicleNo   { get; set; } = string.Empty;
        public string?  RouteName   { get; set; }
        public string?  DriverName  { get; set; }
        public string?  StartedAt   { get; set; }
        public string?  LastPointAt { get; set; }
        /// <summary>Seconds since the server received the last point; null = no point yet.</summary>
        public int?     AgeSeconds  { get; set; }
        public decimal? Lat         { get; set; }
        public decimal? Lng         { get; set; }
        public decimal? AccuracyM   { get; set; }
        public decimal? SpeedMps    { get; set; }
        public int      PointCount  { get; set; }
    }

    /// <summary>One trip in the Trip history list.</summary>
    public class TripHistoryRow
    {
        public int     TripId      { get; set; }
        public int     VehicleId   { get; set; }
        public string? VehicleNo   { get; set; }
        public string? RouteName   { get; set; }
        public string? DriverName  { get; set; }
        public string? StartedAt   { get; set; }
        public string? EndedAt     { get; set; }
        public string? EndReason   { get; set; }
        public int     PointCount  { get; set; }
        public bool    IsRunning   { get; set; }
        public int     DurationMin { get; set; }
    }

    /// <summary>One GPS point of a trip's path.</summary>
    public class TripPoint
    {
        public decimal  Lat        { get; set; }
        public decimal  Lng        { get; set; }
        public decimal? SpeedMps   { get; set; }
        public string?  RecordedAt { get; set; }
    }

    /// <summary>
    /// What the public parent page may see: the route name and, per bus on a trip,
    /// its number and last position. Nothing else -- no driver, phone or students.
    /// </summary>
    public class PublicTrack
    {
        public string RouteName { get; set; } = string.Empty;
        public List<PublicBus> Buses { get; set; } = new();
    }

    public class PublicBus
    {
        public string   VehicleNo   { get; set; } = string.Empty;
        public decimal? Lat         { get; set; }
        public decimal? Lng         { get; set; }
        public int?     AgeSeconds  { get; set; }
        public string?  LastPointAt { get; set; }
    }

    /// <summary>A position posted by the driver's phone.</summary>
    public class TripPointRequest
    {
        public int     TripId     { get; set; }
        public double? Lat        { get; set; }
        public double? Lng        { get; set; }
        public double? Accuracy   { get; set; }
        public double? Speed      { get; set; }
        public double? Heading    { get; set; }
        /// <summary>When the phone took the fix, as Unix milliseconds (position.timestamp).</summary>
        public long    RecordedAt { get; set; }
    }
}
