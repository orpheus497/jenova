# 2026-07-28 - O(N^2) Performance Bottleneck in ChatMessage Rendering

**Learning:** The branching utilities (e.g., `getMessageSiblings`, `findLeafNode`) in `branching.ts` were rebuilding a node map on every invocation, causing O(N^2) complexity when rendering large chat histories in `ChatMessages.svelte`.
**Action:** Extract the map building logic into `buildNodeMap` and pass the precomputed map down to the utilities to reduce rendering time complexity to O(N).

## 2023-10-27 - O(N²) array filter in cascading deletion
**Learning:** Checking for elements in an array within a filter (`array.filter(item => largeArray.includes(item.id))`) creates an O(N²) loop that slows down cascading deletions.
**Action:** Always convert the large look-up array into a `Set` first (`new Set(largeArray)`) and then use `.has()`, changing the operation to O(N).
