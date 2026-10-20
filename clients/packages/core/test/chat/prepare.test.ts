import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import { base64, fromBase64 } from "../../src/record.ts";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";
import { comparable, replay } from "../../src/testing/replay.ts";

const path = "/v1/comma/groups/grp_1/conversations/cnv_1";
const session = { audience: "https://api.comma.test", sessionId: "session-user-1" };
const ask = { session, groupId: "grp_1", conversationId: "cnv_1" };
const conversation = (messages: unknown[], extra: Record<string, unknown> = {}) => ({
  group_id: "grp_1",
  id: "cnv_1",
  kind: "agent_task",
  status: "active",
  title: "Prepared Task",
  updated_at: 2,
  messages,
  ...extra,
});
const message = (id: string, text: string) => ({
  message_id: id,
  kind: "message",
  actor_type: "agent",
  content: [{ type: "text", text }],
});

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  return { core, client, time: host.time!, api: host.api };
}

describe("a conversation read ahead of its opening", () => {
  it("is its last 24 messages, as a window shows them, read once for each ask", async () => {
    const t = setup();
    t.api.on("GET", path, conversation([message("m1", "Ready before navigation")]));
    const read = t.client.call("chat.prepare", ask);
    await t.time.pass(100);
    expect(await read).toMatchObject({
      conversation: { id: "cnv_1", title: "Prepared Task", messages: [] },
      messages: [{ messageId: "m1", text: "Ready before navigation" }],
    });
    expect(t.api.requests.map((r) => r.path)).toContain(`${path}?message_limit=24`);
    await t.time.pass(60_000, 1_000);
    expect(t.api.seen("GET", path)).toHaveLength(1);
  });

  it("is nothing when its last messages are all private delivery records", async () => {
    const t = setup();
    t.api.on(
      "GET",
      path,
      conversation(
        [
          {
            message_id: "msg_delivery",
            kind: "app_event",
            actor_type: "system",
            content: [],
            metadata: { event_type: "provider.status" },
          },
        ],
        { message_count: 100 }
      )
    );
    const read = t.client.call("chat.prepare", ask);
    await t.time.pass(100);
    expect(await read).toBeNull();
  });

  it("is refused to a window of a session the core is no longer on", async () => {
    const t = setup();
    t.api.on("GET", path, conversation([]));
    // Expected before the time passes, so the refusal is never unhandled.
    const stale = expect(
      t.client.call("chat.prepare", {
        ...ask,
        session: { ...session, sessionId: "obsolete" },
      })
    ).rejects.toMatchObject({ code: "session_changed" });
    await t.time.pass(100);
    await stale;
    expect(t.api.seen("GET", path)).toHaveLength(0);
  });
});

describe("a conversation read ahead of its opening, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", path, conversation([message("m1", "Roadmap")]));
    const read = t.client.call("chat.prepare", ask);
    await t.time.pass(100);
    await read;

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const answer = told.find(
      (input) => input.kind === "response" && input.request.path.startsWith(path)
    )!;
    if (answer.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(answer.body));
    answer.body = base64(
      new TextEncoder().encode(body.replaceAll("Roadmap", "Rollout"))
    );
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
