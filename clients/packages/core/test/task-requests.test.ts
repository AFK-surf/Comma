import { CoreClient, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskRequestsValue } from "../src/contract.ts";
import { taskRequestInviteToken } from "../src/task-requests.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const workspace = { group_id: "g", id: "wsp", name: "Work", status: "ready" };
const token = "A".repeat(43);
const owner = { id: "u1", name: "Owner", email: "owner@example.com" };
const sender = { id: "u2", name: "Sender", email: "sender@example.com" };

const pending = {
  id: "trq_1",
  sender,
  title: "Summarize Q3",
  content: "Summarize Q3 from the sheet",
  status: "pending",
  decline_reason: null,
  task: null,
  created_at: 1,
  expires_at: 2,
};
const target = {
  grant_id: "trg_2",
  workspace: { id: "wsp2", name: "Theirs", owner },
  mode: "review",
  daily_limit: 20,
  pending_limit: 10,
  sent_today: 0,
  pending: 0,
};

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  host.api.on("GET", "/v1/comma/workspaces/wsp/task-requests", { data: [pending] });
  host.api.on("GET", "/v1/comma/workspaces/wsp/task-request-grants", []);
  host.api.on("GET", "/v1/comma/task-request-targets", { data: [target] });
  host.api.on("GET", "/v1/comma/sent-task-requests", { data: [] });
  host.api.on("GET", "/v1/comma/provider-links", { data: [] });
  host.api.on("GET", "/v1/comma/workspaces/wsp/task-request-own", { mode: "review" });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  let value: TaskRequestsValue | undefined;
  const topic: Topic = { topic: "taskRequests", prefer: "wsp" };
  client.subscribe(
    topic,
    (v) => (value = v as TaskRequestsValue),
    () => undefined
  );
  core.observeSession(signedIn());
  return { host, client, time: host.time!, api: host.api, shown: () => value };
}

