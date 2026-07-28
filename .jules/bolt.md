## 2026-07-28 - O(N^2) Performance Bottleneck in ChatMessage Rendering
**Learning:** The branching utilities (e.g., `getMessageSiblings`, `findLeafNode`) in `branching.ts` were rebuilding a node map on every invocation, causing O(N^2) complexity when rendering large chat histories in `ChatMessages.svelte`.
**Action:** Extract the map building logic into `buildNodeMap` and pass the precomputed map down to the utilities to reduce rendering time complexity to O(N).
