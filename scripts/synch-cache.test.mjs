import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  realpathSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const run = promisify(execFile);
const script = fileURLToPath(
  new URL("../.github/actions/synch-cache/synch-cache.sh", import.meta.url),
);

// One gateway: a unified read view, and each host's own write view.
function gateway() {
  const objects = new Map();
  let clock = 0;
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://gateway");
    const [, , ...rest] = url.pathname.split("/");
    const key = rest.join("/");
    if (req.method === "GET" && !key) {
      const prefix = url.searchParams.get("prefix");
      const listed = [...objects]
        .filter(([name]) => name.startsWith(prefix))
        .map(
          ([name, value]) =>
            `<Contents><Key>${name}</Key><LastModified>${value.at}</LastModified></Contents>`,
        );
      res.end(`<ListBucketResult>${listed.join("")}</ListBucketResult>`);
    } else if (req.method === "PUT") {
      const chunks = [];
      req.on("data", (chunk) => chunks.push(chunk));
      req.on("end", () => {
        clock += 1;
        objects.set(key, {
          body: Buffer.concat(chunks),
          at: new Date(Date.UTC(2026, 0, 1, 0, 0, clock)).toISOString(),
        });
        res.end();
      });
    } else if (req.method === "DELETE") {
      objects.delete(key);
      res.statusCode = 204;
      res.end();
    } else if (!objects.has(key)) {
      res.statusCode = 404;
      res.end();
    } else {
      res.end(req.method === "HEAD" ? undefined : objects.get(key).body);
    }
  });
  return { server, objects };
}

