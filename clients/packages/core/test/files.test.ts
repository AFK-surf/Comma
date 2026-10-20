import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { FileSource } from "../src/contract.ts";
import { FILE_READ_TIMEOUT_MS } from "../src/files.ts";
import type { ApiResponse } from "../src/host.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const attachmentPath =
  "/v1/comma/groups/g%201/conversations/c/messages/m/attachments/2";
const blobPath = "/v1/comma/groups/g%201/agents/a/resources";
const filesPath = "/v1/comma/groups/g%201/files";
const blobRef = {
  hash: "a".repeat(64),
  kind: "blob" as const,
  size: 3,
  uuid: "b".repeat(32),
};

const bytes = (body: Uint8Array, type?: string): ApiResponse => ({
  status: 200,
  headers: type ? [["content-type", type]] : [],
  body,
});

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  const read = async (source: FileSource, ms = 100, signal?: AbortSignal) => {
    const asked = client.call("files.read", source, undefined, signal).then(
      (value) => ({ value }),
      (error: { code: string; status?: number }) => ({ error })
    );
    await host.time!.pass(ms);
    return asked;
  };
  return { core, time: host.time!, api: host.api, read };
}

describe("a chat file's bytes", () => {
  it("reads a message's attachment, an agent's blob, an uploaded image or the person's avatar, with the type the server gave", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () =>
      bytes(new Uint8Array([1, 2, 3]), "video/mp4")
    );
    t.api.on("POST", blobPath, () => bytes(new Uint8Array([4, 5, 6]), "image/png"));
    t.api.on("GET", filesPath, () => bytes(new Uint8Array([7])));

    expect(
      await t.read({
        source: "attachment",
        group: "g 1",
        conversation: "c",
        message: "m",
        index: 2,
      })
    ).toEqual({ value: { bytes: new Uint8Array([1, 2, 3]), type: "video/mp4" } });
    expect(
      await t.read({ source: "agent-blob", group: "g 1", agent: "a", blobRef })
    ).toEqual({ value: { bytes: new Uint8Array([4, 5, 6]), type: "image/png" } });
    const path = "/uploads/AAAAAAAAAAAAAAAAAAAAAA-chart.png";
    expect(await t.read({ source: "group-file", group: "g 1", path })).toEqual({
      value: { bytes: new Uint8Array([7]), type: "" },
    });

    const [blobRequest] = t.api.seen("POST", blobPath);
    expect(blobRequest!.body).toEqual({ ref: blobRef });
    expect(blobRequest!.headers).toContainEqual(["content-type", "application/json"]);
    expect(t.api.requests.at(-1)!.path).toBe(
      `${filesPath}?${new URLSearchParams({ path })}`
    );

    t.api.on("GET", "/v1/comma/me/avatar/rev%201", () =>
      bytes(new Uint8Array([8]), "image/webp")
    );
    expect(await t.read({ source: "avatar", revision: "rev 1" })).toEqual({
      value: { bytes: new Uint8Array([8]), type: "image/webp" },
    });
  });

  it("asks for nothing it has no source for: a workspace path that is no uploaded image", async () => {
    const t = setup();
    expect(
      await t.read({ source: "group-file", group: "g 1", path: "/etc/passwd" })
    ).toMatchObject({ error: { code: "invalid_params" } });
    expect(t.api.requests).toHaveLength(0);
  });

  it("fails as the server refused it, with no answer from the network, or over 10 MB", async () => {
    const t = setup();
    const source: FileSource = {
      source: "attachment",
      group: "g 1",
      conversation: "c",
      message: "m",
      index: 2,
    };
    t.api.on("GET", attachmentPath, json(404, { error: "attachment_not_found" }));
    expect(await t.read(source)).toMatchObject({
      error: { code: "attachment_not_found", status: 404 },
    });
    t.api.on("GET", attachmentPath, offline());
    expect(await t.read(source)).toMatchObject({ error: { code: "network" } });
    t.api.on("GET", attachmentPath, () => bytes(new Uint8Array(10_000_001)));
    expect(await t.read(source)).toMatchObject({ error: { code: "too_large" } });
    // Each failure was one request: nothing is read again until the person asks.
    expect(t.api.seen("GET", attachmentPath)).toHaveLength(3);
  });

  it("gives a read up after 10 minutes", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () => bytes(new Uint8Array([1])));
    const release = t.api.hold("GET", attachmentPath);
    let settled: unknown;
    void t
      .read(
        {
          source: "attachment",
          group: "g 1",
          conversation: "c",
          message: "m",
          index: 2,
        },
        0
      )
      .then((answer) => (settled = answer));
    await t.time.pass(FILE_READ_TIMEOUT_MS - 1_000, 10_000);
    expect(settled).toBeUndefined();
    await t.time.pass(2_000, 1_000);
    expect(settled).toMatchObject({ error: { code: "timeout" } });
    release();
  });

  it("stops its request when the UI lets the read go", async () => {
    const t = setup();
    let request: AbortSignal | undefined;
    t.api.on("GET", attachmentPath, (_request, signal) => {
      request = signal;
      return new Promise<never>(() => undefined);
    });
    const controller = new AbortController();
    const asked = t.read(
      { source: "attachment", group: "g 1", conversation: "c", message: "m", index: 2 },
      100,
      controller.signal
    );
    await t.time.pass(100);
    expect(request?.aborted).toBe(false);
    controller.abort();
    await t.time.pass(100);
    expect(await asked).toMatchObject({ error: { code: "cancelled" } });
    expect(request?.aborted).toBe(true);
  });

  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () => bytes(new Uint8Array([1, 2]), "text/plain"));
    await t.read({
      source: "attachment",
      group: "g 1",
      conversation: "c",
      message: "m",
      index: 2,
    });
    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
