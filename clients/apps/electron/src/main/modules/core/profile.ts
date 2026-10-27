import type { ProfileValue } from "@comma/core/contract";
import type { CoreClient } from "@comma/core-kernel/client";
import { realMainClock, type MainClock } from "../../clock";

/**
 * The signed-in account's name as the client core reads it (its `profile` topic): null when it has none, the read
 * failed, or no answer came within `timeoutMs`.
 */
export function profileName(
  client: CoreClient,
  timeoutMs: number,
  clock: MainClock = realMainClock
): Promise<string | null> {
  return new Promise((resolve) => {
    let stop: (() => void) | undefined;
    let done = false;
    const finish = (name: string | null) => {
      if (done) return;
      done = true;
      cancelTimer();
      resolve(name);
      queueMicrotask(() => stop?.());
    };
    const cancelTimer = clock.setTimer(timeoutMs, () => finish(null));
    stop = client.subscribe(
      { topic: "profile" },
      (value) => {
        const shown = value as ProfileValue | null;
        if (shown?.status === "ready") finish(shown.profile?.name ?? null);
        else if (shown?.status === "error") finish(null);
      },
      () => finish(null)
    );
    if (done) stop();
  });
}
