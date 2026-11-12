import { electron, expect, test } from "./electron-test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { closeElectronTestApp } from "./close-electron-test-app";
import { defaultAgentVMMHostLifecyclePath } from "../src/main/modules/compute-node";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
// These launches point HOME at a temporary directory, which has no login
// keychain. On macOS the first Safe Storage read then raises the system
// "Keychain Not Found" alert: UserNotificationCenter becomes the active app and
// keeps window focus from every later Electron test in the serial job. The
// mock keychain keeps Safe Storage in the process.
const TEMPORARY_HOME_KEYCHAIN_ARGS = ["--use-mock-keychain"];

test("signed-out desktop can inspect local resources without cloud authority", async () => {
  const directory = await mkdtemp(join(tmpdir(), "comma-local-resources-e2e-"));
  const lifecycle = defaultAgentVMMHostLifecyclePath(directory);
  const collectedAt = new Date().toISOString();
  await mkdir(resolve(lifecycle, ".."), { recursive: true });
  await writeFile(
    lifecycle,
    `#!/bin/sh
set -eu
cat >/dev/null
case "$1" in
local-environments) printf '%s' '${JSON.stringify({ collectedAt, bootId: "fixture-boot", environments: [{ id: "fixture-local-env", origin: "local", state: "observed_active", revision: "1", privateDiskBytes: "1", sampledAt: collectedAt }] })}' ;;
local-disk) printf '%s' '${JSON.stringify({ collectedAt, bootId: "fixture-boot", guestStateFs: { usedBytes: "1024", capacityBytes: "4096", importReservationBytes: "512", imageRuntimeBytes: "700", buildCacheBytes: "300", privateBytes: "1", otherBytes: "23", breakdownSampledAt: collectedAt } })}' ;;
*) exit 2 ;;
esac
`,
    { mode: 0o700 }
  );
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [
      electronMain,
      "--lang=en-US",
      `--user-data-dir=${join(directory, "user-data")}`,
      ...TEMPORARY_HOME_KEYCHAIN_ARGS,
    ],
    cwd: electronAppDir,
    env: {
      ...hostEnv,
      HOME: directory,
      COMMA_API_BASE_URL: "http://127.0.0.1:65535",
      COMMA_ELECTRON_E2E_COMPUTE_NODE_LIFECYCLE_PATH: lifecycle,
      NODE_ENV: "test",
    },
  });
  try {
    const page = await findElectronWindowByNativeRole(app, "main-window");
    await expect(
      page.getByRole("button", { name: "Manage local resources", exact: true })
    ).toBeVisible();
    expect(
      await page.evaluate(() => window.commaNative!.session.state.get())
    ).toMatchObject({ phase: "signed_out" });
    await page
      .getByRole("button", { name: "Manage local resources", exact: true })
      .click();
    await expect(
      page.getByRole("group", {
        name: "1 KiB used of 4 KiB",
        exact: true,
      })
    ).toBeVisible();
    expect(
      await page.evaluate(() => window.commaNative!.computeNode.localOverview({}))
    ).toMatchObject({
      availability: "available",
      disk: {
        usedBytes: "1024",
        imageRuntimeBytes: "700",
        buildCacheBytes: "300",
        privateBytes: "1",
        otherBytes: "23",
        breakdownSampledAt: collectedAt,
      },
    });
    await expect(page.getByText("Local data", { exact: true }).first()).toBeVisible();
    await page.getByRole("button", { name: /Node actions$/ }).click();
    await expect(
      page.getByRole("menuitem", { name: "Delete local environment", exact: true })
    ).toBeVisible();
    await expect(
      page.getByRole("menuitem", { name: "Workloads", exact: true })
    ).toHaveCount(0);
  } finally {
    await closeElectronTestApp(app).catch(() => {});
    await rm(directory, { force: true, recursive: true });
  }
});