describe("Settings › Task requests", () => {
  it("shows both sides, and reads again after the owner accepts", async () => {
    const t = setup();
    await t.time.pass(100);
    expect(t.shown()).toMatchObject({
      workspace: "wsp",
      incoming: [{ id: "trq_1", status: "pending" }],
      grants: [],
      targets: [{ grant_id: "trg_2" }],
      sent: [],
      error: false,
    });

    t.api.on("POST", "/v1/comma/workspaces/wsp/task-requests/trq_1/accept", {
      ...pending,
      status: "accepted",
      task: { group_id: "g", id: "t1" },
    });
    t.api.on("GET", "/v1/comma/workspaces/wsp/task-requests", { data: [] });
    const accepted = await t.client.call("taskRequests.accept", {
      workspace: "wsp",
      request: "trq_1",
      title: "Q3 summary",
    });
    expect(accepted).toEqual({ task: { group_id: "g", id: "t1" } });
    expect(
      t.api.seen("POST", "/v1/comma/workspaces/wsp/task-requests/trq_1/accept")[0]?.body
    ).toEqual({
      to: "task",
      title: "Q3 summary",
    });
    await t.time.pass(100);
    expect(t.shown()?.incoming).toEqual([]);
  });

  it("keeps an answered request on its sender's page, out of the waiting list", async () => {
    const t = setup();
    const answered = {
      ...pending,
      id: "trq_0",
      title: "Book the venue",
      status: "accepted",
      task: { group_id: "g", id: "t0" },
    };
    // The server lists only waiting requests unless asked for every status.
    t.api.on("GET", "/v1/comma/workspaces/wsp/task-requests", (request) =>
      json(200, {
        data: request.path.includes("status=all") ? [pending, answered] : [pending],
      })
    );
    await t.time.pass(100);
    expect(t.shown()?.incoming).toEqual([expect.objectContaining({ id: "trq_1" })]);
    expect(t.shown()?.received).toEqual([
      expect.objectContaining({ id: "trq_1", status: "pending" }),
      expect.objectContaining({ id: "trq_0", status: "accepted" }),
    ]);
  });

  it("reads the requests again when the owner's task stream says one came", async () => {
    const t = setup();
    const events = "/v1/comma/groups/g/conversations/events";
    t.api.on("GET", "/v1/comma/groups/g/conversations", { data: [] });
    t.api.onStream(events);
    t.client.subscribe(
      { topic: "tasks", workspace: "" },
      () => undefined,
      () => undefined
    );
    await t.time.pass(100);
    // The task list's stream asks for request changes beside the stations'.
    expect(t.api.requests.map((r) => r.path)).toContain(
      `${events}?with=station_tasks,task_requests`
    );

    const arrived = { ...pending, id: "trq_2", content: "Draft the notes" };
    t.api.on("GET", "/v1/comma/workspaces/wsp/task-requests", {
      data: [arrived, pending],
    });
    t.api.open(events)!.event({ type: "task_requests_invalidated", group_id: "g" });
    await t.time.pass(100);
    expect(t.shown()?.incoming?.map((r) => r.id)).toEqual(["trq_2", "trq_1"]);

    // A request that came while the stream was down: the reconnected stream's resync reads them again.
    const gap = { ...pending, id: "trq_gap" };
    t.api.on("GET", "/v1/comma/workspaces/wsp/task-requests", {
      data: [gap, arrived, pending],
    });
    t.api.open(events)!.event({
      type: "conversation_list_resync_required",
      group_id: "g",
      kind: "agent_task",
      version: "v9",
    });
    await t.time.pass(100);
    expect(t.shown()?.incoming?.map((r) => r.id)).toEqual([
      "trq_gap",
      "trq_2",
      "trq_1",
    ]);
  });

  it("accepts into a coding sandbox as the New task window chose it", async () => {
    const t = setup();
    await t.time.pass(100);
    const path = "/v1/comma/workspaces/wsp/task-requests/trq_1/accept";
    t.api.on("POST", path, {
      ...pending,
      status: "accepted",
      task: { group_id: "g", id: "t2" },
    });
    await t.client.call("taskRequests.accept", {
      workspace: "wsp",
      request: "trq_1",
      content: "Fix the build",
      run: {
        kind: "sandbox",
        repo: { owner: "acme", name: "api", baseRef: "main" },
        provider: "codex",
        accountId: "p1",
      },
    });
    expect(t.api.seen("POST", path)[0]?.body).toEqual({
      to: "task",
      content: "Fix the build",
      runs_on: { kind: "sandbox" },
      repo: { owner: "acme", name: "api", base_ref: "main" },
      model: { kind: "runtime", provider: "codex" },
      account_id: "p1",
    });
  });

  it("accepts into Comma's cloud with the workspace's Task model when no catalog model is named", async () => {
    const t = setup();
    await t.time.pass(100);
    const path = "/v1/comma/workspaces/wsp/task-requests/trq_1/accept";
    t.api.on("POST", path, {
      ...pending,
      status: "accepted",
      task: { group_id: "g", id: "t3" },
    });
    await t.client.call("taskRequests.accept", {
      workspace: "wsp",
      request: "trq_1",
      content: "Summarize Q3",
      run: { kind: "cloud" },
    });
    expect(t.api.seen("POST", path)[0]?.body).toEqual({
      to: "task",
      content: "Summarize Q3",
      runs_on: { kind: "salix" },
    });
  });

  it("accepts an invite from its link and sends through the grant once per key", async () => {
    const t = setup();
    await t.time.pass(100);
    const back = { workspace: { id: "wsp", name: "Mine" }, mode: "review" };
    t.api.on("GET", `/v1/comma/task-request-invites/${token}`, {
      workspace: target.workspace,
      mode: "review",
      own: false,
      back,
      expires_at: 1_720_600_000,
    });
    const link = `https://comma.test/#/settings?category=task-requests&invite=${token}`;
    await expect(
      t.client.call("taskRequests.invitePreview", { invite: link, workspace: "wsp" })
    ).resolves.toEqual({
      workspace: target.workspace,
      own: false,
      back,
      expiresAt: 1_720_600_000,
    });
    expect(t.api.seen("GET", `/v1/comma/task-request-invites/${token}`)[0]?.path).toBe(
      `/v1/comma/task-request-invites/${token}?workspace_id=wsp`
    );
    t.api.on("POST", `/v1/comma/task-request-invites/${token}/accept`, {
      ...target,
      reciprocal: true,
    });
    // Accepted in the person's own workspace, the inviter may send back to it.
    await expect(
      t.client.call("taskRequests.acceptInvite", { invite: link, workspace: "wsp" })
    ).resolves.toEqual({ reciprocal: true });
    const accepts = t.api.seen(
      "POST",
      `/v1/comma/task-request-invites/${token}/accept`
    );
    expect(accepts).toHaveLength(1);
    expect(accepts[0]?.body).toEqual({ workspace_id: "wsp" });

    t.api.on("POST", "/v1/comma/task-request-targets/trg_2/requests", {
      id: "trq_9",
      workspace: target.workspace,
      title: "Draft notes",
      content: "Draft notes",
      status: "pending",
      decline_reason: null,
      task_status: null,
      reply: null,
      created_at: 3,
    });
    const sent = await t.client.call("taskRequests.send", {
      grant: "trg_2",
      content: "  Draft notes ",
      key: "send-1",
      workspace: "wsp",
    });
    expect(sent).toEqual({ status: "pending" });
    expect(
      t.api.seen("POST", "/v1/comma/task-request-targets/trg_2/requests")[0]?.body
    ).toEqual({
      content: "Draft notes",
      client_request_id: "send-1",
      // The sender's own Workspace it was written in: its Router hears how it went.
      sender_workspace_id: "wsp",
    });
  });

  it("links a chat account from the link a bot posted", async () => {
    const t = setup();
    await t.time.pass(100);
    const path = `/v1/comma/provider-link-requests/${token}`;
    t.api.on("GET", path, { provider: "slack", name: "Sam" });
    t.api.on("POST", `${path}/accept`, {
      id: "pul_1",
      provider: "slack",
      name: "Sam",
      linked_at: 5,
    });
    const url = `https://comma.test/#/settings?category=task-requests&link=${token}`;
    expect(await t.client.call("taskRequests.linkPreview", { link: url })).toEqual({
      provider: "slack",
      name: "Sam",
    });
    t.api.on("GET", "/v1/comma/provider-links", {
      data: [
        {
          id: "pul_1",
          provider: "slack",
          name: "Sam",
          email: "sam@x.test",
          workspace: "Acme",
          linked_at: 5,
        },
      ],
    });
    await t.client.call("taskRequests.acceptLink", { link: url });
    await t.time.pass(100);
    expect(t.shown()?.links).toEqual([
      {
        id: "pul_1",
        provider: "slack",
        name: "Sam",
        email: "sam@x.test",
        workspace: "Acme",
        bot: null,
        linked_at: 5,
      },
    ]);
  });

  it("sets how the workspace takes its owner's own requests", async () => {
    const t = setup();
    await t.time.pass(100);
    expect(t.shown()?.own).toBe("review");
    const path = "/v1/comma/workspaces/wsp/task-request-own";
    t.api.on("PATCH", path, { mode: "auto_accept" });
    t.api.on("GET", path, { mode: "auto_accept" });
    await t.client.call("taskRequests.setOwnMode", {
      workspace: "wsp",
      mode: "auto_accept",
    });
    await t.time.pass(100);
    expect(t.api.seen("PATCH", path)[0]?.body).toEqual({ mode: "auto_accept" });
    expect(t.shown()?.own).toBe("auto_accept");
  });

  it("refuses what is not an invite link without a request", async () => {
    const t = setup();
    await t.time.pass(100);
    await expect(
      t.client.call("taskRequests.acceptInvite", { invite: "https://comma.test/s/abc" })
    ).rejects.toMatchObject({ code: "invalid_params" });
    expect(taskRequestInviteToken(token)).toBe(token);
    expect(
      taskRequestInviteToken(
        `https://x.test/#/settings?invite=${token}&category=task-requests`
      )
    ).toBe(token);
  });

  it("reads again once a new account's Workspace is ready, without a reload", async () => {
    const t = setup();
    // Signed in before the Workspace made at sign-in is there: the page has no workspace to invite from.
    t.api.on("GET", "/v1/comma/workspaces", { data: [] });
    await t.time.pass(100);
    expect(t.shown()).toMatchObject({ workspace: null });

    // The Workspace is ready and another surface reads the list: the page reads its lists for it.
    t.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
    t.client.subscribe(
      { topic: "workspace" },
      () => undefined,
      () => undefined
    );
    await t.time.pass(100);
    expect(t.shown()).toMatchObject({ workspace: "wsp", grants: [] });
  });

  it("hides a decided sent request on the server and resolves one-way grant avatars", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/workspaces/wsp/task-request-grants", [
      {
        id: "trg_oneway",
        status: "active",
        mode: "review",
        daily_limit: 20,
        pending_limit: 10,
        grantee: {
          id: "u3",
          name: "Grantee",
          email: "g@example.com",
          avatar_id: "avt_3",
        },
        created_at: 10,
      },
    ]);
    await t.time.pass(100);
    expect(t.shown()?.people?.find((p) => p.id === "u3")?.avatar).toEqual({
      source: "grant-avatar",
      workspace: "wsp",
      grant: "trg_oneway",
      revision: "avt_3",
    });

    t.api.on("DELETE", "/v1/comma/sent-task-requests/trq_done", { hidden: true });
    await expect(
      t.client.call("taskRequests.hide", { request: "trq_done" })
    ).resolves.toBeNull();
    expect(t.api.seen("DELETE", "/v1/comma/sent-task-requests/trq_done")).toHaveLength(
      1
    );
  });

  it("keeps the lists it had and says a read failed", async () => {
    const t = setup();
    await t.time.pass(100);
    t.api.on("GET", "/v1/comma/sent-task-requests", offline());
    await t.client.call("taskRequests.refresh", {});
    await t.time.pass(100);
    expect(t.shown()).toMatchObject({
      incoming: [{ id: "trq_1" }],
      sent: [],
      error: true,
    });
  });

  it("enforces the 1000 UTF-8 byte limit on decline reasons", async () => {
    const t = setup();
    await t.time.pass(100);
    const overLimit = "中".repeat(334);
    await expect(
      t.client.call("taskRequests.decline", {
        workspace: "wsp",
        request: "trq_1",
        reason: overLimit,
      })
    ).rejects.toThrow(/reason is invalid/);
    expect(
      t.api.seen("POST", "/v1/comma/workspaces/wsp/task-requests/trq_1/decline")
    ).toHaveLength(0);

    const atLimit = "中".repeat(333);
    t.api.on("POST", "/v1/comma/workspaces/wsp/task-requests/trq_1/decline", {
      id: "trq_1",
      sender: { id: "u2", name: "Sender", email: "sender@example.com" },
      title: "Summarize Q3",
      content: "Summarize Q3 from the sheet",
      status: "declined",
      decline_reason: atLimit,
      task: null,
      created_at: 1,
      expires_at: 2,
    });
    await expect(
      t.client.call("taskRequests.decline", {
        workspace: "wsp",
        request: "trq_1",
        reason: atLimit,
      })
    ).resolves.toBeNull();
    expect(
      t.api.seen("POST", "/v1/comma/workspaces/wsp/task-requests/trq_1/decline")
    ).toHaveLength(1);
  });
});
