/// <reference types="@sveltejs/kit" />
import { build, files, version } from "$service-worker";

const CACHE = `cache-${version}`;

const ASSETS = [
  ...build,
  ...files,
  "./",
  "./index.html",
  "./bundle.js",
  "./bundle.css",
  "./manifest.json",
  "./favicon.jpg",
  "./logo.jpg",
];

self.addEventListener("install", (event) => {
  async function addFilesToCache() {
    const cache = await caches.open(CACHE);
    await cache.addAll(ASSETS);
  }

  event.waitUntil(addFilesToCache());
});

self.addEventListener("activate", (event) => {
  async function deleteOldCaches() {
    for (const key of await caches.keys()) {
      if (key !== CACHE) await caches.delete(key);
    }
  }

  event.waitUntil(deleteOldCaches());
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;

  async function respond() {
    const url = new URL(event.request.url);
    const cache = await caches.open(CACHE);

    // Try the cache first
    const cachedResponse = await cache.match(event.request);
    if (cachedResponse) return cachedResponse;

    // Fallback to network
    try {
      const response = await fetch(event.request);

      if (response.status === 200) {
        cache.put(event.request, response.clone());
      }

      return response;
    } catch {
      // If network fails and we have it in cache (should be handled by match above)
      return cachedResponse || new Response("Offline", { status: 503 });
    }
  }

  event.respondWith(respond());
});
