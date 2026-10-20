// Cold storage's files (the Rust station's archive.rs and footprint.rs tests), and the tar it writes and reads.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import fsModule from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { zstdDecompressSync } from "node:zlib";
import {
  jsonlFiles,
  lock,
  packFile,
  packFileIf,
  packWorkspace,
  packWorkspaceIf,
  packed,
  restoreFile,
  restoreWorkspace,
  storage,
  withExtension,
  withLock,
  workspaceArchive,
  workspaceFile,
} from "../src/sessions/archive.ts";
import { measureRoom, measured, rebuildable, roomOf, safeToRemove } from "../src/sessions/footprint.ts";
import { settle } from "./hub-fakes.ts";

const temp = () => realpathSync(mkdtempSync(join(tmpdir(), "cold-")));
const write = (path: string, bytes: string | Buffer) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
};
const rejects = async (p: Promise<unknown>) => {
  try {
    await p;
  } catch {
    return true;
  }
  return false;
};

test("workspace round trip preserves edits, permissions, symlinks and attachments", async () => {
  const room = temp();
  const ws = join(room, "workspace");
  write(join(ws, "project/uncommitted.rs"), Buffer.alloc(100_000, "x"));
  write(join(ws, "script.sh"), "#!/bin/sh\ntrue\n");
  chmodSync(join(ws, "script.sh"), 0o751);
  write(join(ws, "uploads/evidence.txt"), "historical attachment");
  symlinkSync("project/uncommitted.rs", join(ws, "link"));
  const release = await lock(room);
  await packWorkspace(room);
  assert.ok(!existsSync(join(ws, "project/uncommitted.rs")));
  assert.ok(statSync(workspaceArchive(room)).size < 10_000);
  assert.deepEqual(await workspaceFile(room, "uploads/evidence.txt"), Buffer.from("historical attachment"));
  await packWorkspace(room); // An hourly retry must not replace the archive with the now-empty directory.
  write(join(ws, "uploads/new.txt"), "new attachment while archived");
  await restoreWorkspace(room);
  assert.deepEqual(readFileSync(join(ws, "project/uncommitted.rs")), Buffer.alloc(100_000, "x"));
  // Windows keeps no Unix modes.
  if (process.platform !== "win32") assert.equal(statSync(join(ws, "script.sh")).mode & 0o777, 0o751);
  // Windows keeps a link's target with its own separator.
  assert.equal(readlinkSync(join(ws, "link")), join("project", "uncommitted.rs"));
  assert.equal(readFileSync(join(ws, "uploads/new.txt"), "utf8"), "new attachment while archived");
  assert.ok(!existsSync(workspaceArchive(room)));
  await restoreWorkspace(room);
  release();
  assert.ok(existsSync(join(room, "archive.lock")), "the lock file is where the Rust's is");
  rmSync(room, { recursive: true });
});

test("links the machine refuses come back where the restored workspace ends up, not where it was made", { skip: process.platform !== "win32" && "only Windows refuses links" }, async () => {
  const room = temp();
  const ws = join(room, "workspace");
  write(join(ws, "project/main.rs"), "fn main() {}");
  symlinkSync("project", join(ws, "lib"), "dir");
  symlinkSync(join("project", "main.rs"), join(ws, "entry"));
  const release = await lock(room);
  await packWorkspace(room);
  // As Windows without the privilege (Developer Mode off): links refused, junctions made.
  const real = fsModule.promises.symlink;
  fsModule.promises.symlink = (async (target: string, path: string, type?: string) => {
    if (type === "junction") return real(target, path, type);
    throw Object.assign(new Error("EPERM: operation not permitted, symlink"), { code: "EPERM" });
  }) as typeof real;
  syncBuiltinESMExports();
  try {
    await restoreWorkspace(room);
  } finally {
    fsModule.promises.symlink = real;
    syncBuiltinESMExports();
  }
  release();
  // The directory's stand-in (a junction) leads into the workspace at its final path: the tree was made beside it
  // (workspace.restoring) and moved.
  assert.equal(realpathSync(join(ws, "lib")), realpathSync(join(ws, "project")));
  assert.equal(readFileSync(join(ws, "lib", "main.rs"), "utf8"), "fn main() {}");
  assert.equal(readFileSync(join(ws, "entry"), "utf8"), "fn main() {}");
  assert.ok(!existsSync(join(room, "workspace.restoring")));
  rmSync(room, { recursive: true });
});

test("transcript round trip and corruption keep the only good copy", async () => {
  const root = temp();
  const path = join(root, "history.jsonl");
  const text = '{"type":"user"}\n'.repeat(10_000);
  write(path, text);
  await packFile(path);
  assert.ok(!existsSync(path));
  assert.equal(storage(path), packed(path));
  assert.equal(zstdDecompressSync(readFileSync(packed(path))).toString(), text);
  assert.ok(existsSync(join(root, "history.jsonl.archive-lock")));
  await restoreFile(path);
  assert.equal(readFileSync(path, "utf8"), text);
  await packFile(path);
  writeFileSync(packed(path), "broken archive");
  assert.ok(await rejects(restoreFile(path)));
  assert.ok(!existsSync(path));
  assert.ok(existsSync(packed(path)));
  assert.ok(!existsSync(join(root, "history.jsonl.restoring")));
  rmSync(root, { recursive: true });
});

