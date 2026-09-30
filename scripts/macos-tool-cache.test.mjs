import { test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  realpathSync,
  readdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const selector = fileURLToPath(
  new URL(
    "../.github/actions/setup-macos-cache/select-cache.sh",
    import.meta.url,
  ),
);

test("runner-native Go paths and Playwright downloads survive guest replacement", () => {
  const root = mkdtempSync(join(tmpdir(), "comma tools-"));
  try {
    const shared = join(root, "My Shared Files", "cache");
    mkdirSync(shared, { recursive: true });
    const select = (
      guest,
      slot = "tokyo / 1",
      os = "macOS",
      mount = shared,
    ) => {
      const tools = join(root, guest, "_tool");
      const env = join(root, `${guest}.env`);
      writeFileSync(env, "");
      execFileSync("bash", [selector, mount], {
        env: {
          ...process.env,
          RUNNER_OS: os,
          RUNNER_NAME: slot,
          RUNNER_TOOL_CACHE: tools,
          GITHUB_ENV: env,
          GITHUB_OUTPUT: join(root, `${guest}.output`),
        },
      });
      const values = Object.fromEntries(
        readFileSync(env, "utf8")
          .trim()
          .split("\n")
          .filter(Boolean)
          .map((line) => {
            const index = line.indexOf("=");
            return [line.slice(0, index), line.slice(index + 1)];
          }),
      );
      return { tools, browsers: values.PLAYWRIGHT_BROWSERS_PATH };
    };
    // Image tools must survive migration; unrelated tool families remain local.
    const original = join(root, "guest1", "_tool");
    mkdirSync(join(original, "go", "1.26.6", "arm64"), { recursive: true });
    writeFileSync(join(original, "go", "1.26.6", "arm64.complete"), "");
    writeFileSync(
      join(original, "go", "1.26.6", "arm64", "installed"),
      "image Go",
    );
    mkdirSync(join(original, "node"));
    writeFileSync(join(original, "node", "installed"), "image Node");
    const first = select("guest1");
    assert.equal(
      readFileSync(join(first.tools, "node", "installed"), "utf8"),
      "image Node",
    );
    assert.ok(
      realpathSync(join(first.tools, "go")).startsWith(realpathSync(shared)),
      "setup-go must reach shared storage through the runner-provided root",
    );
    const backup = readdirSync(first.tools).find((name) =>
      name.startsWith("comma-go-backup."),
    );
    assert.equal(
      readFileSync(
        join(first.tools, backup, "go", "1.26.6", "arm64", "installed"),
        "utf8",
      ),
      "image Go",
    );
    writeFileSync(join(first.browsers, "chromium-fixture"), "browser download");
    // setup-go's actual tool-cache root is supplied by the runner, not an output.
    mkdirSync(join(first.tools, "go", "1.27.0", "arm64"), { recursive: true });
    writeFileSync(join(first.tools, "go", "1.27.0", "arm64.complete"), "");
    const second = select("guest2");
    assert.ok(existsSync(join(second.tools, "go", "1.27.0", "arm64.complete")));
    assert.equal(
      readFileSync(
        join(second.tools, "go", "1.26.6", "arm64", "installed"),
        "utf8",
      ),
      "image Go",
    );
    assert.equal(
      readFileSync(join(second.browsers, "chromium-fixture"), "utf8"),
      "browser download",
    );
    assert.equal(
      realpathSync(join(second.tools, "go")),
      realpathSync(join(first.tools, "go")),
    );
    assert.deepEqual(select("guest2"), second); // repeated setup is safe
    const other = select("guest3", "tokyo / 2");
    assert.equal(
      existsSync(join(other.tools, "go", "1.27.0", "arm64.complete")),
      false,
    );
    assert.equal(existsSync(join(other.browsers, "chromium-fixture")), false);
    const linux = select("linux", "tokyo", "Linux");
    assert.equal(existsSync(linux.tools), false);
    assert.equal(linux.browsers, undefined);
    const absent = select(
      "absent",
      "tokyo",
      "macOS",
      join(root, "absent-mount"),
    );
    assert.equal(existsSync(absent.tools), false);
    assert.equal(absent.browsers, undefined);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
