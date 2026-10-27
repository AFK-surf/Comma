import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { NodeSql } from "@comma/core-kernel/node-sql";
import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { accountDbName } from "../src/account.ts";
import type { DownloadValue, FileSource } from "../src/contract.ts";
import { fileKey } from "../src/downloads.ts";
import {
  FakeDownloads,
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  signedOut,
  startTestCore,
} from "../src/testing/index.ts";

const attachmentPath = "/v1/comma/groups/g/conversations/c/messages/m/attachments/2";
const blobPath = "/v1/comma/groups/g/agents/a/resources";
const clip = new Uint8Array([1, 2, 3, 4]);
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const attachment: FileSource = {
  source: "attachment",
  group: "g",
  conversation: "c",
  message: "m",
  index: 2,
};
const blob: FileSource = {
  source: "agent-blob",
  group: "g",
  agent: "a",
  blobRef: {
    hash: sha256(clip),
    kind: "blob",
    size: clip.length,
    uuid: "b".repeat(32),
  },
};

/** The session while the core still finds out who is signed in. */
const starting = {
  authority: { authorityInstanceId: "authority-1", kind: "electron_main" },
  cleanup: { revocation: "idle" },
  contractVersion: 1,
  generation: 0,
  revision: 0,
  phase: "initializing",
  principal: null,
  session: null,
};

function setup(
  host = new FakeHost(),
  downloads = new FakeDownloads(host.api),
  sessions: unknown[] = [signedIn()]
) {
  host.downloads = downloads;
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = (source: FileSource) => {
    const topic: Topic = { topic: "download", source: JSON.stringify(source) };
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as DownloadValue;
  };
  const call = async (
    name: "downloads.start" | "downloads.cancel",
    params: unknown
  ) => {
    const done = client.call(name, params as never);
    await host.time!.pass(100);
    return done;
  };
  for (const session of sessions) core.observeSession(session);
  return { host, core, downloads, time: host.time!, api: host.api, watch, call };
}

