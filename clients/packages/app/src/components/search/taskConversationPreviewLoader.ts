import { isPollingTerminalTaskStatus } from "@comma/ui";
import type { CommaApiClient, CommaConversation } from "../../api";
import {
  normalizeServerMessages,
  type ChatMessage,
} from "../chat/model/conversationChannel";
import { normalizeUnixTimestampMs } from "./normalizeUnixTimestampMs";

const maxCacheEntries = 2;
const activeCacheTtlMs = 20_000;
const terminalCacheTtlMs = 5 * 60_000;

export type TaskConversationPreviewTarget = {
  conversationId: string;
  groupId: string;
  status?: string;
  title: string;
  updatedAt?: number;
  workspaceId: string;
};

export type TaskConversationPreviewData = {
  messages: ChatMessage[];
};

type CacheEntry = {
  data: TaskConversationPreviewData;
  expiresAt: number;
  version: string;
};

type PreviewCache = Map<string, CacheEntry>;

const caches = new WeakMap<CommaApiClient, PreviewCache>();

function taskKey(task: TaskConversationPreviewTarget, messageLimit?: number) {
  return `${task.workspaceId}\u0000${task.groupId}\u0000${task.conversationId}\u0000${messageLimit ?? "all"}`;
}

function taskVersion(task: TaskConversationPreviewTarget) {
  const normalizedUpdatedAt = normalizeUnixTimestampMs(task.updatedAt) ?? "unknown";
  return `${normalizedUpdatedAt}\u0000${task.status?.trim().toLowerCase() ?? ""}`;
}

function cacheFor(apiClient: CommaApiClient) {
  let cache = caches.get(apiClient);
  if (!cache) {
    cache = new Map();
    caches.set(apiClient, cache);
  }
  return cache;
}

function touch(cache: PreviewCache, key: string, entry: CacheEntry) {
  cache.delete(key);
  cache.set(key, entry);
}

function trimCache(cache: PreviewCache) {
  while (cache.size > maxCacheEntries) {
    const oldestKey = cache.keys().next().value as string | undefined;
    if (!oldestKey) return;
    cache.delete(oldestKey);
  }
}

function abortError() {
  return new DOMException("The preview request was aborted.", "AbortError");
}

/**
 * Loads one exact conversation snapshot. The cache is scoped to the API client
 * (and therefore its signed-in session) and retains only the canonical display
 * projection rather than a live channel.
 */
export async function loadTaskConversationPreview(
  apiClient: CommaApiClient,
  task: TaskConversationPreviewTarget,
  signal?: AbortSignal,
  messageLimit?: number
): Promise<TaskConversationPreviewData> {
  if (signal?.aborted) {
    throw abortError();
  }

  const cache = cacheFor(apiClient);
  const key = taskKey(task, messageLimit);
  const version = taskVersion(task);
  const now = Date.now();
  const cached = cache.get(key);

  if (cached?.version === version && cached.expiresAt > now) {
    touch(cache, key, cached);
    return cached.data;
  }
  cache.delete(key);

  const conversation =
    messageLimit === undefined
      ? (
          await apiClient.pollConversation(
            task.groupId,
            task.conversationId,
            signal ? { signal } : {}
          )
        ).conversation
      : await apiClient.getConversation(task.groupId, task.conversationId, {
          messageLimit,
          ...(signal ? { signal } : {}),
        });
  if (signal?.aborted) {
    throw abortError();
  }
  if (!conversation) {
    throw new Error("Conversation preview returned no conversation.");
  }

  const data = projectTaskConversation(conversation);
  const ttl =
    task.status && isPollingTerminalTaskStatus(task.status)
      ? terminalCacheTtlMs
      : activeCacheTtlMs;
  touch(cache, key, {
    data,
    expiresAt: Date.now() + ttl,
    version,
  });
  trimCache(cache);
  return data;
}

export function projectTaskConversation(
  conversation: CommaConversation
): TaskConversationPreviewData {
  return {
    messages: normalizeServerMessages(
      conversation.messages ?? [],
      [],
      conversation.kind
    ),
  };
}
