using Microsoft.Extensions.Caching.Memory;

namespace educore.Helpers
{
    /// <summary>
    /// Counts FAILED sign-ins per client IP and blocks that IP for the rest of a
    /// 5-minute window once it reaches the limit.
    ///
    /// WHY not the built-in rate limiter: it counts every request, so correct
    /// logins used up the budget too. A whole school office usually shares one IP,
    /// and six teachers signing in at 9am locked the seventh out. Only wrong
    /// passwords / unknown accounts count here, which still stops password guessing.
    /// In-memory, like AppCache: per app instance, cleared on restart.
    /// </summary>
    public sealed class LoginThrottle
    {
        public const int MaxFailures = 10;
        private static readonly TimeSpan Window = TimeSpan.FromMinutes(5);

        private readonly IMemoryCache _cache;
        public LoginThrottle(IMemoryCache cache) => _cache = cache;

        private sealed class Counter { public int Failures; }

        private static string Key(string? ip) => "login-fail:" + (ip ?? "unknown");

        public bool IsBlocked(string? ip) =>
            _cache.TryGetValue(Key(ip), out Counter? c) && c != null && c.Failures >= MaxFailures;

        public void RecordFailure(string? ip)
        {
            // The window starts at the first failure and is not extended by later ones.
            var c = _cache.GetOrCreate(Key(ip), e =>
            {
                e.AbsoluteExpirationRelativeToNow = Window;
                return new Counter();
            })!;
            Interlocked.Increment(ref c.Failures);
        }
    }
}
