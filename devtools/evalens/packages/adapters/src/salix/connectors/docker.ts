import { constants } from "node:fs";
import { access, chmod, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { z } from "zod";

import type { Salix } from "../types";
import type { SalixConnectorCredentialsService } from "./credentials";
import type { DockerCommandResult, DockerCommandRunner } from "./docker-cli";
import type { SalixConnectorEnvironmentsService } from "./environments";

const CONNECTOR_ROOT = "/workspace" as const;
const CONNECTOR_CONFIG = "/run/secrets/salix-connector.json";
const DEFAULT_TOKEN_TTL_SECONDS = 3_600;
const DEFAULT_CONNECT_TIMEOUT_MS = 30_000;
const DEFAULT_POLL_MS = 250;
const DEFAULT_LOG_TAIL = 100;

const DockerConnectorStartInputSchema = z
  .object({
    groupId: z.string().min(1),
    image: z.string().min(1),
    name: z.string().min(1),
    alias: z.string().min(1),
    root: z.object({ hostPath: z.string().min(1) }).strict(),
    serverUrl: z.url().optional(),
    tokenTtlSeconds: z.number().int().positive().default(DEFAULT_TOKEN_TTL_SECONDS),
    connectTimeoutMs: z.number().int().positive().default(DEFAULT_CONNECT_TIMEOUT_MS),
    pollMs: z.number().int().positive().default(DEFAULT_POLL_MS),
  })
  .strict();

const DockerVersionSchema = z
  .object({
    Client: z.object({ Version: z.string().min(1) }).loose(),
    Server: z
      .object({
        Version: z.string().min(1),
        Os: z.string().min(1),
      })
      .loose(),
  })
  .loose();

const DockerLogOptionsSchema = z
  .object({
    tail: z.number().int().positive().max(1_000).default(DEFAULT_LOG_TAIL),
  })
  .strict();

export class SalixDockerConnectorsService {
  constructor(
    private readonly credentials: SalixConnectorCredentialsService,
    private readonly environments: SalixConnectorEnvironmentsService,
    private readonly docker: DockerCommandRunner
  ) {}

  async probe(): Promise<Salix.DockerConnectorSupport> {
    let result: DockerCommandResult;
    try {
      result = await this.docker.run(["version", "--format", "{{json .}}"], {
        allowFailure: true,
      });
    } catch (error) {
      return {
        supported: false,
        reason: "docker_cli_missing",
        message: message(error),
      };
    }

    if (result.exitCode !== 0) {
      return {
        supported: false,
        reason: "docker_daemon_unavailable",
        message: result.stderr.slice(-4_000),
      };
    }

    try {
      const version = DockerVersionSchema.parse(JSON.parse(result.stdout));
      if (version.Server.Os !== "linux") {
        return {
          supported: false,
          reason: "unsupported_container_os",
          message: `Salix Docker Connector requires Linux containers; Docker is using ${version.Server.Os}`,
        };
      }
      return {
        supported: true,
        clientVersion: version.Client.Version,
        serverVersion: version.Server.Version,
      };
    } catch (error) {
      return {
        supported: false,
        reason: "docker_daemon_unavailable",
        message: `docker version returned an unexpected response: ${message(error)}`,
      };
    }
  }

  async start(
    input: Salix.DockerConnectorStartInput
  ): Promise<Salix.DockerConnectorRuntime> {
    const parsed = DockerConnectorStartInputSchema.parse(input);
    const support = await this.probe();
    if (!support.supported) {
      throw new Error(
        `Salix Docker Connector is unavailable (${support.reason}): ${support.message}`
      );
    }

    await this.requireImage(parsed.image);
    const hostRoot = await requireHostRoot(parsed.root.hostPath);
    const secretRoot = await mkdtemp(
      path.join(os.tmpdir(), "evalens-salix-connector-")
    );
    const configPath = path.join(secretRoot, "salix-connector.json");
    const containerName = dockerName(
      `evalens-salix-${parsed.alias}-${crypto.randomUUID().slice(0, 8)}`
    );
    let credential: Salix.ConnectorToken | undefined;
    let containerId: string | undefined;

    const stop = once(async () => {
      const errors: unknown[] = [];
      if (containerId) {
        const result = await this.docker
          .run(["rm", "--force", containerId], { allowFailure: true })
          .catch((error) => {
            errors.push(error);
            return undefined;
          });
        if (
          result &&
          result.exitCode !== 0 &&
          !/no such container/iu.test(`${result.stdout}\n${result.stderr}`)
        ) {
          errors.push(
            new Error(
              `docker rm failed (${result.exitCode}): ${result.stderr.slice(-4_000)}`
            )
          );
        }
      }
      if (credential) {
        await this.environments
          .remove({
            groupId: credential.groupId,
            deviceId: credential.deviceId,
          })
          .catch((error) => errors.push(error));
      }
      await rm(secretRoot, { recursive: true, force: true }).catch((error) =>
        errors.push(error)
      );
      if (errors.length > 0) {
        throw new AggregateError(errors, "Salix Docker Connector cleanup failed");
      }
    });

    try {
      credential = await this.credentials.create({
        groupId: parsed.groupId,
        name: parsed.name,
        alias: parsed.alias,
        expiresInSeconds: parsed.tokenTtlSeconds,
      });
      const serverUrl = containerServerUrl(parsed.serverUrl ?? credential.server);
      await writeFile(
        configPath,
        JSON.stringify({
          connector: {
            server: serverUrl.href.replace(/\/$/u, ""),
            connector_token: credential.token,
            name: credential.name,
            alias: credential.alias,
            root: CONNECTOR_ROOT,
            reconnect: true,
          },
        })
      );
      await chmod(configPath, 0o444);

      const args = [
        "run",
        "--detach",
        "--rm",
        "--name",
        containerName,
        "--label",
        "dev.evalens.salix-connector=true",
        "--label",
        `dev.evalens.salix-group=${parsed.groupId}`,
        ...dockerUserArgs(),
        "--env",
        "HOME=/tmp",
        ...(serverUrl.hostname === "host.docker.internal"
          ? ["--add-host", "host.docker.internal:host-gateway"]
          : []),
        "--mount",
        `type=bind,src=${hostRoot},dst=${CONNECTOR_ROOT}`,
        "--mount",
        `type=bind,src=${configPath},dst=${CONNECTOR_CONFIG},readonly`,
        parsed.image,
      ];
      const started = await this.docker.run(args);
      containerId = started.stdout.trim();
      if (!/^[a-f0-9]{12,64}$/u.test(containerId)) {
        throw new Error(`docker run returned an invalid container id: ${containerId}`);
      }

      const environment = await this.environments.waitForConnected({
        groupId: credential.groupId,
        deviceId: credential.deviceId,
        alias: credential.alias,
        timeoutMs: parsed.connectTimeoutMs,
        pollMs: parsed.pollMs,
      });
      const token = credential.token;
      return {
        kind: "docker",
        containerId,
        containerName,
        root: {
          hostPath: hostRoot,
          containerPath: CONNECTOR_ROOT,
        },
        environment,
        logs: async (options = {}) => {
          const { tail } = DockerLogOptionsSchema.parse(options);
          const logs = await this.docker.run(
            ["logs", "--tail", String(tail), containerId!],
            { allowFailure: true }
          );
          if (logs.exitCode !== 0) {
            throw new Error(
              `docker logs failed (${logs.exitCode}): ${redact(
                logs.stderr.slice(-4_000),
                token
              )}`
            );
          }
          return redact(`${logs.stdout}${logs.stderr}`, token);
        },
        stop,
      };
    } catch (error) {
      const token = credential?.token;
      const diagnostics = containerId
        ? await this.docker
            .run(["logs", "--tail", String(DEFAULT_LOG_TAIL), containerId], {
              allowFailure: true,
            })
            .catch(() => undefined)
        : undefined;
      const cleanupError = await stop().then(
        () => undefined,
        (cleanupFailure: unknown) => cleanupFailure
      );
      const connectorLogs = diagnostics
        ? redact(
            `\nconnector stdout:\n${diagnostics.stdout.slice(-4_000)}` +
              `\nconnector stderr:\n${diagnostics.stderr.slice(-4_000)}`,
            token
          )
        : "";
      const cleanup = cleanupError
        ? `\ncleanup error: ${redact(message(cleanupError), token)}`
        : "";
      throw new Error(
        `Failed to start Salix Docker Connector: ${redact(message(error), token)}` +
          connectorLogs +
          cleanup,
        { cause: error }
      );
    }
  }

  private async requireImage(image: string): Promise<void> {
    const inspected = await this.docker.run(["image", "inspect", image], {
      allowFailure: true,
    });
    if (inspected.exitCode !== 0) {
      throw new Error(
        `Salix Docker Connector image is unavailable: ${image}: ${inspected.stderr.slice(-4_000)}`
      );
    }
  }
}

async function requireHostRoot(value: string): Promise<string> {
  if (!path.isAbsolute(value)) {
    throw new Error(`Salix Docker Connector root must be absolute: ${value}`);
  }
  if (/[,\r\n]/u.test(value)) {
    throw new Error("Salix Docker Connector root cannot contain commas or line breaks");
  }
  const root = path.resolve(value);
  const rootStat = await stat(root).catch(() => undefined);
  if (!rootStat?.isDirectory()) {
    throw new Error(`Salix Docker Connector root is not a directory: ${root}`);
  }
  await access(root, constants.R_OK | constants.W_OK);
  return root;
}

function containerServerUrl(value: string): URL {
  const url = new URL(value);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(
      `Salix Docker Connector serverUrl must use http or https: ${value}`
    );
  }
  const hostname = url.hostname.toLowerCase();
  if (
    hostname === "localhost" ||
    hostname === "[::1]" ||
    /^127(?:\.\d{1,3}){3}$/u.test(hostname)
  ) {
    throw new Error(
      `Salix Docker Connector cannot reach loopback serverUrl ${value}; provide a container-reachable serverUrl`
    );
  }
  return url;
}

function dockerUserArgs(): string[] {
  const uid = process.getuid?.();
  const gid = process.getgid?.();
  return Number.isInteger(uid) && Number.isInteger(gid)
    ? ["--user", `${uid}:${gid}`]
    : [];
}

function dockerName(value: string): string {
  const normalized = value.toLowerCase().replace(/[^a-z0-9_.-]+/gu, "-");
  return (
    normalized.replace(/^[^a-z0-9]+/u, "").slice(0, 120) ||
    `evalens-salix-${crypto.randomUUID().slice(0, 8)}`
  );
}

function once(callback: () => Promise<void>): () => Promise<void> {
  let result: Promise<void> | undefined;
  return () => (result ??= callback());
}

function redact(value: string, secret: string | undefined): string {
  return secret ? value.replaceAll(secret, "[REDACTED]") : value;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
