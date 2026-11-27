import { describe, expect, it } from "vitest";
import { CommaApi, taskIsActive } from "../api";
import { menuState } from "../menu";
import { CommaStore } from "../store";
import { fakeServer, memoryStore } from "./support";

const origin = "https://comma.test";
const session = {
  token: "comma_sess_raycast",
  email: "ada@example.test",
  expiresAt: 99,
};
const one = {
  "GET /v1/comma/workspaces": () => ({
    status: 200,
    body: { data: [{ id: "wsp_1", group_id: "grp_1", name: "Ada" }] },
  }),
};

function setup(answers: Parameters<typeof fakeServer>[1] = {}, signedIn = true) {
  const server = fakeServer(origin, answers);
  const store = new CommaStore(memoryStore(), "production");
  const state = async () => {
    if (signedIn && !(await store.session())) await store.setSession(session);
    return menuState(store, (token) => new CommaApi(origin, server.fetch, token));
  };
  return { ...server, store, state };
}

describe("the menu bar", () => {
  it("offers to connect only when the extension has no session", async () => {
    const t = setup({}, false);
    expect(await t.state()).toEqual({ kind: "signed_out" });
    expect(t.seen).toEqual([]);
  });

  it("shows the active Tasks of the account's Workspace", async () => {
    const t = setup({
      ...one,
      "GET /v1/comma/groups/grp_1/conversations": () => ({
        status: 200,
        body: {
          data: [
            {
              id: "cnv_1",
              group_id: "grp_1",
              title: "Book a table",
              status: "running",
            },
            { id: "cnv_2", group_id: "grp_1", title: "Old", status: "completed" },
          ],
          has_more: false,
        },
      }),
    });
    expect(await t.state()).toMatchObject({
      kind: "ready",
      email: "ada@example.test",
      tasks: [{ conversationId: "cnv_1", title: "Book a table" }],
    });
  });

  it("counts only Tasks under way, by the Comma app's status buckets", async () => {
    const statuses = [
      "running",
      "active",
      "needs_review",
      "done",
      "closed",
      "canceled",
      "error",
      "archived",
      "COMPLETED",
    ];
    const t = setup({
      ...one,
      "GET /v1/comma/groups/grp_1/conversations": () => ({
        status: 200,
        body: {
          data: statuses.map((status) => ({
            id: `cnv_${status}`,
            title: status,
            status,
          })),
          has_more: false,
        },
      }),
    });
    const state = await t.state();
    expect(state.kind === "ready" && state.tasks.map((task) => task.status)).toEqual([
      "running",
      "active",
      "needs_review",
    ]);
    expect(taskIsActive({ status: " Done " })).toBe(false);
    // Every request is bounded: a server that never answers ends in "unavailable", not a spinner.
    expect(t.seen.every((request) => request.signal instanceof AbortSignal)).toBe(true);
  });

  it("stays connected when the Tasks cannot be read, and says so", async () => {
    const t = setup({
      ...one,
      "GET /v1/comma/groups/grp_1/conversations": () => ({ status: 503 }),
    });
    expect(await t.state()).toEqual({ kind: "unavailable", email: "ada@example.test" });
    expect(await t.store.session()).toMatchObject({ email: "ada@example.test" });
  });

  it("asks for a Workspace when the account has several and none is chosen", async () => {
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
    expect(await t.state()).toEqual({
      kind: "choose_workspace",
      email: "ada@example.test",
    });
  });

  it("offers to connect again once the server ended the session", async () => {
    const t = setup({ "GET /v1/comma/workspaces": () => ({ status: 401 }) });
    expect(await t.state()).toEqual({ kind: "signed_out" });
    expect(await t.store.session()).toBeUndefined();
  });
});
