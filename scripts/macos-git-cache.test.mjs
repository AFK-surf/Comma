import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createServer } from "node:http";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const run = promisify(execFile);
const checkout = fileURLToPath(new URL("./checkout-pvg.sh", import.meta.url));

test("fresh guests reuse fetched Git objects without sharing repository credentials", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-peers-"));
  let snapshot;
  let writes = 0;
  const server = createServer(async (req, res) => {
    if (req.method === "PUT") {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      snapshot = Buffer.concat(chunks);
      writes++;
      res.end();
    } else if (snapshot) {
      res.end(req.method === "HEAD" ? undefined : snapshot);
    } else {
      res.writeHead(404).end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const shared = join(root, "shared");
    mkdirSync(join(shared, "synch"), { recursive: true });
    writeFileSync(
      join(shared, "synch/s3.env"),
      [
        `SYNCH_S3_ENDPOINT=http://127.0.0.1:${server.address().port}`,
        "SYNCH_S3_ACCESS_KEY=fixture",
        "SYNCH_S3_SECRET_KEY=fixture",
        "SYNCH_S3_READ_BUCKET=peers",
        "SYNCH_S3_WRITE_BUCKET=local",
      ].join("\n"),
    );
    const origin = join(root, "origin");
    mkdirSync(origin);
    const git = async (cwd, ...args) =>
      (await run("git", args, { cwd })).stdout.trim();
    await git(origin, "init", "-q");
    await git(origin, "config", "user.name", "Fixture");
    await git(origin, "config", "user.email", "fixture@example.com");
    for (let i = 0; i < 2; i++) {
      writeFileSync(join(origin, "source"), `revision ${i}`);
      await git(origin, "add", "source");
      await git(origin, "commit", "-qm", `revision ${i}`);
    }
    const sha = await git(origin, "rev-parse", "HEAD");
    const first = join(root, "first");
    await run("git", ["clone", "-q", "--depth=1", `file://${origin}`, first]);
    await git(first, "config", "http.extraheader", "SECRET");
    writeFileSync(join(first, ".git/hooks/pre-commit"), "SECRET");
    const env = {
      ...process.env,
      RUNNER_TEMP: root,
      GITHUB_SHA: sha,
      GITHUB_REPOSITORY: "fixture/repo",
      GITHUB_SERVER_URL: "https://github.com",
      SYNCH_CACHE_SHARED_DIRECTORY: shared,
    };
    const missingConfig = {
      ...env,
      SYNCH_CACHE_SHARED_DIRECTORY: join(root, "missing"),
    };
    await run("bash", [checkout, "publish"], {
      cwd: first,
      env: missingConfig,
    });
    await assert.rejects(
      run("bash", [checkout, "publish"], {
        cwd: first,
        env: { ...missingConfig, PVG_REQUIRE_CACHE: "true" },
      }),
      { code: 1 },
    );
    const second = join(root, "second");
    mkdirSync(second);
    assert.match(
      (await run("bash", [checkout, "restore"], { cwd: second, env })).stdout,
      /no peer snapshot/,
    );
    assert.equal(existsSync(join(second, ".git")), false);
    assert.match(
      (await run("bash", [checkout, "publish"], { cwd: first, env })).stdout,
      /published/,
    );
    assert.equal(snapshot.includes(Buffer.from("SECRET")), false);
    assert.match(
      (await run("bash", [checkout, "restore"], { cwd: second, env })).stdout,
      /restored/,
    );
    // Exercise the clean/reset and fetch operations checkout performs on a seed.
    await git(second, "clean", "-ffdx");
    await git(second, "reset", "--hard", "HEAD");
    assert.equal(readFileSync(join(second, "source"), "utf8"), "revision 1");
    assert.equal(
      await git(second, "rev-parse", "--is-shallow-repository"),
      "true",
    );
    await git(second, "fetch", "--unshallow", `file://${origin}`);
    assert.equal(await git(second, "rev-list", "--count", "HEAD"), "2");
    assert.match(
      (await run("bash", [checkout, "publish"], { cwd: second, env })).stdout,
      /already published/,
    );
    assert.equal(writes, 1);
    // A full-history first publisher also supplies the requested commit.
    snapshot = undefined;
    await run("bash", [checkout, "publish"], { cwd: second, env });
    const third = join(root, "third");
    mkdirSync(third);
    await run("bash", [checkout, "restore"], { cwd: third, env });
    assert.equal(await git(third, "rev-list", "--count", "HEAD"), "2");
    assert.equal(
      await git(third, "rev-parse", "--is-shallow-repository"),
      "false",
    );
    // A consumer can check out an exact cached commit while origin is offline.
    const offline = join(root, "offline");
    mkdirSync(offline);
    await run("bash", [checkout], {
      cwd: offline,
      env: {
        ...env,
        GITHUB_WORKSPACE: offline,
        GITHUB_SERVER_URL: `file://${root}/unavailable`,
        GH_TOKEN: "FETCH_ONLY_SECRET",
      },
    });
    assert.equal(readFileSync(join(offline, "source"), "utf8"), "revision 1");
    assert.equal(await git(offline, "rev-parse", "HEAD"), sha);
    assert.doesNotMatch(
      readFileSync(join(offline, ".git/config"), "utf8"),
      /SECRET|extraheader/,
    );

    // The producer fetches full history and branch/tag refs on a cold cache.
    snapshot = undefined;
    await git(origin, "tag", "fixture-tag");
    const cold = join(root, "cold");
    mkdirSync(cold);
    await run("bash", [checkout], {
      cwd: cold,
      env: {
        ...env,
        GITHUB_WORKSPACE: cold,
        GITHUB_SERVER_URL: `file://${root}`,
        GITHUB_REPOSITORY: "origin",
        PVG_FETCH_DEPTH: "0",
        PVG_REQUIRE_CACHE: "true",
        GH_TOKEN: "FETCH_ONLY_SECRET",
      },
    });
    assert.equal(await git(cold, "rev-list", "--count", "HEAD"), "2");
    assert.equal(await git(cold, "rev-parse", "fixture-tag"), sha);
    assert.match(await git(cold, "branch", "-r"), /origin\//);
    assert.doesNotMatch(
      readFileSync(join(cold, ".git/config"), "utf8"),
      /SECRET|extraheader/,
    );
    assert.ok(snapshot);
  } finally {
    server.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("a push whose base has no snapshot starts from the newest published ancestor", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-ancestor-"));
  const objects = new Map();
  let ancestors = [];
  const server = createServer(async (req, res) => {
    const path = new URL(req.url, "http://fixture").pathname;
    if (path === "/repos/origin/commits") {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(ancestors.map((sha) => ({ sha }))));
    } else if (req.method === "PUT") {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      objects.set(path.replace("/local/", "/peers/"), Buffer.concat(chunks));
      res.end();
    } else if (objects.has(path)) {
      res.end(req.method === "HEAD" ? undefined : objects.get(path));
    } else {
      res.writeHead(404).end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;
    const shared = join(root, "shared");
    mkdirSync(join(shared, "synch"), { recursive: true });
    writeFileSync(
      join(shared, "synch/s3.env"),
      [
        `SYNCH_S3_ENDPOINT=${endpoint}`,
        "SYNCH_S3_ACCESS_KEY=fixture",
        "SYNCH_S3_SECRET_KEY=fixture",
        "SYNCH_S3_READ_BUCKET=peers",
        "SYNCH_S3_WRITE_BUCKET=local",
      ].join("\n"),
    );
    const origin = join(root, "origin");
    mkdirSync(origin);
    const git = async (cwd, ...args) =>
      (await run("git", args, { cwd })).stdout.trim();
    await git(origin, "init", "-q");
    await git(origin, "config", "user.name", "Fixture");
    await git(origin, "config", "user.email", "fixture@example.com");
    const shas = [];
    for (let i = 0; i < 3; i++) {
      writeFileSync(join(origin, "source"), `revision ${i}`);
      await git(origin, "add", "source");
      await git(origin, "commit", "-qm", `revision ${i}`);
      shas.push(await git(origin, "rev-parse", "HEAD"));
    }
    const env = {
      ...process.env,
      RUNNER_TEMP: root,
      GITHUB_REPOSITORY: "origin",
      GITHUB_SERVER_URL: `file://${root}`,
      GITHUB_API_URL: endpoint,
      SYNCH_CACHE_SHARED_DIRECTORY: shared,
    };
    // Only the oldest commit was published; the push's base (the middle one) was not.
    const published = join(root, "published");
    mkdirSync(published);
    await git(published, "init", "-q");
    await git(
      published,
      "fetch",
      "-q",
      "--depth=1",
      `file://${origin}`,
      shas[0],
    );
    await git(published, "checkout", "-q", "--detach", shas[0]);
    await run("bash", [checkout, "publish"], {
      cwd: published,
      env: { ...env, GITHUB_SHA: shas[0] },
    });
    const event = join(root, "event.json");
    writeFileSync(event, JSON.stringify({ before: shas[1] }));
    ancestors = [shas[2], shas[1], shas[0]];
    const pushed = join(root, "pushed");
    mkdirSync(pushed);
    const { stdout } = await run("bash", [checkout], {
      cwd: pushed,
      env: {
        ...env,
        GITHUB_SHA: shas[2],
        GITHUB_EVENT_PATH: event,
        GITHUB_WORKSPACE: pushed,
      },
    });
    assert.match(stdout, new RegExp(`restored base ${shas[0]} from peers`));
    assert.equal(await git(pushed, "rev-parse", "HEAD"), shas[2]);
    assert.equal(readFileSync(join(pushed, "source"), "utf8"), "revision 2");
  } finally {
    server.close();
    rmSync(root, { recursive: true, force: true });
  }
});