test("a cut-off transcript archive is refused, not restored short", async () => {
  const root = temp();
  const path = join(root, "history.jsonl");
  write(path, Array.from({ length: 20_000 }, (_, i) => `{"n":${i}}\n`).join(""));
  await packFile(path);
  const whole = readFileSync(packed(path));
  writeFileSync(packed(path), whole.subarray(0, whole.length - 7));
  assert.ok(await rejects(restoreFile(path)));
  assert.ok(!existsSync(path));
  rmSync(root, { recursive: true });
});

test("failed workspace restore preserves archive and new files", async () => {
  const room = temp();
  write(join(room, "workspace/source.rs"), "original");
  await packWorkspace(room);
  write(join(room, "workspace/new.txt"), "new");
  writeFileSync(workspaceArchive(room), "broken archive");
  assert.ok(await rejects(restoreWorkspace(room)));
  assert.equal(readFileSync(join(room, "workspace/new.txt"), "utf8"), "new");
  assert.ok(existsSync(workspaceArchive(room)));
  rmSync(room, { recursive: true });
});

test("interrupted workspace retirement can be restored", async () => {
  const room = temp();
  write(join(room, "workspace/source.rs"), "snapshot");
  await packWorkspace(room);
  write(join(room, "workspace.retiring/source.rs"), "latest surviving original");
  await restoreWorkspace(room);
  assert.equal(readFileSync(join(room, "workspace/source.rs"), "utf8"), "latest surviving original");
  rmSync(room, { recursive: true });
});

