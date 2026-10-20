import { existsSync } from "node:fs";
import { electron, expect, test } from "./electron-test";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { closeElectronTestApp } from "./close-electron-test-app";
import { defaultAgentVMMHostLifecyclePath } from "../src/main/modules/compute-node";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
// These launches point HOME at a temporary directory, which has no login
// keychain. On macOS the first Safe Storage read then raises the system
// "Keychain Not Found" alert: UserNotificationCenter becomes the active app and
// keeps window focus from every later Electron test in the serial job. The
// mock keychain keeps Safe Storage in the process.
const TEMPORARY_HOME_KEYCHAIN_ARGS = ["--use-mock-keychain"];

test(
  "compute node resumes acknowledged enrollment and re-enables an existing Shell across restart",
  { tag: "@mac" },
  async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-compute-node-e2e-"));
    const userDataPath = join(directory, "user-data");
    const runtimeDirectory = join(directory, "runtime");
    const lifecycle = defaultAgentVMMHostLifecyclePath(directory);
    const workspaceId = "wsp_compute_node_e2e";
    let operationId = "vmm_install_compute_node_e2e";
    let productStatus: "processing" | "ready" | "stopped" | "removed" = "processing";
    const productRequests: string[] = [];
    const authorizationKeys: string[] = [];
    let loseAuthorizationResponse = true;
    const sessionStub = await startSessionProjectionStub({
      email: "compute-node@comma.local",
      handleRequest: (request, response, path) => {
        productRequests.push(`${request.method ?? "UNKNOWN"} ${path}`);
        // The client core reads Compute for a workspace of the account's list.
        if (request.method === "GET" && path === "/v1/comma/workspaces") {
          respondJson(response, {
            data: [
              { id: workspaceId, group_id: "grp_compute_node_e2e", name: "Compute" },
            ],
          });
          return true;
        }
        if (
          request.method === "GET" &&
          path === `/v1/comma/workspaces/${workspaceId}/compute`
        ) {
          respondJson(response, { can_manage: true, environments: [], workloads: [] });
          return true;
        }
        const requestedWorkspace =
          path.match(/workspaces\/([^/]+)\/compute-nodes/)?.[1] ?? workspaceId;
        const operationPath = `/v1/comma/workspaces/${requestedWorkspace}/compute-nodes/agent-vmm/install-operations`;
        if (
          request.method === "POST" &&
          (path === operationPath || path === `${operationPath}/${operationId}/retry`)
        ) {
          request.resume();
          productStatus = "ready";
          if (path === operationPath)
            authorizationKeys.push(String(request.headers["idempotency-key"]));
          if (loseAuthorizationResponse) {
            loseAuthorizationResponse = false;
            // The request is delivered and its answer is lost after it began:
            // the app cannot know whether the product authorized it. (A
            // connection that drops before any answer, the network stack
            // sends again by itself.)
            request.on("end", () => {
              response.writeHead(200, { "content-type": "application/json" });
              response.write("{", () => request.socket.destroy());
            });
            return true;
          }
          respondJson(response, {
            descriptor: {
              exchange_url:
                "https://api.comma.test/v1/compute/agent-vmm/install-operations/exchange",
              expires_at: "2099-01-01T00:00:00Z",
              one_time_secret: "vmmi_e2e",
              operation_id: operationId,
              version: 1,
            },
            operation: {
              id: operationId,
              registration_id: `${operationId}_registration`,
              status: productStatus,
            },
          });
          return true;
        }
        if (path === `${operationPath}/${operationId}` && request.method === "GET") {
          respondJson(response, {
            operation: {
              authorization_status: existsSync(join(runtimeDirectory, "installed"))
                ? "handed_off"
                : "requested",
              status: existsSync(join(runtimeDirectory, "installed"))
                ? productStatus
                : "processing",
            },
          });
          return true;
        }
        const action = path.slice(`${operationPath}/${operationId}/`.length);
        if (
          request.method === "POST" &&
          path.startsWith(`${operationPath}/${operationId}/`) &&
          ["enable", "disable", "revoke", "initialize-workload"].includes(action)
        ) {
          request.resume();
          productStatus =
            action === "enable" || action === "initialize-workload"
              ? "ready"
              : action === "disable"
                ? "stopped"
                : "removed";
          respondJson(response, {
            operation: {
              authorization_status: action === "revoke" ? "revoked" : "handed_off",
              status: productStatus,
            },
          });
          return true;
        }
        return false;
      },
    });
    await mkdir(userDataPath, { recursive: true });
    recordElectronOnboardingCompleted(userDataPath, [sessionStub.userId]);
    await mkdir(runtimeDirectory, { recursive: true });
    await mkdir(resolve(lifecycle, ".."), { recursive: true });
    await writeFile(lifecycle, lifecycleFixture(runtimeDirectory), { mode: 0o700 });
    await writeFile(
      join(userDataPath, "compute-node-intent.json"),
      JSON.stringify({
        desiredEnabled: false,
        revision: 1,
        version: 1,
      })
    );
    await chmod(lifecycle, 0o700);
    await writeFile(join(runtimeDirectory, "fail-install"), "once");

    const launch = (seedSession = true) => {
      const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
      return electron.launch({
        args: [
          electronMain,
          "--lang=en-US",
          `--user-data-dir=${userDataPath}`,
          ...TEMPORARY_HOME_KEYCHAIN_ARGS,
        ],
        cwd: electronAppDir,
        env: {
          ...hostEnv,
          HOME: directory,
          COMMA_API_BASE_URL: sessionStub.baseUrl,
          ...(seedSession
            ? {
                COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "compute-node@comma.local",
                COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "comma_sess_compute_node_e2e",
              }
            : {}),
          COMMA_ELECTRON_E2E_COMPUTE_NODE_LIFECYCLE_PATH: lifecycle,
          NODE_ENV: "test",
        },
      });
    };

    let app = await launch();
    try {
      await findElectronWindowByNativeRole(app, "main-window");

      let page = await openComputeNode(app);
      await page.getByRole("button", { name: "Enable this Mac", exact: true }).click();
      await page
        .getByRole("dialog", { name: "Enable this Mac", exact: true })
        .getByRole("button", { name: "Enable this Mac", exact: true })
        .click();
      await expect
        .poll(
          async () =>
            (await page.evaluate(() => window.commaNative!.computeNode.state.get()))
              .recoveryActions
        )
        .toContain("continue_enable");
      await expect(
        page.getByRole("button", { name: "Continue setup", exact: true })
      ).toBeVisible();
      await expect(
        page.getByText(
          "The workspace service could not be reached. Check its status before continuing the same setup.",
          { exact: true }
        )
      ).toBeVisible();
      await expect(
        page.getByText("Native command failed.", { exact: true })
      ).toHaveCount(0);
      await closeElectronTestApp(app);
      app = await launch(false);
      page = await openComputeNode(app);
      const commandsBeforeRetry = await readFile(
        join(runtimeDirectory, "commands"),
        "utf8"
      ).catch(() => "");
      expect(
        commandsBeforeRetry
          .split("\n")
          .filter((command) => command.startsWith("install "))
      ).toHaveLength(0);
      await page.getByRole("button", { name: "Continue setup", exact: true }).click();
      await page
        .getByRole("dialog", { name: "Enable this Mac", exact: true })
        .getByRole("button", { name: "Enable this Mac", exact: true })
        .click();
      await expect(
        page.getByRole("button", { name: "Continue setup", exact: true })
      ).toBeVisible();
      await expect.poll(() => authorizationKeys).toHaveLength(2);
      expect(authorizationKeys[1]).toBe(authorizationKeys[0]);
      await expect(
        page.getByText(/The local workspace connection could not finish/)
      ).toBeVisible();
      await closeElectronTestApp(app);
      app = await launch(false);
      page = await openComputeNode(app);
      // Main reports the retryable connection failure as `connection_failed`; the page words it.
      await expect(
        page.getByText(
          /The components are installed, but the workspace connection did not finish/
        )
      ).toBeVisible();
      await expect(
        page.getByRole("button", { name: "Continue setup", exact: true })
      ).toBeVisible();
      const receiptPath = join(runtimeDirectory, "operation.json");
      const recoverableReceipt = await readFile(receiptPath, "utf8");
      await closeElectronTestApp(app);
      const terminalReceipt = JSON.parse(recoverableReceipt);
      delete terminalReceipt.retryable;
      terminalReceipt.attempt = 3;
      terminalReceipt.failureCode = "retry_limit_reached";
      await writeFile(receiptPath, JSON.stringify(terminalReceipt));
      app = await launch(false);
      page = await openComputeNode(app);
      await expect(
        page.getByText(/The connection reached its retry limit/)
      ).toBeVisible();
      await expect(
        page.getByRole("button", { name: "Continue setup", exact: true })
      ).toHaveCount(0);
      await expect(
        page.getByRole("button", { name: "Reconnect", exact: true })
      ).toHaveCount(0);
      const nativeMutations = async () =>
        (await readFile(join(runtimeDirectory, "commands"), "utf8"))
          .split("\n")
          .filter((line) =>
            /^(install|repair|registration-state|registration-revoke) /.test(line)
          );
      const beforeCheck = await nativeMutations();
      await page
        .getByRole("button", { name: "Check status", exact: true })
        .first()
        .click();
      await expect(
        page.getByRole("dialog", { name: "Repair compute node", exact: true })
      ).toHaveCount(0);
      expect(await nativeMutations()).toEqual(beforeCheck);
      await closeElectronTestApp(app);
      await writeFile(receiptPath, recoverableReceipt);
      app = await launch(false);
      page = await openComputeNode(app);

      await page.screenshot({
        path: "/tmp/compute-lifecycle-repair-visual/ack-enrollment-failed-electron.png",
        fullPage: true,
      });
      await page.getByRole("button", { name: "Continue setup", exact: true }).click();
      await page
        .getByRole("dialog", { name: "Enable this Mac", exact: true })
        .getByRole("button", { name: "Enable this Mac", exact: true })
        .click();
      await expect
        .poll(() => page.evaluate(() => window.commaNative!.computeNode.state.get()))
        .toMatchObject({ status: "ready", observationFresh: true });
      await expect
        .poll(async () => readFile(join(runtimeDirectory, "commands"), "utf8"))
        .toContain(
          "install --service-type agent --request-id vmm_install_compute_node_e2e --operation-stdin"
        );
      expect(
        productRequests.filter((request) => request.endsWith("/initialize-workload"))
      ).toHaveLength(1);
      expect(await readFile(join(runtimeDirectory, "commands"), "utf8")).toContain(
        `--resume-operation ${operationId}`
      );
      const enables = productRequests.filter((request) =>
        request.endsWith("/enable")
      ).length;
      await page.evaluate(async (id) => {
        const state = await window.commaNative!.computeNode.state.get();
        await window.commaNative!.computeNode.drain({
          workspaceId: state.bindingWorkspaceId!,
          installationId: state.bindingInstallationId ?? null,
          confirmationId: state.confirmationId,
          bindingRevision: state.bindingRevision!,
        });
        await window.commaNative!.computeNode.configure({
          desiredEnabled: true,
          workspaceId: id,
        });
      }, workspaceId);
      await expect
        .poll(() => page.evaluate(() => window.commaNative!.computeNode.state.get()))
        .toMatchObject({ status: "ready" });
      expect(
        productRequests.filter((request) => request.endsWith("/enable"))
      ).toHaveLength(enables + 1);
      expect(
        productRequests.filter((request) => request.endsWith("/initialize-workload"))
      ).toHaveLength(2);
      await page.screenshot({
        path: "/tmp/compute-lifecycle-repair-visual/existing-shell-reenabled-electron.png",
        fullPage: true,
      });
      await closeElectronTestApp(app);
      app = await launch(false);
      page = await openComputeNode(app);
      await expect(
        page.getByText(/^(Connected|Available for new work)$/).first()
      ).toBeVisible();
      expect(
        productRequests.filter((request) => request.endsWith("/initialize-workload"))
      ).toHaveLength(2);
      await openLocalSettings(page);
      await page
        .getByRole("button", { name: "Stop providing compute…", exact: true })
        .click();
      await expect(page.getByText(/Running work may not stop at once/)).toBeVisible();
      await page.getByRole("button", { name: "Cancel", exact: true }).click();
      await expect(
        page.getByText(/^(Connected|Available for new work)$/).first()
      ).toBeVisible();
      expect(
        productRequests.filter((request) => request.endsWith("/disable"))
      ).toHaveLength(1);
      for (const [action, nextWorkspace] of [
        ["Disable node", "wsp_other"],
        ["Remove compute node", workspaceId],
      ] as const) {
        await page
          .getByRole("button", {
            name:
              action === "Disable node"
                ? "Stop providing compute…"
                : "Disconnect this workspace…",
            exact: true,
          })
          .click();
        // Another window replaces the binding while this confirmation remains open.
        await page.evaluate(async (id) => {
          const state = await window.commaNative!.computeNode.state.get();
          await window.commaNative!.computeNode.remove({
            workspaceId: state.bindingWorkspaceId!,
            installationId: state.bindingInstallationId ?? null,
            confirmationId: state.confirmationId,
            bindingRevision: state.bindingRevision!,
          });
          await window.commaNative!.computeNode.configure({
            desiredEnabled: true,
            workspaceId: id,
          });
        }, nextWorkspace);
        const mutations = productRequests.filter(
          (request) => request.endsWith("/disable") || request.endsWith("/revoke")
        );
        await expect(
          page.getByRole("dialog", { name: action, exact: true })
        ).toHaveCount(0);
        await expect
          .poll(async () =>
            page.evaluate(() => window.commaNative!.computeNode.state.get())
          )
          .toMatchObject({
            desiredEnabled: true,
            bindingWorkspaceId: nextWorkspace,
            status: "ready",
          });
        expect(
          productRequests.filter(
            (request) => request.endsWith("/disable") || request.endsWith("/revoke")
          )
        ).toEqual(mutations);
      }
      await page
        .getByRole("button", { name: "Stop providing compute…", exact: true })
        .click();
      await page.getByRole("button", { name: "Disable node", exact: true }).click();
      await expect(page.getByText("Node disabled", { exact: true })).toBeVisible();

      // A completed local reset fences this install even while cloud handoff remains accepted.
      const maintenanceDirectory = join(
        directory,
        "Library",
        "Application Support",
        "Agent VMM Maintenance"
      );
      await mkdir(maintenanceDirectory, { recursive: true });
      await writeFile(
        join(maintenanceDirectory, "state.json"),
        JSON.stringify({
          version: 1,
          uninstalled: false,
          blockedInstalls: { [operationId]: true },
        })
      );
      await writeFile(join(runtimeDirectory, "reset"), "confirmed");
      await closeElectronTestApp(app);
      app = await launch(false);
      page = await openComputeNode(app);
      await expect(
        page.getByRole("button", { name: "Finish removal", exact: true })
      ).toBeVisible();
      await expect(
        page.getByRole("button", { name: "Continue setup", exact: true })
      ).toHaveCount(0);
      const commandsBeforeResetRecovery = await readFile(
        join(runtimeDirectory, "commands"),
        "utf8"
      );
      await page.evaluate(async () => {
        const state = await window.commaNative!.computeNode.state.get();
        await window.commaNative!.computeNode.configure({
          desiredEnabled: true,
          workspaceId: state.bindingWorkspaceId!,
        });
      });
      const commandsAfterResetRecovery = await readFile(
        join(runtimeDirectory, "commands"),
        "utf8"
      );
      expect(
        commandsAfterResetRecovery
          .split("\n")
          .filter((line) => line.startsWith("install "))
      ).toEqual(
        commandsBeforeResetRecovery
          .split("\n")
          .filter((line) => line.startsWith("install "))
      );
      const revocations = () =>
        productRequests.filter((request) => request.endsWith(`/${operationId}/revoke`));
      const revocationsBeforeConfirmation = revocations().length;
      await page.getByRole("button", { name: "Finish removal", exact: true }).click();
      await page
        .getByRole("dialog", { name: "Remove compute node", exact: true })
        .getByRole("button", { name: "Remove compute node", exact: true })
        .click();
      await expect
        .poll(() => page.evaluate(() => window.commaNative!.computeNode.state.get()))
        .toMatchObject({ status: "removed" });
      expect(revocations()).toHaveLength(revocationsBeforeConfirmation + 1);
      operationId = "vmm_install_after_reset_e2e";
      await page.getByRole("button", { name: "Enable this Mac", exact: true }).click();
      await page
        .getByRole("dialog", { name: "Enable this Mac", exact: true })
        .getByRole("button", { name: "Enable this Mac", exact: true })
        .click();
      await expect
        .poll(() => page.evaluate(() => window.commaNative!.computeNode.state.get()))
        .toMatchObject({ status: "ready", bindingInstallationId: operationId });
    } finally {
      await closeElectronTestApp(app).catch(() => {});
      await sessionStub.close();
      await rm(directory, { force: true, recursive: true });
    }
  }
);

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
local-environments) printf '%s' '${JSON.stringify({ collectedAt, bootId: "fixture-boot", environments: [{ id: "fixture-local-env", origin: "local", state: "observed_active", revision: "1", privateDiskBytes: "256", sampledAt: collectedAt }] })}' ;;
local-disk) printf '%s' '${JSON.stringify({ collectedAt, bootId: "fixture-boot", guestStateFs: { usedBytes: "1024", capacityBytes: "4096", importReservationBytes: "512" } })}' ;;
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
    await page.getByRole("button", { name: "Manage storage", exact: true }).click();
    await expect(
      page.getByRole("group", {
        name: "1 KiB used of 4 KiB",
        exact: true,
      })
    ).toBeVisible();
    await expect(page.getByText(/Local environment/).first()).toBeVisible();
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

