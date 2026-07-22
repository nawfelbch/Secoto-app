/* SECOTO — Service Worker (PWA + Web Push) */
const CACHE = "secoto-shell-v1";

self.addEventListener("install", (event) => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

// Réception d'une notification push envoyée par le serveur (fonction Netlify).
self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (e) {
    payload = { title: "SECOTO", body: event.data ? event.data.text() : "" };
  }

  const title = payload.title || "SECOTO";
  const options = {
    body: payload.body || "",
    icon: "/icon-192.png",
    badge: "/favicon-32.png",
    vibrate: [80, 40, 80],
    tag: payload.tag || "secoto-notif",
    renotify: true,
    data: { url: payload.url || "/", missionId: payload.missionId || null },
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

// Clic sur la notification : focus l'app ou l'ouvre.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const targetUrl = (event.notification.data && event.notification.data.url) || "/";

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ("focus" in client) {
          client.navigate(targetUrl).catch(() => {});
          return client.focus();
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
    })
  );
});
