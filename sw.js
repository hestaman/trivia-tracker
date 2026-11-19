// Service worker: lets the app open offline and load fast.
// Pages (index.html) are fetched from the network first so updates show up right away;
// the saved copy is only used when there is no connection.
// Other files (icons, manifest) come from the saved copy first.
// Bump CACHE when you change icons or other files so phones pick up the new versions.
const CACHE = 'trivia-tracker-v8';
const ASSETS = ['./', './index.html', './manifest.webmanifest?v=2', './icon.svg?v=2', './apple-touch-icon.png?v=2', './icon-192.png?v=2', './icon-512.png?v=2', './icon-maskable-512.png?v=2'];

self.addEventListener('install', e => e.waitUntil(
  caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting())
));

self.addEventListener('activate', e => e.waitUntil(
  caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim())
));

function saveCopy(request, response) {
  if (response.ok && new URL(request.url).origin === location.origin) {
    const copy = response.clone();
    caches.open(CACHE).then(c => c.put(request, copy));
  }
  return response;
}

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  if (e.request.mode === 'navigate') {
    e.respondWith(
      fetch(e.request)
        .then(res => saveCopy(e.request, res))
        .catch(() => caches.match(e.request).then(c => c || caches.match('./index.html')))
    );
    return;
  }
  e.respondWith(
    caches.match(e.request).then(cached => cached || fetch(e.request).then(res => saveCopy(e.request, res)))
  );
});
