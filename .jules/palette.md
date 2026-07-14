## 2026-07-14 - Use ARIA State Attributes Instead of Labels for Dynamic Content
**Learning:** Adding `aria-label` to an element with dynamic visible text (like a folder name) causes a severe accessibility regression because it completely overrides the element's inner text for screen readers, hiding the actual dynamic content.
**Action:** Always prefer context-appropriate state attributes like `aria-expanded` for toggles rather than using `aria-label`, ensuring the element's dynamic visible text remains readable by screen readers while still conveying its interactive state.
