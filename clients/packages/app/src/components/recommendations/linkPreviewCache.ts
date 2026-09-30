import type { CommaApiClient, CommaRecommendationLinkPreview } from "../../api";

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
};

let sessionCaches = new WeakMap<CommaApiClient, Map<string, PreviewCacheEntry>>();

/** Session-scoped, bounded and concurrent-deduplicated inline-link previews. */
export function loadRecommendationLinkPreview(
  api: CommaApiClient,
  workspaceId: string,
  link: { href: string; sourceId?: string | undefined }
) {
  const cache = previewCache(api);
  const key = `${workspaceId} ${link.sourceId ?? ""} ${link.href}`;
  const current = cache.get(key);
  const now = Date.now();

  if (current?.value && current.expiresAt > now) {
    touch(cache, key, current);
    return Promise.resolve(current.value);
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
      if (cache.get(key) === entry) cache.delete(key);
      throw error;
    }
  );
  entry.promise = promise;
  touch(cache, key, entry);
  evictOverflow(cache);
  return promise;
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
