const CACHE_NAME = "shoufa-v4";
const APP_SHELL = "/";
const PRECACHE_ASSETS = [
  APP_SHELL,
  "/icons/icon-192x192.png",
  "/icons/icon-512x512.png",
];

// Install: precache the app shell. A failed precache should not block updates.
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.addAll(PRECACHE_ASSETS))
      .catch(() => undefined)
      .then(() => self.skipWaiting())
  );
});

// Activate: delete old app-shell caches.
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((cacheNames) =>
        Promise.all(
          cacheNames
            .filter((name) => name !== CACHE_NAME)
            .map((name) => caches.delete(name))
        )
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== location.origin) return;

  // Never intercept API calls, change notifications, health checks, or the
  // service worker script itself. These must always hit the network.
  if (
    url.pathname === "/sw.js" ||
    url.pathname === "/wait" ||
    url.pathname === "/health" ||
    url.pathname === "/healthz" ||
    url.pathname.startsWith("/api/")
  ) {
    return;
  }

  // Navigations are network-first and are NOT cached. Caching room HTML was
  // causing stale app shells after deployments.
  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(async () => {
        const cachedShell = await caches.match(APP_SHELL);
        return cachedShell || Response.error();
      })
    );
    return;
  }

  // Static assets are cache-first, with a network fallback that handles
  // offline/network errors instead of rejecting the FetchEvent.
  event.respondWith(
    caches.match(request).then((cached) => {
      if (cached) return cached;

      return fetch(request)
        .then((response) => {
          if (response.ok && response.type === "basic") {
            const responseClone = response.clone();
            caches
              .open(CACHE_NAME)
              .then((cache) => cache.put(request, responseClone))
              .catch(() => undefined);
          }
          return response;
        })
        .catch(() => Response.error());
    })
  );
});
