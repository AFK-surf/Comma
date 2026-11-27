import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";
import { fileURLToPath } from "node:url";

const run = promisify(execFile);
const checkout = fileURLToPath(new URL("./checkout-pvg.sh", import.meta.url));
const lockLibrary = fileURLToPath(new URL("./synch-lock.sh", import.meta.url));
const rustCache = fileURLToPath(
  new URL("../.github/actions/setup-macos-cache/station-rust-cache.sh", import.meta.url),
);
const repository = fileURLToPath(new URL("..", import.meta.url));
const snapshot = fileURLToPath(
  new URL("../.github/actions/setup-macos-cache/synch-snapshot.sh", import.meta.url),
);

// A gateway with the lock-key semantics of synch-s3 (synchronicity
// docs/LOCKS.md §11): a conditional PUT acquires, 412 while held, DELETE with
// the token releases. Objects are slow to upload, so publishers overlap.
function gateway({ lockBucket, stallUploads = false, failReads = false, onUpload = () => {} }) {
  const objects = new Map();
  const locks = new Map();
  const puts = [];
  let holders = 0;
  let mostHolders = 0;
  let tokens = 0;
  const server = createServer(async (req, res) => {
    const [, bucket, ...rest] = new URL(req.url, "http://gateway").pathname.split("/");
    const key = rest.join("/");
    if (bucket === lockBucket && key.startsWith("locks/")) {
      if (req.method === "PUT") {
        for await (const _ of req);
        if (req.headers["if-none-match"] !== "*") return res.writeHead(400).end();
        if (locks.has(key)) return res.writeHead(412).end();
        const token = `t${++tokens}`;
        locks.set(key, token);
        mostHolders = Math.max(mostHolders, ++holders);
        return res.writeHead(200, { etag: `"${token}"` }).end();
      }
      if (req.method === "DELETE") {
        if (req.headers["if-match"] === `"${locks.get(key)}"`) {
          locks.delete(key);
          holders--;
        }
        return res.writeHead(204).end();
      }
    }
    if (bucket === "missing-locks") return res.writeHead(404).end();
    if (req.method === "PUT" && stallUploads) return onUpload(); // never answers
    if (req.method !== "PUT" && failReads) return res.writeHead(500).end();
    if (req.method === "PUT") {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      await new Promise((resolve) => setTimeout(resolve, 300));
      puts.push(key);
      objects.set(key, Buffer.concat(chunks));
      return res.end();
    }
    if (!objects.has(key)) return res.writeHead(404).end();
    res.end(req.method === "HEAD" ? undefined : objects.get(key));
  });
  return { server, puts, locks, mostHolders: () => mostHolders };
}

async function fixture(root, port, lockBucket) {
  const shared = join(root, "shared");
  mkdirSync(join(shared, "synch"), { recursive: true });
  writeFileSync(
    join(shared, "synch/s3.env"),
    [
      `SYNCH_S3_ENDPOINT=http://127.0.0.1:${port}`,
      "SYNCH_S3_ACCESS_KEY=fixture",
      "SYNCH_S3_SECRET_KEY=fixture",
      "SYNCH_S3_READ_BUCKET=peers",
      "SYNCH_S3_WRITE_BUCKET=local",
      ...(lockBucket ? [`SYNCH_S3_LOCK_BUCKET=${lockBucket}`] : []),
    ].join("\n"),
  );
  const origin = join(root, "origin");
  mkdirSync(join(origin, "scripts"), { recursive: true });
  const git = async (cwd, ...args) => (await run("git", args, { cwd })).stdout.trim();
  await git(origin, "init", "-q");
  await git(origin, "config", "user.name", "Fixture");
  await git(origin, "config", "user.email", "fixture@example.com");
  copyFileSync(lockLibrary, join(origin, "scripts/synch-lock.sh"));
  await git(origin, "add", "scripts");
  await git(origin, "commit", "-qm", "fixture");
  const sha = await git(origin, "rev-parse", "HEAD");
  const clones = [];
  for (const name of ["a", "b", "c"]) {
    const clone = join(root, name);
    await run("git", ["clone", "-q", "--depth=1", `file://${origin}`, clone]);
    clones.push(clone);
  }
  const env = {
    ...process.env,
    RUNNER_TEMP: root,
    GITHUB_SHA: sha,
    GITHUB_REPOSITORY: "fixture/repo",
    GITHUB_SERVER_URL: "https://github.com",
    SYNCH_CACHE_SHARED_DIRECTORY: shared,
    SYNCH_LOCK_WAIT: "20",
  };
  return { clones, env };
}

