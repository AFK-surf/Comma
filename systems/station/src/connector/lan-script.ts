// lan_script: a JavaScript function this gateway runs on its own network, for device protocols that take more than one
// request (Gree and miIO handshakes, encrypted replies). The script runs in the runner (`comma-runner
// --lan-script`, native/runner/src/lan_script.rs) on the gateway boards' own runtime (Micro QuickJS), so a script
// gives the same answers on a computer as on a board; each of its LAN calls comes back here and runs as
// lan_http_request or udp_request, with their limits. The API scripts see: AFK-surf/Hardware docs/lan-script.md.
import { spawn } from "node:child_process";
import { lookup } from "node:dns/promises";
import { connect, isIP } from "node:net";
import { createInterface } from "node:readline";
import { Effect } from "effect";
import { runnerBinary } from "../platform/processes.ts";
import { intParam, stringParam } from "./message.ts";
import { lanHttpRequest, udpRequest } from "./lan-gateway.ts";

/** What the runtime reports to scripts (`LAN_SCRIPT_API`); a change to what a script sees raises it. */
export const LAN_SCRIPT_API = 2;
export const LAN_SCRIPT_MAX_SOURCE_BYTES = 64 * 1024;
export const LAN_SCRIPT_MAX_RESULT_BYTES = 64 * 1024;
export const LAN_SCRIPT_DEFAULT_TIMEOUT_MS = 10_000;
export const LAN_SCRIPT_MIN_TIMEOUT_MS = 1_000;
export const LAN_SCRIPT_MAX_TIMEOUT_MS = 30_000;
export const LAN_SCRIPT_HEAP_BYTES = 1024 * 1024;
/** The largest lan_script request Salix may send, source and args together. */
export const LAN_SCRIPT_MAX_REQUEST_BYTES = 1024 * 1024;
export const LAN_TCP_DEFAULT_TIMEOUT_MS = 10_000;
export const LAN_TCP_MAX_TIMEOUT_MS = 30_000;
export const LAN_TCP_DEFAULT_IDLE_MS = 2_000;
export const LAN_TCP_MAX_BYTES = 64 * 1024;
/** After its own deadline, how long the runner has to answer before it is stopped. */
const GRACE_MS = 2_000;

export function lanScriptCapability() {
  return {
    api: LAN_SCRIPT_API,
    max_source_bytes: LAN_SCRIPT_MAX_SOURCE_BYTES,
    max_result_bytes: LAN_SCRIPT_MAX_RESULT_BYTES,
    max_timeout_ms: LAN_SCRIPT_MAX_TIMEOUT_MS,
    heap_bytes: LAN_SCRIPT_HEAP_BYTES,
    max_request_bytes: LAN_SCRIPT_MAX_REQUEST_BYTES,
  };
}

const toError = (e: unknown) => (e instanceof Error ? e : new Error(String(e)));

/** One LAN method a script calls, as the gateway serves it to Salix; it stops when the script does. */
type LanCall = (method: string, params: Record<string, unknown>, signal: AbortSignal) => Promise<unknown>;

function lanCall(method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown> {
  if (method === "http_request") {
    if (params.response_mode != null) return Promise.reject(new Error("response_mode is not available to scripts"));
    return Effect.runPromise(lanHttpRequest(params), { signal });
  }
  if (method === "udp_request") return Effect.runPromise(udpRequest(params), { signal });
  if (method === "tcp_request") return tcpRequest(params, signal);
  return Promise.reject(new Error(`this gateway has no ${method.slice(0, 40)}`));
}

/** Runs the script; answers `{result, logs}` or `{error, logs}` (a script that throws is still an answer). */
export function lanScript(params: Record<string, unknown>, call: LanCall = lanCall): Effect.Effect<unknown, Error> {
  return Effect.suspend(() => {
    const source = stringParam(params, "source");
    if (!source) return Effect.fail(new Error("'source' is required"));
    if (Buffer.byteLength(source) > LAN_SCRIPT_MAX_SOURCE_BYTES) return Effect.fail(new Error(`'source' is longer than ${LAN_SCRIPT_MAX_SOURCE_BYTES} bytes`));
    let timeoutMs = intParam(params, "timeout_ms", LAN_SCRIPT_DEFAULT_TIMEOUT_MS);
    timeoutMs = Math.min(Math.max(timeoutMs, LAN_SCRIPT_MIN_TIMEOUT_MS), LAN_SCRIPT_MAX_TIMEOUT_MS);
    const request = { source, args: params.args ?? null, timeout_ms: timeoutMs, heap_bytes: LAN_SCRIPT_HEAP_BYTES, max_result_bytes: LAN_SCRIPT_MAX_RESULT_BYTES };
    return Effect.tryPromise({ try: (signal) => runScript(request, timeoutMs + GRACE_MS, signal, call), catch: toError });
  });
}

function runScript(request: Record<string, unknown>, limitMs: number, signal: AbortSignal, call: LanCall): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const child = spawn(runnerBinary(), ["--lan-script"], { stdio: ["pipe", "pipe", "pipe"] });
    let settled = false;
    let stderr = "";
    // Ends the LAN call in flight when the script ends, whatever ended it.
    const calls = new AbortController();
    const finish = (error: Error | null, value?: unknown) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      calls.abort();
      signal.removeEventListener("abort", abort);
      child.kill("SIGKILL");
      if (error) reject(error);
      else resolve(value);
    };
    const abort = () => finish(new Error("the script was stopped"));
    const timer = setTimeout(() => finish(new Error(`the script did not finish in ${limitMs} ms`)), limitMs);
    signal.addEventListener("abort", abort);
    child.on("error", (e) => finish(e));
    child.stdin.on("error", () => {});
    child.stderr.on("data", (chunk: Buffer) => {
      if (stderr.length < 2048) stderr += chunk.toString();
    });
    child.on("exit", (code) => finish(new Error(`the script runner exited (${code})${stderr ? `: ${stderr.trim()}` : ""}`)));
    // One call at a time: the script waits for each answer.
    createInterface({ input: child.stdout }).on("line", (line) => {
      let message: Record<string, any>;
      try {
        message = JSON.parse(line);
      } catch {
        return finish(new Error("the script runner wrote something other than JSON"));
      }
      if ("done" in message) return finish(null, message.done);
      const method = String(message.call ?? "");
      const params = message.params && typeof message.params === "object" ? message.params : {};
      call(method, params, calls.signal).then(
        (result) => !settled && child.stdin.write(JSON.stringify({ result }) + "\n"),
        (e) => !settled && child.stdin.write(JSON.stringify({ error: toError(e).message }) + "\n"),
      );
    });
    child.stdin.write(JSON.stringify(request) + "\n");
  });
}

