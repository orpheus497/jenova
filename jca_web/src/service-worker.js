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

  const url = new URL(event.request.url);
  const isApiRequest =
    url.pathname.startsWith("/v1/") || url.pathname.startsWith("/api/") || url.pathname === "/props";

  async function respond() {
    // API requests: network-only, never cache
    if (isApiRequest) {
      return fetch(event.request);
    }

    // Non-API requests: cache-first
    const cache = await caches.open(CACHE);

    const cachedResponse = await cache.match(event.request);
    if (cachedResponse) return cachedResponse;

    try {
      const response = await fetch(event.request);

      if (response.status === 200) {
        cache.put(event.request, response.clone());
      }

      return response;
    } catch {
      return cachedResponse || new Response("Offline", { status: 503 });
    }
  }

  event.respondWith(respond());
});
