import { act } from "@testing-library/react";
import { vi } from "vitest";

/**
 * Lets what has already started finish, without moving the fake clock
 * (test-clock.ts): pending promises (a scripted core's answers and values),
 * React's work, and timers due now, in that order, inside `act`.
 */
export async function flush(rounds = 4) {
  for (let round = 0; round < rounds; round += 1)
    await act(() => vi.advanceTimersByTimeAsync(0));
}

/** Moves the fake clock by `ms`, running each timer that falls due, then lets what they started finish. */
export async function advance(ms: number) {
  await act(() => vi.advanceTimersByTimeAsync(ms));
  await flush();
}