const clamp = (value: unknown, fallback: number, min: number, max: number) =>
  typeof value === "number" && Number.isInteger(value) ? Math.min(Math.max(value, min), max) : fallback;

/**
 * tcp_request (lan.tcp): one connection. Sends send_b64, shuts the write side when close_write, then reads until the
 * host closes (closed), max_bytes arrive (truncated), idle_ms pass without data, or timeout_ms pass (timed_out).
 */
export async function tcpRequest(params: Record<string, unknown>, signal: AbortSignal) {
  const host = typeof params.host === "string" ? params.host : "";
  if (!host) throw new Error("'host' is required");
  const port = params.port;
  if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error("'port' must be a whole number between 1 and 65535");
  const encoded = params.send_b64 == null ? "" : params.send_b64;
  if (typeof encoded !== "string" || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) throw new Error("'send_b64' is not valid standard base64");
  const timeoutMs = clamp(params.timeout_ms, LAN_TCP_DEFAULT_TIMEOUT_MS, 100, LAN_TCP_MAX_TIMEOUT_MS);
  const idleMs = clamp(params.idle_ms, LAN_TCP_DEFAULT_IDLE_MS, 0, LAN_TCP_MAX_TIMEOUT_MS);
  const maxBytes = clamp(params.max_bytes, LAN_TCP_MAX_BYTES, 0, LAN_TCP_MAX_BYTES);
  const address = isIP(host) ? host : (await lookup(host)).address;
  return new Promise<{ data_b64: string; closed: boolean; truncated: boolean; timed_out: boolean }>((resolve, reject) => {
    const chunks: Buffer[] = [];
    let got = 0;
    let idle: ReturnType<typeof setTimeout> | undefined;
    const socket = connect({ host: address, port });
    const finish = (error: Error | null, flags = { closed: false, truncated: false, timed_out: false }) => {
      clearTimeout(total);
      clearTimeout(idle);
      signal.removeEventListener("abort", abort);
      socket.destroy();
      if (error) reject(error);
      else resolve({ data_b64: Buffer.concat(chunks).subarray(0, maxBytes).toString("base64"), ...flags });
    };
    const abort = () => finish(new Error("the script was stopped"));
    const total = setTimeout(() => (socket.connecting ? finish(new Error(`connect to ${address}:${port} timed out`)) : finish(null, { closed: false, truncated: false, timed_out: true })), timeoutMs);
    const armIdle = () => {
      clearTimeout(idle);
      if (idleMs > 0) idle = setTimeout(() => finish(null), idleMs);
    };
    signal.addEventListener("abort", abort);
    socket.on("error", (e: NodeJS.ErrnoException) =>
      finish(new Error(e.code === "ECONNREFUSED" ? `connect to ${address}:${port} refused: nothing is listening on that port` : `${address}:${port}: ${e.message}`)),
    );
    socket.on("connect", () => {
      socket.write(Buffer.from(encoded, "base64"));
      if (params.close_write === true) socket.end();
      armIdle();
    });
    socket.on("data", (data: Buffer) => {
      chunks.push(data);
      got += data.length;
      if (got > maxBytes) return finish(null, { closed: false, truncated: true, timed_out: false });
      armIdle();
    });
    socket.on("end", () => finish(null, { closed: true, truncated: false, timed_out: false }));
  });
}
