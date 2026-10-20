import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatViewValue } from "../../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const view = {
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};
const task = (updatedAt: number, status = "ready_for_review") => ({
  group_id: "grp_1",
  id: "cnv_1",
  kind: "agent_task",
  title: "Review Task",
  status,
  review_version: updatedAt,
  updated_at: updatedAt,
  messages: [],
});

// The real core, its clock and its HTTP boundary; startTestCore also replays each run.
describe("manual Task status on the core protocol", () => {
  it("refreshes past an old detail response after a conflict, then retries with the new version", async () => {
    const host = new FakeHost();
    host.api
      .on("GET", base, task(2))
      .onStream("/v1/comma/groups/grp_1/conversations/events");
    const core = startTestCore(host, { coalesceMs: 0 });
    const client = new CoreClient(inProcessOpener(core, host, view.surface), {
      schedule: () => undefined,
    });
    let shown: ChatViewValue | undefined;
    client.subscribe(
      { topic: "chatView", ...view },
      (value) => (shown = value as ChatViewValue),
      () => undefined
    );
    core.observeSession(signedIn());
    await host.time!.pass(0);
    expect(shown?.state?.conversation).toMatchObject(taskFields(2));

    // Capture version 2 before the write. Its body arrives after the conflict.
    const releaseOldDetail = host.api.holdBody("GET", base);
    const before = host.api.seen("GET", base).length;
    await client.call("chatView.refresh", view);
    await host.time!.pass(0);
    expect(host.api.seen("GET", base)).toHaveLength(before + 1);
    host.api.on("GET", base, task(3));
    host.api.on("POST", `${base}/status`, json(409, { error: "conflict" }));
    const rejected = expect(
      client.call("chatView.setTaskStatus", {
        ...view,
        status: "completed",
        expectedUpdatedAt: 2,
      })
    ).rejects.toMatchObject({ code: "chat_refused", status: 409 });
    await host.time!.pass(0);
    await rejected;
    releaseOldDetail();
    await host.time!.pass(0);
    expect(host.api.seen("GET", base).length).toBeGreaterThan(before + 1);
    expect(shown?.state?.conversation).toMatchObject(taskFields(3));

    await host.time!.pass(60_000);
    expect(host.api.seen("POST", `${base}/status`)).toHaveLength(1);
    host.api.on("POST", `${base}/status`, (request) => {
      const body = request.body as { expected_updated_at: number };
      return body.expected_updated_at === 3
        ? json(200, task(4, "completed"))
        : json(409, { error: "conflict" });
    });
    host.api.on("GET", base, task(4, "completed"));
    await client.call("chatView.setTaskStatus", {
      ...view,
      status: "completed",
      expectedUpdatedAt: shown!.state!.conversation!.updated_at,
    });
    await host.time!.pass(0);
    expect(
      host.api.seen("POST", `${base}/status`).map((request) => request.body)
    ).toEqual([
      { status: "completed", expected_updated_at: 2 },
      { status: "completed", expected_updated_at: 3 },
    ]);
    expect(shown?.state?.conversation).toMatchObject({
      status: "completed",
      updated_at: 4,
    });
    client.close();
  });
});

function taskFields(version: number) {
  return { status: "ready_for_review", review_version: version, updated_at: version };
}
