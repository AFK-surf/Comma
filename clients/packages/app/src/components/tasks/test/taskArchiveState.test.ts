import { describe, expect, it, vi } from "vitest";
import type { CommaApiClient, CommaConversation } from "../../../api";
import {
  invalidateTaskSummaries,
  observeTaskProjection,
  readTaskSummary,
  recordTaskSummary,
  requestTaskSummary,
} from "../taskArchiveState";

const summary = (id: string, status = "completed") =>
  ({
    id,
    group_id: "g",
    kind: "agent_task",
    title: id,
    status,
    updated_at: 1,
  }) as CommaConversation;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
describe("canonical Task reference summaries", () => {
  it("deduplicates the loaded window into serial batches of at most 50", async () => {
    let running = 0,
      maximum = 0;
    const getTaskSummaries = vi.fn(async (_group: string, ids: string[]) => {
      running++;
      maximum = Math.max(maximum, running);
      await tick();
      running--;
      return ids.map((id) => summary(id));
    });
    const api = { getTaskSummaries } as unknown as CommaApiClient;
    for (let i = 0; i < 121; i++) {
      requestTaskSummary(api, "g", String(i));
      requestTaskSummary(api, "g", String(i));
    }
    await vi.waitFor(() => expect(readTaskSummary(api, "g", "120")).toBeDefined());
    expect(getTaskSummaries.mock.calls.map((call) => call[1].length)).toEqual([
      50, 50, 21,
    ]);
    expect(maximum).toBe(1);
  });

  it("drops a pre-invalidation response and learns an out-of-page archive on owner update", async () => {
    let settle!: (value: CommaConversation[]) => void;
    const getTaskSummaries = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            settle = resolve;
          })
      )
      .mockResolvedValue([summary("old", "archived")]);
    const api = { getTaskSummaries } as unknown as CommaApiClient;
    observeTaskProjection(api, {});
    requestTaskSummary(api, "g", "old");
    await tick();
    const next = {};
    observeTaskProjection(api, next);
    observeTaskProjection(api, next);
    expect(readTaskSummary(api, "g", "old")).toBeUndefined();
    requestTaskSummary(api, "g", "old");
    settle([summary("old")]);
    await vi.waitFor(() =>
      expect(readTaskSummary(api, "g", "old")?.status).toBe("archived")
    );
    expect(getTaskSummaries).toHaveBeenCalledTimes(2);
  });

  it("retains an acknowledged archive through failed refreshes and rejects older facts", async () => {
    const getTaskSummaries = vi
      .fn()
      .mockRejectedValueOnce(new Error("offline"))
      .mockResolvedValueOnce([summary("old")])
      .mockResolvedValueOnce([{ ...summary("old"), updated_at: 3 }]);
    const api = { getTaskSummaries } as unknown as CommaApiClient;
    recordTaskSummary(api, { ...summary("old", "archived"), updated_at: 2 });
    for (let attempt = 0; attempt < 2; attempt++) {
      invalidateTaskSummaries(api);
      expect(readTaskSummary(api, "g", "old")?.status).toBe("archived");
      requestTaskSummary(api, "g", "old");
      await tick();
      expect(readTaskSummary(api, "g", "old")?.status).toBe("archived");
    }
    invalidateTaskSummaries(api);
    requestTaskSummary(api, "g", "old");
    await tick();
    expect(readTaskSummary(api, "g", "old")?.status).toBe("completed");
    expect(getTaskSummaries).toHaveBeenCalledTimes(3);
  });

  it("caps distinct references without eviction and refetch loops", async () => {
    const getTaskSummaries = vi.fn(async (_group: string, ids: string[]) =>
      ids.map((id) => summary(id))
    );
    const api = { getTaskSummaries } as unknown as CommaApiClient;
    for (let i = 0; i < 1200; i++) requestTaskSummary(api, "g", String(i));
    await vi.waitFor(() => expect(readTaskSummary(api, "g", "999")).toBeDefined());
    expect(readTaskSummary(api, "g", "1000")).toBeUndefined();
    requestTaskSummary(api, "g", "0");
    requestTaskSummary(api, "g", "1000");
    await tick();
    expect(getTaskSummaries).toHaveBeenCalledTimes(20);
    invalidateTaskSummaries(api);
    expect(readTaskSummary(api, "g", "0")?.status).toBe("completed");
  });
});
