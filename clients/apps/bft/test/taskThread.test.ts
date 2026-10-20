import { describe, expect, it } from "vitest";
import type { BftTaskMessage } from "../src/api";
import {
  nextPollDelay,
  pollIntervalMs,
  pollMaxIntervalMs,
} from "../src/TaskDetailPage";
import {
  appendNewer,
  mergeMessages,
  prependOlder,
  startThread,
} from "../src/taskThread";

const message = (seq: number, text = `m${seq}`): BftTaskMessage => ({
  id: `msg${seq}`,
  seq,
  author: "Agent",
  from_person: false,
  created_at: null,
  blocks: [{ type: "text", html: `<p>${text}</p>` }],
});

const ids = (messages: BftTaskMessage[]) => messages.map((item) => item.id);
const range = (from: number, to: number) =>
  Array.from({ length: to - from + 1 }, (_, index) => message(from + index));

describe("task thread", () => {
  it("keeps each message once, in server order, whatever order replies arrive in", () => {
    const merged = mergeMessages(
      [message(1), message(3)],
      [message(2), message(3, "edited")]
    );
    expect(ids(merged)).toEqual(["msg1", "msg2", "msg3"]);
    expect(merged[2]?.blocks).toEqual([{ type: "text", html: "<p>edited</p>" }]);
  });

  it("polls from the newest message and ignores ones it already holds", () => {
    const thread = startThread([message(1), message(2)], false);
    expect(thread.tailId).toBe("msg2");
    const next = appendNewer(thread, [message(2), message(3)]);
    expect(ids(next.messages)).toEqual(["msg1", "msg2", "msg3"]);
    expect(next.tailId).toBe("msg3");
    expect(appendNewer(next, [])).toBe(next);
  });

  it("drops the oldest messages past the cap and says older ones exist", () => {
    const thread = startThread(range(1, 4), false);
    const next = appendNewer(thread, range(5, 6), 5);
    expect(ids(next.messages)).toEqual(["msg2", "msg3", "msg4", "msg5", "msg6"]);
    expect(next.hasOlder).toBe(true);
  });

  it("pages older messages in above, dropping the newest past the cap", () => {
    const thread = startThread(range(4, 6), true);
    const next = prependOlder(thread, range(1, 3), false, 5);
    expect(ids(next.messages)).toEqual(["msg1", "msg2", "msg3", "msg4", "msg5"]);
    expect(next.hasOlder).toBe(false);
    expect(next.detached).toBe(true);
    // The poll still starts after the newest message the server returned;
    // new ones are counted until the reader returns to the latest.
    expect(next.tailId).toBe("msg6");
    const later = appendNewer(next, [message(6), message(7)], 5);
    expect(ids(later.messages)).toEqual(ids(next.messages));
    expect(later.unseen).toBe(1);
    expect(later.tailId).toBe("msg7");
  });

  it("backs off while nothing changes and starts over after a change", () => {
    expect(nextPollDelay(pollIntervalMs, false)).toBe(pollIntervalMs * 2);
    expect(nextPollDelay(pollMaxIntervalMs, false)).toBe(pollMaxIntervalMs);
    expect(nextPollDelay(pollMaxIntervalMs, true)).toBe(pollIntervalMs);
  });
});
