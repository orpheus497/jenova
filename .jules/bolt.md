## 2024-05-18 - Avoid O(N) re-computations inside filter maps
**Learning:** In string filtering functions inside computed variables (e.g. Svelte $derived blocks), it's common to see `searchQuery.toLowerCase()` called inside an `.includes()` or `.startsWith()` inside a `.filter(x => ...)` map. This causes the query transformation to execute O(N) times redundantly.
**Action:** Extract the `.toLowerCase()` to `const query = searchQuery.toLowerCase();` *outside* the filter loop whenever iterating arrays of entities.

## 2024-05-18 - Promise loop batching for Sync pull
**Learning:** Standard `for...of` loops with inner `await` completely serialize data fetching in the sync loop `SyncService.pull()`.
**Action:** Use an `active` promise queue array alongside `Promise.race()` to create a bounded concurrency loop or map to a fixed array of Promises with `Promise.all()` to vastly accelerate synchronous file fetches from simulated or real network backends.
