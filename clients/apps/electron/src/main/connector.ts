import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";
import { app } from "electron";
import log from "electron-log/main";
import type {
  ComputerUsePermissionFlowResult,
  ConnectorConfig,
  ConnectorStatus,
} from "@comma/native-bridge";
import { z } from "zod";
import {
  connectorConfigPath,
  readConnectorConfig,
  writeConnectorFileConfig,
  writeConnectorConfig,
  type SalixConnectorFileConfig,
} from "./connector-config";
import { isMacOS } from "./os";
import { getCommaReleaseConfig } from "../release-config";
import { openWaitTargetAlreadyExited } from "./open-wait";

interface CommandResult {
  code: number;
  stdout: string;
  stderr: string;
}

type RunCommand = (command: string, args: string[]) => Promise<CommandResult>;

type ComputerUseCLIResponse = {
  ok?: boolean;
  error?: string;
  text?: string;
  message?: string;
  permissions?: {
    accessibility?: boolean;
    screenRecording?: boolean;
  };
};

const connectorRuntimeStatusSchema = z.object({
  connector_run_id: z.string().trim().min(1).optional(),
  device_id: z.string().trim().min(1).optional(),
  local_file_index_version: z.number().int().positive().optional(),
  mode: z.enum(["static", "managed"]).optional(),
  state: z.string().trim().min(1).optional(),
  server: z.string().trim().min(1).optional(),
  workspace_id: z.string().trim().min(1).optional(),
  env_id: z.string().trim().min(1).optional(),
  last_connected_at: z.number().int().positive().optional(),
  token_expires_at: z.number().int().positive().optional(),
  last_error: z.string().trim().min(1).optional(),
  updated_at: z.number().int().positive().optional(),
});

type ConnectorRuntimeStatusFile = z.output<typeof connectorRuntimeStatusSchema>;

export interface ConnectorServiceOptions {
  appBundleId: string;
  runtimeNamespace?: string | undefined;
  binaryPath?: string;
  configPath?: string;
  logDir?: string;
  platform?: NodeJS.Platform | string;
  plistPath?: string;
  runCommand?: RunCommand;
  userId?: number;
}

export type ComputerUsePermissionProvider = Pick<
  ConnectorService,
  "getPermissions" | "openComputerUsePermissionFlow"
>;

export class ConnectorService {
  private readonly serviceLabel: string;
  private readonly runCommand: RunCommand;

  constructor(private readonly options: ConnectorServiceOptions) {
    this.serviceLabel = `${options.appBundleId}.salix-connect`;
    this.runCommand = options.runCommand ?? runCommand;
  }

  async status(): Promise<ConnectorStatus> {
    if (!this.isMacOS()) {
      return this.unavailable(
        "Background connector service is only supported on macOS."
      );
    }

    const binaryPath = this.resolveBinaryPath();
    const plistPath = this.plistPath();
    const configPath = this.configPath();
    const installed = existsSync(plistPath);
    const configured = existsSync(configPath);
    const running = installed ? await this.isRunning() : false;
    const connectorBinaryHash = existsSync(binaryPath)
      ? await this.connectorBinaryHash()
      : undefined;
    const status: ConnectorStatus = {
      available: existsSync(binaryPath),
      configured,
      installed,
      running,
      serviceLabel: this.serviceLabel,
      configPath,
      plistPath,
      binaryPath,
    };
    if (connectorBinaryHash) {
      status.connectorBinaryHash = connectorBinaryHash;
    }

    if (!status.available) {
      status.reason = `salix-connect binary was not found at ${binaryPath}. Run pnpm --filter @comma/electron build:native.`;
    }

    if (configured) {
      try {
        applyConfigStatus(status, await readConnectorConfig(configPath));
        applyRuntimeStatus(status, await readConnectorRuntimeStatus(configPath));
      } catch (error) {
        status.error = error instanceof Error ? error.message : String(error);
      }
    }

    return status;
  }

  /**
   * Retires the abandoned managed-mode launchd deployment. Local-file
   * registration targets are now owned by the Main-supervised per-workspace
   * connector runtime, so a `comma`-managed singleton service left behind by an
   * earlier build must stop competing for the same identity. Explicit static
   * configurations (custom server + token) remain untouched.
   */
  async retireManagedLaunchAgent(): Promise<boolean> {
    if (!this.isMacOS() || !existsSync(this.configPath())) {
      return false;
    }

    let config: SalixConnectorFileConfig;
    try {
      config = await readConnectorConfig(this.configPath());
    } catch {
      return false;
    }
    if (!config.comma) return false;

    if (existsSync(this.plistPath())) {
      await this.bootout();
      await rm(this.plistPath(), { force: true });
    }
    await rm(this.configPath(), { force: true });
    await rm(`${this.configPath()}.status.json`, { force: true });
    log.info("retired legacy managed salix-connect launch agent");
    return true;
  }

