import { _electron as electron, expect, test } from "@playwright/test";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { defaultAgentVMMHostLifecyclePath } from "../src/main/modules/compute-node";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

test("compute node recovers unknown authorization and interrupted setup across restart", async () => {
  test.setTimeout(120_000);
  const directory = await mkdtemp(join(tmpdir(), "comma-compute-node-e2e-"));
  const userDataPath = join(directory, "user-data");
  const runtimeDirectory = join(directory, "runtime");
  const lifecycle = defaultAgentVMMHostLifecyclePath(directory);
  const workspaceId = "wsp_compute_node_e2e";
  const operationId = "vmm_install_compute_node_e2e";
  let productStatus: "processing" | "ready" | "stopped" | "removed" = "processing";
  const productRequests: string[] = [];
  const authorizationKeys: string[] = [];
  let loseAuthorizationResponse = true;
  const sessionStub = await startSessionProjectionStub({
    email: "compute-node@comma.local",
    handleRequest: (request, response, path) => {
      productRequests.push(`${request.method ?? "UNKNOWN"} ${path}`);
      const requestedWorkspace =
        path.match(/workspaces\/([^/]+)\/compute-nodes/)?.[1] ?? workspaceId;
      const operationPath = `/v1/comma/workspaces/${requestedWorkspace}/compute-nodes/agent-vmm/install-operations`;
      if (request.method === "POST" && path === operationPath) {
        request.resume();
        productStatus = "ready";
        authorizationKeys.push(String(request.headers["idempotency-key"]));
        if (loseAuthorizationResponse) {
          loseAuthorizationResponse = false;
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
            registration_id: "vmm_registration_compute_node_e2e",
            status: productStatus,
          },
        });
        return true;
      }
      if (path === `${operationPath}/${operationId}` && request.method === "GET") {
        respondJson(response, {
          operation: {
            authorization_status: "handed_off",
            status: productStatus,
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
      args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataPath}`],
      cwd: electronAppDir,
      env: {
        ...hostEnv,
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
    await page.evaluate((id) => {
      localStorage.setItem("comma.activeWorkspaceId", id);
      window.dispatchEvent(
        new CustomEvent("comma:active-workspace-changed", {
          detail: { workspaceId: id },
        })
      );
    }, workspaceId);
    await page.getByRole("button", { name: "Enable this Mac", exact: true }).click();
    await page.getByRole("button", { name: "Confirm", exact: true }).click();
    await expect(page.getByText("Needs attention", { exact: true })).toBeVisible({
      timeout: 15_000,
    });
    await app.close();
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
    await page
      .getByRole("button", { name: "Continue setup", exact: true })
      .click({ timeout: 8_000 });
    await page.getByRole("button", { name: "Confirm", exact: true }).click();
    await expect(page.getByText("Needs attention", { exact: true })).toBeVisible();
    expect(authorizationKeys).toHaveLength(2);
    expect(authorizationKeys[1]).toBe(authorizationKeys[0]);
    await page
      .getByRole("button", { name: "Continue setup", exact: true })
      .click({ timeout: 8_000 });
    await page.getByRole("button", { name: "Confirm", exact: true }).click();
    await expect(
      page.getByText("Available for new work", { exact: true })
    ).toBeVisible();
    await expect
      .poll(async () => readFile(join(runtimeDirectory, "commands"), "utf8"))
      .toContain(
        "install --service-type agent --request-id vmm_install_compute_node_e2e --operation-stdin"
      );
    expect(
      productRequests.filter((request) => request.endsWith("/initialize-workload"))
    ).toHaveLength(1);
    await app.close();
    app = await launch(false);
    page = await openComputeNode(app);
    await expect(
      page.getByText("Available for new work", { exact: true })
    ).toBeVisible();
    expect(
      productRequests.filter((request) => request.endsWith("/initialize-workload"))
    ).toHaveLength(1);
    await page.getByRole("button", { name: "Node actions", exact: true }).click();
    await page.getByRole("menuitem", { name: "Disable node", exact: true }).click();
    await expect(
      page.getByText(/Existing execution may not stop immediately/)
    ).toBeVisible();
    await page.getByRole("button", { name: "Cancel", exact: true }).click();
    await expect(
      page.getByText("Available for new work", { exact: true })
    ).toBeVisible();
    expect(
      productRequests.filter((request) => request.endsWith("/disable"))
    ).toHaveLength(0);
    await page.getByRole("button", { name: "Node actions", exact: true }).click();
    await page.getByRole("menuitem", { name: "Disable node", exact: true }).click();
    await page.getByRole("button", { name: "Confirm", exact: true }).click();
    await expect(page.getByText("Node disabled", { exact: true })).toBeVisible();
    for (const [action, nextWorkspace] of [
      ["Disable node", "wsp_other"],
      ["Remove compute node", workspaceId],
    ] as const) {
      await page.getByRole("button", { name: "Node actions", exact: true }).click();
      await page.getByRole("menuitem", { name: action, exact: true }).click();
      // Another window replaces the binding while this confirmation remains open.
      await page.evaluate(async (id) => {
        await window.commaNative!.computeNode.remove();
        await window.commaNative!.computeNode.configure({
          desiredEnabled: true,
          workspaceId: id,
        });
      }, nextWorkspace);
      const mutations = productRequests.filter(
        (request) => request.endsWith("/disable") || request.endsWith("/revoke")
      );
      await page.getByRole("button", { name: "Confirm", exact: true }).click();
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
  } finally {
    await app.close().catch(() => {});
    await sessionStub.close();
    await rm(directory, { force: true, recursive: true });
  }
});

async function openComputeNode(app: Awaited<ReturnType<typeof electron.launch>>) {
  const page = await findElectronWindowByNativeRole(app, "main-window");
  await page.waitForLoadState("domcontentloaded");
  await page.evaluate(() => {
    window.location.hash = "#/settings";
  });
  await page.getByRole("button", { name: "Compute node" }).click();
  await expect(
    page.getByRole("heading", { level: 1, name: "Compute node" })
  ).toBeVisible();
  return page;
}

function lifecycleFixture(runtimeDirectory: string) {
  return `#!/bin/sh
set -eu
runtime=${JSON.stringify(runtimeDirectory)}
mkdir -p "$runtime"
printf '%s\n' "$*" >> "$runtime/commands"
case "\${1:-}" in
status)
  if [ -f "$runtime/installed" ]; then installed=true; else installed=false; fi
  if [ -f "$runtime/loaded" ]; then loaded=true; else loaded=false; fi
  if [ "$loaded" = true ]; then
    host_readable=true
    host_healthy=true
  else
    host_readable=false
    host_healthy=false
  fi
  printf '{"appInstalled":%s,"hostInstalled":%s,"connectorInstalled":%s,"hostLoaded":%s,"connectorLoaded":%s,"hostReadable":%s,"hostHealthy":%s,"salixRevoked":false}\n' "$installed" "$installed" "$installed" "$loaded" "$loaded" "$host_readable" "$host_healthy"
  ;;
install|repair)
  case " $* " in *" --operation-stdin "*) cat >/dev/null ;; esac
  if [ -f "$runtime/fail-install" ]; then
    rm "$runtime/fail-install"
    echo "fixture install interrupted" >&2
    exit 1
  fi
  touch "$runtime/installed" "$runtime/loaded"
  ;;
registration-state)
  case "$*" in
    *"--state enabled"*) touch "$runtime/loaded" ;;
    *"--state draining"*) rm -f "$runtime/loaded" ;;
    *) exit 2 ;;
  esac
  ;;
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
