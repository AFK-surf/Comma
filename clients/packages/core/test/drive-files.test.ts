import { COALESCE_MS } from "@comma/core-kernel";
import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { DriveFileVersion, DriveValue } from "../src/contract.ts";
import { DRIVE_POLL_MS, DRIVE_REFRESH_MS, HOSTED_SPACE } from "../src/drive/index.ts";
import { SYSTEM_SPACE } from "../src/drive/system-files.ts";
import {
  FakeHost,
  FakeLocalDrive,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const file = FakeLocalDrive.file;
const WORKSPACES = "/v1/comma/workspaces";
const SYSTEM = "/v1/comma/groups/grp_w1/system-files";
const STATUS = "/v1/comma/me/synchronicity/status";
const DEVICE = "/v1/comma/me/synchronicity/devices/current";

function setup(drive: FakeLocalDrive | null = new FakeLocalDrive()) {
  const host = new FakeHost();
  /** The memory file's hash on the server. */
  const memory = { hash: "h1" };
  if (drive) host.localDrive = drive;
  host.api.on("GET", WORKSPACES, {
    data: [{ id: "w1", group_id: "grp_w1", name: "One" }],
  });
  host.api.on("GET", "/v1/comma/workspaces/w1/skills", {
    data: [{ skill_id: "sk1", name: "Write/notes", location: "x" }],
  });
  host.api.on("GET", SYSTEM, (request) =>
    json(
      200,
      request.path.includes("memory")
        ? {
            files: [
              { path: "/memory/index.md", size: 4, hash: memory.hash, modified_at: 10 },
            ],
            next_cursor: null,
          }
        : request.path.includes("Comma")
          ? {
              files: [
                { path: "/Comma/Notebook.md", size: 11, hash: "n1", modified_at: 10 },
              ],
              next_cursor: null,
            }
          : { files: [], next_cursor: null }
    )
  );
  host.api.on("GET", `${SYSTEM}/instructions`, { content: "Be kind." });
  // A node named by a zone already: no enrollment unless a test says so.
  if (drive) {
    drive.domain = "w1.sync.test";
    drive.origins = ["here", "there"];
  }
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  let value: DriveValue | undefined;
  const topic: Topic = { topic: "drive" };
  const watch = () =>
    client.subscribe(
      topic,
      (v) => (value = v as DriveValue),
      () => undefined
    );
  const settle = (ms = 0) =>
    host.time!.pass(ms + COALESCE_MS + 10, ms >= 10_000 ? 1_000 : 10);
  void topicKey;
  return {
    host,
    memory,
    drive: drive!,
    client,
    watch,
    settle,
    value: () => value!,
    paths: (space?: string) =>
      value!.files
        .filter((f) => space === undefined || f.spaceId === space)
        .map((f) => (f.folderPath ? `${f.folderPath}/${f.name}` : f.name)),
  };
}

describe("Drive on a device with a node", () => {
  it("waits for the node to start, then lists its spaces, files and devices", async () => {
    const t = setup();
    t.drive.status = "starting";
    t.drive.put("drive", [file("a.txt", 1), file("docs/b.md", 2, { origin: "there" })]);
    t.drive.put("photos", [], "Photos", {
      sourcePath: "",
      replica: true,
      checkoutPath: "",
    });
    t.watch();
    await t.settle();
    expect(t.value().node).toEqual({ status: "starting" });
    t.drive.status = "ready";
    await t.settle(DRIVE_POLL_MS);
    expect(t.value().node).toEqual({ status: "ready" });
    expect(
      t.value().spaces.map((s) => [s.id, s.name, s.protected ?? false, s.synced])
    ).toEqual([
      ["drive", "Drive", true, true],
      ["photos", "Photos", false, false],
      [SYSTEM_SPACE, "", false, undefined],
    ]);
    expect(t.paths("drive")).toEqual(["a.txt", "docs/b.md"]);
    expect(t.value().devices.map((d) => [d.id, d.current, d.label])).toEqual([
      ["here", true, "This test"],
      ["there", false, "there"],
    ]);
    // The workspace's System Files, beside the node's spaces.
    expect(t.paths(SYSTEM_SPACE)).toEqual([
      "memory/index.md",
      "Comma/Notebook.md",
      "Skills/Write-notes.md",
      "Instructions.md",
    ]);
    // Memory files and the instructions are written; Comma's notebook and the skills are read-only.
    expect(
      t
        .value()
        .files.filter((f) => f.spaceId === SYSTEM_SPACE && f.writable)
        .map((f) => f.name)
    ).toEqual(["index.md", "Instructions.md"]);
  });

  it("enrolls a node named by its key once, and lists it under its zone", async () => {
    const t = setup();
    t.drive.domain = "";
    t.drive.origin = "key:abc";
    t.drive.origins = ["key:abc"];
    t.host.api.on("GET", STATUS, {
      status: "ready",
      configured: true,
      provisioned: true,
    });
    t.host.api.on("PUT", DEVICE, { domain: "w1.sync.test" });
    t.drive.put("drive", []);
    t.watch();
    await t.settle();
    expect(t.drive.ran).toContainEqual(["setDomain", { domain: "w1.sync.test" }]);
    expect(t.value().originDeviceId).toBe("here@w1.sync.test");
    await t.settle(DRIVE_REFRESH_MS);
    expect(t.host.api.seen("PUT", DEVICE)).toHaveLength(1);
  });

  it("reads the listing again every 20 s, after the files changed, and on refresh", async () => {
    const t = setup();
    t.drive.put("drive", [file("a.txt", 1)]);
    t.watch();
    await t.settle();
    const pages = t.drive.pages;
    t.drive.put("drive", [file("a.txt", 1), file("new.txt", 2)]);
    t.drive.change();
    t.drive.change();
    await t.settle(200);
    expect(t.paths("drive")).toEqual(["a.txt", "new.txt"]);
    expect(t.drive.pages).toBe(pages + 1);
    await t.client.call("drive.refresh", {});
    await t.settle();
    expect(t.drive.pages).toBe(pages + 2);
    await t.settle(DRIVE_REFRESH_MS);
    expect(t.drive.pages).toBe(pages + 3);
  });

  it("reads a diverged path's copies and settles it on one", async () => {
    const t = setup();
    t.drive.put("drive", [file("a.txt", 1, { versions: 2 })]);
    t.drive.versions.set("drive/a.txt", [
      { attestors: ["there"], kind: "file", root: "r-there", seq: 2, size: 5 },
      { attestors: ["here"], kind: "file", root: "r-here", seq: 1, size: 3 },
    ]);
    t.watch();
    await t.settle();
    const id = t.value().files[0]!.id;
    const versions = (await t.client.call("drive.versions", {
      file: id,
    })) as DriveFileVersion[];
    expect(versions.map((v) => [v.deviceId, v.contentsHash])).toEqual([
      ["here", "r-here"],
      ["there", "r-there"],
    ]);
    await t.settle();
    expect(t.value().files[0]!.versions).toHaveLength(2);
    await t.client.call("drive.settle", { file: id, version: versions[1]!.id });
    expect(t.drive.ran).toContainEqual([
      "adopt",
      { space: "drive", path: "a.txt", select: "origin=there" },
    ]);
  });

  it("deletes, pins and writes files, and reads one in ranges from one object", async () => {
    const t = setup();
    t.drive.put("drive", [file("a.txt", 1), file("b.txt", 2)]);
    t.drive.contents.set("drive/a.txt", new Uint8Array([1, 2, 3]));
    t.watch();
    await t.settle();
    const [a, b] = t.value().files;
    expect(await t.client.call("drive.read", { file: a!.id })).toEqual({
      bytes: new Uint8Array([1, 2, 3]),
      mediaType: "text/plain",
    });
    await t.client.call("drive.keepOffline", { files: [a!.id], keepOffline: true });
    await t.client.call("drive.delete", { files: [b!.id] });
    await t.client.call("drive.write", {
      space: "drive",
      folderPath: "notes",
      name: "c.md",
      bytes: new Uint8Array([7]),
    });
    await t.settle();
    expect(t.paths("drive")).toEqual(["a.txt", "notes/c.md"]);
    expect(t.value().files.find((f) => f.id === a!.id)?.keepOffline).toBe(true);
    await expect(
      t.client.call("drive.write", {
        space: "drive",
        name: "..",
        bytes: new Uint8Array(),
      })
    ).rejects.toMatchObject({ code: "invalid_params" });
  });

  it("reads the install's own space from the node, though the hosted Drive has its id", async () => {
    const t = setup();
    t.drive.put(HOSTED_SPACE, [file("a.txt", 1)]);
    t.drive.contents.set(`${HOSTED_SPACE}/a.txt`, new Uint8Array([4, 5]));
    t.watch();
    await t.settle();
    expect(await t.client.call("drive.read", { file: t.value().files[0]!.id })).toEqual(
      {
        bytes: new Uint8Array([4, 5]),
        mediaType: "text/plain",
      }
    );
  });

  it("adds, renames and removes spaces, and keeps the install's own", async () => {
    const t = setup();
    t.drive.put("drive", []);
    t.watch();
    await t.settle();
    expect(await t.client.call("drive.addSpace", {})).toBeNull();
    t.drive.picked = "/Users/me/Field Recordings";
    expect(await t.client.call("drive.addSpace", {})).toEqual({
      space: "field-recordings",
      name: "Field Recordings",
      path: "/Users/me/Field Recordings",
    });
    await t.client.call("drive.renameSpace", {
      space: "field-recordings",
      name: "Field",
    });
    await t.settle();
    expect(t.value().spaces.find((s) => s.id === "field-recordings")?.name).toBe(
      "Field"
    );
    await t.client.call("drive.removeSpace", { space: "field-recordings" });
    await expect(
      t.client.call("drive.removeSpace", { space: "drive" })
    ).rejects.toMatchObject({
      code: "invalid_params",
    });
    await t.settle();
    expect(t.value().spaces.map((s) => s.id)).toEqual(["drive", SYSTEM_SPACE]);
  });

  it("syncs a published space, records what landed and what conflicts, and retries the conflicts", async () => {
    const t = setup();
    t.drive.put(
      "work",
      [
        file("mine.txt", 1, { origin: "here" }),
        file("theirs.txt", 2, { origin: "there" }),
        file("both.txt", 3, { origin: "there", versions: 2 }),
      ],
      "Work",
      { sourcePath: "/Users/me/Work", sourcePaused: true, autoAdopt: false }
    );
    t.watch();
    await t.settle();
    expect(
      await t.client.call("drive.setSpaceSynced", { space: "work", synced: true })
    ).toEqual({
      adopt: 1,
      current: 1,
      differing: 1,
      skipped: 0,
    });
    await t.settle();
    expect(
      t
        .value()
        .syncHistory.map((e) => [
          e.kind,
          e.name,
          e.operation,
          e.status,
          e.reason ?? null,
        ])
    ).toEqual([
      ["file", "both.txt", "updated", "failed", "conflict"],
      ["file", "theirs.txt", "added", "success", null],
      ["folder", "Work", "added", "success", null],
    ]);
    await t.client.call("drive.retrySync", {});
    await t.settle();
    expect(t.value().syncHistory[0]).toMatchObject({
      name: "both.txt",
      status: "success",
    });
    expect(t.value().syncHistory.find((e) => e.status === "failed")?.resolved).toBe(
      true
    );
  });

  it("restarts a node that could not start once Drive is shown", async () => {
    const t = setup();
    t.drive.status = "error";
    t.drive.reason = "start timed out";
    t.watch();
    await t.settle();
    await t.settle(DRIVE_POLL_MS);
    expect(t.value().node).toEqual({ status: "ready" });
    expect(t.drive.ran.filter(([op]) => op === "restart")).toHaveLength(1);
  });

  it("restarts a node that still cannot start after a backoff, five times each time Drive comes back", async () => {
    const t = setup();
    t.drive.status = "error";
    t.drive.reason = "no disk";
    t.drive.refuse.add("restart");
    const restarts = () => t.drive.ran.filter(([op]) => op === "restart").length;
    t.watch();
    await t.settle();
    await t.settle(DRIVE_POLL_MS);
    expect(restarts()).toBe(1);
    expect(t.value().node).toEqual({ status: "error", reason: "no disk" });
    // Again after 5, 10, 20 and 40 s.
    for (const [index, wait] of [5_000, 10_000, 20_000, 40_000].entries()) {
      await t.settle(wait / 2);
      expect(restarts()).toBe(index + 1);
      await t.settle(wait / 2 + DRIVE_POLL_MS);
      expect(restarts()).toBe(index + 2);
    }
    // Five is the most: the error stays until Drive comes back to the front or is asked.
    await t.settle(DRIVE_REFRESH_MS * 4);
    expect(restarts()).toBe(5);
    expect(t.value().node).toEqual({ status: "error", reason: "no disk" });
    expect(
      t.host.time!.sleeps.filter((ms) =>
        [5_000, 10_000, 20_000, 40_000, 80_000].includes(ms)
      )
    ).toEqual([5_000, 10_000, 20_000, 40_000]);
    await t.client.call("drive.refresh", {});
    await t.settle(DRIVE_POLL_MS);
    expect(restarts()).toBe(6);
    t.drive.refuse.delete("restart");
    await t.client.call("drive.restart", {});
    await t.settle();
    expect(t.value().node).toEqual({ status: "ready" });
  });

  it("lists another device's copies on request", async () => {
    const t = setup();
    t.drive.put("drive", [file("a.txt", 1)]);
    t.watch();
    await t.settle();
    await t.client.call("drive.setView", { originDeviceId: "there" });
    await t.settle();
    expect(t.value().originDeviceId).toBe("there");
  });
});

describe("Drive on the web", () => {
  it("shows the Workspace's hosted Drive, read-only, and reads its files", async () => {
    const t = setup(null);
    t.host.api.on("GET", "/v1/comma/groups/grp_w1/drive/tree", {
      entries: [
        { path: "docs", name: "docs", kind: "dir", size: 0 },
        { path: "docs/a.md", name: "a.md", kind: "file", size: 2, modified_at: 5 },
      ],
      truncated: false,
    });
    t.host.api.on("GET", "/v1/comma/groups/grp_w1/drive/file", {
      status: 200,
      headers: [],
      body: new Uint8Array([104, 105]),
    });
    t.watch();
    await t.settle();
    expect(t.value().node).toEqual({ status: "off" });
    expect(t.value().spaces.map((s) => [s.id, s.writable])).toEqual([
      [HOSTED_SPACE, false],
      [SYSTEM_SPACE, false],
    ]);
    expect(t.paths(HOSTED_SPACE)).toEqual(["docs/a.md"]);
    const id = t.value().files[0]!.id;
    expect(await t.client.call("drive.read", { file: id })).toEqual({
      bytes: new Uint8Array([104, 105]),
      mediaType: "text/markdown",
    });
    await expect(t.client.call("drive.delete", { files: [id] })).rejects.toMatchObject({
      code: "unavailable",
    });
  });
});

describe("Drive's System Files", () => {
  it("saves a memory file if it still holds what was read, and says when the Router changed it", async () => {
    const t = setup(null);
    t.host.api.on("GET", "/v1/comma/groups/grp_w1/drive/tree", { entries: [] });
    t.host.api.on("PUT", `${SYSTEM}/content`, (request) => {
      const body = request.body as { expected_hash?: string };
      if (body.expected_hash !== t.memory.hash) return json(409, { code: "conflict" });
      t.memory.hash = "h2";
      return json(200, { path: "/memory/index.md", size: 3, hash: t.memory.hash });
    });
    t.host.api.on("GET", `${SYSTEM}/content`, () =>
      json(200, {
        path: "/memory/index.md",
        content: "new",
        size: 3,
        hash: t.memory.hash,
      })
    );
    t.watch();
    await t.settle();
    await t.client.call("drive.write", {
      space: SYSTEM_SPACE,
      folderPath: "memory",
      name: "index.md",
      bytes: new TextEncoder().encode("abc"),
      expectedHash: "h1",
    });
    await t.settle();
    const saved = t.value().files.find((f) => f.id === "system:memory/index.md")!;
    expect(saved.system).toMatchObject({ hash: "h2" });
    // The Router writes it again: a save naming the old version is refused with the one now there.
    t.memory.hash = "h3";
    await expect(
      t.client.call("drive.write", {
        space: SYSTEM_SPACE,
        folderPath: "memory",
        name: "index.md",
        bytes: new TextEncoder().encode("old"),
        expectedHash: "h2",
      })
    ).rejects.toMatchObject({ code: "changed", detail: { hash: "h3" } });
    await t.settle();
    expect(
      t.value().files.find((f) => f.id === "system:memory/index.md")!.system
    ).toMatchObject({
      hash: "h3",
    });
  });

  it("replaces the Router's instructions if they still hold what was read, and clears them on delete", async () => {
    const t = setup(null);
    const instructions = { content: "Be kind.", hash: "i1" };
    t.host.api.on("GET", "/v1/comma/groups/grp_w1/drive/tree", { entries: [] });
    t.host.api.on("GET", `${SYSTEM}/instructions`, () => json(200, instructions));
    t.host.api.on("PUT", `${SYSTEM}/instructions`, (request) => {
      const body = request.body as { content: string; expected_hash?: string };
      if (body.expected_hash !== instructions.hash)
        return json(409, { code: "conflict" });
      instructions.content = body.content;
      instructions.hash = `i-${body.content}`;
      return json(200, instructions);
    });
    t.watch();
    await t.settle();
    const listed = () =>
      t.value().files.find((f) => f.id === "system:Instructions.md")!;
    expect(listed().system).toMatchObject({ kind: "instructions", hash: "i1" });
    await t.client.call("drive.write", {
      space: SYSTEM_SPACE,
      name: "Instructions.md",
      bytes: new TextEncoder().encode("Be brief."),
      expectedHash: "i1",
    });
    await t.settle();
    expect(listed().system).toMatchObject({ hash: "i-Be brief." });
    // An edit from the earlier read does not overwrite the saved one.
    await expect(
      t.client.call("drive.write", {
        space: SYSTEM_SPACE,
        name: "Instructions.md",
        bytes: new TextEncoder().encode("Be long."),
        expectedHash: "i1",
      })
    ).rejects.toMatchObject({ code: "changed", detail: { hash: "i-Be brief." } });
    await t.client.call("drive.delete", { files: ["system:Instructions.md"] });
    await t.settle();
    expect(instructions.content).toBe("");
    expect(listed().system).toMatchObject({ hash: "i-" });
  });
});
