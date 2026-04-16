/**
 * coi-serviceworker — Cross-Origin Isolation via Service Worker
 *
 * Intercepts all fetch responses and adds the COOP/COEP headers required
 * for SharedArrayBuffer (needed by the dart2wasm WASM Worker).
 *
 * Adapted from https://github.com/gzuidhof/coi-serviceworker (MIT)
 */

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('fetch', function (e) {
  // Pass-through for opaque requests that would fail with CORS
  if (e.request.cache === 'only-if-cached' && e.request.mode !== 'same-origin') return;

  e.respondWith(
    fetch(e.request)
      .then(function (r) {
        if (r.status === 0) return r;
        const h = new Headers(r.headers);
        h.set('Cross-Origin-Opener-Policy', 'same-origin');
        h.set('Cross-Origin-Embedder-Policy', 'require-corp');
        h.set('Cross-Origin-Resource-Policy', 'cross-origin');
        return new Response(r.body, {
          status: r.status,
          statusText: r.statusText,
          headers: h,
        });
      })
      .catch(() => fetch(e.request)),
  );
});