test("jobs checking out the same commit at once publish its snapshot once", async () => {
  const root = mkdtempSync(join(tmpdir(), "synch-lock-"));
  const gw = gateway({ lockBucket: "locks" });
  await new Promise((resolve) => gw.server.listen(0, "127.0.0.1", resolve));
  try {
    const { clones, env } = await fixture(root, gw.server.address().port, "locks");
    const outputs = await Promise.all(
      clones.map((cwd) => run("bash", [checkout, "publish"], { cwd, env })),
    );
    assert.equal(gw.puts.length, 1);
    assert.equal(gw.mostHolders(), 1);
    assert.equal(gw.locks.size, 0, "every hold is released");
    const said = outputs.map(({ stdout }) => stdout).join("");
    assert.equal(said.match(/Synch git: published/g).length, 1);
    assert.equal(said.match(/already published/g).length, 2);
  } finally {
    gw.server.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("a run's jobs fetch a new commit from origin once and restore it from that job's snapshot", async () => {
  const root = mkdtempSync(join(tmpdir(), "synch-lock-"));
  const gw = gateway({ lockBucket: "locks" });
  await new Promise((resolve) => gw.server.listen(0, "127.0.0.1", resolve));
  try {
    const { env } = await fixture(root, gw.server.address().port, "locks");
    const workspaces = ["x", "y", "z"].map((name) => {
      const workspace = join(root, name);
      mkdirSync(workspace);
      return workspace;
    });
    const outputs = await Promise.all(
      workspaces.map((workspace) =>
        run("bash", [checkout], {
          cwd: workspace,
          env: {
            ...env,
            GITHUB_WORKSPACE: workspace,
            GITHUB_SERVER_URL: `file://${root}`,
            GITHUB_REPOSITORY: "origin",
          },
        }),
      ),
    );
    const said = outputs.map(({ stdout }) => stdout);
    assert.equal(gw.puts.length, 1);
    assert.equal(gw.locks.size, 0, "every hold is released");
    assert.equal(said.filter((out) => /Synch git: published/.test(out)).length, 1);
    assert.equal(
      said.filter((out) => out.includes(`restored ${env.GITHUB_SHA} from peers`)).length,
      2,
    );
  } finally {
    gw.server.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("publishing proceeds without a lock the gateway cannot give", async () => {
  for (const lockBucket of [undefined, "missing-locks"]) {
    const root = mkdtempSync(join(tmpdir(), "synch-lock-"));
    const gw = gateway({ lockBucket: "locks" });
    await new Promise((resolve) => gw.server.listen(0, "127.0.0.1", resolve));
    try {
      const { clones, env } = await fixture(root, gw.server.address().port, lockBucket);
      const { stdout } = await run("bash", [checkout, "publish"], { cwd: clones[0], env });
      assert.match(stdout, /Synch git: published/);
      assert.equal(gw.puts.length, 1);
    } finally {
      gw.server.close();
      rmSync(root, { recursive: true, force: true });
    }
  }
});

test("a lock still held when the wait runs out does not hold the job", async () => {
  const root = mkdtempSync(join(tmpdir(), "synch-lock-"));
  const gw = gateway({ lockBucket: "locks" });
  await new Promise((resolve) => gw.server.listen(0, "127.0.0.1", resolve));
  try {
    const { clones, env } = await fixture(root, gw.server.address().port, "locks");
    gw.locks.set(`locks/comma-git/v1/${Buffer.from("fixture/repo").toString("hex")}/${env.GITHUB_SHA}.shallow.tar`, "elsewhere");
    const { stdout } = await run("bash", [checkout, "publish"], {
      cwd: clones[0],
      env: { ...env, SYNCH_LOCK_WAIT: "1" },
    });
    assert.match(stdout, /still held after 1s; proceeding without it/);
    assert.match(stdout, /Synch git: published/);
  } finally {
    gw.server.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("a save with a budget waits briefly for a held lock and stops its own stalled upload", async () => {
  const root = mkdtempSync(join(tmpdir(), "synch-lock-"));
  const gw = gateway({ lockBucket: "locks", stallUploads: true });
  await new Promise((resolve) => gw.server.listen(0, "127.0.0.1", resolve));
  try {
    const { env } = await fixture(root, gw.server.address().port, "locks");
    delete env.SYNCH_LOCK_WAIT; // the 600 s default, which the budget overrides
    const archive = join(root, "cache.tar");
    writeFileSync(archive, "x".repeat(4096));
    const machine = (await run("bash", ["-c", 'echo "$(uname -s)-$(uname -m)"'])).stdout.trim();
    gw.locks.set(`locks/comma-cache/${machine}/fixture/k.tar`, "elsewhere");
    const { stdout, stderr } = await run(
      "bash",
      [snapshot, "save", "fixture", "k", archive, "mutable"],
      { env: { ...env, RUNNER_OS: "macOS", SYNCH_SAVE_BUDGET: "6" } },
    );
    assert.match(stdout, /still held after 3s; proceeding without it/);
    // Stopped by the budget (--max-time), not by the 30 s speed limit.
    assert.match(stderr, /Operation timed out/);
    assert.match(stdout, /could not publish k/);
  } finally {
    gw.server.closeAllConnections();
    gw.server.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("a save cancelled mid-upload releases its lock", async () => {
  const root = mkdtempSync(join(tmpdir(), "synch-lock-"));
  let uploading;
  const upload = new Promise((resolve) => (uploading = resolve));
  const gw = gateway({ lockBucket: "locks", stallUploads: true, onUpload: () => uploading() });
  await new Promise((resolve) => gw.server.listen(0, "127.0.0.1", resolve));
  try {
    const { env } = await fixture(root, gw.server.address().port, "locks");
    const archive = join(root, "cache.tar");
    writeFileSync(archive, "x".repeat(4096));
    const save = run("bash", [snapshot, "save", "fixture", "k", archive, "mutable"], {
      env: { ...env, RUNNER_OS: "macOS" },
    });
    await upload;
    assert.equal(gw.locks.size, 1, "the save holds the lock while it uploads");
    save.child.kill("SIGTERM");
    // It stops its upload and exits through its own handler at once, rather
    // than dying with the signal once the upload gives up on its own.
    await assert.rejects(save, (error) => {
      assert.equal(error.code, 143);
      assert.doesNotMatch(error.stderr, /Operation too slow/);
      return true;
    });
    assert.equal(gw.locks.size, 0, "a cancelled save releases its lock");
  } finally {
    gw.server.closeAllConnections();
    gw.server.close();
    rmSync(root, { recursive: true, force: true });
  }
});

// station-rust-cache.sh's environment in a job: its own temp and GITHUB_ENV.
function rustJob(root, env, extra = {}) {
  const temp = join(root, "job");
  mkdirSync(temp, { recursive: true });
  writeFileSync(join(temp, "env"), "");
  return {
    ...env,
    RUNNER_OS: "macOS",
    RUNNER_TEMP: temp,
    GITHUB_ENV: join(temp, "env"),
    GITHUB_WORKSPACE: repository,
    RUST_CACHE_KEY: "k",
    HOME: temp,
    ...extra,
  };
}

test("a cancelled Rust cache step stops its publishing and releases the lock", async () => {
  const root = mkdtempSync(join(tmpdir(), "synch-lock-"));
  let uploading;
  const upload = new Promise((resolve) => (uploading = resolve));
  const gw = gateway({ lockBucket: "locks", stallUploads: true, onUpload: () => uploading() });
  await new Promise((resolve) => gw.server.listen(0, "127.0.0.1", resolve));
  try {
    const { env } = await fixture(root, gw.server.address().port, "locks");
    const save = run("bash", [rustCache, "save"], { env: rustJob(root, env) });
    await upload;
    assert.equal(gw.locks.size, 1, "publishing holds the lock while it uploads");
    save.child.kill("SIGTERM");
    await assert.rejects(save, (error) => {
      assert.equal(error.code, 143);
      return true;
    });
    assert.equal(gw.locks.size, 0, "a cancelled step releases its lock");
  } finally {
    gw.server.closeAllConnections();
    gw.server.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("a host's toolchain is published only when the peers answer they have none", async () => {
  const toolchain = (await run("bash", ["-c", `sed -n 's/^const TOOLCHAIN = "\\(.*\\)";$/\\1/p' systems/station/scripts/native.ts`], { cwd: repository })).stdout.trim();
  const machine = (await run("bash", ["-c", 'echo "$(uname -s)-$(uname -m)"'])).stdout.trim();
  for (const failReads of [false, true]) {
    const root = mkdtempSync(join(tmpdir(), "synch-lock-"));
    const gw = gateway({ lockBucket: "locks", failReads });
    await new Promise((resolve) => gw.server.listen(0, "127.0.0.1", resolve));
    try {
      const { env } = await fixture(root, gw.server.address().port, "locks");
      // This host's copy: a toolchain that runs and has every target.
      const built = join(root, "built");
      const dir = join(built, "toolchains", `${toolchain}-fixture`);
      mkdirSync(join(dir, "bin"), { recursive: true });
      writeFileSync(join(dir, "bin/rustc"), "#!/bin/sh\necho rustc fixture\n", { mode: 0o755 });
      for (const target of ["aarch64-linux-android", "aarch64-apple-ios", "aarch64-apple-ios-sim", "wasm32-unknown-unknown"]) {
        mkdirSync(join(dir, "lib/rustlib", target, "lib"), { recursive: true });
      }
      const store = join(root, "shared/comma-snapshots", machine, "rust-toolchain");
      mkdirSync(store, { recursive: true });
      const key = `rust-${toolchain}-clients-${machine}`;
      await run("tar", ["-cf", join(store, `${key}.tar`), "-C", built, "."]);
      const { stdout } = await run("bash", [rustCache, "restore"], { env: rustJob(root, env) });
      assert.match(stdout, /restored rust-[^ ]* from this host/);
      const published = gw.puts.filter((put) => put.includes("/rust-toolchain/"));
      assert.deepEqual(published, failReads ? [] : [`comma-cache/${machine}/rust-toolchain/${key}.tar`]);
    } finally {
      gw.server.close();
      rmSync(root, { recursive: true, force: true });
    }
  }
});
