import { announcesTasks, type ChatMessage } from "@comma/core/chat";
import { createContext, useLayoutEffect, useState } from "react";
import { MAX_FOCUS_TASK_FEEDS } from "../thread/activity/activityFocus";

/**
 * The messages that created one Task, by message id. A message that names
 * exactly one Task for the first time in this chat, inline, created it; the
 * Task dock uses the same first-mention rule for "created in this chat"
 * (useChatCreatedTasks). A Task reference counts as a naming too. Tasks the
 * chat named before do not count, so a reply that creates one Task beside an
 * earlier one still shows its card. A message that names several new Tasks,
 * whether it created them together or lists them, keeps its inline chips
 * only; a Task first named only as a reference has no inline Task to show as
 * a card; and a later mention of a Task creates nothing. An unavailable chip
 * names no Task the chat can tell is new, so it counts as an earlier one.
 * Only messages that announce Tasks count (`announcesTasks`): an agent's, and
 * a person's Quick Chat, which started its Task. A person's `comma:task`
 * mention is not a creation.
 */
export function taskAnnouncements(
  messages: readonly ChatMessage[]
): Map<string, string> {
  const announced = new Map<string, string>();
  const seen = new Set<string>();
  for (const message of messages) {
    if (!announcesTasks(message)) continue;
    const inline = new Set<string>();
    for (const part of message.parts ?? []) {
      if (part.kind !== "inline-task") continue;
      const id = part.task.conversationId;
      if (id && !part.task.unavailable) inline.add(id);
    }
    const named = new Set(inline);
    for (const ref of message.refs) {
      if (ref.kind === "agent_task") named.add(ref.conversationId);
    }
    const fresh = [...named].filter((id) => !seen.has(id));
    const [only] = fresh;
    if (message.messageId && only && fresh.length === 1 && inline.has(only))
      announced.set(message.messageId, only);
    for (const id of named) seen.add(id);
  }
  return announced;
}

/**
 * The chat's Task cards, shared by its rows. Rows read their own message's
 * Task and whether its card follows the Worker; each answer is a plain value,
 * so one new message re-renders only the rows it affects.
 *
 * A card follows its Worker's steps only for the MAX_FOCUS_TASK_FEEDS most
 * recently announced running Tasks, as the chat's activity bubble does. Each
 * followed card costs one Participant feed and one Session history stream;
 * every other card shows the Task's status words.
 */
export class ChatTaskCards {
  private announced = new Map<string, string>();
  /** Each announced Task's message, by transcript order. */
  private order = new Map<string, number>();
  /** How many cards show each Task running. */
  private running = new Map<string, number>();
  private followed: ReadonlySet<string> = new Set();
  private enabled = false;
  private listeners = new Set<() => void>();

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  taskOf(messageId: string | undefined): string | undefined {
    return messageId ? this.announced.get(messageId) : undefined;
  }

  follows(conversationId: string): boolean {
    return this.followed.has(conversationId);
  }

  update(messages: readonly ChatMessage[], enabled: boolean) {
    const next = taskAnnouncements(messages);
    const changed =
      next.size !== this.announced.size ||
      [...next].some(([messageId, id]) => this.announced.get(messageId) !== id);
    this.enabled = enabled;
    if (changed) {
      this.announced = next;
      this.order = new Map([...next.values()].map((id, index) => [id, index] as const));
    }
    if (this.refollow() || changed) this.notify();
  }

  /**
   * Counts a card that shows its Task running, until the returned release. A
   * Task can have two cards (a reply thread draws its message again), so it
   * stays running until no card holds it.
   */
  holdRunning(conversationId: string): () => void {
    const holds = (this.running.get(conversationId) ?? 0) + 1;
    this.running.set(conversationId, holds);
    if (holds === 1 && this.refollow()) this.notify();
    return () => {
      const left = this.running.get(conversationId)! - 1;
      if (left > 0) {
        this.running.set(conversationId, left);
        return;
      }
      this.running.delete(conversationId);
      if (this.refollow()) this.notify();
    };
  }

  private refollow(): boolean {
    const next = this.enabled
      ? new Set(
          [...this.running.keys()]
            .filter((id) => this.order.has(id))
            .toSorted((left, right) => this.order.get(right)! - this.order.get(left)!)
            .slice(0, MAX_FOCUS_TASK_FEEDS)
        )
      : new Set<string>();
    if (
      next.size === this.followed.size &&
      [...next].every((id) => this.followed.has(id))
    )
      return false;
    this.followed = next;
    return true;
  }

  private notify() {
    for (const listener of this.listeners) listener();
  }
}

export const ChatTaskCardsContext = createContext<ChatTaskCards | undefined>(undefined);

/**
 * One chat surface's Task cards. `follow` is whether the surface may read
 * Workers' steps now: a retained surface that is not shown follows none.
 */
export function useChatTaskCards(messages: readonly ChatMessage[], follow: boolean) {
  const [cards] = useState(() => new ChatTaskCards());
  useLayoutEffect(() => cards.update(messages, follow), [cards, messages, follow]);
  return cards;
}