  async configure(config: ConnectorConfig) {
    await writeConnectorConfig(
      config,
      this.configPath(),
      await this.connectorMetadata()
    );
    await this.writeLaunchAgent();
    return this.status();
  }

  async start(config?: ConnectorConfig) {
    if (config) {
      await this.configure(config);
    } else if (!existsSync(this.configPath())) {
      throw new Error("Configure the connector before starting it.");
    } else {
      await this.refreshConnectorMetadata();
      await this.writeLaunchAgent();
    }

    await this.bootstrap();
    await this.kickstart();
    return this.status();
  }

  async stop() {
    if (this.isMacOS() && existsSync(this.plistPath())) {
      await this.bootout();
    }

    return this.status();
  }

  async restart(config?: ConnectorConfig) {
    if (config) {
      await this.configure(config);
    }

    await this.stop();
    return this.start();
  }

  async uninstall() {
    await this.stop();
    await rm(this.plistPath(), { force: true });
    return this.status();
  }

  getPermissions(_input?: void): Promise<ComputerUsePermissionFlowResult> {
    return this.runComputerUsePermissionCommand("permissions-status");
  }

  openComputerUsePermissionFlow(
    _input?: void
  ): Promise<ComputerUsePermissionFlowResult> {
    return this.runComputerUsePermissionCommand("open-permission-flow");
  }

