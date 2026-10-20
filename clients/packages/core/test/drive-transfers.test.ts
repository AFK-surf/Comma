import { COALESCE_MS } from "@comma/core-kernel";
import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { DriveDownloaded, DriveValue } from "../src/contract.ts";
import { HOSTED_SPACE } from "../src/drive/index.ts";
import {
  FakeDesktop,
  FakeHost,
  FakeLocalDrive,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const file = FakeLocalDrive.file;
const SYSTEM = "/v1/comma/groups/grp_w1/system-files";

/** Follows `drive` on a window: its latest value. */
function watch(on: CoreClient) {
  let value: DriveValue | undefined;
  on.subscribe(
    { topic: "drive" },
    (v) => (value = v as DriveValue),
    () => undefined
  );
  return () => value!;
}

/** A desktop with a node (`web`: neither, the hosted Drive instead). */
function setup({ web = false } = {}) {
  const host = new FakeHost();
  const drive = new FakeLocalDrive();
  const desktop = new FakeDesktop();
  if (!web) {
    host.localDrive = drive;
    host.desktop = desktop;
    drive.domain = "w1.sync.test";
  }
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "w1", group_id: "grp_w1", name: "One" }],
  });
  host.api.on("GET", "/v1/comma/workspaces/w1/skills", { data: [] });
  host.api.on("GET", SYSTEM, (request) =>
    json(
      200,
      request.path.includes("memory")
        ? {
            files: [{ path: "/memory/index.md", size: 4, hash: "h1", modified_at: 10 }],
            next_cursor: null,
          }
        : { files: [], next_cursor: null }
    )
  );
  host.api.on("GET", `${SYSTEM}/content`, {
    path: "/memory/index.md",
    content: "note",
    size: 4,
    hash: "h1",
  });
  host.api.on("GET", `${SYSTEM}/instructions`, { content: "" });
  const core = startTestCore(host);
  const open = () =>
    new CoreClient(inProcessOpener(core, host), { schedule: () => undefined });
  const client = open();
  core.observeSession(signedIn());
  const value = watch(client);
  const settle = (ms = 0) => host.time!.pass(ms + COALESCE_MS + 10, 10);
  const id = (name: string) => value().files.find((f) => f.name === name)!.id;
  const rows = () => value().transfers.map((t) => [t.direction, t.fileName, t.status]);
  return { host, core, drive, desktop, client, open, watch, value, settle, id, rows };
}

const pending = <A>(call: Promise<A>) => {
  let done: { ok: A } | { error: unknown } | undefined;
  call.then(
    (ok) => (done = { ok }),
    (error) => (done = { error })
  );
  return () => done;
};

describe("Drive downloads", () => {
  it("streams a node's file into Downloads, and every window lists the transfer", async () => {
    const t = setup();
    t.drive.put("drive", [file("a.txt", 1, { size: 3 })]);
    t.drive.contents.set("drive/a.txt", new Uint8Array([1, 2, 3]));
    await t.settle();
    const other = t.watch(t.open());
    await t.settle();

    const downloaded = await t.client.call("drive.download", { file: t.id("a.txt") });
    expect(downloaded).toEqual({
      transfer: expect.any(String),
      saved: { downloadRef: "download:a.txt", fileName: "a.txt" },
    });
    // The node streamed it; nothing was read through the core.
    expect(t.drive.ran.map(([op]) => op)).not.toContain("read");
    expect(t.drive.downloaded).toEqual([
      { fileName: "a.txt", content: new Uint8Array([1, 2, 3]) },
    ]);
    await t.settle();
    expect(t.rows()).toEqual([["download", "a.txt", "success"]]);
    expect(t.value().transfers[0]).toMatchObject({
      fileId: t.id("a.txt"),
      downloadRef: "download:a.txt",
    });
    expect(other().transfers).toEqual(t.value().transfers);
  });

  it("reads a System File and has Main save its bytes", async () => {
    const t = setup();
    await t.settle();
    const downloaded = await t.client.call("drive.download", {
      file: t.id("index.md"),
    });
    expect(downloaded).toMatchObject({ saved: { fileName: "index.md" } });
    expect(t.desktop.saved).toEqual([
      { fileName: "index.md", content: new TextEncoder().encode("note") },
    ]);
  });

  it("hands the page a hosted file's bytes on the web", async () => {
    const t = setup({ web: true });
    t.host.api.on("GET", "/v1/comma/groups/grp_w1/drive/tree", {
      entries: [{ path: "a.md", name: "a.md", kind: "file", size: 2, modified_at: 5 }],
    });
    t.host.api.on("GET", "/v1/comma/groups/grp_w1/drive/file", {
      status: 200,
      headers: [],
      body: new Uint8Array([104, 105]),
    });
    await t.settle();
    const downloaded = await t.client.call("drive.download", { file: t.id("a.md") });
    expect(downloaded).toEqual({
      transfer: expect.any(String),
      bytes: new Uint8Array([104, 105]),
      mediaType: "text/markdown",
    });
    await t.settle();
    expect(t.value().transfers[0]).toMatchObject({ status: "success" });
    expect(t.value().files[0]!.spaceId).toBe(HOSTED_SPACE);
  });

  it("moves two at a time, and the rest wait their turn", async () => {
    const t = setup();
    t.drive.put("drive", [file("a", 1), file("b", 1), file("c", 1)]);
    await t.settle();
    t.drive.hold();
    const calls = ["a", "b", "c"].map((name) =>
      pending(t.client.call("drive.download", { file: t.id(name) }))
    );
    await t.settle();
    // Two asked the node; the third waits for one of them.
    expect(t.drive.waiting).toBe(2);
    expect(t.rows().map(([, , status]) => status)).toEqual([
      "in_progress",
      "in_progress",
      "in_progress",
    ]);
    t.drive.release();
    await t.settle();
    expect(t.drive.ran.filter(([op]) => op === "saveDownload")).toHaveLength(3);
    expect(calls.every((call) => call() && "ok" in call()!)).toBe(true);
    expect(t.rows().map(([, , status]) => status)).toEqual([
      "success",
      "success",
      "success",
    ]);
  });

  it("marks a failed download, and a retry saves it under the same row", async () => {
    const t = setup();
    t.drive.put("drive", [file("a.txt", 1)]);
    await t.settle();
    t.drive.refuse.add("saveDownload");
    await expect(
      t.client.call("drive.download", { file: t.id("a.txt") })
    ).rejects.toMatchObject({ code: "refused" });
    await t.settle();
    expect(t.rows()).toEqual([["download", "a.txt", "error"]]);

    t.drive.refuse.delete("saveDownload");
    const row = t.value().transfers[0]!.id;
    const retried = (await t.client.call("drive.retryTransfer", {
      transfer: row,
    })) as DriveDownloaded;
    expect(retried).toMatchObject({ transfer: row, saved: { fileName: "a.txt" } });
    await t.settle();
    expect(t.rows()).toEqual([["download", "a.txt", "success"]]);
    // A finished row is not retried.
    await expect(
      t.client.call("drive.retryTransfer", { transfer: row })
    ).rejects.toMatchObject({ code: "not_found" });
  });
});

