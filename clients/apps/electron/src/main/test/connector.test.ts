import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ConnectorService, type ConnectorStation } from "../connector";
import { getCommaReleaseConfig } from "../../release-config";

vi.mock("electron", () => ({
  app: {
    getAppPath: () => "/Applications/Comma.app",
    getPath: (name: string) => (name === "userData" ? "/tmp/comma-user" : "/tmp"),
  },
}));

let tempDir = "";
let stationDir = "";
let station: ConnectorStation & { events: string[] };

beforeEach(async () => {
  tempDir = await mkdtemp(join(tmpdir(), "comma-connector-service-"));
  stationDir = join(tempDir, "station-release");
  await mkdir(join(stationDir, "mesh", "target", "release"), { recursive: true });
  await writeFile(
    join(stationDir, "mesh", "target", "release", "stillfail-station"),
    "#!/bin/sh\n",
    { mode: 0o755 }
  );
  await writeFile(join(stationDir, "VERSION"), "release-1\n");
  const events: string[] = [];
  station = {
    data: join(tempDir, "station-data"),
    dir: stationDir,
    events,
    instancesDir: join(tempDir, "station-data", "connector", "instances"),
    release: async () => void events.push("release"),
    resume: () => void events.push("resume"),
  };
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe("ConnectorService", () => {
  it("returns unavailable on unsupported platforms", async () => {
    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      platform: "linux",
      station,
    });

    await expect(service.status()).resolves.toMatchObject({
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Background connector service is only supported on macOS.",
    });
  });

  it("writes the static connection and has launchd run the station before starting", async () => {
    const configPath = join(tempDir, "connector.json");
    const plistPath = join(tempDir, "surf.comma.desktop.test.salix-connect.plist");
    const logDir = join(tempDir, "logs");
    const commands: string[] = [];

    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      runtimeNamespace: "@comma-staging",
      station,
      configPath,
      legacyConfigPath: undefined,
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
      server: "https://api.comma.test",
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
      server: "https://api.comma.test",
      name: "dev machine",
      root: "/tmp/salix-root",
      connectorBinaryHash: sha256("release-1\n"),
      configuredConnectorBinaryHash: sha256("release-1\n"),
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
    const plist = await readFile(plistPath, "utf8");
    expect(plist).toContain(
      `<string>${join(stationDir, "mesh", "target", "release", "stillfail-station")}</string>
    <string>run</string>
    <string>--app</string>
    <string>${stationDir}</string>
    <string>--data</string>
    <string>${station.data}</string>`
    );
    // One station per machine: the app's own gives the data directory over first.
    expect(station.events).toEqual(["release"]);
    expect(commands).toContain(`launchctl bootstrap gui/501 ${plistPath}`);
    expect(commands).toContain(
      "launchctl kickstart -k gui/501/surf.comma.desktop.test.salix-connect"
    );
  });

  it("opens the standalone permission window and reads permissions without a connector", async () => {
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
      computerUseHelperApp: helperApp,
      platform: "darwin",
      runCommand,
      station,
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

  it("reports the static connection's status from the station's status file", async () => {
    const configPath = join(tempDir, "connector.json");
    const plistPath = join(tempDir, "surf.comma.desktop.test.salix-connect.plist");

    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      station,
      configPath,
      legacyConfigPath: undefined,
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
      commaApiBaseUrl: "https://api.comma.test",
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
        server: "wss://salix.test",
        workspace_id: "wsp_1",
        env_id: "env_1",
        token_expires_at: 1800000000,
        updated_at: 1700000000,
      })
    );

    await expect(service.status()).resolves.toMatchObject({
      mode: "managed",
      state: "connected",
      server: "wss://salix.test",
      workspaceId: "wsp_1",
      envId: "env_1",
      tokenExpiresAt: 1800000000,
      statusUpdatedAt: 1700000000,
    });
  });

  it("retires a legacy managed launch agent and moves a legacy static config onto the station", async () => {
    const legacyConfigPath = join(tempDir, "connector.json");
    const configPath = join(station.instancesDir, "static.json");
    const plistPath = join(tempDir, "surf.comma.desktop.test.salix-connect.plist");
    const commands: string[] = [];
    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      configPath,
      legacyConfigPath,
      logDir: join(tempDir, "logs"),
      platform: "darwin",
      plistPath,
      station,
      userId: 501,
      runCommand: vi.fn(async (command, args) => {
        commands.push(`${command} ${args.join(" ")}`);
        return { code: 0, stdout: "", stderr: "" };
      }),
    });
    const legacy = (
      connector: Record<string, unknown>,
      comma?: Record<string, unknown>
    ) =>
      writeFile(
        legacyConfigPath,
        JSON.stringify({
          ...(comma ? { comma } : {}),
          connector: {
            name: "machine",
            root: "/tmp/salix-root",
            reconnect: true,
            ...connector,
          },
        })
      );

    await legacy({
      server: "wss://salix.test",
      connector_token: "salix_static_token",
    });
    await writeFile(plistPath, "salix-connect");
    await expect(service.retireManagedLaunchAgent()).resolves.toBe(false);
    await service.reconcileBundledConnector();
    await expect(readFile(legacyConfigPath, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
    await expect(readFile(configPath, "utf8")).resolves.toContain("salix_static_token");
    await expect(readFile(plistPath, "utf8")).resolves.toContain(
      "<string>run</string>"
    );

    await legacy(
      {},
      {
        api_base_url: "https://api.comma.test",
        session_token: "comma_sess_test",
        workspace_id: "wsp_1",
      }
    );
    await writeFile(
      `${legacyConfigPath}.status.json`,
      JSON.stringify({ state: "connected" })
    );
    await expect(service.retireManagedLaunchAgent()).resolves.toBe(true);
    expect(commands.some((command) => command.startsWith("launchctl bootout"))).toBe(
      true
    );
    await expect(readFile(legacyConfigPath, "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
    await expect(readFile(plistPath, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    await expect(
      readFile(`${legacyConfigPath}.status.json`, "utf8")
    ).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("restarts an installed service when the bundled station changes", async () => {
    const configPath = join(tempDir, "connector.json");
    const plistPath = join(tempDir, "surf.comma.desktop.test.salix-connect.plist");
    const logDir = join(tempDir, "logs");
    const commands: string[] = [];

    const service = new ConnectorService({
      appBundleId: "surf.comma.desktop.test",
      station,
      configPath,
      legacyConfigPath: undefined,
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
      server: "https://api.comma.test",
      token: "connector-token",
      name: "dev machine",
      root: "/tmp/salix-root",
    });
    commands.length = 0;
    await writeFile(join(stationDir, "VERSION"), "release-2\n");

    const status = await service.reconcileBundledConnector();

    expect(status).toMatchObject({
      running: true,
      connectorBinaryHash: sha256("release-2\n"),
      configuredConnectorBinaryHash: sha256("release-2\n"),
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
