import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ConnectorService } from "../connector";
import { getCommaReleaseConfig } from "../../release-config";

vi.mock("electron", () => ({
  app: {
    getAppPath: () => "/Applications/Comma.app",
    getPath: (name: string) => (name === "userData" ? "/tmp/comma-user" : "/tmp"),
  },
}));

let tempDir = "";

beforeEach(async () => {
  tempDir = await mkdtemp(join(tmpdir(), "comma-connector-service-"));
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe("ConnectorService", () => {
  it("returns unavailable on unsupported platforms", async () => {
    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      platform: "linux",
    });

    await expect(service.status()).resolves.toMatchObject({
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Background connector service is only supported on macOS.",
    });
  });

  it("writes config and installs a LaunchAgent before starting", async () => {
    const binaryPath = join(tempDir, "salix-connect");
    const configPath = join(tempDir, "connector.json");
    const plistPath = join(tempDir, "surf.comma.desktop.test.salix-connect.plist");
    const logDir = join(tempDir, "logs");
    const commands: string[] = [];
    await writeFile(binaryPath, "#!/bin/sh\n");
    await chmod(binaryPath, 0o755);

    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      runtimeNamespace: "@comma-staging",
      binaryPath,
      configPath,
      logDir,
      platform: "darwin",
      plistPath,
      userId: 501,
      runCommand: vi.fn(async (command, args) => {
        commands.push(`${command} ${args.join(" ")}`);
        if (args[0] === "print") {
          return { code: 0, stdout: "", stderr: "state = running" };
        }
        return { code: 0, stdout: "", stderr: "" };
      }),
    });

    const status = await service.start({
      server: "http://127.0.0.1:4200",
      token: "connector-token",
      name: "dev machine",
      root: "/tmp/salix-root",
    });

    expect(status).toMatchObject({
      available: true,
      configured: true,
      installed: true,
      running: true,
      serviceLabel: "surf.comma.desktop.test.salix-connect",
      server: "http://127.0.0.1:4200",
      name: "dev machine",
      root: "/tmp/salix-root",
      connectorBinaryHash: sha256("#!/bin/sh\n"),
      configuredConnectorBinaryHash: sha256("#!/bin/sh\n"),
    });
    expect(JSON.parse(await readFile(configPath, "utf8"))).toMatchObject({
      connector: { connector_token: "connector-token" },
      electron: {
        runtime_namespace: "@comma-staging",
        runtime_root: "/tmp/comma-user",
      },
    });
    expect(await readFile(plistPath, "utf8")).toContain(
      "<string>surf.comma.desktop.test.salix-connect</string>"
    );
    expect(await readFile(plistPath, "utf8")).toContain(
      `<string>${binaryPath}</string>`
    );
    expect(commands).toContain(`launchctl bootstrap gui/501 ${plistPath}`);
    expect(commands).toContain(
      "launchctl kickstart -k gui/501/surf.comma.desktop.test.salix-connect"
    );
  });

  it("opens the standalone permission window and reads permissions without a connector", async () => {
    const binaryPath = join(tempDir, "salix-connect");
    const helperApp = join(
      tempDir,
      "native",
      "macos",
      `${getCommaReleaseConfig().productName} Computer Use.app`
    );
    const executable = join(helperApp, "Contents", "MacOS", "CommaComputerUseDaemon");
    await mkdir(join(helperApp, "Contents", "MacOS"), { recursive: true });
    await writeFile(executable, "#!/bin/sh\n");
    const standaloneApp = join(tempDir, "installed", "Computer Use.app");
    const runCommand = vi.fn(async (command: string, _args: string[]) => ({
      code: 0,
      stdout: command === executable ? standaloneApp : "",
      stderr: "",
    }));
    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      binaryPath,
      platform: "darwin",
      runCommand,
    });
    await expect(service.openComputerUsePermissionFlow()).resolves.toEqual({
      ok: true,
    });
    expect(runCommand).toHaveBeenCalledWith("open", [
      "-n",
      standaloneApp,
      "--args",
      "--permissions-ui",
    ]);
    let permissions: { accessibility: boolean; screenRecording?: boolean } = {
      accessibility: true,
      screenRecording: false,
    };
    runCommand.mockImplementation(async (command: string, args: string[] = []) => {
      if (command === executable) return { code: 0, stdout: standaloneApp, stderr: "" };
      await writeFile(
        args[args.indexOf("--stdout") + 1]!,
        JSON.stringify({
          ok: true,
          permissions,
        })
      );
      return { code: 0, stdout: "", stderr: "" };
    });
    await expect(service.getPermissions()).resolves.toMatchObject({
      ok: true,
      permissions: { accessibility: true, screenRecording: false },
    });
    expect(runCommand).toHaveBeenLastCalledWith("open", [
      "-n",
      "-g",
      "-W",
      "--stdout",
      expect.any(String),
      "--stderr",
      expect.any(String),
      standaloneApp,
      "--args",
      "--permissions-status",
    ]);
    // A fast probe can exit before open(1) installs its process wait.
    // Valid app output remains required, and unrelated launch errors fail.
    let launchError =
      "Unable to block on applications (initial call to kevent() failed: No such process)";
    runCommand.mockImplementation(async (command: string, args: string[] = []) => {
      if (command === executable) return { code: 0, stdout: standaloneApp, stderr: "" };
      await writeFile(
        args[args.indexOf("--stdout") + 1]!,
        JSON.stringify({ ok: true, permissions })
      );
      return { code: 1, stdout: "", stderr: launchError };
    });
    await expect(service.getPermissions()).resolves.toMatchObject({
      ok: true,
      permissions: { accessibility: true, screenRecording: false },
    });
    launchError = "The application could not be opened.";
    await expect(service.getPermissions()).resolves.toMatchObject({ ok: false });
    launchError =
      "Unable to block on applications (initial call to kevent() failed: No such process)";
    permissions = { accessibility: true };
    await expect(service.getPermissions()).resolves.toMatchObject({ ok: false });
    runCommand.mockResolvedValue({ code: 1, stdout: "", stderr: launchError });
    await expect(service.getPermissions()).resolves.toMatchObject({ ok: false });
  });

  it("reports managed connector runtime status from the salix-connect status file", async () => {
    const binaryPath = join(tempDir, "salix-connect");
    const configPath = join(tempDir, "connector.json");
    const plistPath = join(tempDir, "surf.comma.desktop.test.salix-connect.plist");
    await writeFile(binaryPath, "#!/bin/sh\n");
    await chmod(binaryPath, 0o755);

    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      binaryPath,
      configPath,
      platform: "darwin",
      plistPath,
      userId: 501,
      runCommand: vi.fn(async (_command, args) => {
        if (args[0] === "print") {
          return { code: 0, stdout: "", stderr: "state = running" };
        }
        return { code: 0, stdout: "", stderr: "" };
      }),
    });

    await service.configure({
      commaApiBaseUrl: "http://127.0.0.1:4200",
      commaSessionToken: "comma_sess_test",
      workspaceId: "wsp_1",
      name: "dev machine",
      root: "/tmp/salix-root",
    });
    await writeFile(
      `${configPath}.status.json`,
      JSON.stringify({
        mode: "managed",
        state: "connected",
        server: "ws://127.0.0.1:4000",
        workspace_id: "wsp_1",
        env_id: "env_1",
        token_expires_at: 1800000000,
        updated_at: 1700000000,
      })
    );

    await expect(service.status()).resolves.toMatchObject({
      mode: "managed",
      state: "connected",
      server: "ws://127.0.0.1:4000",
      workspaceId: "wsp_1",
      envId: "env_1",
      tokenExpiresAt: 1800000000,
      statusUpdatedAt: 1700000000,
    });
  });

  it("retires a legacy managed launch agent but leaves static configs alone", async () => {
    const binaryPath = join(tempDir, "salix-connect");
    const configPath = join(tempDir, "connector.json");
    const plistPath = join(tempDir, "surf.comma.desktop.test.salix-connect.plist");
    const commands: string[] = [];
    await writeFile(binaryPath, "#!/bin/sh\n");
    await chmod(binaryPath, 0o755);
    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      binaryPath,
      configPath,
      platform: "darwin",
      plistPath,
      userId: 501,
      runCommand: vi.fn(async (command, args) => {
        commands.push(`${command} ${args.join(" ")}`);
        return { code: 0, stdout: "", stderr: "" };
      }),
    });

    await service.configure({
      server: "ws://127.0.0.1:4000",
      token: "salix_static_token",
      name: "static machine",
      root: "/tmp/salix-root",
    });
    await expect(service.retireManagedLaunchAgent()).resolves.toBe(false);
    await expect(readFile(configPath, "utf8")).resolves.toContain("salix_static_token");

    await service.configure({
      commaApiBaseUrl: "http://127.0.0.1:4200",
      commaSessionToken: "comma_sess_test",
      workspaceId: "wsp_1",
      name: "managed machine",
      root: "/tmp/salix-root",
    });
    await writeFile(
      `${configPath}.status.json`,
      JSON.stringify({ state: "connected" })
    );
    await expect(service.retireManagedLaunchAgent()).resolves.toBe(true);
    expect(commands.some((command) => command.startsWith("launchctl bootout"))).toBe(
      true
    );
    await expect(readFile(configPath, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
    await expect(readFile(plistPath, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
    await expect(readFile(`${configPath}.status.json`, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("restarts an installed service when the bundled connector hash changes", async () => {
    const binaryPath = join(tempDir, "salix-connect");
    const configPath = join(tempDir, "connector.json");
    const plistPath = join(tempDir, "surf.comma.desktop.test.salix-connect.plist");
    const logDir = join(tempDir, "logs");
    const commands: string[] = [];
    await writeFile(binaryPath, "#!/bin/sh\n");
    await chmod(binaryPath, 0o755);

    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      binaryPath,
      configPath,
      logDir,
      platform: "darwin",
      plistPath,
      userId: 501,
      runCommand: vi.fn(async (command, args) => {
        commands.push(`${command} ${args.join(" ")}`);
        if (args[0] === "print") {
          return { code: 0, stdout: "", stderr: "state = running" };
        }
        return { code: 0, stdout: "", stderr: "" };
      }),
    });

    await service.start({
      server: "http://127.0.0.1:4200",
      token: "connector-token",
      name: "dev machine",
      root: "/tmp/salix-root",
    });
    commands.length = 0;
    await writeFile(binaryPath, "#!/bin/sh\necho updated\n");

    const status = await service.reconcileBundledConnector();

    expect(status).toMatchObject({
      running: true,
      connectorBinaryHash: sha256("#!/bin/sh\necho updated\n"),
      configuredConnectorBinaryHash: sha256("#!/bin/sh\necho updated\n"),
    });
    expect(commands).toContain(`launchctl bootout gui/501 ${plistPath}`);
    expect(commands).toContain(`launchctl bootstrap gui/501 ${plistPath}`);
    expect(commands).toContain(
      "launchctl kickstart -k gui/501/surf.comma.desktop.test.salix-connect"
    );
  });
});

function sha256(value: string) {
  return createHash("sha256").update(value).digest("hex");
}