async function openComputeNode(app: Awaited<ReturnType<typeof electron.launch>>) {
  const page = await findElectronWindowByNativeRole(app, "main-window");
  await page.waitForLoadState("domcontentloaded");
  await page.evaluate(() => {
    window.location.hash = "#/settings";
  });
  await page.getByRole("button", { name: "Devices" }).click();
  await expect(page.getByRole("heading", { level: 1, name: "Devices" })).toBeVisible();
  return page;
}

function lifecycleFixture(runtimeDirectory: string) {
  return `#!/bin/sh
set -eu
runtime=${JSON.stringify(runtimeDirectory)}
mkdir -p "$runtime"
printf '%s\n' "$*" >> "$runtime/commands"
case "\${1:-}" in
maintenance-status) cat >/dev/null; printf null ;;
status)
  if [ -f "$runtime/installed" ]; then installed=true; else installed=false; fi
  if [ -f "$runtime/loaded" ]; then loaded=true; else loaded=false; fi
  if [ "$installed" = true ]; then registration_read=present; else registration_read=absent; fi
  if [ -f "$runtime/reset" ]; then registration_read=absent; loaded=false; fi
  if [ -f "$runtime/revoked" ]; then registration_state=revoked; elif [ -f "$runtime/draining" ]; then registration_state=draining; else registration_state=enabled; fi
  if [ "$installed" = true ]; then
    host_readable=true
    host_healthy=true
  else
    host_readable=false
    host_healthy=false
  fi
  operation=null
  if [ -f "$runtime/operation.json" ]; then operation=$(cat "$runtime/operation.json"); fi
  printf '{"operation":%s,"appInstalled":%s,"hostInstalled":%s,"connectorInstalled":%s,"hostLoaded":%s,"connectorLoaded":%s,"hostReadable":%s,"hostHealthy":%s,"salixRevoked":false,"registrationRead":"%s","registrationState":"%s"}\n' "$operation" "$installed" "$installed" "$installed" "$host_healthy" "$loaded" "$host_readable" "$host_healthy" "$registration_read" "$registration_state"
  ;;
install|repair)
  case " $* " in *" --operation-stdin "*) cat >/dev/null ;; esac
  if [ -f "$runtime/fail-install" ]; then
    rm "$runtime/fail-install"
    touch "$runtime/installed"
    request_id=""
    previous=""
    for argument in "$@"; do
      if [ "$previous" = "--request-id" ]; then request_id="$argument"; fi
      previous="$argument"
    done
    printf '{"operationId":"%s","kind":"install-managed","outcome":"failed","attempt":1,"failureStage":"register","failureCode":"transient_unavailable","retryable":true,"failureMessage":"private transport details"}' "$request_id" > "$runtime/operation.json"
    cat "$runtime/operation.json"
    exit 1
  fi
  rm -f "$runtime/revoked" "$runtime/draining" "$runtime/reset" "$runtime/operation.json"
  touch "$runtime/installed" "$runtime/loaded"
  ;;
registration-state)
  case "$*" in
    *"--state enabled"*) rm -f "$runtime/draining"; touch "$runtime/loaded" ;;
    *"--state draining"*) touch "$runtime/draining"; rm -f "$runtime/loaded" ;;
    *) exit 2 ;;
  esac
  ;;
registration-revoke) touch "$runtime/revoked"; rm -f "$runtime/loaded" ;;
drain) rm -f "$runtime/loaded" ;;
*) exit 2 ;;
esac
`;
}

function respondJson(response: import("node:http").ServerResponse, body: unknown) {
  response.writeHead(200, {
    "cache-control": "no-store",
    "content-type": "application/json",
  });
  response.end(JSON.stringify(body));
}

async function openLocalSettings(page: import("@playwright/test").Page) {
  if (await page.locator('[data-compute-screen="setup"]').isVisible())
    await page
      .getByLabel("Settings content")
      .getByRole("button", { name: "Back", exact: true })
      .click();
  await page.getByRole("button", { name: "Local settings", exact: true }).click();
}
