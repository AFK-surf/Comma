import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskMembersValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const workspace = { group_id: "g", id: "wsp", name: "Work", status: "ready" };
const member = {
  person: { id: "u2", name: "Maya", avatar_id: null },
  status: "active",
};

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  host.api.on("GET", "/v1/comma/collaborations", { data: [] });
  host.api.on("GET", "/v1/comma/workspaces/wsp/collaborations/t1/members", {
    data: [member],
  });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  let value: TaskMembersValue | undefined;
  client.subscribe(
    { topic: "taskMembers", workspace: "wsp", task: "t1" },
    (v) => (value = v as TaskMembersValue),
    () => undefined
  );
  core.observeSession(signedIn());
  return { host, client, time: host.time!, api: host.api, shown: () => value };
}

describe("People › a Task together's members", () => {
  it("the host takes a member out, and the members read again", async () => {
    const t = setup();
    await t.time.pass(100);
    expect(t.shown()?.members).toMatchObject([member]);

    t.api.on("DELETE", "/v1/comma/workspaces/wsp/collaborations/t1/members/u2", {
      removed: true,
    });
    t.api.on("GET", "/v1/comma/workspaces/wsp/collaborations/t1/members", {
      data: [{ ...member, status: "removed" }],
    });
    await t.client.call("collaborations.remove", {
      workspace: "wsp",
      task: "t1",
      person: "u2",
    });
    await t.time.pass(100);
    expect(t.shown()?.members).toMatchObject([{ ...member, status: "removed" }]);
  });
});
