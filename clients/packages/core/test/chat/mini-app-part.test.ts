// A Task's deployed Mini App in a window's view (`chatView`): the `mini_app` block of the Task agent's message becomes
// an app card part; a person's message, or a block the client cannot read, shows only its summary.
import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatViewValue, MiniApp } from "../../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/task_1";
const summary = "Habit tracker — preview version 3";
const block = (extra: Record<string, unknown> = {}) => ({
  type: "mini_app",
  version: 1,
  app_id: "app_1",
  app_version: 3,
  name: "Habit tracker",
  summary,
  ...extra,
});
const message = (id: string, actor: "agent" | "user", content: unknown[]) => ({
  message_id: id,
  seq: Number(id.slice(1)),
  kind: "message",
  actor_type: actor,
  ...(actor === "agent" ? { agent_id: "agt_1" } : { user_id: "usr_1" }),
  created_at: 1,
  text: summary,
  content,
});

describe("a Task's app card", () => {
  it("shows the app the Task built from its agent's mini_app block", async () => {
    const host = new FakeHost();
    host.api
      .onStream(`${base}/events`)
      .onStream("/v1/comma/groups/grp_1/conversations/events")
      .on("POST", "/v1/comma/workspaces/wsp_1/apps", {
        id: "app_1",
        slug: "x7k2q9",
        workspace_id: "wsp_1",
        name: "Habit tracker",
        description: "",
        icon_url: null,
        repo: { owner: "me", name: "comma-app-x7k2q9" },
        visibility: "private",
        status: "active",
        live_version: null,
        latest_version: null,
        author: { name: "Ada" },
        capabilities: [],
        egress: [],
        storage: [],
        has_backend: false,
        secrets: [],
        grants: [],
        installed: false,
        install: null,
        created_at: "",
        updated_at: "",
      })
      .on("GET", base, {
        group_id: "grp_1",
        id: "task_1",
        kind: "agent_task",
        title: "Build a habit tracker",
        status: "ready_for_review",
        messages: [
          // As Salix posts it: the summary as text for other clients, then the card.
          message("m1", "agent", [{ type: "text", text: summary }, block()]),
          message("m2", "user", [block()]),
          message("m3", "agent", [block({ version: 2 })]),
          message("m4", "agent", [block({ app_version: 0 })]),
        ],
      });
    const core = startTestCore(host);
    core.observeSession(signedIn());
    const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
      schedule: () => undefined,
    });
    // The Router made the app; its Coding Task deployed a preview.
    const made = (await client.call("miniApps.create", {
      workspace: "wsp_1",
      name: "Habit tracker",
    })) as MiniApp;
    let value: ChatViewValue | undefined;
    client.subscribe(
      {
        topic: "chatView",
        workspace: "wsp_1",
        group: "grp_1",
        conversation: "task_1",
        surface: "win_main",
      },
      (v) => (value = v as ChatViewValue),
      () => undefined
    );
    await host.time!.pass(100);
    const parts = (id: string) =>
      value!.state!.messages.find((m) => m.messageId === id)?.parts;
    expect(parts("m1")).toEqual([
      {
        kind: "mini-app",
        appId: made.id,
        appVersion: 3,
        name: "Habit tracker",
        summary,
        conversationId: "task_1",
        messageId: "m1",
      },
    ]);
    // A person cannot post an app card, and a block this client cannot read shows no card.
    for (const id of ["m2", "m3", "m4"])
      expect(parts(id)?.some((p) => p.kind === "mini-app")).toBe(false);
  });
});
