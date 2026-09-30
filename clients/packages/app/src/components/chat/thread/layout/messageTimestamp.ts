import { formatDate, type CommaLocale } from "@comma/i18n";
import type { ChatMessage } from "../../model/conversationChannel";

const CONVERSATION_TIMESTAMP_INTERVAL_MS = 60_000;

export function normalizeMessageTimestamp(createdAt: number | undefined) {
  if (createdAt === undefined || !Number.isFinite(createdAt)) {
    return undefined;
  }

  const normalized = createdAt < 10_000_000_000 ? createdAt * 1000 : createdAt;
  return Number.isFinite(normalized) ? normalized : undefined;
}

export function formatConversationTimestamp(
  createdAt: number | undefined,
  locale: CommaLocale
) {
  const normalized = normalizeMessageTimestamp(createdAt);
  if (normalized === undefined) {
    return undefined;
  }

  const date = new Date(normalized);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }

  const now = new Date();
  const isToday =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();

  return {
    isToday,
    iso: date.toISOString(),
    label: formatDate(
      date,
      locale,
      isToday
        ? {
            hour: "numeric",
            minute: "2-digit",
          }
        : {
            day: "numeric",
            hour: "numeric",
            minute: "2-digit",
            month: "short",
          }
    ),
  };
}

/** User messages that open a new timestamp interval in the transcript. */
export function conversationTimestampMessageIds(messages: ChatMessage[]) {
  const timestampMessageIds = new Set<string>();
  let intervalStartedAt: number | undefined;

  for (const message of messages) {
    if (message.role !== "user") {
      continue;
    }

    const createdAt = normalizeMessageTimestamp(message.createdAt);
    if (createdAt === undefined) {
      continue;
    }

    if (
      intervalStartedAt === undefined ||
      createdAt - intervalStartedAt >= CONVERSATION_TIMESTAMP_INTERVAL_MS
    ) {
      timestampMessageIds.add(message.messageId);
      intervalStartedAt = createdAt;
    }
  }

  return timestampMessageIds;
}
