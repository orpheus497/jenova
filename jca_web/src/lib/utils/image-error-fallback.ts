/**
 * Simplified HTML fallback for external images that fail to load.
 * Displays a centered message with a link to open the image in a new tab.
 */
export function getImageErrorFallbackHtml(src: string): string {
  const trimmedSrc = src.trim();
  const hasUnsafeProtocol = /^(javascript|vbscript):/i.test(trimmedSrc);
  const safeSrc = hasUnsafeProtocol ? "#" : trimmedSrc;
  const escapedSrc = safeSrc
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");

  return `<div class="image-error-content">
		<span>Image cannot be displayed</span>
		<a href="${escapedSrc}" target="_blank" rel="noopener noreferrer">(open link)</a>
	</div>`;
}
