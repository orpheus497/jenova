import { base } from "$app/paths";
import { settingsStore } from "$lib/stores/settings.svelte";
import { getJsonHeaders, getAuthHeaders } from "./api-headers";
import { UrlProtocol } from "$lib/enums";

/**
 * API Fetch Utilities
 *
 * Provides common fetch patterns used across services:
 * - Automatic JSON headers
 * - Error handling with proper error messages
 * - Base path resolution
 */

export interface ApiFetchOptions extends Omit<RequestInit, "headers"> {
  authOnly?: boolean;
  headers?: Record<string, string>;
}

/**
 * Perform a fetch request with JSON headers and error handling.
 * Automatically prefixes paths with the application base path.
 *
 * @param path - API path (relative to base) or full URL
 * @param options - Fetch options including custom headers and auth-only mode
 * @returns Parsed JSON response
 * @throws Error with a descriptive message if the request fails
 *
 * @example
 * ```typescript
 * const models = await apiFetch<ApiModel[]>('/v1/models');
 * ```
 */
function getEffectiveBase(defaultBase: string): string {
  const serverUrl = settingsStore.config.serverUrl?.toString().trim();
  if (serverUrl) {
    return serverUrl.endsWith("/") ? serverUrl.slice(0, -1) : serverUrl;
  }
  return defaultBase;
}

export async function apiFetch<T>(
  path: string,
  options: ApiFetchOptions = {},
): Promise<T> {
  const { authOnly = false, headers: customHeaders, ...fetchOptions } = options;

  const baseHeaders = authOnly ? getAuthHeaders() : getJsonHeaders();
  const headers = { ...baseHeaders, ...customHeaders };

  const effectiveBase = getEffectiveBase(base);

  const url =
    path.startsWith(UrlProtocol.HTTP) || path.startsWith(UrlProtocol.HTTPS)
      ? path
      : `${effectiveBase}${path.startsWith("/") ? "" : "/"}${path}`;

  const response = await fetch(url, {
    ...fetchOptions,
    headers,
  });

  if (!response.ok) {
    const errorMessage = await parseErrorMessage(response);
    throw new Error(errorMessage);
  }

  return response.json() as Promise<T>;
}

/**
 * Fetch with URL constructed from base URL and query parameters.
 *
 * @param basePath - Base API path
 * @param params - Query parameters to append
 * @param options - Fetch options
 * @returns Parsed JSON response
 *
 * @example
 * ```typescript
 * const props = await apiFetchWithParams<ApiProps>('./props', {
 *   model: 'gpt-4',
 *   autoload: 'false'
 * });
 * ```
 */
export async function apiFetchWithParams<T>(
  basePath: string,
  params: Record<string, string>,
  options: ApiFetchOptions = {},
): Promise<T> {
  const effectiveBase = getEffectiveBase(
    typeof window !== "undefined" ? window.location.origin + base : base,
  );

  let urlStr = basePath;
  if (
    !basePath.startsWith(UrlProtocol.HTTP) &&
    !basePath.startsWith(UrlProtocol.HTTPS)
  ) {
    urlStr = `${effectiveBase}${basePath.startsWith("/") ? "" : "/"}${basePath}`;
  }

  const url = new URL(urlStr, window.location.href);

  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null) {
      url.searchParams.set(key, value);
    }
  }

  const { authOnly = false, headers: customHeaders, ...fetchOptions } = options;

  const baseHeaders = authOnly ? getAuthHeaders() : getJsonHeaders();
  const headers = { ...baseHeaders, ...customHeaders };

  const response = await fetch(url.toString(), {
    ...fetchOptions,
    headers,
  });

  if (!response.ok) {
    const errorMessage = await parseErrorMessage(response);
    throw new Error(errorMessage);
  }

  return response.json() as Promise<T>;
}

/**
 * Perform a POST request with JSON body.
 *
 * @param path - API path
 * @param body - Object to be stringified as JSON
 * @param options - Additional fetch options
 * @returns Parsed JSON response
 */
export async function apiPost<T, B = unknown>(
  path: string,
  body: B,
  options: ApiFetchOptions = {},
): Promise<T> {
  return apiFetch<T>(path, {
    method: "POST",
    body: JSON.stringify(body),
    ...options,
  });
}

/**
 * Parse error message from a failed response.
 * Tries to extract error message from JSON body, falls back to status text.
 */
async function parseErrorMessage(response: Response): Promise<string> {
  try {
    const errorData = await response.json();
    if (errorData?.error?.message) {
      return errorData.error.message;
    }
    if (errorData?.error && typeof errorData.error === "string") {
      return errorData.error;
    }
    if (errorData?.message) {
      return errorData.message;
    }
  } catch {
    // JSON parsing failed, use status text
  }

  return `Request failed: ${response.status} ${response.statusText}`;
}
