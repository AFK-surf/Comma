import type { CommaApiClient, CommaConversationPreview } from "../../../../api";

const ACTIVE_PREVIEW_TTL_MS = 20_000;
const TERMINAL_PREVIEW_TTL_MS = 5 * 60_000;
const MAX_PREVIEW_ENTRIES = 128;

type PreviewCacheEntry = {
  expiresAt: number;
  promise: Promise<CommaConversationPreview> | undefined;
  value?: CommaConversationPreview;
};

let sessionCaches = new WeakMap<CommaApiClient, Map<string, PreviewCacheEntry>>();

/** Session-scoped, bounded and concurrent-deduplicated exact Task previews. */
export function loadTaskPreview(
  api: CommaApiClient,
  groupId: string,
  conversationId: string
) {
  const cache = previewCache(api);
  const key = `${groupId}\u0000${conversationId}`;
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
  const promise = api.getConversationPreview(groupId, conversationId).then(
    (preview) => {
      if (cache.get(key) === entry) {
        entry.promise = undefined;
        entry.value = preview;
        entry.expiresAt = Date.now() + previewTtl(preview.status);
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

function previewTtl(status: string) {
  return ["completed", "failed", "cancelled", "canceled"].includes(status)
    ? TERMINAL_PREVIEW_TTL_MS
    : ACTIVE_PREVIEW_TTL_MS;
}

export function resetTaskPreviewCacheForTests() {
  sessionCaches = new WeakMap();
}

export function taskPreviewCacheSizeForTests(api: CommaApiClient) {
  return sessionCaches.get(api)?.size ?? 0;
}
