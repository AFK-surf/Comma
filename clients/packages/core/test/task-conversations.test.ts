import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskConversationValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const path = "/v1/comma/groups/grp_1/conversations/cnv_1";
const conversation = (text: string, status = "running") => ({
  group_id: "grp_1",
  id: "cnv_1",
  kind: "agent_task",
  title: "Task",
  status,
  messages: [
    {
      message_id: "msg_1",
      kind: "message",
      actor_type: "agent",
      content: [{ type: "text", text }],
      created_at: 1,
    },
  ],
});
const preview = (
  extra: { version?: string; status?: string; limit?: string; read?: number } = {}
) => ({
  topic: "taskConversation",
  group: "grp_1",
  conversation: "cnv_1",
  limit: extra.limit ?? "",
  version: extra.version ?? "1",
  status: extra.status ?? "running",
  read: String(extra.read ?? 0),
});
const texts = (value: TaskConversationValue | undefined) =>
  (value?.messages ?? []).map((m) => JSON.stringify(m)).join(" ");

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops: (() => void)[] = [];
  const watch = (topic: Topic) => {
    const k = topicKey(topic);
    stops.push(
      client.subscribe(
        topic,
        (v) => values.set(k, v),
        () => undefined
      )
    );
    return () => values.get(k) as TaskConversationValue | undefined;
  };
  // Every preview closes, and the core lets the topics go (after its grace).
  const closeAll = async () => {
    for (const stop of stops.splice(0)) stop();
    await host.time!.pass(61_000, 1_000);
  };
  core.observeSession(signedIn());
  return { time: host.time!, api: host.api, watch, closeAll };
}

describe("a task's conversation preview", () => {
  it("is kept for the same version, and a newer version is read again with the kept one shown meanwhile", async () => {
    const t = setup();
    let text = "first";
    t.api.on("GET", path, () => json(200, conversation(text)));
    const first = t.watch(preview());
    expect(first()).toBeUndefined();
    await t.time.pass(10);
    expect(first()?.status).toBe("ready");
    expect(texts(first())).toContain("first");

    t.watch(preview({ read: 1 }));
    await t.time.pass(10);
    expect(t.api.seen("GET", path)).toHaveLength(1);

    text = "second";
    const release = t.api.hold("GET", path);
    const newer = t.watch(preview({ version: "2" }));
    await t.time.pass(10);
    expect(newer()?.status).toBe("loading");
    expect(texts(newer())).toContain("first");
    release();
    await t.time.pass(100);
    expect(newer()?.status).toBe("ready");
    expect(texts(newer())).toContain("second");
  });

  it("reads a running task's again after 20 seconds, and an ended one's after 5 minutes", async () => {
    const t = setup();
    t.api.on("GET", path, json(200, conversation("text")));
    t.watch(preview());
    await t.time.pass(20_010, 5_000);
    t.watch(preview({ read: 1 }));
    await t.time.pass(10);
    expect(t.api.seen("GET", path)).toHaveLength(2);

    t.watch(preview({ version: "3", status: "completed" }));
    await t.time.pass(10);
    await t.time.pass(4 * 60_000, 30_000);
    t.watch(preview({ version: "3", status: "completed", read: 1 }));
    await t.time.pass(10);
    expect(t.api.seen("GET", path)).toHaveLength(3);
    await t.time.pass(60_000, 30_000);
    t.watch(preview({ version: "3", status: "completed", read: 2 }));
    await t.time.pass(10);
    expect(t.api.seen("GET", path)).toHaveLength(4);
  });

  it("asks for the last messages only when given a limit, and says a failed read failed until a retry", async () => {
    const t = setup();
    let up = false;
    t.api.on("GET", path, () => (up ? json(200, conversation("tail")) : offline()));
    const failed = t.watch(preview({ limit: "20" }));
    await t.time.pass(10);
    expect(failed()?.status).toBe("failed");
    expect(t.api.seen("GET", path)[0]!.path).toBe(`${path}?message_limit=20`);

    up = true;
    const retried = t.watch(preview({ limit: "20", read: 1 }));
    await t.time.pass(10);
    expect(retried()?.status).toBe("ready");
    expect(texts(retried())).toContain("tail");
  });

  it("stops a read nobody shows any more, so the next showing reads again", async () => {
    const t = setup();
    t.api.on("GET", path, json(200, conversation("text")));
    const release = t.api.hold("GET", path);
    t.watch(preview());
    await t.time.pass(10);
    await t.closeAll();
    release();
    await t.time.pass(100);
    const again = t.watch(preview());
    await t.time.pass(100);
    expect(again()?.status).toBe("ready");
    expect(t.api.seen("GET", path)).toHaveLength(2);
  });

  it("keeps the 24 most recently shown, and reads an older one again", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/groups/grp_1/conversations/*", (request) =>
      json(200, { ...conversation("text"), id: request.path.split("/")[6] })
    );
    const show = (id: string) => ({
      ...preview({ status: "completed" }),
      conversation: id,
    });
    for (let index = 0; index < 25; index += 1) t.watch(show(`cnv_${index}`));
    await t.time.pass(100);
    // All 25 close: the oldest beyond 24 is let go.
    await t.closeAll();
    t.watch(show("cnv_1"));
    await t.time.pass(10);
    expect(t.api.requests.filter((r) => r.path.endsWith("/cnv_1"))).toHaveLength(1);
    t.watch(show("cnv_0"));
    await t.time.pass(10);
    expect(t.api.requests.filter((r) => r.path.endsWith("/cnv_0"))).toHaveLength(2);
  });
});
