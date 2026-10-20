import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";

const path = "/v1/comma/groups/grp_1/conversations/cnv_1/messages/m2/context";
const ask = {
  groupId: "grp_1",
  conversationId: "cnv_1",
  messageId: "m2",
  conversationKind: "agent_task",
} as const;
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
  return { client, time: host.time!, api: host.api };
}

describe("the messages around a message", () => {
  it("are read once for each ask, as a window shows them", async () => {
    const t = setup();
    t.api.on("GET", path, {
      data: [message("m1", "Earlier"), message("m2", "Quoted")],
    });
    const read = t.client.call("chat.messageContext", ask);
    await t.time.pass(100);
    expect(await read).toMatchObject([
      { messageId: "m1", text: "Earlier" },
      { messageId: "m2", text: "Quoted" },
    ]);
    await t.time.pass(60_000, 1_000);
    expect(t.api.seen("GET", path)).toHaveLength(1);
  });

  it("refuses a message it cannot address", async () => {
    const t = setup();
    await expect(
      t.client.call("chat.messageContext", { ...ask, messageId: "" })
    ).rejects.toMatchObject({ code: "invalid_params" });
  });
});
