using Microsoft.Extensions.Caching.Memory;

namespace EduCoreDataAccessLayer.Infrastructure
{
    /// <summary>
    /// Thin wrapper over <see cref="IMemoryCache"/> for read-mostly reference data (Fix #6).
    ///
    /// WHY:
    ///  - One consistent place for cache keys + a sensible default TTL.
    ///  - <see cref="Key"/> scopes EVERY key by tenant + school, so one school can never read
    ///    another school's cached data (the cardinal multi-tenant caching rule).
    ///  - In-memory (per-instance) is exactly right for our single-instance target. If we ever
    ///    scale out, this is the seam where a Redis-backed IDistributedCache would slot in.
    ///
    /// CAVEAT: cached objects are shared references — treat what you read as read-only. Callers
    /// that need to mutate should map to a fresh object first.
    /// </summary>
    public sealed class AppCache
    {
        private readonly IMemoryCache _cache;
        private static readonly TimeSpan DefaultTtl = TimeSpan.FromMinutes(10);

        public AppCache(IMemoryCache cache) => _cache = cache;

        /// <summary>Return the cached value, or run <paramref name="factory"/> once and cache it.</summary>
        public async Task<T> GetOrCreateAsync<T>(string key, Func<Task<T>> factory, TimeSpan? ttl = null)
        {
            return (await _cache.GetOrCreateAsync(key, entry =>
            {
                entry.AbsoluteExpirationRelativeToNow = ttl ?? DefaultTtl;
                return factory();
            }))!;
        }

        /// <summary>Drop a cached entry — call after a write so the next read refreshes (invalidation).</summary>
        public void Remove(string key) => _cache.Remove(key);

        /// <summary>Build a tenant/school-scoped key, e.g. "feeheads:t7:s12".</summary>
        public static string Key(string name, int tenantId, int schoolId) => $"{name}:t{tenantId}:s{schoolId}";
    }
}
