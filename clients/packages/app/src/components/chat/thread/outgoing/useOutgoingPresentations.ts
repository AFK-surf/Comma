import { useMemo } from "react";
import type { ChatMessage } from "../../model/conversationChannel";
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
  return { outgoingPresentationByTurnKey, outgoingPresentations, outgoingTurnKeys };
}
