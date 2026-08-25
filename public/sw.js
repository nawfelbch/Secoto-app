/* SECOTO — Service Worker (PWA + Web Push) */
const CACHE = "secoto-shell-v4";
const OFFLINE_SHELL = [
  "/",
  "/manifest.json",
  "/icon-192.png",
  "/icon-512.png",
  "/politique-confidentialite.html",
  "/suppression-compte.html",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(OFFLINE_SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key.startsWith("secoto-shell-") && key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin || url.pathname.startsWith("/.netlify/functions/")) return;

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request)
        .then((response) => {
          const copy = response.clone();
          const cacheKey = url.pathname === "/" ? "/" : request;
          caches.open(CACHE)
            .then((cache) => cache.put(cacheKey, copy))
            .catch(() => {});
          return response;
        })
        .catch(() => caches.match(request).then((cached) => cached || caches.match("/"))),
    );
    return;
  }

  event.respondWith(
    caches.match(request).then((cached) => {
      const refresh = fetch(request)
        .then((response) => {
          // Le clone DOIT être pris tout de suite : `caches.open` est
          // asynchrone, et si l'on attend sa résolution le navigateur a déjà
          // commencé à lire le corps de la réponse renvoyée à la page.
          // C'est ce qui provoquait « Failed to execute 'clone' on 'Response':
          // Response body is already used » à chaque chargement.
          if (response.ok) {
            const copy = response.clone();
            caches.open(CACHE)
              .then((cache) => cache.put(request, copy))
              .catch(() => {});
          }
          return response;
        })
        .catch(() => cached);
      return cached || refresh;
    }),
  );
});

// Réception d'une notification push envoyée par le serveur (fonction Netlify).
self.addEventListener("push", (event) => {
  let payload;
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
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
          // On force la navigation vers l'ecran cible AVANT de remettre
          // l'application au premier plan, sinon l'onglet deja ouvert reste
          // sur la page precedente et la notification ne menait nulle part.
          return client.focus().then((c) => (c || client).navigate(targetUrl).catch(() => {}));
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
    })
  );
});
