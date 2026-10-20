// Files of an archived workspace through the admin API (admin/files.rs `session_file` and `attachments`): read out of
// its archive under the room's lock, a file sent again taken back out of it.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Admin } from "../src/api/admin.ts";
import type { Request } from "../src/api/request.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { tr } from "../src/ops/i18n.ts";
import { Readers } from "../src/read/pool.ts";
import { packWorkspace, withLock, workspaceArchive } from "../src/sessions/archive.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { roomOf } from "../src/sessions/footprint.ts";
import { Hub } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { Store } from "../src/store/store.ts";
import { FakeDriver } from "./hub-fakes.ts";

const viewer = { sub: "u", email: "a@x", name: "A", role: "member", workspace: "w", device: "d" };

test("an archived workspace's uploads: shown from its archive, and sent again from it", async () => {
  const data = mkdtempSync(join(tmpdir(), "cold-routes-"));
  const config = hubConfig({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["opus"] }] }, data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [new FakeDriver("claude")], mcpUrl: "http://127.0.0.1:1/mcp", internal: new InternalChat(), runners: () => [] });
  const jobs = new Jobs({ store, data, notify: () => {}, link: () => null });
  hub.setJobs(jobs);
  const readers = new Readers(data, 1);
  const admin = new Admin(readers, { store, agents: { hub, jobs } as any });
  const ask = async (method: string, path: string, body?: unknown, query: [string, string][] = []) => {
    const r: Request = { method, path, query, headers: {}, body: Buffer.from(body === undefined ? "" : JSON.stringify(body)), viewer, lang: "en" };
    return admin.handle(r);
  };
  try {
    const made = JSON.parse(String((await ask("POST", "/sessions", { runtime: "claude" })).body));
    const workspace = store.getSession(made.key)!.workspace;
    mkdirSync(join(workspace, "uploads/sub"), { recursive: true });
    writeFileSync(join(workspace, "uploads/note.txt"), "kept in the archive");
    writeFileSync(join(workspace, "uploads/sub/deeper.txt"), "nested");
    const room = roomOf(data, workspace)!;
    await withLock(room, () => packWorkspace(room));
    assert.ok(existsSync(workspaceArchive(room)) && !existsSync(join(workspace, "uploads/note.txt")));

    const shown = await ask("GET", `/sessions/${made.key}/files`, undefined, [["name", "note.txt"]]);
    assert.equal(shown.status, 200);
    assert.equal(shown.headers?.["content-type"], "text/plain; charset=utf-8");
    assert.equal(String(shown.body), "kept in the archive");
    const thumb = await ask("GET", `/sessions/${made.key}/files`, undefined, [["name", "note.txt"], ["thumb", "1"]]);
    assert.equal(String(thumb.body), "kept in the archive");
    const missing = await ask("GET", `/sessions/${made.key}/files`, undefined, [["name", "nothing.txt"]]);
    assert.equal(missing.status, 404);
    assert.deepEqual(JSON.parse(String(missing.body)), { error: tr("en", "station.files.notFound") });

    const id = made.thread.id;
    const sent = await ask("POST", `/threads/${id}/messages`, {
      text: "again",
      attachments: [{ path: join(workspace, "uploads/note.txt") }, { path: join(workspace, "uploads/sub/deeper.txt") }],
    });
    assert.equal(sent.status, 200, String(sent.body));
    assert.equal(readFileSync(join(workspace, "uploads/note.txt"), "utf8"), "kept in the archive", "taken back out of the archive");
    assert.equal(readFileSync(join(workspace, "uploads/sub/deeper.txt"), "utf8"), "nested");
    const refused = await ask("POST", `/threads/${id}/messages`, { attachments: [{ path: join(workspace, "uploads/never.txt") }] });
    assert.equal(refused.status, 400);
  } finally {
    await hub.shutdown();
    await jobs.shutdown();
    readers.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

test("a big file in parts, a whole one streamed, a video's poster or none", async () => {
  const data = mkdtempSync(join(tmpdir(), "file-parts-"));
  const config = hubConfig({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["opus"] }] }, data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [new FakeDriver("claude")], mcpUrl: "http://127.0.0.1:1/mcp", internal: new InternalChat(), runners: () => [] });
  const jobs = new Jobs({ store, data, notify: () => {}, link: () => null });
  hub.setJobs(jobs);
  const readers = new Readers(data, 1);
  const admin = new Admin(readers, { store, agents: { hub, jobs } as any });
  const ask = async (method: string, path: string, body?: unknown, query: [string, string][] = []) => {
    const r: Request = { method, path, query, headers: {}, body: Buffer.from(body === undefined ? "" : JSON.stringify(body)), viewer, lang: "en" };
    return admin.handle(r);
  };
  const whole = async (body: Buffer | AsyncIterable<Buffer>) => {
    if (Buffer.isBuffer(body)) return body;
    const parts: Buffer[] = [];
    for await (const b of body) parts.push(Buffer.from(b));
    return Buffer.concat(parts);
  };
  try {
    const made = JSON.parse(String((await ask("POST", "/sessions", { runtime: "claude" })).body));
    const workspace = store.getSession(made.key)!.workspace;
    mkdirSync(join(workspace, "uploads"), { recursive: true });
    const big = Buffer.alloc(9 * 1024 * 1024 + 5);
    for (let i = 0; i < big.length; i++) big[i] = i % 251;
    writeFileSync(join(workspace, "uploads/big.bin"), big);

    // Whole: over 8 MB it is streamed, not read into memory first.
    const shown = await ask("GET", `/sessions/${made.key}/files`, undefined, [["name", "big.bin"]]);
    assert.equal(shown.status, 200);
    assert.ok(!Buffer.isBuffer(shown.body), "streamed");
    assert.ok((await whole(shown.body)).equals(big));

    const part = (offset: number, length: number) => ask("GET", `/sessions/${made.key}/parts`, undefined, [["name", "big.bin"], ["offset", String(offset)], ["length", String(length)]]);
    const first = await part(0, 4);
    assert.equal(first.status, 200);
    assert.equal(first.headers["stillfail-total"], String(big.length));
    assert.ok((await whole(first.body)).equals(big.subarray(0, 4)));
    // At the end: what is left; past it: nothing.
    assert.ok((await whole((await part(big.length - 3, 8)).body)).equals(big.subarray(big.length - 3)));
    assert.equal((await whole((await part(big.length + 10, 8)).body)).length, 0);
    assert.equal((await part(0, 8 * 1024 * 1024 + 1)).status, 400);
    assert.equal((await ask("GET", `/sessions/${made.key}/parts`, undefined, [["name", "../x"]])).status, 404);

    // A poster: none for what is not a video, nor for a video none can be read from.
    writeFileSync(join(workspace, "uploads/clip.mp4"), "not really a video");
    assert.equal((await ask("GET", `/sessions/${made.key}/poster`, undefined, [["name", "big.bin"]])).status, 404);
    assert.equal((await ask("GET", `/sessions/${made.key}/poster`, undefined, [["name", "clip.mp4"]])).status, 404);
  } finally {
    await hub.shutdown();
    await jobs.shutdown();
    readers.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});
