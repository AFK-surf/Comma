import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const share = "/v1/comma/groups/g/conversations/t1/document-share";
const shares = "/v1/comma/groups/g/document-shares";
const document = { group: "g", conversation: "t1", fileName: "plan.md" };
const link = (url: string, message = "m1") => ({
  url,
  file_name: "plan.md",
  message_id: message,
  index: 1,
  created_at: 1,
  shared_at: 2,
});

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  return { api: host.api, client };
}

describe("a document's public link", () => {
  it("is read by the document's name, and each change answers the link it made", async () => {
    const t = setup();
    // No link: the document is not shared.
    expect(await t.client.call("documentShare.get", document)).toBeNull();
    expect(t.api.seen("GET", share)[0]!.path).toBe(`${share}?file_name=plan.md`);

    // A link is made of one version: a Message's attachment.
    t.api.on("PUT", share, link("https://comma.test/s/one"));
    const made = await t.client.call("documentShare.publish", {
      group: "g",
      conversation: "t1",
      message: "m1",
      index: 1,
    });
    expect(made).toMatchObject({ url: "https://comma.test/s/one", message_id: "m1" });
    expect(t.api.seen("PUT", share)[0]!.body).toEqual({ message_id: "m1", index: 1 });

    t.api.on("POST", `${share}/reset`, link("https://comma.test/s/two"));
    expect(await t.client.call("documentShare.reset", document)).toMatchObject({
      url: "https://comma.test/s/two",
    });
    expect(t.api.seen("POST", `${share}/reset`)[0]!.path).toBe(
      `${share}/reset?file_name=plan.md`
    );

    t.api.on("DELETE", share, { revoked: true });
    expect(await t.client.call("documentShare.revoke", document)).toBeNull();
  });

  it("fails a read the server could not answer, where no link reads as none", async () => {
    const t = setup();
    t.api.on("GET", share, () => json(503, { error: "conversation_unavailable" }));
    await expect(t.client.call("documentShare.get", document)).rejects.toBeDefined();
  });

  it("lists a Group's links a page at a time, each with its document and its Task", async () => {
    const t = setup();
    t.api.on("GET", shares, {
      data: [
        {
          url: "https://comma.test/s/one",
          file_name: "plan.md",
          conversation: { id: "t1", title: "Quarterly report", kind: "agent_task" },
          shared_at: 1_700_000_000,
        },
      ],
      has_more: true,
      next_cursor: "5_abc",
    });
    expect(await t.client.call("documentShares.list", { group: "g" })).toEqual({
      shares: [
        {
          url: "https://comma.test/s/one",
          fileName: "plan.md",
          conversation: "t1",
          task: "Quarterly report",
          shared_at: 1_700_000_000,
        },
      ],
      cursor: "5_abc",
    });
    await t.client.call("documentShares.list", { group: "g", cursor: "5_abc" });
    expect(t.api.seen("GET", shares)[1]!.path).toBe(`${shares}?cursor=5_abc`);
  });
});
