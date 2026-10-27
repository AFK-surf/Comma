import { useMemo } from "react";
import type { ChatMessage } from "@comma/core/chat";
import {
  resolveOutgoingPresentations,
  type ChatOutgoingLaunch,
} from "./outgoingPresentation";

export type OutgoingPresentations = ReturnType<typeof useOutgoingPresentations>;

export function useOutgoingPresentations(
  outgoingLaunches: readonly ChatOutgoingLaunch[],
  messages: ChatMessage[],
  outgoingMatches: ReadonlyMap<number, string>
) {
  const outgoingPresentations = useMemo(
    () => resolveOutgoingPresentations(outgoingLaunches, messages, outgoingMatches),
    [messages, outgoingLaunches, outgoingMatches]
  );
  const outgoingPresentationByTurnKey = useMemo(
    () =>
      new Map(
        outgoingPresentations.map((presentation) => [
          presentation.turnKey,
          presentation,
        ])
      ),
    [outgoingPresentations]
  );
  const outgoingTurnKeys = useMemo(
    () => new Set(outgoingPresentations.map((presentation) => presentation.turnKey)),
    [outgoingPresentations]
  );
  // Only a message with a bubble flies; one of attachments or quotes alone
  // has nothing to launch, and its turn is anchored as any other.
  const flyingTurnKeys = useMemo(
    () =>
      new Set(
        outgoingPresentations
          .filter(({ message }) => (message.display?.body ?? message.text).trim())
          .map((presentation) => presentation.turnKey)
      ),
    [outgoingPresentations]
  );
  return {
    flyingTurnKeys,
    outgoingPresentationByTurnKey,
    outgoingPresentations,
    outgoingTurnKeys,
  };
}
