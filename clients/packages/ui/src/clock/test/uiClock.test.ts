import { describe, expect, it } from "vitest";
import { installUiClock, scheduleLayoutRead, uiClock } from "../index";
import { createVirtualUiClock } from "../virtual";

describe("uiClock", () => {
  it("runs timers and frames of an installed virtual clock in time order", () => {
    const clock = createVirtualUiClock({ start: 1_000, frameMs: 16 });
    const restore = installUiClock(clock);
    const log: string[] = [];
    try {
      uiClock.after(16, () => log.push(`timer@${uiClock.monotonic()}`));
      uiClock.frame((time) => {
        log.push(`frame@${time}`);
        uiClock.frame((next) => log.push(`frame@${next}`));
      });
      const cancel = uiClock.after(5, () => log.push("cancelled"));
      const stop = uiClock.every(10, () => {
        log.push(`every@${uiClock.monotonic()}`);
        if (uiClock.monotonic() >= 20) stop();
      });
      cancel();

      clock.advance(15);
      expect(log).toEqual(["every@10"]);
      clock.advanceFrames(2);
      expect(log).toEqual(["every@10", "timer@16", "frame@16", "every@20", "frame@32"]);
      expect(uiClock.now()).toBe(1_032);
      expect(clock.pending()).toBe(0);
    } finally {
      restore();
    }
  });

  it("moves one frame per step with no frame waiting, and runs a frame a timer lands on", () => {
    const clock = createVirtualUiClock({ start: 0, frameMs: 16 });
    const log: number[] = [];
    clock.advanceFrames(1);
    clock.advanceFrames(1);
    expect(clock.monotonic()).toBe(32);
    clock.after(16, () => clock.frame((time) => log.push(time)));
    clock.advance(16);
    expect(log).toEqual([48]);
    clock.advanceFrames(1);
    expect(log).toEqual([48]);
    expect(clock.monotonic()).toBe(64);
  });

  it("runs every layout read of a frame before any of their writes", () => {
    const clock = createVirtualUiClock({ start: 0, frameMs: 16 });
    const restore = installUiClock(clock);
    const log: string[] = [];
    try {
      const reader = (name: string) => () => {
        log.push(`read ${name}`);
        return () => {
          log.push(`write ${name}`);
          if (name === "a") scheduleLayoutRead(reader("next"));
        };
      };
      scheduleLayoutRead(reader("a"));
      scheduleLayoutRead(reader("b"));
      scheduleLayoutRead(reader("cancelled"))();

      clock.advanceFrames(1);
      expect(log).toEqual(["read a", "read b", "write a", "write b"]);
      clock.advanceFrames(1);
      expect(log.slice(4)).toEqual(["read next", "write next"]);
    } finally {
      restore();
    }
  });

  it("cancels the frame when its last layout read is cancelled", () => {
    const clock = createVirtualUiClock({ start: 0, frameMs: 16 });
    const restore = installUiClock(clock);
    try {
      scheduleLayoutRead(() => undefined)();
      expect(clock.pending()).toBe(0);
    } finally {
      restore();
    }
  });

  it("schedules a layout read on the installed clock while another clock holds a batch", () => {
    const first = createVirtualUiClock({ start: 0, frameMs: 16 });
    const second = createVirtualUiClock({ start: 0, frameMs: 16 });
    const log: string[] = [];
    const restoreFirst = installUiClock(first);
    // A batch left waiting on a clock that never runs again (a test's page
    // clock, restored).
    scheduleLayoutRead(() => void log.push("first"));
    restoreFirst();
    const restoreSecond = installUiClock(second);
    try {
      scheduleLayoutRead(() => void log.push("second"));
      second.advanceFrames(1);
      expect(log).toEqual(["second"]);
    } finally {
      restoreSecond();
    }
  });
});