test("a Linux runner restores and saves path snapshots through its gateway", async () => {
  const { server, objects } = gateway();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  // Real paths: bsdtar does not extract through a symlinked /var.
  const root = realpathSync(mkdtempSync(join(tmpdir(), "synch cache-")));
  try {
    const shared = join(root, "cache");
    mkdirSync(join(shared, "synch"), { recursive: true });
    writeFileSync(
      join(shared, "synch", "s3.env"),
      [
        `SYNCH_S3_ENDPOINT=http://127.0.0.1:${server.address().port}`,
        "SYNCH_S3_ACCESS_KEY=ci-vm",
        "SYNCH_S3_SECRET_KEY=secret",
        "SYNCH_S3_READ_BUCKET=cinet",
        "SYNCH_S3_WRITE_BUCKET=cinet-own",
      ].join("\n"),
    );
    const job = async (name, inputs, slot = "ci-linux09") => {
      const workspace = join(root, name, "workspace");
      const home = join(root, name, "home");
      const temp = join(root, name, "temp");
      for (const dir of [workspace, home, temp])
        mkdirSync(dir, { recursive: true });
      const output = join(temp, "output");
      writeFileSync(output, "");
      const { stdout } = await run("bash", [script], {
        env: {
          ...process.env,
          RUNNER_OS: "Linux",
          SYNCH_CACHE_SLOT: slot,
          SYNCH_CACHE_SHARED_DIRECTORY: shared,
          RUNNER_TEMP: temp,
          GITHUB_WORKSPACE: workspace,
          GITHUB_OUTPUT: output,
          HOME: home,
          RESTORE_KEYS: "",
          KEEP: "3",
          ...inputs,
        },
      });
      const outputs = Object.fromEntries(
        readFileSync(output, "utf8")
          .trim()
          .split("\n")
          .map((line) => line.split("=")),
      );
      return { stdout, outputs, workspace, home };
    };

    // A main build publishes its deps and its toolchain under the home directory.
    const main = join(root, "main");
    mkdirSync(join(main, "workspace", "systems", "deps"), { recursive: true });
    writeFileSync(
      join(main, "workspace", "systems", "deps", "lib"),
      "deps of main",
    );
    mkdirSync(join(main, "home", ".elan"), { recursive: true });
    writeFileSync(join(main, "home", ".elan", "lean"), "toolchain");
    const paths = "systems/deps\n~/.elan";
    for (const key of ["mix-abc-1", "mix-abc-2"]) {
      const saved = await job("main", {
        MODE: "save",
        FAMILY: "mix",
        KEY: key,
        PATHS: paths,
      });
      assert.match(saved.stdout, new RegExp(`published ${key}`));
    }
    const again = await job("main", {
      MODE: "save",
      FAMILY: "mix",
      KEY: "mix-abc-2",
      PATHS: paths,
    });
    assert.match(again.stdout, /a peer already published mix-abc-2/);

    rmSync(join(main, "workspace", "systems"), { recursive: true });
    rmSync(join(main, "home", ".elan"), { recursive: true });
    // A pull request misses its exact key and takes the newest build of its prefix.
    const pr = await job("pr", {
      MODE: "restore",
      FAMILY: "mix",
      KEY: "mix-abc-3",
      RESTORE_KEYS: "mix-zzz-\nmix-abc-",
      PATHS: paths,
    });
    assert.equal(pr.outputs["cache-hit"], "false");
    assert.equal(pr.outputs["matched-key"], "mix-abc-2");
    // Members are absolute paths, so they land where the main job had them.
    assert.equal(
      readFileSync(join(main, "workspace", "systems", "deps", "lib"), "utf8"),
      "deps of main",
    );
    assert.equal(
      readFileSync(join(main, "home", ".elan", "lean"), "utf8"),
      "toolchain",
    );

    // A job whose source is as old as the first build takes that build: the
    // newer one holds commits the source lacks. With none that old, the newest.
    const stamp = (key) =>
      [...objects].find(([name]) => name.endsWith(`/${key}.tar`))[1].at;
    const older = await job("pr", {
      MODE: "restore",
      FAMILY: "mix",
      KEY: "mix-abc-3",
      RESTORE_KEYS: "mix-abc-",
      NOT_AFTER: stamp("mix-abc-1").slice(0, 19),
      PATHS: paths,
    });
    assert.equal(older.outputs["matched-key"], "mix-abc-1");
    const none = await job("pr", {
      MODE: "restore",
      FAMILY: "mix",
      KEY: "mix-abc-3",
      RESTORE_KEYS: "mix-abc-",
      NOT_AFTER: "2025-12-31T23:59:59",
      PATHS: paths,
    });
    assert.equal(none.outputs["matched-key"], "mix-abc-2");

    const exact = await job("pr", {
      MODE: "restore",
      FAMILY: "mix",
      KEY: "mix-abc-1",
      PATHS: paths,
    });
    assert.equal(exact.outputs["cache-hit"], "true");

    // Each host keeps its newest snapshots of a family.
    for (const key of ["mix-abc-3", "mix-abc-4"]) {
      await job("main", {
        MODE: "save",
        FAMILY: "mix",
        KEY: key,
        PATHS: paths,
        KEEP: "2",
      });
    }
    assert.deepEqual(
      [...objects.keys()].filter((key) => key.includes("/mix/")).sort(),
      [
        `comma-cache/${process.platform === "darwin" ? "Darwin" : "Linux"}-${(
          await run("uname", ["-m"])
        ).stdout.trim()}/mix/mix-abc-3.tar`,
        `comma-cache/${process.platform === "darwin" ? "Darwin" : "Linux"}-${(
          await run("uname", ["-m"])
        ).stdout.trim()}/mix/mix-abc-4.tar`,
      ],
    );

    // A runner without a slot has no gateway: a miss, and nothing published.
    const hosted = await job(
      "hosted",
      { MODE: "restore", FAMILY: "mix", KEY: "mix-abc-1", PATHS: paths },
      "",
    );
    assert.equal(hosted.outputs["cache-hit"], "false");
    assert.match(hosted.stdout, /no gateway on this runner/);
    assert.equal(existsSync(join(hosted.workspace, "systems", "deps")), false);
  } finally {
    server.close();
    rmSync(root, { recursive: true, force: true });
  }
});
