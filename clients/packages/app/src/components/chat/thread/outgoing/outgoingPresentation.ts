import type { MessageSendMotionConfig } from "@comma/ui/tokens";
import type { ChatMessage } from "@comma/core/chat";
import type {
  OutgoingBubbleFrame,
  OutgoingBubblePlaybackRate,
} from "../../motion/outgoingBubbleMotion";
import {
  QUICK_CHAT_MESSAGE_TYPE,
  conversationMessageTurnKey as messageTurnKey,
} from "@comma/core/chat";

export type ChatOutgoingLaunch = {
  playbackRate?: OutgoingBubblePlaybackRate | undefined;
  motionConfig?: MessageSendMotionConfig | undefined;
  existingTurnKeys: ReadonlySet<string>;
  expiresAt: number;
  id: number;
  sourceFrame: OutgoingBubbleFrame;
  text: string;
};

export type OutgoingPresentation = {
  launch: ChatOutgoingLaunch;
  message: ChatMessage;
  turnKey: string;
};

export function resolveOutgoingPresentations(
  launches: readonly ChatOutgoingLaunch[],
  messages: readonly ChatMessage[],
  lockedMatches: ReadonlyMap<number, string>
): OutgoingPresentation[] {
  const claimedTurnKeys = new Set<string>();
  const presentations: OutgoingPresentation[] = [];

  for (const launch of launches) {
    const lockedTurnKey = lockedMatches.get(launch.id);
    const lockedMessage = lockedTurnKey
      ? messages.find(
          (message) =>
            message.role === "user" &&
            messageTurnKey(message) === lockedTurnKey &&
            !message.platformSource
        )
      : undefined;
    const message =
      lockedMessage ??
      messages.find((candidate) => {
        // Another platform's message or a Quick Chat was not sent from this composer.
        if (
          candidate.role !== "user" ||
          candidate.platformSource ||
          candidate.messageType === QUICK_CHAT_MESSAGE_TYPE
        )
          return false;
        const turnKey = messageTurnKey(candidate);
        return !launch.existingTurnKeys.has(turnKey) && !claimedTurnKeys.has(turnKey);
      });
    if (!message) continue;

    const turnKey = messageTurnKey(message);
    claimedTurnKeys.add(turnKey);
    presentations.push({ launch, message, turnKey });
  }

  return presentations;
}

export function sameNumberStringMap(
  left: ReadonlyMap<number, string>,
  right: ReadonlyMap<number, string>
) {
  return (
    left.size === right.size &&
    [...left].every(([key, value]) => right.get(key) === value)
  );
}
