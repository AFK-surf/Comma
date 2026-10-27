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
import { FakeDesktop } from "../src/testing/fake-desktop.ts";

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
  return { core, client, time: host.time!, api: host.api, read };
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

  it("asks an attachment for no more than its bound, and fails a larger one from the size it names", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () => ({
      status: 206,
      headers: [
        ["content-type", "application/pdf"],
        ["content-range", "bytes 0-10000000/40000000"],
      ],
      body: new Uint8Array(10_000_001),
    }));
    expect(await t.read(savedAttachment)).toMatchObject({
      error: { code: "too_large" },
    });
    expect(t.api.seen("GET", attachmentPath)[0]?.headers).toContainEqual([
      "range",
      "bytes=0-10000000",
    ]);
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

describe("a span of a chat file", () => {
  const span = async (
    source: FileSource,
    offset: number,
    length: number,
    answer: (t: ReturnType<typeof setup>) => void
  ) => {
    const t = setup();
    answer(t);
    const asked = t.client.call("files.readRange", { source, offset, length }).then(
      (value) => ({ value }),
      (error: { code: string }) => ({ error })
    );
    await t.time.pass(100);
    return { seen: t.api, result: await asked };
  };

  it("asks an attachment for just the span, and learns the file's size from the answer", async () => {
    const { seen, result } = await span(savedAttachment, 4, 3, (t) =>
      t.api.on("GET", attachmentPath, () => ({
        status: 206,
        headers: [
          ["content-type", "text/plain"],
          ["content-range", "bytes 4-6/12000000"],
        ],
        body: new Uint8Array([5, 6, 7]),
      }))
    );
    expect(result).toEqual({
      value: { bytes: new Uint8Array([5, 6, 7]), type: "text/plain", size: 12_000_000 },
    });
    expect(seen.seen("GET", attachmentPath)[0]?.headers).toContainEqual([
      "range",
      "bytes=4-6",
    ]);
  });

  it("cuts the span from a whole answer, and is empty past the end", async () => {
    const blob: FileSource = {
      source: "agent-blob",
      group: "g 1",
      agent: "a",
      blobRef,
    };
    const whole = await span(blob, 1, 5, (t) =>
      t.api.on("POST", blobPath, () => bytes(new Uint8Array([1, 2, 3]), "text/csv"))
    );
    expect(whole.result).toEqual({
      value: { bytes: new Uint8Array([2, 3]), type: "text/csv", size: 3 },
    });

    const past = await span(savedAttachment, 9, 4, (t) =>
      t.api.on("GET", attachmentPath, json(416, { error: "range_not_satisfiable" }))
    );
    expect(past.result).toEqual({
      value: { bytes: new Uint8Array(), type: "", size: 9 },
    });
  });
});

function saving({ desktop = true } = {}) {
  const host = new FakeHost();
  const fake = new FakeDesktop();
  if (desktop) host.desktop = fake;
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  host.api.on(
    "POST",
    `${attachmentPath}/media`,
    json(200, {
      url: "https://blobs.example.test/b/clip?X-Amz-Signature=s",
      expires_at: 4_102_444_800,
    })
  );
  const save = async (source: FileSource, name = "clip.mp4") => {
    const asked = client.call("files.save", { source, name }).then(
      (value) => ({ value }),
      (error: { code: string; status?: number }) => ({ error })
    );
    await host.time!.pass(100);
    return asked;
  };
  return { desktop: fake, api: host.api, save };
}

const savedAttachment: FileSource = {
  source: "attachment",
  group: "g 1",
  conversation: "c",
  message: "m",
  index: 2,
};

describe("a chat file a browser downloads itself", () => {
  const link = async (source: FileSource, { desktop = false } = {}) => {
    const host = new FakeHost();
    if (desktop) host.desktop = new FakeDesktop();
    const core = startTestCore(host);
    const client = new CoreClient(inProcessOpener(core, host), {
      schedule: () => undefined,
    });
    core.observeSession(signedIn());
    host.api.on(
      "POST",
      `${attachmentPath}/media`,
      json(200, {
        url: "https://blobs.example.test/b/clip?X-Amz-Signature=t1",
        expires_at: 4_102_444_800,
      })
    );
    const asked = client.call("files.link", source).then(
      (value) => ({ value }),
      (error: { code: string }) => ({ error })
    );
    await host.time!.pass(100);
    return { api: host.api, result: await asked };
  };

  it("is a message attachment's media URL, which the blob store signed", async () => {
    const { api, result } = await link(savedAttachment);
    expect(result).toEqual({
      value: { url: "https://blobs.example.test/b/clip?X-Amz-Signature=t1" },
    });
    expect(api.seen("POST", `${attachmentPath}/media`)).toHaveLength(1);
  });

  it("is unsupported on the desktop, which saves through Main, and for other sources", async () => {
    expect((await link(savedAttachment, { desktop: true })).result).toEqual({
      error: expect.objectContaining({ code: "unsupported" }),
    });
    expect(
      (await link({ source: "agent-blob", group: "g 1", agent: "a", blobRef })).result
    ).toEqual({ error: expect.objectContaining({ code: "unsupported" }) });
  });
});

describe("a chat file saved into Downloads", () => {
  it("is written by Main as it arrives from the attachment's media URL, never read by the core or the API", async () => {
    const t = saving();
    expect(await t.save(savedAttachment)).toEqual({
      value: { downloadRef: "download:clip.mp4", fileName: "clip.mp4" },
    });
    expect(t.desktop.streamedSaves).toEqual([
      {
        url: "https://blobs.example.test/b/clip?X-Amz-Signature=s",
        fileName: "clip.mp4",
      },
    ]);
    expect(t.api.requests.filter((request) => request.path === attachmentPath)).toEqual(
      []
    );
  });

  it("reads any other file through the API under the session", async () => {
    const t = saving();
    await t.save({ source: "avatar", revision: "rev 1" }, "me.png");
    expect(t.desktop.streamedSaves).toEqual([
      {
        path: "/v1/comma/me/avatar/rev%201",
        fileName: "me.png",
        lease: expect.objectContaining({ sessionId: "session-user-1" }),
      },
    ]);
  });

  it("fails as the server refused it", async () => {
    const t = saving();
    t.desktop.saveStreamed = () => ({ status: 404, code: "not_found" });
    expect(await t.save(savedAttachment)).toEqual({
      error: expect.objectContaining({ code: "not_found", status: 404 }),
    });
  });

  it("is unsupported without Downloads, and only for a file read with a GET", async () => {
    expect(await saving({ desktop: false }).save(savedAttachment)).toEqual({
      error: expect.objectContaining({ code: "unsupported" }),
    });
    const t = saving();
    expect(
      await t.save({ source: "agent-blob", group: "g 1", agent: "a", blobRef })
    ).toEqual({ error: expect.objectContaining({ code: "invalid_params" }) });
    expect(t.desktop.streamedSaves).toEqual([]);
  });
});
