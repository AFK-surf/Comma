import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  rmSync,
  realpathSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const run = promisify(execFile);
const script = fileURLToPath(
  new URL("../.github/actions/host-snapshot/host-snapshot.sh", import.meta.url),
);

test("the guests of a host share snapshots through its store", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "host snapshot-")));
  try {
    const shared = join(root, "cache");
    const store = join(shared, "comma-snapshots");
    mkdirSync(store, { recursive: true });
    const job = async (name, inputs) => {
      const home = join(root, name, "home");
      const temp = join(root, name, "temp");
      for (const dir of [home, temp]) mkdirSync(dir, { recursive: true });
      const output = join(temp, "output");
      writeFileSync(output, "");
      const { stdout } = await run("bash", [script], {
        env: {
          ...process.env,
          RUNNER_OS: "macOS",
          SYNCH_CACHE_SHARED_DIRECTORY: shared,
          RUNNER_TEMP: temp,
          GITHUB_WORKSPACE: join(root, name),
          GITHUB_OUTPUT: output,
          HOME: home,
          RESTORE_KEYS: "",
          ...inputs,
        },
      });
      const outputs = Object.fromEntries(
        readFileSync(output, "utf8")
          .trim()
          .split("\n")
          .map((line) => line.split("=")),
      );
      return { stdout, outputs };
    };
    const sdk = join(root, "sdk");
    const save = async (key, content) => {
      mkdirSync(sdk, { recursive: true });
      writeFileSync(join(sdk, "tools"), content);
      return job("save", { MODE: "save", FAMILY: "sdk", KEY: key, PATHS: sdk });
    };
    assert.match((await save("sdk-v1-a", "a")).stdout, /saved sdk-v1-a/);
    assert.match(
      (await save("sdk-v1-a", "a")).stdout,
      /the store already has sdk-v1-a/,
    );

    // Another guest misses its exact key and takes the prefix's newest snapshot.
    rmSync(sdk, { recursive: true });
    const restored = await job("guest", {
      MODE: "restore",
      FAMILY: "sdk",
      KEY: "sdk-v1-b",
      RESTORE_KEYS: "sdk-v1-",
      PATHS: sdk,
    });
    assert.equal(restored.outputs["cache-hit"], "false");
    assert.equal(restored.outputs["matched-key"], "sdk-v1-a");
    assert.equal(readFileSync(join(sdk, "tools"), "utf8"), "a");
    const exact = await job("guest", {
      MODE: "restore",
      FAMILY: "sdk",
      KEY: "sdk-v1-a",
      PATHS: sdk,
    });
    assert.equal(exact.outputs["cache-hit"], "true");

    // Over the size limit, the least recently used snapshots go first.
    writeFileSync(join(store, "max-gb"), "0\n");
    assert.match(
      (await save("sdk-v1-b", "b")).stdout,
      /removed \S+sdk-v1-a\.tar[\s\S]*removed \S+sdk-v1-b\.tar/,
    );

    // Without the store, nothing is restored or saved.
    rmSync(store, { recursive: true });
    const none = await job("guest", {
      MODE: "restore",
      FAMILY: "sdk",
      KEY: "sdk-v1-a",
      PATHS: sdk,
    });
    assert.match(none.stdout, /no snapshot store on this runner/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
