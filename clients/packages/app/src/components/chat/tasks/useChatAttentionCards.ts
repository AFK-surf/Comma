import type { ChatQuestionPart } from "@comma/chat-contract";
import type { AgentRequest } from "@comma/core-client";
import type { CommaTaskLabelCatalog } from "@comma/core/api-schemas";
import type { ChatMessage } from "@comma/core/chat";
import { asksRouter, conversationMessageTurnKey } from "@comma/core/chat";
import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { useEffect, useMemo, useRef, useState } from "react";
import { taskLabelProposalLabels } from "../../tasks/taskLabelProposal";
import { agentRequestTitle } from "../requests/AgentRequestCard";
import { groupAgentRequestsByAnchor } from "../requests/agentRequestAnchor";
import { conversationLabelProposals } from "./labels/ChatLabelProposals";
import { groupLabelProposalsByAnchor } from "./labels/labelProposalAnchor";

export type ChatAttentionCardKind =
  | "question"
  | "secret"
  | "login"
  | "oauth"
  | "location"
  | "phone"
  | "plugin"
  | "labels";

export type ChatAttentionCard = {
  /** Short verb on the focus strip CTA (e.g. "Answer", "Fill in", "Review"). */
  actionLabel: string;
  /** Unix ms when the card expires, or null if it has no deadline. */
  expiresAt: number | null;
  id: string;
  kind: ChatAttentionCardKind;
  /** Short badge label naming the card kind (e.g. "Question", "Secret"). */
  kindLabel: string;
  /** Message to reveal & highlight when clicked; undefined only if transcript is empty. */
  messageId: string | undefined;
  /** Sort rank: lower shows first in the focus strip and popover. */
  priority: number;
  title: string;
  /** Fallback turn key when revealing. */
  turnKey: string | undefined;
};

const NO_CARDS: readonly ChatAttentionCard[] = [];

function classifyRequest(
  request: AgentRequest,
  messages: ReturnType<typeof useCommaMessages>
): {
  actionLabel: string;
  kind: ChatAttentionCardKind;
  kindLabel: string;
} {
  switch (request.type) {
    case "oauth_authorization":
      if (request.oauth.provider === "secret") {
        return {
          actionLabel: messages.chat_dock_action_fill(),
          kind: "secret",
          kindLabel: messages.chat_dock_card_secret(),
        };
      }
      if (request.oauth.provider === "cli") {
        return {
          actionLabel: messages.chat_dock_action_login(),
          kind: "login",
          kindLabel: messages.chat_dock_card_login(),
        };
      }
      return {
        actionLabel: messages.chat_dock_action_connect(),
        kind: "oauth",
        kindLabel: messages.chat_dock_card_oauth(),
      };
    case "location":
      return {
        actionLabel: messages.chat_dock_action_review(),
        kind: "location",
        kindLabel: messages.chat_dock_card_location(),
      };
    case "computer_use_start":
      return {
        actionLabel: messages.chat_dock_action_review(),
        kind: "phone",
        kindLabel: messages.chat_dock_card_phone(),
      };
    case "plugin_install":
      return {
        actionLabel: messages.chat_dock_action_review(),
        kind: "plugin",
        kindLabel: messages.chat_dock_card_plugin(),
      };
  }
}

/**
 * Pending interactive cards in this conversation (unanswered QuestionCards,
 * pending AgentRequests, and pending label proposals) projected for the
 * composer's sticky attention bubble.
 *
 * Returns a stable array reference when nothing changed, so streamed reply
 * deltas do not re-render the dock.
 */
