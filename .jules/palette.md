## 2024-10-26 - Contextual ARIA labels on sidebar actions
**Learning:** Many icon-only action buttons in hierarchical components (like sidebars for Workspaces, Projects, Folders) were missing contextual `aria-label` attributes, which makes it difficult for screen reader users to understand what the action applies to.
**Action:** Always ensure icon-only buttons include an `aria-label` that provides context, especially in lists or hierarchical views where the action applies to a specific item.

## 2024-08-04 - [Sidebar Tooltip A11y & Lockfile Hygiene]
**Learning:** Adding aria-labels to delete/action icons inside dense lists (like the ChatSidebar note item) is critical since the icon visibility may rely solely on hover or focus states, which obscures context for screen reader users navigating linearly. Additionally, when running package tools for verification (like pnpm install) within a monorepo subdirectory, massive unintended side-effects (e.g. creating huge localized lockfiles like `jca_web/pnpm-lock.yaml`) and formatting cascade changes can accidentally sneak into the final commit if not carefully pruned.
**Action:** Always manually `git checkout .` on the parent repository or precisely unstage any untracked or unrelated auto-formatted files (especially `.lock` files or deeply nested lint updates) *before* submitting code review for a micro UX PR.