describe("a file downloaded to the device", () => {
  it("goes out for the session as it is now, a new generation of the same one", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () => ({ status: 200, headers: [], body: clip }));
    const shown = t.watch(attachment);
    await t.time.pass(100);
    t.core.observeSession(signedIn("user-1", { generation: 2 }));
    await t.time.pass(100);

    await t.call("downloads.start", { source: attachment, name: "clip.mp4" });
    await t.time.pass(100);
    expect(t.downloads.requests.map((request) => request.lease.generation)).toEqual([
      2,
    ]);
    expect(shown().status).toBe("ready");
  });

  it("is downloaded once into the account's directory, and is ready there for every surface", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () => ({ status: 200, headers: [], body: clip }));
    const shown = t.watch(attachment);
    const again = t.watch(attachment);
    await t.time.pass(100);
    expect(shown().status).toBe("idle");
    expect(
      await t.call("downloads.start", { source: attachment, name: "clip.mp4" })
    ).toEqual({ asked: 1 });
    // A surface asking again hears the count from which the state answers its call.
    expect(
      await t.call("downloads.start", { source: attachment, name: "clip.mp4" })
    ).toEqual({ asked: 2 });
    expect(shown().asked).toBe(2);
    expect(t.api.seen("GET", attachmentPath)).toHaveLength(1);
    expect(shown()).toMatchObject({ status: "ready", received: 4, total: 4 });
    expect(again()).toEqual(shown());
    const path = shown().path!;
    expect(path).toMatch(/^[^/]+\/a[0-9a-f]{16}\/clip\.mp4$/);
    expect(t.downloads.files.get(path)).toEqual(clip);
  });

  it("keeps only the file it asked for: another size or hash is removed and unavailable", async () => {
    const t = setup();
    t.api.on("POST", blobPath, () => ({
      status: 200,
      headers: [],
      body: new Uint8Array([9]),
    }));
    const shown = t.watch(blob);
    await t.call("downloads.start", {
      source: blob,
      name: "chart.png",
      expect: { size: clip.length, sha256: sha256(clip) },
    });
    expect(shown()).toMatchObject({
      status: "failed",
      failure: "unavailable",
      path: null,
    });
    expect(t.downloads.files.size).toBe(0);
    expect(t.api.seen("POST", blobPath)[0]!.body).toEqual({
      ref: blob.source === "agent-blob" && blob.blobRef,
    });
  });

  it("says a refusal unavailable and anything else worth starting again", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () => json(404, { error: "not_found" }));
    const shown = t.watch(attachment);
    await t.call("downloads.start", { source: attachment, name: "clip.mp4" });
    expect(shown()).toMatchObject({ status: "failed", failure: "unavailable" });
    t.api.on("GET", attachmentPath, () => json(503, { error: "busy" }));
    await t.call("downloads.start", { source: attachment, name: "clip.mp4" });
    expect(shown()).toMatchObject({ status: "failed", failure: "network" });
    t.api.on("GET", attachmentPath, () => ({ status: 200, headers: [], body: clip }));
    await t.call("downloads.start", { source: attachment, name: "clip.mp4" });
    expect(shown().status).toBe("ready");
  });

  it("stops a download that is cancelled, and keeps nothing of it", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () => ({ status: 200, headers: [], body: clip }));
    const release = t.api.hold("GET", attachmentPath);
    const shown = t.watch(attachment);
    await t.call("downloads.start", { source: attachment, name: "clip.mp4" });
    expect(shown().status).toBe("downloading");
    await t.call("downloads.cancel", { source: attachment });
    release();
    await t.time.pass(100);
    expect(shown().status).toBe("idle");
    expect(t.downloads.files.size).toBe(0);
  });

  it("keeps the account's files when the core starts again: before it knows who is signed in, and while their data opens", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () => ({ status: 200, headers: [], body: clip }));
    const before = t.watch(attachment);
    await t.call("downloads.start", { source: attachment, name: "clip.mp4" });
    const path = before().path!;
    t.core.close();
    t.host.openDbMs = 20;
    const again = setup(t.host, t.downloads, [starting, signedIn()]);
    const shown = again.watch(attachment);
    await again.time.pass(100);
    expect(again.downloads.files.get(path)).toEqual(clip);
    expect(shown()).toMatchObject({ status: "ready", path });
  });

  it("drops the index an earlier core kept for files it had removed: they download again when shown", async () => {
    const host = new FakeHost();
    const name = accountDbName("https://api.comma.test", "user-1");
    const db = NodeSql.memory(true);
    db.exec(`
      CREATE TABLE doc (name TEXT PRIMARY KEY, json TEXT NOT NULL, read_at INTEGER NOT NULL);
      CREATE TABLE meta (key TEXT PRIMARY KEY, json TEXT NOT NULL);
      PRAGMA user_version = 1;
    `);
    const key = fileKey(attachment);
    const kept = {
      [key]: { path: `${name}/${key}/clip.mp4`, size: clip.length, usedAt: 1_000 },
    };
    db.run("INSERT INTO doc (name, json, read_at) VALUES (?, ?, ?)", [
      "downloads",
      JSON.stringify(kept),
      1_000,
    ]);
    host.dbs.set(name, db);
    const t = setup(host);
    t.api.on("GET", attachmentPath, () => ({ status: 200, headers: [], body: clip }));
    const shown = t.watch(attachment);
    await t.time.pass(100);
    expect(shown().status).toBe("idle");
    await t.call("downloads.start", { source: attachment, name: "clip.mp4" });
    expect(shown()).toMatchObject({ status: "ready", path: `${name}/${key}/clip.mp4` });
    expect(t.downloads.files.get(shown().path!)).toEqual(clip);
  });

  it("removes another account's files when the session changes, and every file once signed out", async () => {
    const t = setup();
    t.api.on("GET", attachmentPath, () => ({ status: 200, headers: [], body: clip }));
    const shown = t.watch(attachment);
    await t.call("downloads.start", { source: attachment, name: "clip.mp4" });
    const first = shown().path!;
    t.core.observeSession(signedIn("user-2"));
    await t.time.pass(100);
    expect(t.downloads.files.has(first)).toBe(false);
    expect(shown().status).toBe("idle");
    await t.call("downloads.start", { source: attachment, name: "clip.mp4" });
    expect([...t.downloads.files.keys()]).toEqual([shown().path]);
    t.core.observeSession(signedOut());
    await t.time.pass(100);
    expect(t.downloads.files.size).toBe(0);
  });
});
