import type { ChatMessage } from "@comma/core/chat";
import { useLayoutEffect, useState } from "react";

/**
 * Whether a coding Task's sandbox's screen shows in its conversation now. It shows while something is on that screen
 * (`active`: the station's `screen_active`) and no message has closed the Worker's turn. A message that ends the
 * Worker's turn (`endsTurn`: its result, or what it needs of a person) ends the showing as the message appears: the
 * station says the screen ended only when the turn does, which is after that message. The showing stays ended while
 * other agents speak (the Router delivering that result), until the station says the screen ended or a person writes
 * again: a person's message is new input for the Worker, whose next turn may use the screen again, and a client that
 * missed the station's `false` in between would otherwise hide that whole turn.
 *
 * It reads the last message of `messages`, the transcript as shown: a message that is never shown must not come last.
 * What it remembers changes before the browser paints (a layout effect), never while it renders.
 */
export function useCodingScreenLive(
  active: boolean,
  messages: readonly ChatMessage[]
): boolean {
  const last = messages.at(-1);
  const ending = last?.endsTurn === true ? last.messageId : undefined;
  const person = last?.role === "user";
  // The message that closed the showing under way.
  const [closedBy, setClosedBy] = useState<string>();
  useLayoutEffect(() => {
    if (!active || person) setClosedBy(undefined);
    else if (ending !== undefined) setClosedBy(ending);
  }, [active, ending, person]);
  return active && ending === undefined && (person || closedBy === undefined);
}