  private async runComputerUsePermissionCommand(
    action: "permissions-status" | "open-permission-flow"
  ): Promise<ComputerUsePermissionFlowResult> {
    if (!this.isMacOS()) {
      return {
        ok: false,
        error: "ComputerUse permission flow is only supported on macOS.",
      };
    }

    try {
      const helperApp = join(
        dirname(this.resolveBinaryPath()),
        "native",
        "macos",
        `${getCommaReleaseConfig().productName} Computer Use.app`
      );
      const executable = join(helperApp, "Contents", "MacOS", "CommaComputerUseDaemon");
      if (!existsSync(executable)) {
        throw new Error(
          "ComputerUse helper is missing. Rebuild Comma's native components."
        );
      }
      // Permission reads must not claim or replace the connector's control socket.
      const execute =
        this.options.runCommand ??
        ((command: string, args: string[]) =>
          runCommand(command, args, { timeout: 15_000 }));
      if (action === "open-permission-flow") {
        const opened = await execute("open", [
          "-n",
          helperApp,
          "--args",
          "--permissions-ui",
        ]);
        if (opened.code !== 0) throw commandError("ComputerUse permissions", opened);
        return { ok: true };
      }
      const directory = await mkdtemp(join(tmpdir(), "comma-permissions-"));
      let output: string;
      try {
        const outputPath = join(directory, "status.json");
        // LaunchServices preserves the helper app's macOS permission identity.
        const command = await execute("open", [
          "-n",
          "-g",
          "-W",
          "--stdout",
          outputPath,
          "--stderr",
          join(directory, "stderr"),
          helperApp,
          "--args",
          "--permissions-status",
        ]);
        if (command.code !== 0 && !openWaitTargetAlreadyExited(command)) {
          throw commandError("ComputerUse permissions", command);
        }
        output = await readFile(outputPath, "utf8");
      } finally {
        await rm(directory, { recursive: true, force: true });
      }
      const response = parseComputerUseCLIResponse(output);
      if (response.ok !== true) {
        const result: ComputerUsePermissionFlowResult = {
          ok: false,
          error:
            response.error ||
            response.text ||
            response.message ||
            "ComputerUse permission flow failed.",
        };
        const permissions = normalizeComputerUsePermissions(response.permissions);
        if (permissions) {
          result.permissions = permissions;
        }
        return result;
      }

      const result: ComputerUsePermissionFlowResult = {
        ok: true,
        text: response.text || response.message,
      };
      const permissions = normalizeComputerUsePermissions(response.permissions);
      if (permissions) {
        result.permissions = permissions;
      }
      if (action === "permissions-status" && !permissions) {
        return { ok: false, error: "ComputerUse returned no permission status." };
      }
      return result;
    } catch (error) {
      return {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  }

  async reconcileBundledConnector() {
    if (
      !this.isMacOS() ||
      !existsSync(this.plistPath()) ||
      !existsSync(this.configPath())
    ) {
      return this.status();
    }

    const config = await readConnectorConfig(this.configPath());
    const currentHash = await this.connectorBinaryHash();
    if (config.electron?.connector_binary_sha256 === currentHash) {
      return this.status();
    }

    await writeConnectorFileConfig(
      {
        ...config,
        electron: {
          ...config.electron,
          connector_binary_sha256: currentHash,
        },
      },
      this.configPath()
    );
    await this.writeLaunchAgent();

    if (await this.isRunning()) {
      await this.stop();
      return this.start();
    }

    return this.status();
  }

  private unavailable(reason: string): ConnectorStatus {
    return {
      available: false,
      configured: false,
      installed: false,
      running: false,
      serviceLabel: this.serviceLabel,
      reason,
    };
  }

  private async writeLaunchAgent() {
    if (!this.isMacOS()) {
      throw new Error("Background connector service is only supported on macOS.");
    }

    const binaryPath = this.resolveBinaryPath();
    if (!existsSync(binaryPath)) {
      throw new Error(`salix-connect binary was not found at ${binaryPath}`);
    }

    const plistPath = this.plistPath();
    await mkdir(dirname(plistPath), { recursive: true });
    await mkdir(this.logDir(), { recursive: true });
    await writeFile(plistPath, this.launchAgentPlist(), { mode: 0o644 });
  }

  private async refreshConnectorMetadata() {
    const config = await readConnectorConfig(this.configPath());
    await writeConnectorFileConfig(
      {
        ...config,
        electron: {
          ...config.electron,
          ...(await this.connectorMetadata()),
        },
      },
      this.configPath()
    );
  }

  private async connectorMetadata() {
    return {
      connector_binary_sha256: await this.connectorBinaryHash(),
      ...(this.options.runtimeNamespace
        ? { runtime_namespace: this.options.runtimeNamespace }
        : {}),
      runtime_root: app.getPath("userData"),
    };
  }

  private async connectorBinaryHash() {
    return sha256(await readFile(this.resolveBinaryPath()));
  }

  private async bootstrap() {
    const result = await this.runCommand("launchctl", [
      "bootstrap",
      this.launchctlDomain(),
      this.plistPath(),
    ]);

    if (result.code !== 0 && !alreadyBootstrapped(result)) {
      throw commandError("launchctl bootstrap", result);
    }
  }

  private async bootout() {
    const result = await this.runCommand("launchctl", [
      "bootout",
      this.launchctlDomain(),
      this.plistPath(),
    ]);

    if (result.code !== 0 && !notBootstrapped(result)) {
      log.warn(commandError("launchctl bootout", result).message);
    }
  }

  private async kickstart() {
    const result = await this.runCommand("launchctl", [
      "kickstart",
      "-k",
      `${this.launchctlDomain()}/${this.serviceLabel}`,
    ]);

    if (result.code !== 0) {
      throw commandError("launchctl kickstart", result);
    }
  }

  private async isRunning() {
    const result = await this.runCommand("launchctl", [
      "print",
      `${this.launchctlDomain()}/${this.serviceLabel}`,
    ]);

    return result.code === 0 && /state = running/.test(commandOutput(result));
  }

  private launchAgentPlist() {
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${escapeXml(this.serviceLabel)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escapeXml(this.resolveBinaryPath())}</string>
    <string>--config</string>
    <string>${escapeXml(this.configPath())}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${escapeXml(join(this.logDir(), "salix-connect.out.log"))}</string>
  <key>StandardErrorPath</key>
  <string>${escapeXml(join(this.logDir(), "salix-connect.err.log"))}</string>
</dict>
</plist>
`;
  }

  private plistPath() {
    if (this.options.plistPath) {
      return this.options.plistPath;
    }

    return join(homedir(), "Library", "LaunchAgents", `${this.serviceLabel}.plist`);
  }

  private logDir() {
    return this.options.logDir ?? join(app.getPath("userData"), "logs");
  }

  private launchctlDomain() {
    return `gui/${this.options.userId ?? process.getuid?.() ?? 0}`;
  }

  private resolveBinaryPath() {
    return resolveConnectorBinaryPath({ binaryPath: this.options.binaryPath });
  }

  private configPath() {
    return this.options.configPath ?? connectorConfigPath();
  }

  private isMacOS() {
    return isMacOS(this.options.platform);
  }
}

export function resolveConnectorBinaryPath(
  options: { binaryPath?: string | undefined } = {}
) {
  if (options.binaryPath) {
    return options.binaryPath;
  }

  const binaryName =
    process.platform === "win32" ? "salix-connect.exe" : "salix-connect";
  if (app.isPackaged) {
    return join(
      process.resourcesPath,
      "native",
      process.platform,
      process.arch,
      binaryName
    );
  }

  const devBinaryPath = join(
    process.cwd(),
    "dist",
    "native",
    process.platform,
    process.arch,
    binaryName
  );
  const candidates = [
    devBinaryPath,
    join(
      app.getAppPath(),
      "dist",
      "native",
      process.platform,
      process.arch,
      binaryName
    ),
  ];

  return candidates.find((candidate) => existsSync(candidate)) ?? devBinaryPath;
}

function applyConfigStatus(status: ConnectorStatus, config: SalixConnectorFileConfig) {
  status.mode = config.comma ? "managed" : "static";
  const server = config.connector.server ?? config.comma?.api_base_url;
  if (server) {
    status.server = server;
  }
  if (config.comma?.workspace_id) {
    status.workspaceId = config.comma.workspace_id;
  }
  status.name = config.connector.name;
  status.root = config.connector.root;
  if (config.connector.alias) {
    status.alias = config.connector.alias;
  }
  if (config.connector.env_id) {
    status.envId = config.connector.env_id;
  }
  if (config.electron?.connector_binary_sha256) {
    status.configuredConnectorBinaryHash = config.electron.connector_binary_sha256;
  }
}

async function readConnectorRuntimeStatus(configPath: string) {
  const statusPath = `${configPath}.status.json`;
  if (!existsSync(statusPath)) {
    return undefined;
  }

  const parsed = JSON.parse(await readFile(statusPath, "utf8")) as unknown;
  const result = connectorRuntimeStatusSchema.safeParse(parsed);
  return result.success ? result.data : undefined;
}

function applyRuntimeStatus(
  status: ConnectorStatus,
  runtimeStatus?: ConnectorRuntimeStatusFile
) {
  if (!runtimeStatus) {
    return;
  }

  if (runtimeStatus.mode) {
    status.mode = runtimeStatus.mode;
  }
  if (runtimeStatus.state) {
    status.state = runtimeStatus.state;
  }
  if (runtimeStatus.server) {
    status.server = runtimeStatus.server;
  }
  if (runtimeStatus.workspace_id) {
    status.workspaceId = runtimeStatus.workspace_id;
  }
  if (runtimeStatus.env_id) {
    status.envId = runtimeStatus.env_id;
  }
  if (runtimeStatus.last_connected_at) {
    status.lastConnectedAt = runtimeStatus.last_connected_at;
  }
  if (runtimeStatus.token_expires_at) {
    status.tokenExpiresAt = runtimeStatus.token_expires_at;
  }
  if (runtimeStatus.updated_at) {
    status.statusUpdatedAt = runtimeStatus.updated_at;
  }
  if (runtimeStatus.last_error) {
    status.error = runtimeStatus.last_error;
  }
}

function runCommand(command: string, args: string[], options?: { timeout: number }) {
  return new Promise<CommandResult>((resolve) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
      killSignal: "SIGKILL",
    });
    const stdout: string[] = [];
    const stderr: string[] = [];

    child.stdout.on("data", (chunk) => stdout.push(chunk.toString()));
    child.stderr.on("data", (chunk) => stderr.push(chunk.toString()));
    child.on("error", (error) =>
      resolve({ code: 1, stdout: "", stderr: error.message })
    );
    child.on("close", (code, signal) =>
      resolve({
        code: code ?? 1,
        stdout: stdout.join(""),
        stderr: signal ? `Command stopped (${signal}).` : stderr.join(""),
      })
    );
  });
}

function alreadyBootstrapped(result: CommandResult) {
  return commandOutput(result).includes("Bootstrap failed: 5");
}

function notBootstrapped(result: CommandResult) {
  const output = commandOutput(result);
  return (
    output.includes("No such process") || output.includes("Could not find service")
  );
}

function commandError(command: string, result: CommandResult) {
  return new Error(
    `${command} failed with code ${result.code}: ${
      result.stderr.trim() || result.stdout.trim() || "no output"
    }`
  );
}

function commandOutput(result: CommandResult) {
  return `${result.stdout}\n${result.stderr}`;
}

function parseComputerUseCLIResponse(output: string): ComputerUseCLIResponse {
  const trimmed = output.trim();
  if (!trimmed) {
    throw new Error("salix-connect returned an empty ComputerUse response.");
  }
  return JSON.parse(trimmed) as ComputerUseCLIResponse;
}

function normalizeComputerUsePermissions(
  permissions?: ComputerUseCLIResponse["permissions"]
) {
  if (
    !permissions ||
    typeof permissions.accessibility !== "boolean" ||
    typeof permissions.screenRecording !== "boolean"
  ) {
    return undefined;
  }

  return {
    accessibility: permissions.accessibility === true,
    screenRecording: permissions.screenRecording === true,
  };
}

function sha256(data: Buffer) {
  return createHash("sha256").update(data).digest("hex");
}

function escapeXml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}
