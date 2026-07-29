self.addEventListener("install", event => {
    console.log("SmartSchoolWala service worker installed");
    self.skipWaiting();
});

self.addEventListener("activate", event => {
    console.log("SmartSchoolWala service worker activated");
    event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", event => {
    if (event.request.method !== "GET") {
        return;
    }

    event.respondWith(fetch(event.request));
});
