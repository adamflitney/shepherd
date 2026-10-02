const CACHE = "shepherd-shell-v2";
const SHELL = ["/", "/manifest.webmanifest", "/icon-192.png", "/icon-512.png", "/apple-touch-icon.png"];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Network-first for the shell so a rebuilt page is never masked by a stale
// cache (we've been bitten by that already); the cache is only the fallback
// when the phone can't reach the Mac. The live API and SSE stream are never
// cached - stale session state is worse than an error.
self.addEventListener("fetch", event => {
  const { request } = event;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/api/")) return;
  event.respondWith(
    fetch(request)
      .then(res => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(request, copy));
        }
        return res;
      })
      .catch(() => caches.match(request))
  );
});

// Safari (and Chrome) require every push to show a notification
// (`userVisibleOnly`), so there's no "skip it because the app is open" path.
// `tag` collapses repeats for the same session into one entry.
self.addEventListener("push", event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) {}
  event.waitUntil(self.registration.showNotification(data.title || "Shepherd", {
    body: data.body || "",
    tag: data.session_id || "shepherd",
    renotify: true,
    icon: "/icon-192.png",
    data: { session_id: data.session_id || "" }
  }));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const id = (event.notification.data && event.notification.data.session_id) || "";
  event.waitUntil((async () => {
    const windows = await clients.matchAll({ type: "window", includeUncontrolled: true });
    if (windows.length) {
      const client = windows[0];
      await client.focus();
      client.postMessage({ type: "open-session", id });
    } else {
      await clients.openWindow(id ? `/?session=${encodeURIComponent(id)}` : "/");
    }
  })());
});
