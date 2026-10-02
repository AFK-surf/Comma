import {
  CommaApiError,
  type CommaApiClient,
  type CommaRecommendationLinkPreview,
} from "../../api";

const PREVIEW_TTL_MS = 5 * 60_000;
const MAX_PREVIEW_ENTRIES = 64;
// Mirrors CommaWeb.RecommendationLinkPreview: GitHub pull requests, Linear
// issues, Notion pages, Google Calendar events (public ones render; the
// server keeps the rest link-only), Slack messages and Google Drive files.
// Gmail never matches — mail is private.
const RICH_LINK_SHAPES = [
  /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+(?:[/?#].*)?$/,
  /^https:\/\/linear\.app\/[\w-]+\/issue\/[A-Za-z][A-Za-z0-9]*-\d+(?:[/?#].*)?$/,
  /^https:\/\/(?:www\.)?notion\.so\/(?:[^/?#]+\/)?(?:[^/?#]*?-)?[0-9a-fA-F]{32}(?:[/?#].*)?$/,
  /^https:\/\/(?:www\.google\.com|calendar\.google\.com)\/calendar\/(?:u\/\d+\/)?(?:r\/)?(?:event\?(?:[^#]*&)?eid=[\w=-]+|eventedit\/[\w=-]+)/,
  /^https:\/\/[\w-]+\.slack\.com\/archives\/([A-Z0-9]+)\/p(\d{10,})(?:[/?#].*)?$/,
  // Drive ids demand >= 10 chars (mirrors the server's hardening) so pseudo-id
  // path segments like the published-form `/d/e/` never read as a file id.
  /^https:\/\/docs\.google\.com\/(?:document|spreadsheets|presentation|forms)\/d\/([\w-]{10,})(?:[/?#].*)?$/,
  /^https:\/\/drive\.google\.com\/file\/d\/([\w-]{10,})(?:[/?#].*)?$/,
  /^https:\/\/drive\.google\.com\/open\?(?:[^#]*&)?id=([\w-]{10,})/,
];

/**
 * Whether hovering this link can show a rich preview, so unsupported links
 * never pay a request for a 404.
 */
export function hasRecommendationLinkPreview(href: string) {
  const trimmed = href.trim();
  return RICH_LINK_SHAPES.some((shape) => shape.test(trimmed));
}

type PreviewCacheEntry = {
  expiresAt: number;
  promise: Promise<CommaRecommendationLinkPreview> | undefined;
  value?: CommaRecommendationLinkPreview;
  // The server answered 404: no connected source can read this link (no
  // access, private event, deleted message). Remembered like a value so every
  // hover doesn't re-ask and flash the skeleton before the generic card.
  missing?: CommaApiError;
};

type PreviewLink = { href: string; sourceId?: string | undefined };

let sessionCaches = new WeakMap<CommaApiClient, Map<string, PreviewCacheEntry>>();

/**
 * The settled, unexpired answer for this link without a request: the preview,
 * `"missing"` when the server has no preview for it, or `undefined` when it
 * still needs a read. Lets a hover card skip its loading state on a hit.
 */
export function peekRecommendationLinkPreview(
  api: CommaApiClient,
  workspaceId: string,
  link: PreviewLink
): CommaRecommendationLinkPreview | "missing" | undefined {
  const current = previewCache(api).get(cacheKey(workspaceId, link));
  if (!current || current.expiresAt <= Date.now()) return undefined;
  return current.value ?? (current.missing ? "missing" : undefined);
}

/** Session-scoped, bounded and concurrent-deduplicated inline-link previews. */
export function loadRecommendationLinkPreview(
  api: CommaApiClient,
  workspaceId: string,
  link: PreviewLink
) {
  const cache = previewCache(api);
  const key = cacheKey(workspaceId, link);
  const current = cache.get(key);
  const now = Date.now();

  if (current && current.expiresAt > now) {
    if (current.value) {
      touch(cache, key, current);
      return Promise.resolve(current.value);
    }
    if (current.missing) {
      touch(cache, key, current);
      return Promise.reject(current.missing);
    }
  }
  if (current?.promise) {
    touch(cache, key, current);
    return current.promise;
  }

  const entry: PreviewCacheEntry = { expiresAt: 0, promise: undefined };
  const request = link.sourceId
    ? { href: link.href, sourceId: link.sourceId }
    : { href: link.href };
  const promise = api.getRecommendationLinkPreview(workspaceId, request).then(
    (preview) => {
      if (cache.get(key) === entry) {
        entry.promise = undefined;
        entry.value = preview;
        entry.expiresAt = Date.now() + PREVIEW_TTL_MS;
        touch(cache, key, entry);
        evictOverflow(cache);
      }
      return preview;
    },
    (error: unknown) => {
      if (cache.get(key) === entry) {
        // Only a definite 404 is remembered; transient failures retry on the
        // next hover.
        if (error instanceof CommaApiError && error.status === 404) {
          entry.promise = undefined;
          entry.missing = error;
          entry.expiresAt = Date.now() + PREVIEW_TTL_MS;
        } else {
          cache.delete(key);
        }
      }
      throw error;
    }
  );
  entry.promise = promise;
  touch(cache, key, entry);
  evictOverflow(cache);
  return promise;
}

function cacheKey(workspaceId: string, link: PreviewLink) {
  return `${workspaceId} ${link.sourceId ?? ""} ${link.href}`;
}

function previewCache(api: CommaApiClient) {
  let cache = sessionCaches.get(api);
  if (!cache) {
    cache = new Map();
    sessionCaches.set(api, cache);
  }
  return cache;
}

function touch(
  cache: Map<string, PreviewCacheEntry>,
  key: string,
  entry: PreviewCacheEntry
) {
  cache.delete(key);
  cache.set(key, entry);
}

function evictOverflow(cache: Map<string, PreviewCacheEntry>) {
  while (cache.size > MAX_PREVIEW_ENTRIES) {
    const oldestKey = cache.keys().next().value;
    if (typeof oldestKey !== "string") return;
    cache.delete(oldestKey);
  }
}

export function resetRecommendationLinkPreviewCacheForTests() {
  sessionCaches = new WeakMap();
}
