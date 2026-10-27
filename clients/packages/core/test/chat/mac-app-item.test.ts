// An Agent's Mac app cards in a window's view (`chatView`): each `mac_app_item` block of an agent message becomes
// a card part in place of the cards' plain-text version; a person's message cannot carry one.
import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatViewValue } from "../../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const events = `${base}/events`;

const card = {
  type: "mac_app_item",
  app: "calendar",
  item_id: "E1",
  title: "和设计团队过需求",
  start: "2026-10-20T02:00:00Z",
  end: "2026-10-20T03:00:00Z",
  calendar: "Calendar",
  color: "#0088FF",
};
const fallback = {
  type: "text",
  text: "- 和设计团队过需求 · 2026-10-20T02:00:00Z · Calendar",
  fallback_for: "mac_app_item",
};
const message = (id: string, actor: "agent" | "user", content: unknown[]) => ({
  message_id: id,
  seq: Number(id.slice(1)),
  kind: "message",
  actor_type: actor,
  ...(actor === "agent" ? { agent_id: "agt_1" } : { user_id: "usr_1" }),
  created_at: 1,
  content,
});

function view(messages: unknown[]) {
  const host = new FakeHost();
  host.api
    .onStream(events)
    .onStream("/v1/comma/groups/grp_1/conversations/events")
    .on("GET", base, {
      group_id: "grp_1",
      id: "cnv_1",
      kind: "user_chat",
      title: "Thread",
      status: "open",
      messages,
    });
  const core = startTestCore(host);
  core.observeSession(signedIn());
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  let value: ChatViewValue | undefined;
  client.subscribe(
    {
      topic: "chatView",
      workspace: "wsp_1",
      group: "grp_1",
      conversation: "cnv_1",
      surface: "win_main",
    },
    (v) => (value = v as ChatViewValue),
    () => undefined
  );
  return {
    time: host.time!,
    parts: (id: string) =>
      value!.state!.messages.find((m) => m.messageId === id)?.parts,
    open: () => host.api.open(events)!,
    messages,
  };
}

describe("an Agent's Mac app cards", () => {
  it("draws each card in place of the cards' plain-text version", async () => {
    const agent = message("m1", "agent", [
      { type: "text", text: "建好了。" },
      card,
      fallback,
    ]);
    const t = view([agent]);
    await t.time.pass(1_500);
    t.open().named("snapshot", {
      type: "snapshot",
      conversation_id: "cnv_1",
      group_id: "grp_1",
      status: "open",
      messages: [agent],
    });
    await t.time.pass(100);

    expect(t.parts("m1")).toEqual([
      { kind: "markdown", text: "建好了。" },
      {
        kind: "mac-app-item",
        item: {
          app: "calendar",
          itemId: "E1",
          title: "和设计团队过需求",
          start: "2026-10-20T02:00:00Z",
          end: "2026-10-20T03:00:00Z",
          calendar: "Calendar",
          color: "#0088FF",
        },
      },
    ]);
  });

  it("shows a person's card block only as its text", async () => {
    const user = message("m2", "user", [card, fallback]);
    const t = view([user]);
    await t.time.pass(1_500);
    t.open().named("snapshot", {
      type: "snapshot",
      conversation_id: "cnv_1",
      group_id: "grp_1",
      status: "open",
      messages: [user],
    });
    await t.time.pass(100);

    expect(t.parts("m2")).toEqual([{ kind: "markdown", text: fallback.text }]);
  });
});
