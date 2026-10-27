import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import {
  cpSync,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  readdirSync,
  rmSync,
  utimesSync,
  realpathSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const run = promisify(execFile);
const source = fileURLToPath(new URL("..", import.meta.url));

test("only Electron jobs fetch its archive and peers reuse it before job cleanup", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "electron cache-")));
  const bytes = Buffer.from("verified Electron download fixture\n".repeat(64));
  const objects = new Map();
  let downloads = 0;
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://gateway");
    if (url.pathname === "/download") {
      if (req.method === "HEAD") {
        res.setHeader("Content-Length", bytes.length);
        return res.end();
      }
      downloads++;
      const [, first, last] = req.headers.range.match(/bytes=(\d+)-(\d+)/);
      res.statusCode = 206;
      return res.end(bytes.subarray(Number(first), Number(last) + 1));
    }
    const [, , ...rest] = url.pathname.split("/");
    const key = rest.join("/");
    if (req.method === "PUT") {
      const chunks = [];
      req.on("data", (chunk) => chunks.push(chunk));
      req.on("end", () => {
        objects.set(key, Buffer.concat(chunks));
        res.end();
      });
    } else if (url.searchParams.has("list-type")) {
      res.end("<ListBucketResult/>");
    } else if (objects.has(key)) {
      res.end(req.method === "HEAD" ? undefined : objects.get(key));
    } else {
      res.statusCode = 404;
      res.end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;
    const repo = join(root, "repo");
    const action = join(repo, ".github/actions/setup-macos-cache");
    cpSync(join(source, ".github/actions/setup-macos-cache"), action, {
      recursive: true,
    });
    mkdirSync(join(repo, "scripts"));
    cpSync(
      join(source, "scripts/synch-lock.sh"),
      join(repo, "scripts/synch-lock.sh"),
    );
    writeFileSync(
      join(repo, "pnpm-lock.yaml"),
      "packages:\n  electron@45.0.0:\n",
    );
    const pkg = join(repo, "clients/apps/electron/node_modules/electron");
    mkdirSync(pkg, { recursive: true });
    writeFileSync(
      join(pkg, "package.json"),
      JSON.stringify({ version: "45.0.0" }),
    );
    const name = "electron-v45.0.0-darwin-arm64.zip";
    writeFileSync(
      join(pkg, "checksums.json"),
      JSON.stringify({
        [name]: createHash("sha256").update(bytes).digest("hex"),
      }),
    );
    execFileSync("git", ["init", "-q", repo]);
    const bin = join(root, "bin");
    mkdirSync(bin);
    const curl = execFileSync("which", ["curl"], { encoding: "utf8" }).trim();
    // Only release requests are redirected. Gateway requests use real local HTTP.
    writeFileSync(
      join(bin, "curl"),
      `#!${process.execPath}\nconst {spawnSync}=require('node:child_process');\nconst args=process.argv.slice(2).map(a=>a.startsWith('https://github.com/electron/electron/releases/download/')?${JSON.stringify(endpoint + "/download")}:a);\nconst r=spawnSync(${JSON.stringify(curl)},args,{stdio:'inherit'});process.exit(r.status ?? 1);\n`,
      { mode: 0o755 },
    );
    writeFileSync(
      join(bin, "uname"),
      '#!/bin/sh\ncase "$1" in -m) echo arm64;; *) echo Darwin;; esac\n',
      { mode: 0o755 },
    );
    const host = (name) => {
      const home = join(root, name, "home");
      const shared = join(root, name, "cache");
      const temp = join(root, name, "temp");
      for (const dir of [home, temp, join(shared, "synch")])
        mkdirSync(dir, { recursive: true });
      writeFileSync(
        join(shared, "synch/s3.env"),
        `SYNCH_S3_ENDPOINT=${endpoint}\nSYNCH_S3_ACCESS_KEY=test\nSYNCH_S3_SECRET_KEY=test\nSYNCH_S3_READ_BUCKET=cinet\nSYNCH_S3_WRITE_BUCKET=${name}\n`,
      );
      return {
        ...process.env,
        HOME: home,
        PATH: `${bin}:${process.env.PATH}`,
        RUNNER_OS: "macOS",
        RUNNER_NAME: name,
        SYNCH_CACHE_SLOT: "",
        SYNCH_CACHE_SHARED_DIRECTORY: shared,
        RUNNER_TEMP: temp,
        RUNNER_TOOL_CACHE: join(root, name, "tools"),
        GITHUB_ENV: join(temp, "env"),
        GITHUB_WORKSPACE: repo,
      };
    };
    const setup = async (env, families) => {
      writeFileSync(env.GITHUB_ENV, "");
      await run(process.execPath, [join(action, "main.mjs")], {
        cwd: repo,
        env: { ...env, INPUT_FAMILIES: families },
      });
      const values = Object.fromEntries(
        readFileSync(env.GITHUB_ENV, "utf8")
          .trim()
          .split("\n")
          .map((line) => {
            const i = line.indexOf("=");
            return [line.slice(0, i), line.slice(i + 1)];
          }),
      );
      // Files the job writes later are newer than this fixed past stamp.
      const past = new Date("2000-01-01T00:00:00Z");
      utimesSync(join(env.RUNNER_TEMP, "synch-cache.stamp"), past, past);
      return { ...env, ...values };
    };
    const prefetch = (env) =>
      run("bash", [join(action, "electron-prefetch.sh")], { cwd: repo, env });
    const browser = await setup(host("browser"), "pnpm-store playwright");
    await prefetch(browser);
    assert.equal(downloads, 0, "browser jobs must not fetch Electron");
    assert.equal(objects.size, 0);
    const first = await setup(host("first"), "electron");
    const base =
      "https://github.com/electron/electron/releases/download/v45.0.0";
    const hash = createHash("sha256").update(base).digest("hex");
    // Parts an interrupted earlier job left on the host must not reach peers.
    const stale = join(first.electron_config_cache, hash, ".prefetch.stale");
    mkdirSync(stale, { recursive: true });
    writeFileSync(join(stale, "0"), "partial");
    await prefetch(first);
    assert.equal(downloads, 8);
    const key = "comma-cache/Darwin-arm64/electron/45.0.0.tar";
    assert.ok(
      objects.has(key),
      "publish before job cleanup or any later tests run",
    );
    const second = await setup(host("second"), "electron");
    await prefetch(second);
    assert.equal(
      downloads,
      8,
      "a new host uses the peer instead of the release server",
    );
    const zip = join(second.electron_config_cache, hash, name);
    assert.deepEqual(readFileSync(zip), bytes);
    assert.deepEqual(
      readdirSync(dirname(zip)),
      [name],
      "peers receive no temporary download parts",
    );
    // A warm local archive must seed an empty peer cache without downloading again.
    objects.clear();
    rmSync(
      join(
        first.SYNCH_CACHE_SHARED_DIRECTORY,
        "comma-toolchains",
        Buffer.from(first.RUNNER_NAME).toString("hex"),
        "synch-cache/electron/45.0.0",
      ),
    );
    await prefetch(first);
    assert.ok(objects.has(key));
    assert.equal(downloads, 8);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    rmSync(root, { recursive: true, force: true });
  }
});
