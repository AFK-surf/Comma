import { describe, expect, it } from "vitest";
import { ask } from "../ask";
import { CommaApi } from "../api";
import { CommaAppMissing } from "../links";
import { CommaStore } from "../store";
import { fakeServer, memoryStore } from "./support";

const origin = "https://comma.test";
const session = {
  token: "comma_sess_raycast",
  email: "ada@example.test",
  expiresAt: 99,
};

function setup(answers: Parameters<typeof fakeServer>[1] = {}) {
  const server = fakeServer(origin, answers);
  const store = new CommaStore(memoryStore(), "production");
  const opened: string[] = [];
  const run = (text: string) =>
    ask(text, {
      store,
      scheme: "comma",
      api: (token) => new CommaApi(origin, server.fetch, token),
      open: (url) => Promise.resolve(void opened.push(url)),
      requestId: () => "req-1",
    });
  return { ...server, store, opened, run };
}

const home = {
  "GET /v1/comma/workspaces": () => ({
    status: 200,
    body: { data: [{ id: "wsp_1", group_id: "grp_1", name: "Ada" }] },
  }),
  "POST /v1/comma/groups/grp_1/assistant-chat": () => ({
    status: 200,
    body: { id: "cnv_home" },
  }),
};

const accepted = () => ({ status: 200, body: { accepted_message_id: "msg_1" } });

describe("Ask Comma", () => {
  it("hands the words to the desktop app's composer before the extension is connected", async () => {
    const t = setup();
    expect(await t.run("Book a table & a taxi")).toEqual({
      kind: "draft",
      reconnect: false,
    });
    expect(t.opened).toEqual([
      "comma://home/compose?text=Book%20a%20table%20%26%20a%20taxi&entry=raycast",
    ]);
    expect(t.seen).toEqual([]);
    expect(await t.run("a".repeat(8_001))).toEqual({ kind: "too_long" });
  });

  it("sends and hands over nothing when the words are only blank space", async () => {
    const t = setup(home);
    expect(await t.run("   ")).toEqual({ kind: "empty" });
    await t.store.setSession(session);
    expect(await t.run(" \n\t ")).toEqual({ kind: "empty" });
    expect(t.opened).toEqual([]);
    expect(t.seen).toEqual([]);
    expect(await t.store.session()).toEqual(session);
    await t.store.clearSession();
    expect(await t.run("a".repeat(8_001))).toEqual({ kind: "too_long" });
    expect(t.opened).toEqual([]);
  });

  it("says the app is missing, and claims no draft, when nothing takes the link", async () => {
    const t = setup();
    const missing = ask("Hello", {
      store: t.store,
      scheme: "comma",
      api: () => {
        throw new Error("no session, no request");
      },
      open: () => Promise.reject(new CommaAppMissing()),
      requestId: () => "req-1",
    });
    await expect(missing).rejects.toBeInstanceOf(CommaAppMissing);
  });

  it("sends an ordinary Home message with its own session once connected", async () => {
    const t = setup({
      ...home,
      "POST /v1/comma/groups/grp_1/conversations/cnv_home/messages": () => ({
        status: 200,
        body: { id: "cnv_home", accepted_message_id: "msg_1" },
      }),
    });
    await t.store.setSession(session);
    expect(await t.run("Book a table")).toMatchObject({ kind: "sent" });
    const sent = t.seen.at(-1)!;
    expect(sent.body).toEqual({
      message: { type: "text", text: "Book a table" },
      client_request_id: "req-1",
    });
    expect(sent.headers["authorization"]).toBe("Bearer comma_sess_raycast");
    expect(t.opened).toEqual([]);
    // The account's only Workspace is remembered: the next message asks for no list.
    await t.run("And a taxi");
    expect(t.seen.filter((r) => r.path === "/v1/comma/workspaces")).toHaveLength(1);
  });

  it("sends the next message in one request, and finds Home again when the kept one is gone", async () => {
    let homeId = "cnv_home";
    const t = setup({
      ...home,
      "POST /v1/comma/groups/grp_1/assistant-chat": () => ({
        status: 200,
        body: { id: homeId },
      }),
      "POST /v1/comma/groups/grp_1/conversations/cnv_home/messages": () =>
        homeId === "cnv_home" ? accepted() : { status: 404 },
      "POST /v1/comma/groups/grp_1/conversations/cnv_new/messages": accepted,
    });
    await t.store.setSession(session);
    await t.run("Book a table");

    const before = t.seen.length;
    expect(await t.run("And a taxi")).toMatchObject({ kind: "sent" });
    expect(t.seen.slice(before).map((r) => r.path)).toEqual([
      "/v1/comma/groups/grp_1/conversations/cnv_home/messages",
    ]);

    // The server replaced the Home: the message goes to the new one, and the Workspace stays chosen.
    homeId = "cnv_new";
    expect(await t.run("And flowers")).toMatchObject({
      kind: "sent",
      workspace: { id: "wsp_1" },
    });
    expect(t.seen.at(-1)).toMatchObject({
      path: "/v1/comma/groups/grp_1/conversations/cnv_new/messages",
      body: { message: { text: "And flowers" } },
    });
    expect(t.seen.filter((r) => r.path === "/v1/comma/workspaces")).toHaveLength(1);
  });

  it("asks which Workspace when the account has several, and sends nothing", async () => {
    const t = setup({
      "GET /v1/comma/workspaces": () => ({
        status: 200,
        body: {
          data: [
            { id: "wsp_1", group_id: "grp_1", name: "Ada" },
            { id: "wsp_2", group_id: "grp_2", name: "Team" },
          ],
        },
      }),
    });
    await t.store.setSession(session);
    expect(await t.run("Hello")).toEqual({ kind: "choose_workspace" });
    expect(t.seen.map((r) => r.method)).toEqual(["GET"]);
  });

  it("chooses again when the chosen Workspace is no longer the account's, and sends there", async () => {
    const t = setup({
      ...home,
      // The Workspace chosen before is gone: the server refuses its group.
      "POST /v1/comma/groups/grp_gone/assistant-chat": () => ({ status: 404 }),
      "POST /v1/comma/groups/grp_1/conversations/cnv_home/messages": () => ({
        status: 200,
        body: { id: "cnv_home", accepted_message_id: "msg_1" },
      }),
    });
    await t.store.setSession(session);
    await t.store.setWorkspace({ id: "wsp_gone", groupId: "grp_gone", name: "Gone" });
    expect(await t.run("Hello")).toMatchObject({
      kind: "sent",
      workspace: { id: "wsp_1" },
    });
    expect(await t.store.workspace()).toMatchObject({ id: "wsp_1" });
  });

  it("forgets a session the server ended and keeps the words in the composer", async () => {
    const t = setup({ "GET /v1/comma/workspaces": () => ({ status: 401 }) });
    await t.store.setSession(session);
    expect(await t.run("Still there?")).toEqual({ kind: "draft", reconnect: true });
    expect(await t.store.session()).toBeUndefined();
    expect(t.opened).toHaveLength(1);
  });

  it("says a message the server did not accept was not sent", async () => {
    const t = setup({
      ...home,
      "POST /v1/comma/groups/grp_1/conversations/cnv_home/messages": () => ({
        status: 200,
        body: { id: "cnv_home" },
      }),
    });
    await t.store.setSession(session);
    await expect(t.run("Hello")).rejects.toMatchObject({ status: 502 });
  });
});
