import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { expect, test } from "@playwright/test";
import { openWaitTargetAlreadyExited } from "../src/main/open-wait";

const run = promisify(execFile);
const helper = resolve(
  __dirname,
  "../dist/native/darwin/arm64/native/macos/Comma Computer Use.app"
);

test("permission probes exit without credentials and preserve the control socket", async () => {
  test.skip(process.platform !== "darwin" || process.arch !== "arm64");
  const directory = await mkdtemp(join(tmpdir(), "comma-permission-probe-"));
  const socketPath = join(directory, "computeruse.sock");
  await writeFile(socketPath, "active connector owns this path");
  try {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const outputPath = join(directory, `status-${attempt}.json`);
      await run(
        "open",
        [
          "-n",
          "-g",
          "-W",
          "--stdout",
          outputPath,
          "--stderr",
          join(directory, "stderr"),
          "--env",
          "COMMA_COMPUTER_USE_AUTH_TOKEN=",
          "--env",
          `COMMA_COMPUTER_USE_SOCKET_PATH=${socketPath}`,
          helper,
          "--args",
          "--permissions-status",
        ],
        { timeout: 10_000 }
      ).catch((error: unknown) => {
        if (!openWaitTargetAlreadyExited(error)) throw error;
      });
      expect(JSON.parse(await readFile(outputPath, "utf8"))).toEqual({
        ok: true,
        permissions: {
          accessibility: expect.any(Boolean),
          screenRecording: expect.any(Boolean),
        },
      });
      expect(await readFile(socketPath, "utf8")).toBe(
        "active connector owns this path"
      );
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("authorization window exits after existing permissions are confirmed", async () => {
  test.skip(process.platform !== "darwin" || process.arch !== "arm64");
  const directory = await mkdtemp(join(tmpdir(), "comma-authorization-window-"));
  try {
    const output = join(directory, "permissions.json");
    await run(
      "open",
      ["-n", "-g", "-W", "--stdout", output, helper, "--args", "--permissions-status"],
      { timeout: 10_000 }
    ).catch((error: unknown) => {
      if (!openWaitTargetAlreadyExited(error)) throw error;
    });
    const { permissions } = JSON.parse(await readFile(output, "utf8"));
    test.skip(
      !permissions.accessibility || !permissions.screenRecording,
      "This smoke test requires manually granted macOS permissions."
    );
    await run("open", ["-n", "-W", helper, "--args", "--permissions-ui"], {
      timeout: 10_000,
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
