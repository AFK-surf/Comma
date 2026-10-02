import { memo, type ReactNode, type Ref } from "react";
import type { OutgoingBubbleFrame } from "../chat/motion/outgoingBubbleMotion";
import { MessageAvatar } from "../chat/thread/rows/MessageAvatar";
import {
  UserMessageBubble,
  type UserBubbleOutgoingPresentation,
} from "../chat/thread/rows/user/UserMessageBubble";
import { onboardingMessageSend } from "./onboardingMotion";
import type { OnboardingItemId, OnboardingMessage } from "./onboardingSetup";

/** Consecutive messages from one side, as the chat groups them. */
type MessageGroup = {
  from: OnboardingMessage["from"];
  messages: OnboardingMessage[];
};

function groupMessages(messages: readonly OnboardingMessage[]) {
  const groups: MessageGroup[] = [];
  for (const message of messages) {
    const group = groups.at(-1);
    if (group?.from === message.from) group.messages.push(message);
    else groups.push({ from: message.from, messages: [message] });
  }
  return groups;
}

/**
 * The onboarding thread, as the chat shows a conversation: Comma's messages
 * on the left under its name, in the assistant's grey, with its mark at the
 * latest one; the user's on the right, in the chat's blue. Each is the
 * client's own message bubble, and the last of each side's run carries the
 * chat's tail on that side. Each is sent with the chat's send motion from the
 * invisible composer under the thread (`source`): Comma's lift off its start
 * edge, the user's off its end edge, as a sent message does. The item's card
 * hangs under the question that asked for it.
 *
 * The thread stands on its composer: a new message grows in at the bottom
 * and lifts what is above it; the overlay moves the rest (onboardingMotion.ts).
 */
export function OnboardingConversation({
  card,
  cardItem,
  contentRef,
  messages,
  onLanded,
  settled,
  speaker,
  texts,
}: {
  messages: readonly OnboardingMessage[];
  /** Each message's words, by id. */
  texts: readonly string[];
  /** The card on show, under the question that asked for it. */
  card: ReactNode;
  cardItem: OnboardingItemId | undefined;
  /** Nothing flies any more (the thread is leaving): what is in flight lands. */
  settled: boolean;
  /** A message's send motion has landed. */
  onLanded: (id: number) => void;
  /** The label of a group said before the stored name was read. */
  speaker: string;
  contentRef: Ref<HTMLDivElement>;
}) {
  const groups = groupMessages(messages);

  return (
    // While a message flies, its slot is laid out whole at once and what it
    // pushes aside moves on the compositor (outgoingBubbleMotion.ts): the
    // thread itself, and the mark that keeps to its group's latest bubble.
    <div
      className="comma-onboarding-thread__content"
      data-outgoing-lift=""
      ref={contentRef}
    >
      {/* Each message is read out as it is sent, however many arrive at once
          (Comma hurried along); a card's controls are not: focus brings the
          reader to them. */}
      <div aria-live="polite" className="app-sr-only" role="log">
        {messages.map((message) => (
          <p key={message.id}>{texts[message.id]}</p>
        ))}
      </div>
      {groups.map((group, index) => {
        const first = group.messages[0]!;
        const last = group.messages.at(-1)!;
        // The name the previous Comma group went by: when the user has just
        // renamed it, this group's label turns from that name into the new
        // one as it arrives.
        const previous = groups
          .slice(0, index)
          .findLast((candidate) => candidate.from === "comma")?.messages[0];
        const name = first.from === "comma" ? (first.speaker ?? speaker) : "";
        const formerName =
          previous?.from === "comma" ? (previous.speaker ?? speaker) : undefined;
        const renamed =
          !settled &&
          first.landedAt === undefined &&
          formerName !== undefined &&
          formerName !== name
            ? formerName
            : undefined;
        // The item still waiting for its answer: its card comes, or is,
        // under the question that asks for it.
        const asking =
          index === groups.length - 1 &&
          last.from === "comma" &&
          last.line.kind === "question"
            ? last.line.item
            : undefined;
        // A run ends in the tail, as the chat ends a reply in it, the
        // question over a card included.
        const tailed = last.id;
        const bubbles = group.messages.map((message) => (
          <OnboardingBubble
            flying={!settled && message.landedAt === undefined}
            id={message.id}
            key={message.id}
            onLanded={onLanded}
            source={message.source}
            tail={
              message.id !== tailed
                ? undefined
                : group.from === "user"
                  ? "right"
                  : "left"
            }
            text={texts[message.id] ?? ""}
          />
        ));
        if (group.from === "user") {
          return (
            <div
              className="comma-onboarding-thread__group"
              data-from="user"
              data-onboarding-part=""
              key={first.id}
            >
              {bubbles}
            </div>
          );
        }
        return (
          <section
            className="comma-onboarding-thread__group"
            data-from="comma"
            key={first.id}
          >
            <div className="comma-onboarding-thread__head" data-onboarding-part="">
              <span
                className="comma-chat-assistant-source-label comma-onboarding-thread__speaker"
                data-renamed={renamed === undefined ? undefined : ""}
              >
                {/* The former name is drawn, not read: the label's text is the
                    name Comma goes by now. */}
                <span
                  className="comma-onboarding-thread__name"
                  data-former-name={renamed}
                >
                  <span className="comma-onboarding-thread__name-text">{name}</span>
                </span>
              </span>
              {/* Comma speaks from the assistant's side: each bubble lifts off
                  the composer from its start edge (outgoingBubbleMotion.ts). */}
              <div
                className="comma-onboarding-thread__bubbles"
                data-outgoing-align="start"
              >
                {bubbles}
                <span
                  className="comma-onboarding-thread__avatar"
                  data-outgoing-follow=""
                >
                  <MessageAvatar actorRole="router" />
                </span>
              </div>
            </div>
            {asking && asking === cardItem ? card : null}
          </section>
        );
      })}
    </div>
  );
}

/**
 * One message: the client's bubble, flying in from the composer while its
 * send motion plays. The words and the source never change for a message,
 * so the bubble re-renders only as it lands, and once its tail passes to a
 * later message of its run.
 */
const OnboardingBubble = memo(function OnboardingBubble({
  flying,
  id,
  onLanded,
  source,
  tail,
  text,
}: {
  id: number;
  text: string;
  source: OutgoingBubbleFrame | undefined;
  flying: boolean;
  /** The last of its side's run: the chat's tail on that side. */
  tail: "left" | "right" | undefined;
  onLanded: (id: number) => void;
}) {
  const presentation: UserBubbleOutgoingPresentation | undefined =
    flying && source
      ? {
          launch: { id, motionConfig: onboardingMessageSend, sourceFrame: source },
          turnKey: `onboarding-${id}`,
        }
      : undefined;
  return (
    <div
      className="comma-onboarding-thread__bubble"
      data-bubble-tail={tail}
      data-onboarding-message={id}
    >
      <UserMessageBubble
        onOutgoingAnimationComplete={onLanded}
        outgoingPresentation={presentation}
        text={text}
      />
    </div>
  );
});
