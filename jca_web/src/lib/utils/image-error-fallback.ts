/**
 * Escapes HTML characters to prevent XSS.
 */
function escapeHtml(unsafe: string): string {
  return unsafe
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

/**
 * Validates the URL protocol to prevent javascript: and vbscript: execution.
 */
function isSafeUrl(url: string): boolean {
  try {
    const parsed = new URL(url, "http://localhost");
    return ["http:", "https:"].includes(parsed.protocol);
  } catch {
    return false;
  }
}

/**
 * Simplified HTML fallback for external images that fail to load.
 * Displays a centered message with a link to open the image in a new tab.
 */
export function getImageErrorFallbackHtml(src: string): string {
  const safeSrc = isSafeUrl(src) ? escapeHtml(src) : "#";
  return `<div class="image-error-content">
		<span>Image cannot be displayed</span>
		<a href="${safeSrc}" target="_blank" rel="noopener noreferrer">(open link)</a>
	</div>`;
}