test("archived git worktree survives prune and restores dirty files", async () => {
  const root = temp();
  const repo = join(root, "repo");
  mkdirSync(repo);
  const git = (dir: string, args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8" });
  git(repo, ["init", "-q"]);
  write(join(repo, "source.rs"), "committed");
  git(repo, ["add", "."]);
  git(repo, ["-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-qm", "initial"]);
  const room = join(root, "chat");
  const ws = join(room, "workspace");
  mkdirSync(ws, { recursive: true });
  const worktree = join(ws, "project");
  git(repo, ["worktree", "add", "--detach", worktree]);
  write(join(worktree, "source.rs"), "uncommitted edit");
  const gitdir = readFileSync(join(worktree, ".git"), "utf8").trim().slice("gitdir: ".length);
  await packWorkspace(room);
  assert.ok(existsSync(join(gitdir, "locked")));
  assert.equal(readFileSync(join(gitdir, "locked"), "utf8"), `still.fail archived workspace: ${room}\n`);
  assert.deepEqual(JSON.parse(readFileSync(join(room, "workspace-locks.json"), "utf8")), [join(realpathSync(gitdir), "locked")]);
  git(repo, ["worktree", "prune", "--expire", "now"]);
  assert.ok(existsSync(gitdir));
  await restoreWorkspace(room);
  assert.ok(!existsSync(join(gitdir, "locked")));
  assert.ok(!existsSync(join(room, "workspace-locks.json")));
  assert.equal(readFileSync(join(worktree, "source.rs"), "utf8"), "uncommitted edit");
  assert.ok(git(worktree, ["status", "--porcelain"]).includes("source.rs"));
  rmSync(root, { recursive: true });
});

test("becoming active before commit keeps originals and removes temporary archives", async () => {
  const room = temp();
  write(join(room, "workspace/source.rs"), "work");
  await packWorkspaceIf(room, () => false);
  assert.equal(readFileSync(join(room, "workspace/source.rs"), "utf8"), "work");
  assert.ok(!existsSync(workspaceArchive(room)));
  assert.ok(!existsSync(join(room, "workspace.tar.zst.writing")));
  const history = join(room, "history.jsonl");
  write(history, "history\n");
  await packFileIf(history, () => false);
  assert.equal(readFileSync(history, "utf8"), "history\n");
  assert.ok(!existsSync(packed(history)));
  assert.ok(!existsSync(join(room, "history.jsonl.zst.writing")));
  rmSync(room, { recursive: true });
});

test("long names, long link targets, nested directories, empty files and hard links come back", async () => {
  const room = temp();
  const ws = join(room, "workspace");
  const deep = `${"d".repeat(60)}/${"e".repeat(60)}/${"名".repeat(40)}.txt`;
  write(join(ws, deep), "deep");
  write(join(ws, "empty"), "");
  mkdirSync(join(ws, "an/empty/dir"), { recursive: true });
  symlinkSync(`${"t".repeat(150)}/target`, join(ws, "far"));
  write(join(ws, "a"), "linked");
  linkSync(join(ws, "a"), join(ws, "b"));
  chmodSync(join(ws, "an"), 0o750);
  await packWorkspace(room);
  assert.deepEqual(await workspaceFile(room, deep), Buffer.from("deep"));
  assert.deepEqual(await workspaceFile(room, `./${deep}`), Buffer.from("deep"));
  assert.equal(await workspaceFile(room, "an"), null, "a directory is no file");
  assert.equal(await workspaceFile(room, "missing"), null);
  await restoreWorkspace(room);
  assert.equal(readFileSync(join(ws, deep), "utf8"), "deep");
  assert.equal(readFileSync(join(ws, "empty"), "utf8"), "");
  assert.ok(statSync(join(ws, "an/empty/dir")).isDirectory());
  if (process.platform !== "win32") assert.equal(statSync(join(ws, "an")).mode & 0o777, 0o750);
  assert.equal(readlinkSync(join(ws, "far")), join("t".repeat(150), "target"));
  assert.equal(readFileSync(join(ws, "b"), "utf8"), "linked");
  rmSync(room, { recursive: true });
});

test("the room's lock is taken in turn", async () => {
  const room = temp();
  const order: string[] = [];
  let entered = () => {};
  const inside = new Promise<void>((r) => (entered = r));
  let leave = () => {};
  const out = new Promise<void>((r) => (leave = r));
  const first = withLock(room, async () => {
    order.push("first in");
    entered();
    await out;
    order.push("first out");
  });
  // Asked for while the first holds it (and given what is queued to run meanwhile): it waits.
  await inside;
  const second = withLock(room, async () => void order.push("second"));
  await settle();
  leave();
  await Promise.all([first, second]);
  assert.deepEqual(order, ["first in", "first out", "second"]);
  rmSync(room, { recursive: true });
});

test("jsonl files: logical names, packed ones too, once each", () => {
  const root = temp();
  write(join(root, "a.jsonl"), "");
  write(join(root, "sub/b.jsonl.zst"), "");
  write(join(root, "sub/b.jsonl"), "");
  write(join(root, "c.txt"), "");
  write(join(root, "a.jsonl.archive-lock"), "");
  const out: string[] = [];
  jsonlFiles(root, out);
  assert.deepEqual(out.sort(), [join(root, "a.jsonl"), join(root, "sub/b.jsonl")]);
  assert.equal(withExtension("/x/abc.jsonl", "jsonl.archive-lock"), join("/x", "abc.jsonl.archive-lock"));
  assert.equal(withExtension("/x/abc.jsonl.zst", "zst.writing"), join("/x", "abc.jsonl.zst.writing"));
  rmSync(root, { recursive: true });
});

// ── footprint.rs ──

test("a file linked twice counts once", async () => {
  const root = temp();
  write(join(root, "a/file"), Buffer.alloc(64_000, 7));
  mkdirSync(join(root, "b"));
  linkSync(join(root, "a/file"), join(root, "b/file"));
  const once = await measured(join(root, "a"));
  const both = await measured(root);
  assert.ok(both < once + 10_000, `${once} ${both}`);
  rmSync(root, { recursive: true });
});

test("what can be made again", () => {
  const p = temp();
  write(join(p, "android/build.gradle.kts"), "x");
  write(join(p, "android/settings.gradle.kts"), "x");
  assert.ok(rebuildable(join(p, "x/node_modules")) && rebuildable(join(p, "android/build")) && rebuildable(join(p, "android/.gradle")));
  assert.ok(!rebuildable(join(p, "site/build")) && !rebuildable(join(p, "site/target")) && !rebuildable(join(p, "dist")));
  rmSync(p, { recursive: true });
});

test("archive cleanup keeps attachments, git and symlink targets", async () => {
  const p = temp();
  write(join(p, "uploads/node_modules/evidence.js"), "x".repeat(100));
  write(join(p, ".git/node_modules/metadata"), "x".repeat(100));
  write(join(p, "app/node_modules/dependency.js"), "x".repeat(100));
  const outside = temp();
  write(join(outside, "node_modules/source"), "x".repeat(100));
  symlinkSync(outside, join(p, "linked"));
  const found = (await measureRoom(p)).rebuild;
  assert.equal(found.length, 1);
  assert.equal(found[0]![0], join(p, "app/node_modules"));
  const data = join(p, "data");
  const workspace = join(data, "sessions/cl/chat/workspace");
  mkdirSync(workspace, { recursive: true });
  assert.equal(roomOf(data, workspace), join(data, "sessions/cl/chat"));
  symlinkSync(outside, join(data, "sessions/cl/escape"));
  mkdirSync(join(outside, "workspace"));
  assert.equal(roomOf(data, join(data, "sessions/cl/escape/workspace")), null);
  rmSync(p, { recursive: true });
  rmSync(outside, { recursive: true });
});

test("archive cleanup keeps tracked files in generated directories", async () => {
  const p = temp();
  const git = (args: string[]) => execFileSync("git", ["-C", p, ...args]);
  git(["init", "-q"]);
  write(join(p, "node_modules/local-source.js"), "x".repeat(100));
  git(["add", "node_modules/local-source.js"]);
  assert.ok(!(await safeToRemove(join(p, "node_modules"))));
  write(join(p, "scratch/node_modules/dependency.js"), "x".repeat(100));
  assert.ok(await safeToRemove(join(p, "scratch/node_modules")));
  rmSync(p, { recursive: true });
});
