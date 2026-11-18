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
    ///
    /// Design (QA BUG-014): 5 failed attempts per 5 minutes per IP. The 5th failure
    /// starts the block; the login page then answers 429 with a Retry-After header.
    /// </summary>
    public sealed class LoginThrottle
    {
        public const int MaxFailures = 5;
        private static readonly TimeSpan Window = TimeSpan.FromMinutes(5);

        private readonly IMemoryCache _cache;
        public LoginThrottle(IMemoryCache cache) => _cache = cache;

        private sealed class Counter { public int Failures; public DateTimeOffset WindowEnds; }

        private static string Key(string? ip) => "login-fail:" + (ip ?? "unknown");

        public bool IsBlocked(string? ip) =>
            _cache.TryGetValue(Key(ip), out Counter? c) && c != null && c.Failures >= MaxFailures;

        /// <summary>Seconds until a blocked IP may try again (at least 1).</summary>
        public int RetryAfterSeconds(string? ip)
        {
            if (!_cache.TryGetValue(Key(ip), out Counter? c) || c == null)
                return 0;
            var left = (int)Math.Ceiling((c.WindowEnds - DateTimeOffset.UtcNow).TotalSeconds);
            return Math.Max(1, left);
        }

        public void RecordFailure(string? ip)
        {
            // The window starts at the first failure and is not extended by later ones.
            var c = _cache.GetOrCreate(Key(ip), e =>
            {
                e.AbsoluteExpirationRelativeToNow = Window;
                return new Counter { WindowEnds = DateTimeOffset.UtcNow.Add(Window) };
            })!;
            Interlocked.Increment(ref c.Failures);
        }
    }
}
