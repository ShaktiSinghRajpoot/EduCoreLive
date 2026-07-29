// SmartSchoolWala service worker.
//
// Offline support is deliberately narrow:
//   * static assets (/css/ /js/ /vendor/ /img/ /icons/ /splash/) -> stale-while-revalidate
//   * page navigations                                           -> network first, /offline.html when the network is gone
//   * everything else (controller XHR, /uploads/, non-GET)       -> network only, never cached
//
// NOTHING tenant-scoped is ever written to the cache. School logos and student
// photos live under /uploads/{tenantId}/{schoolId}/, and every ERP page is
// rendered for one school. Caching either would hand one school's data to the
// next person who opens the app on a shared staff device. That is why the rule
// below is an allowlist of static folders and not a "cache everything" rule.
//
// Bump CACHE when the precache list changes — activate deletes every other cache.

var CACHE = "ssw-static-v1";
var OFFLINE_URL = "/offline.html";

// Kept short on purpose: cache.addAll is atomic, so a single 404 here would
// abort the install and leave the app with no service worker at all.
var PRECACHE = [
    OFFLINE_URL,
    "/img/brand/ssw-stacked.png"
];

var STATIC_DIRS = ["/css/", "/js/", "/vendor/", "/img/", "/icons/", "/splash/"];

function isStaticAsset(url) {
    // Tenant-scoped uploads look like static files but are not. Never cache them.
    if (url.pathname.indexOf("/uploads/") === 0) {
        return false;
    }
    for (var i = 0; i < STATIC_DIRS.length; i++) {
        if (url.pathname.indexOf(STATIC_DIRS[i]) === 0) {
            return true;
        }
    }
    return false;
}

self.addEventListener("install", function (event) {
    event.waitUntil(
        caches.open(CACHE).then(function (cache) {
            return cache.addAll(PRECACHE);
        })
    );
    self.skipWaiting();
});

self.addEventListener("activate", function (event) {
    event.waitUntil(
        caches.keys().then(function (keys) {
            return Promise.all(keys.map(function (key) {
                return key === CACHE ? Promise.resolve() : caches.delete(key);
            }));
        }).then(function () {
            return self.clients.claim();
        })
    );
});

self.addEventListener("fetch", function (event) {
    var req = event.request;

    if (req.method !== "GET") {
        return;
    }

    var url = new URL(req.url);
    if (url.origin !== self.location.origin) {
        return;   // let the browser deal with anything off-origin
    }

    if (isStaticAsset(url)) {
        event.respondWith(staleWhileRevalidate(event));
        return;
    }

    if (req.mode === "navigate") {
        event.respondWith(networkThenOfflinePage(req));
        return;
    }

    // Everything else falls through to the network untouched.
});

// Serve the cached copy immediately, refresh it in the background. Plain
// cache-first would pin an old stylesheet forever; this way a deploy lands on
// the next page load.
function staleWhileRevalidate(event) {
    var req = event.request;

    return caches.open(CACHE).then(function (cache) {
        return cache.match(req).then(function (cached) {
            var network = fetch(req).then(function (res) {
                // Only store real same-origin successes — not redirects, 404s
                // or opaque cross-origin responses.
                if (res && res.ok && res.type === "basic") {
                    cache.put(req, res.clone());
                }
                return res;
            });

            // Keep the worker alive until the background refresh settles,
            // otherwise it can be killed mid-update.
            event.waitUntil(network.catch(function () { }));

            return cached || network;
        });
    });
}

// Only a genuine network failure falls back to the offline page. A 404 or a
// 500 from the server resolves normally and is shown as-is.
function networkThenOfflinePage(req) {
    return fetch(req).catch(function () {
        return caches.match(OFFLINE_URL);
    });
}
