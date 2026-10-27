import { uiClock } from "@comma/ui/clock";
import { formatDate, type CommaLocale } from "@comma/i18n";
import { asksRouter, type ChatMessage } from "@comma/core/chat";
import { startOfLocalDay } from "./calendarDay";

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
  locale: CommaLocale,
  now = uiClock.now()
) {
  const normalized = normalizeMessageTimestamp(createdAt);
  if (normalized === undefined) {
    return undefined;
  }

  const date = new Date(normalized);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }

  const isToday = startOfLocalDay(normalized) === startOfLocalDay(now);

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

/**
 * Messages that open a new timestamp interval in the transcript. A user
 * message opens one a minute after the last. An agent message opens one when
 * the agent writes on its own, such as a reminder, and not when it answers a
 * user's request (see `agentMessageOpensTimestamp`). Both kinds share one
 * interval, so a user who answers within the minute adds no second timestamp.
 */
export function conversationTimestampMessageIds(messages: readonly ChatMessage[]) {
  const timestampMessageIds = new Set<string>();
  let intervalStartedAt: number | undefined;
  let previous: ChatMessage | undefined;

  for (const message of messages) {
    const createdAt = normalizeMessageTimestamp(message.createdAt);
    const opens =
      createdAt !== undefined &&
      (message.role === "user"
        ? intervalStartedAt === undefined ||
          createdAt - intervalStartedAt >= CONVERSATION_TIMESTAMP_INTERVAL_MS
        : agentMessageOpensTimestamp(createdAt, previous));
    if (opens) {
      timestampMessageIds.add(message.messageId);
      intervalStartedAt = createdAt;
    }
    previous = message;
  }

  return timestampMessageIds;
}

/**
 * An agent's work sends several messages minutes apart, so an agent message
 * opens a timestamp only after the transcript has been quiet this long.
 */
const AGENT_TIMESTAMP_QUIET_MS = 5 * 60_000;

/**
 * Whether an agent message created at `createdAt` (ms) opens a timestamp after
 * the transcript's `previous` message. One that follows a user's request, a
 * Quick Chat included, is its reply and shares its timestamp.
 */
export function agentMessageOpensTimestamp(
  createdAt: number,
  previous: ChatMessage | undefined
) {
  if (!previous) return true;
  if (asksRouter(previous)) return false;
  const previousAt = normalizeMessageTimestamp(previous.createdAt);
  return previousAt !== undefined && createdAt - previousAt >= AGENT_TIMESTAMP_QUIET_MS;
}