export function useChatAttentionCards({
  conversationId,
  labelCatalog,
  messages,
  requests,
}: {
  conversationId: string | undefined;
  labelCatalog: CommaTaskLabelCatalog | undefined;
  messages: readonly ChatMessage[];
  requests: readonly AgentRequest[] | undefined;
}): readonly ChatAttentionCard[] {
  const copy = useCommaMessages();
  const locale = useCommaLocale();
  const [expiryTick, setExpiryTick] = useState(0);

  // Schedule one wake-up for the soonest pending request deadline so an
  // expired request leaves the dock automatically without polling.
  const nextExpiryAt = useMemo(() => {
    if (!requests?.length) return null;
    const now = uiClock.now();
    let soonest: number | null = null;
    for (const request of requests) {
      if (request.status !== "pending" || request.expiresAt === null) continue;
      if (request.expiresAt <= now) continue;
      if (soonest === null || request.expiresAt < soonest) {
        soonest = request.expiresAt;
      }
    }
    return soonest;
    // Re-evaluate after a scheduled expiry fires.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [requests, expiryTick]);

  useEffect(() => {
    if (nextExpiryAt === null) return undefined;
    const delay = Math.max(0, nextExpiryAt - uiClock.now()) + 50;
    return uiClock.after(delay, () => setExpiryTick((value) => value + 1));
  }, [nextExpiryAt]);

  const previousRef = useRef(NO_CARDS);

  const cards = useMemo(() => {
    const now = uiClock.now();
    const latestMessageId = messages.at(-1)?.messageId;
    const turnKeyByMessageId = new Map<string, string | undefined>();
    let currentTurnKey: string | undefined;
    for (const message of messages) {
      if (asksRouter(message)) currentTurnKey = conversationMessageTurnKey(message);
      turnKeyByMessageId.set(message.messageId, currentTurnKey);
    }

    type RankedCard = ChatAttentionCard & { order: number };
    const collected: RankedCard[] = [];

    // 1. Open or failed QuestionCards in the transcript.
    let order = 0;
    for (const message of messages) {
      for (const part of message.parts ?? []) {
        if (part.kind !== "question") continue;
        const question: ChatQuestionPart = part;
        if (question.state.status !== "open" && question.state.status !== "failed") {
          continue;
        }
        collected.push({
          actionLabel: copy.chat_dock_action_answer(),
          expiresAt: null,
          id: `question:${question.messageId}`,
          kind: "question",
          kindLabel: copy.chat_dock_card_question(),
          messageId: message.messageId,
          order: order++,
          priority: 2,
          title: question.prompt,
          turnKey: turnKeyByMessageId.get(message.messageId),
        });
      }
    }

    // 2. Pending AgentRequests (OAuth, CLI login, secrets, location, device, plugin).
    if (requests?.length) {
      const anchored = groupAgentRequestsByAnchor(requests, messages);
      for (const group of anchored) {
        for (const request of group.requests) {
          if (request.status !== "pending") continue;
          if (request.expiresAt !== null && request.expiresAt <= now) continue;
          const meta = classifyRequest(request, copy);
          const targetMessageId =
            group.messageId ?? request.sourceMessageId ?? latestMessageId;
          collected.push({
            actionLabel: meta.actionLabel,
            expiresAt: request.expiresAt,
            id: `request:${request.id}`,
            kind: meta.kind,
            kindLabel: meta.kindLabel,
            messageId: targetMessageId,
            order: order++,
            priority: request.expiresAt !== null ? 1 : 2,
            title: agentRequestTitle(request, copy),
            turnKey:
              targetMessageId !== undefined
                ? turnKeyByMessageId.get(targetMessageId)
                : undefined,
          });
        }
      }
    }

    // 3. Pending label proposals anchored in this conversation.
    if (conversationId && labelCatalog) {
      const pendingProposals = conversationLabelProposals(
        labelCatalog,
        conversationId
      ).filter((proposal) => proposal.status === "pending");
      if (pendingProposals.length > 0) {
        const labelById = new Map(
          (labelCatalog.labels ?? []).map((label) => [label.id, label.name])
        );
        const groups = groupLabelProposalsByAnchor(pendingProposals, messages);
        for (const group of groups) {
          const names: string[] = [];
          const seen = new Set<string>();
          for (const proposal of group.proposals) {
            for (const label of taskLabelProposalLabels(proposal)) {
              if (label.name && !seen.has(label.name)) {
                seen.add(label.name);
                names.push(label.name);
              }
            }
            const payload = proposal.payload as Record<string, unknown>;
            const singleId =
              typeof payload["label_id"] === "string" ? payload["label_id"] : undefined;
            const singleName = singleId ? labelById.get(singleId) : undefined;
            if (singleName && !seen.has(singleName)) {
              seen.add(singleName);
              names.push(singleName);
            }
            if (Array.isArray(payload["label_ids"])) {
              for (const rawId of payload["label_ids"]) {
                if (typeof rawId !== "string") continue;
                const mapped = labelById.get(rawId);
                if (mapped && !seen.has(mapped)) {
                  seen.add(mapped);
                  names.push(mapped);
                }
              }
            }
          }
          const count = group.proposals.length;
          const formattedCount = formatNumber(count, locale);
          const title =
            names.length > 0
              ? copy.chat_dock_labels_summary({
                  count,
                  formattedCount,
                  labels: names.slice(0, 3).join(", "),
                })
              : copy.chat_dock_labels_summary_no_names({ count, formattedCount });
          const targetMessageId = group.messageId ?? latestMessageId;
          collected.push({
            actionLabel: copy.chat_dock_action_review(),
            expiresAt: null,
            id: `labels:${group.messageId ?? "tail"}`,
            kind: "labels",
            kindLabel: copy.chat_dock_card_labels(),
            messageId: targetMessageId,
            order: order++,
            priority: 3,
            title,
            turnKey:
              targetMessageId !== undefined
                ? turnKeyByMessageId.get(targetMessageId)
                : undefined,
          });
        }
      }
    }

    if (collected.length === 0) return NO_CARDS;

    collected.sort((a, b) => {
      if (a.priority !== b.priority) return a.priority - b.priority;
      if (a.expiresAt !== null && b.expiresAt !== null && a.expiresAt !== b.expiresAt) {
        return a.expiresAt - b.expiresAt;
      }
      // Within the same priority tier, surface the newest card first.
      return b.order - a.order;
    });

    const previous = previousRef.current;
    const previousById =
      previous.length > 0
        ? new Map(previous.map((card) => [card.id, card]))
        : undefined;
    const next: ChatAttentionCard[] = collected.map(({ order: _order, ...card }) => {
      const before = previousById?.get(card.id);
      if (
        before &&
        before.actionLabel === card.actionLabel &&
        before.expiresAt === card.expiresAt &&
        before.kind === card.kind &&
        before.kindLabel === card.kindLabel &&
        before.messageId === card.messageId &&
        before.priority === card.priority &&
        before.title === card.title &&
        before.turnKey === card.turnKey
      ) {
        return before;
      }
      return card;
    });

    const unchanged =
      next.length === previous.length &&
      next.every((card, index) => card === previous[index]);
    return unchanged ? previous : next;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversationId, copy, expiryTick, labelCatalog, locale, messages, requests]);

  useEffect(() => {
    previousRef.current = cards;
  }, [cards]);

  return cards;
}
