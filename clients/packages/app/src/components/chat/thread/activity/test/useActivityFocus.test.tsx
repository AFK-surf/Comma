import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { useTaskParticipantFeeds } from "../useActivityFocus";

// How often the core reads each feed, and what it keeps through reconnects, is tested in
// packages/core/test/task-workers.test.ts.

const worker = {
  active: true,
  avatarId: "actor_worker",
  name: "Codex Worker",
  participantId: "ptp_worker",
};

describe("useTaskParticipantFeeds", () => {
  it("asks the core to follow at most two Tasks, shows each bound Worker, and lets go on unmount", async () => {
    let value: Record<string, unknown> = {};
    const shown: Record<string, unknown>[] = [];
    const left: Record<string, unknown>[] = [];
    const core = createScriptedCore({
      values: (topic) => (topic.topic === "taskWorkers" ? value : undefined),
      onSubscribe: (topic) => shown.push(topic),
      onUnsubscribe: (topic) => left.push(topic),
    });
    const { result, unmount } = renderHook(
      () => useTaskParticipantFeeds("group", ["t1", "t2", "t3", "t4", "t5"]),
      { wrapper: ({ children }: { children: ReactNode }) => core.wrap(children) }
    );
    await waitFor(() =>
      expect(shown).toEqual([{ topic: "taskWorkers", group: "group", ids: "t1,t2" }])
    );
    expect(result.current.size).toBe(0);

    act(() => {
      value = { t1: null, t2: worker };
      core.changed("taskWorkers");
    });
    await waitFor(() => expect(result.current.get("t2")).toEqual(worker));
    // A Task with no bound Worker yet is a known answer.
    expect(result.current.get("t1")).toBeNull();

    unmount();
    await waitFor(() => expect(left).toHaveLength(1));
  });
});
