// What the Rust station packed, this one restores, and the other way round (a station switched to TS, or rolled back):
// the Rust's archive.rs compiled as it is (test/archive-rs; `cargo build --release` there, or ARCHIVE_RS=<binary>).
// Skipped where it is not built.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { zstdDecompressSync } from "node:zlib";
import { packFile, packWorkspace, packed, restoreFile, restoreWorkspace, workspaceArchive, workspaceFile } from "../src/sessions/archive.ts";

const binary = process.env.ARCHIVE_RS ?? join(import.meta.dirname, "archive-rs", "target", "release", "archive-rs");
const skip = existsSync(binary) ? false : `the Rust archive command is not built (${binary})`;
const rust = (...args: string[]) => execFileSync(binary, args);

const temp = () => realpathSync(mkdtempSync(join(tmpdir(), "cold-compat-")));
const write = (path: string, bytes: string | Buffer) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
};

/// Everything under `dir` as a line each: its kind, mode, and contents (a file's hash and mtime, a link's target).
function manifest(dir: string, rel = ""): string[] {
  const out: string[] = [];
  for (const name of readdirSync(join(dir, rel)).sort()) {
    const path = join(dir, rel, name);
    const r = rel === "" ? name : `${rel}/${name}`;
    const meta = lstatSync(path);
    if (meta.isSymbolicLink()) out.push(`${r} link ${readlinkSync(path)}`);
    else if (meta.isDirectory()) {
      out.push(`${r} dir ${(meta.mode & 0o7777).toString(8)}`);
      out.push(...manifest(dir, r));
    } else {
      const hash = createHash("sha256").update(readFileSync(path)).digest("hex").slice(0, 16);
      out.push(`${r} file ${(meta.mode & 0o7777).toString(8)} ${meta.size} ${hash} ${Math.floor(meta.mtimeMs / 1000)}`);
    }
  }
  return out;
}

/// A workspace with what people's have: sources, a script, links, long and non-ASCII names, empty files and
/// directories, a big file, a hard link, an upload.
function fill(ws: string) {
  write(join(ws, "project/src/main.rs"), "fn main() {}\n");
  write(join(ws, "project/uncommitted.rs"), Buffer.alloc(300_000, "x"));
  write(join(ws, "script.sh"), "#!/bin/sh\ntrue\n");
  chmodSync(join(ws, "script.sh"), 0o751);
  write(join(ws, "readonly.txt"), "ro");
  chmodSync(join(ws, "readonly.txt"), 0o444);
  write(join(ws, "uploads/截图 1.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3]));
  write(join(ws, `${"long-".repeat(30)}/${"名字".repeat(30)}.md`), "deep and long");
  write(join(ws, "empty"), "");
  mkdirSync(join(ws, "an/empty/dir"), { recursive: true });
  chmodSync(join(ws, "an"), 0o750);
  write(join(ws, "random.bin"), Buffer.from(Array.from({ length: 3 << 20 }, (_, i) => (i * 2654435761) >>> 24)));
  symlinkSync("project/uncommitted.rs", join(ws, "link"));
  symlinkSync(`${"far/".repeat(40)}target`, join(ws, "long-link"));
  symlinkSync("/nonexistent/absolute", join(ws, "dangling"));
  write(join(ws, "a"), "hard linked");
  linkSync(join(ws, "a"), join(ws, "b"));
  utimesSync(join(ws, "project/src/main.rs"), 1_700_000_000, 1_700_000_000);
}

for (const [packer, restorer] of [
  ["Rust", "TS"],
  ["TS", "Rust"],
] as const) {
  test(`a workspace the ${packer} station packed, the ${restorer} one reads and restores as it was`, { skip }, async () => {
    const room = temp();
    const ws = join(room, "workspace");
    fill(ws);
    const before = manifest(ws);
    if (packer === "Rust") rust("pack", room);
    else await packWorkspace(room);
    assert.ok(existsSync(workspaceArchive(room)));
    assert.deepEqual(readdirSync(ws), [], "the originals go once packed");
    // An attachment read straight out of the archive.
    const upload = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3]);
    if (restorer === "TS") assert.deepEqual(await workspaceFile(room, "uploads/截图 1.png"), upload);
    else {
      assert.deepEqual(rust("file", room, "uploads/截图 1.png"), upload);
      assert.equal(spawnSync(binary, ["file", room, "uploads/missing"]).status, 3);
    }
    write(join(ws, "uploads/new.txt"), "new while archived");
    if (restorer === "TS") await restoreWorkspace(room);
    else rust("restore", room);
    assert.ok(!existsSync(workspaceArchive(room)));
    assert.deepEqual(
      manifest(ws).filter((l) => !l.startsWith("uploads/new.txt") && !l.startsWith("uploads dir")),
      before.filter((l) => !l.startsWith("uploads dir")),
    );
    assert.equal(readFileSync(join(ws, "uploads/new.txt"), "utf8"), "new while archived");
    chmodSync(join(ws, "readonly.txt"), 0o644);
    rmSync(room, { recursive: true });
  });

  test(`a git worktree the ${packer} station archived, the ${restorer} one lets go of`, { skip }, async () => {
    const root = temp();
    const repo = join(root, "repo");
    mkdirSync(repo);
    const git = (dir: string, args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8" });
    git(repo, ["init", "-q"]);
    write(join(repo, "source.rs"), "committed");
    git(repo, ["add", "."]);
    git(repo, ["-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-qm", "initial"]);
    const room = join(root, "chat");
    const worktree = join(room, "workspace", "project");
    mkdirSync(dirname(worktree), { recursive: true });
    git(repo, ["worktree", "add", "--detach", worktree]);
    write(join(worktree, "source.rs"), "uncommitted edit");
    const gitdir = readFileSync(join(worktree, ".git"), "utf8").trim().slice("gitdir: ".length);
    if (packer === "Rust") rust("pack", room);
    else await packWorkspace(room);
    assert.ok(existsSync(join(gitdir, "locked")));
    git(repo, ["worktree", "prune", "--expire", "now"]);
    if (restorer === "TS") await restoreWorkspace(room);
    else rust("restore", room);
    assert.ok(!existsSync(join(gitdir, "locked")), "the lock the other station made is let go");
    assert.ok(!existsSync(join(room, "workspace-locks.json")));
    assert.ok(git(worktree, ["status", "--porcelain"]).includes("source.rs"));
    rmSync(root, { recursive: true });
  });

  test(`a transcript the ${packer} station packed, the ${restorer} one restores`, { skip }, async () => {
    const root = temp();
    const path = join(root, "projects", "x", "abc.jsonl");
    const text = Array.from({ length: 30_000 }, (_, i) => `{"type":"user","n":${i},"text":"第${i}行"}\n`).join("");
    write(path, text);
    if (packer === "Rust") rust("pack-file", path);
    else await packFile(path);
    assert.ok(!existsSync(path) && existsSync(packed(path)));
    assert.equal(zstdDecompressSync(readFileSync(packed(path))).toString(), text);
    if (restorer === "TS") await restoreFile(path);
    else rust("restore-file", path);
    assert.equal(readFileSync(path, "utf8"), text);
    assert.ok(!existsSync(packed(path)));
    assert.equal(lstatSync(path).mode & 0o777, 0o600);
    rmSync(root, { recursive: true });
  });
}