describe("Drive uploads", () => {
  it("imports staged files into a folder, then lets Main forget them", async () => {
    const t = setup();
    t.drive.put("drive", []);
    t.drive.staged.set("r1", new Uint8Array([1]));
    t.drive.staged.set("r2", new Uint8Array([2, 2]));
    await t.settle();
    expect(
      await t.client.call("drive.upload", {
        space: "drive",
        folderPath: "docs",
        files: [
          { ref: "r1", name: "a.txt" },
          { ref: "r2", name: "b.txt", relativeDir: "pics" },
        ],
      })
    ).toEqual({ uploaded: 2, failed: 0 });
    await t.settle();
    expect(t.drive.contents.get("drive/docs/a.txt")).toEqual(new Uint8Array([1]));
    expect(t.drive.contents.get("drive/docs/pics/b.txt")).toEqual(
      new Uint8Array([2, 2])
    );
    expect(t.drive.staged.size).toBe(0);
    expect(
      t.value().transfers.map((row) => [row.fileName, row.status, row.fileId])
    ).toEqual([
      ["b.txt", "success", "synch:drive:docs/pics/b.txt"],
      ["a.txt", "success", "synch:drive:docs/a.txt"],
    ]);
  });

  it("keeps a failed upload's file for its retry, and releases it when the row is dismissed", async () => {
    const t = setup();
    t.drive.put("drive", []);
    t.drive.staged.set("r1", new Uint8Array([1]));
    t.drive.staged.set("r2", new Uint8Array([2]));
    await t.settle();
    t.drive.refuse.add("importStaged");
    expect(
      await t.client.call("drive.upload", {
        space: "drive",
        files: [
          { ref: "r1", name: "a.txt" },
          { ref: "r2", name: "b.txt" },
        ],
      })
    ).toEqual({ uploaded: 0, failed: 2 });
    await t.settle();
    expect(t.rows()).toEqual([
      ["upload", "b.txt", "error"],
      ["upload", "a.txt", "error"],
    ]);

    t.drive.refuse.delete("importStaged");
    const [b] = t.value().transfers;
    expect(await t.client.call("drive.retryTransfer", { transfer: b!.id })).toBeNull();
    await t.settle();
    expect(t.drive.contents.get("drive/b.txt")).toEqual(new Uint8Array([2]));
    expect([...t.drive.staged.keys()]).toEqual(["r1"]);

    await t.client.call("drive.dismissTransfers", {});
    await t.settle();
    expect(t.value().transfers).toEqual([]);
    expect(t.drive.staged.size).toBe(0);
  });

  it("refuses a path that leaves the space, before any row", async () => {
    const t = setup();
    t.drive.put("drive", []);
    await t.settle();
    await expect(
      t.client.call("drive.upload", {
        space: "drive",
        files: [{ ref: "r1", name: "a.txt", relativeDir: "../out" }],
      })
    ).rejects.toMatchObject({ code: "invalid_params" });
    await t.settle();
    expect(t.value().transfers).toEqual([]);
  });

  it("drops another account's transfers", async () => {
    const t = setup();
    t.drive.put("drive", [file("a.txt", 1)]);
    t.drive.staged.set("r1", new Uint8Array([1]));
    t.drive.refuse.add("importStaged");
    await t.settle();
    await t.client.call("drive.upload", {
      space: "drive",
      files: [{ ref: "r1", name: "a.txt" }],
    });
    await t.settle();
    expect(t.value().transfers).toHaveLength(1);
    t.core.observeSession(signedIn("u2"));
    await t.settle();
    expect(t.value().transfers).toEqual([]);
    expect(t.drive.staged.size).toBe(0);
  });
});
