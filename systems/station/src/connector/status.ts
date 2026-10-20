// The status file the desktop app reads (connector.status.json): connection state, the acknowledged scope, the
// connection identity and the last error. Written atomically (temp file, rename) with private permissions. The scope
// field is an acknowledgement: it advances only when metadata carrying the scope was published.
import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { LOCAL_FILE_INDEX_VERSION } from "./local-file-index.ts";

export type BuildInfo = { component: string; version: string; release_id: string; commit: string; built_at: string; goos: string; goarch: string; go_version: string };

export type ConnectorStatusFile = {
  mode: string;
  state: string;
  scope: string;
  local_file_index_version: number;
  server?: string;
  connector_run_id?: string;
  device_id?: string;
  connector_id?: string;
  last_connected_at?: number;
  last_error_class?: string;
  last_error_message?: string;
  consecutive_failures?: number;
  reconnect_backoff_seconds?: number;
  last_metadata_sent_at?: number;
  component_release: BuildInfo;
  updated_at: number;
};

export class AuthError extends Error {
  override readonly name = "AuthError";
  readonly status: number;
  constructor(status: number, body: string) {
    super(`connector authentication failed (${status}): ${body}`);
    this.status = status;
  }
}

export class WebSocketHandshakeError extends Error {
  override readonly name = "WebSocketHandshakeError";
  readonly status: number;
  constructor(status: number, body: string) {
    super(`websocket handshake failed (${status}): ${body}`);
    this.status = status;
  }
}

export class LocalRequestError extends Error {
  override readonly name = "LocalRequestError";
}

export function classifyConnectorError(error: unknown): string {
  if (!error) return "";
  if (error instanceof AuthError) return "auth";
  if (error instanceof LocalRequestError) return "local_request";
  if (error instanceof WebSocketHandshakeError) return error.status >= 500 ? "server" : "websocket_handshake";
  const code = (error as NodeJS.ErrnoException).code;
  if (code === "ENOTFOUND" || code === "EAI_AGAIN") return "dns";
  if (code === "ECONNREFUSED" || code === "ECONNRESET" || code === "ETIMEDOUT") return "server";
  const message = String(error instanceof Error ? error.message : error).toLowerCase();
  if (message.includes("no such host") || message.includes("enotfound")) return "dns";
  if (message.includes("tls") || message.includes("certificate")) return "tls";
  if (message.includes("bad handshake") || message.includes("websocket")) return "websocket_handshake";
  if (message.includes("connection refused") || message.includes("connection reset") || message.includes("timeout") || message.includes("econnrefused")) return "server";
  if (message.includes("json") || message.includes("protocol")) return "protocol";
  return "unknown";
}

export type StatusSource = {
  path: string;
  server: string;
  scope(): string;
  identity(): { runId: string; deviceId: string; connectorId: string };
  build(): BuildInfo;
  nowSeconds(): number;
};

export function makeStatusWriter(source: StatusSource) {
  const read = (): Partial<ConnectorStatusFile> => {
    try {
      return JSON.parse(readFileSync(source.path, "utf8"));
    } catch {
      return {};
    }
  };
  const write = (status: ConnectorStatusFile) => {
    try {
      mkdirSync(dirname(source.path), { recursive: true, mode: 0o755 });
      const tmp = `${source.path}.${process.pid}.tmp`;
      const ordered = Object.fromEntries(Object.entries(status).filter(([, v]) => v !== undefined && v !== "" && v !== 0) as Array<[string, unknown]>);
      // Always-present fields, as Go wrote them without omitempty.
      Object.assign(ordered, { mode: status.mode, state: status.state, scope: status.scope, local_file_index_version: status.local_file_index_version, component_release: status.component_release, updated_at: status.updated_at });
      writeFileSync(tmp, `${JSON.stringify(ordered, null, 2)}\n`, { mode: 0o600 });
      chmodSync(tmp, 0o600);
      renameSync(tmp, source.path);
      chmodSync(source.path, 0o600);
    } catch {
      // The status file is advisory; the connection does not depend on it.
    }
  };
  const statusServer = (server: string) => server.trim() || source.server.trim();
  const errorFields = (error: unknown) => ({ last_error_class: classifyConnectorError(error), last_error_message: error instanceof Error ? error.message : String(error) });

  return {
    writeStatus(state: string, server: string, error: unknown, reconnectBackoffMs?: number) {
      if (!source.path) return;
      const previous = read();
      const now = source.nowSeconds();
      const id = source.identity();
      const status: ConnectorStatusFile = {
        mode: "static",
        state,
        scope: source.scope(),
        local_file_index_version: LOCAL_FILE_INDEX_VERSION,
        server: statusServer(server) || previous.server,
        connector_run_id: id.runId,
        device_id: id.deviceId,
        connector_id: id.connectorId,
        last_connected_at: previous.last_connected_at,
        last_error_class: previous.last_error_class,
        last_error_message: previous.last_error_message,
        consecutive_failures: previous.consecutive_failures,
        reconnect_backoff_seconds: previous.reconnect_backoff_seconds,
        last_metadata_sent_at: previous.last_metadata_sent_at,
        component_release: source.build(),
        updated_at: now,
      };
      if (state === "connected") Object.assign(status, { last_connected_at: now, last_error_class: "", last_error_message: "", consecutive_failures: 0, reconnect_backoff_seconds: 0 });
      if (error) {
        Object.assign(status, errorFields(error));
        if (state !== "connected" && state !== "stopped" && state !== "stopping") status.consecutive_failures = (previous.consecutive_failures ?? 0) + 1;
      }
      if (reconnectBackoffMs !== undefined) status.reconnect_backoff_seconds = reconnectBackoffMs <= 0 ? 0 : Math.max(reconnectBackoffMs, 1) / 1000;
      else if (["starting", "minting_token", "connecting", "connected"].includes(state)) status.reconnect_backoff_seconds = 0;
      write(status);
    },
    /** Metadata (with the current scope) reached the live transport: acknowledge the scope. */
    writeStatusMetadataSent(server: string) {
      if (!source.path) return;
      const status = read() as ConnectorStatusFile;
      if (!status.state) return;
      const id = source.identity();
      const now = source.nowSeconds();
      write({ ...status, mode: "static", scope: source.scope(), local_file_index_version: LOCAL_FILE_INDEX_VERSION, server: statusServer(server) || status.server, connector_run_id: id.runId, device_id: id.deviceId, connector_id: id.connectorId, last_metadata_sent_at: now, component_release: source.build(), updated_at: now });
    },
    /** A failed request: recorded without touching the scope acknowledgement. */
    writeStatusLocalRequestError(error: unknown) {
      if (!source.path || !error) return;
      const status = read() as ConnectorStatusFile;
      if (!status.state) return;
      const id = source.identity();
      write({ ...status, mode: "static", local_file_index_version: LOCAL_FILE_INDEX_VERSION, server: statusServer(status.server ?? ""), connector_run_id: id.runId, device_id: id.deviceId, connector_id: id.connectorId, ...errorFields(error), component_release: source.build(), updated_at: source.nowSeconds() });
    },
  };
}
