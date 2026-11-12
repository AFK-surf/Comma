// `comma`: the CLI agents run to call Comma. On a desktop it calls the Comma app's declarative Main API (modules,
// describe, call) with the bearer Main launched the station with; the HTTP side is the ClientControl service. In a
// sandbox, or wherever there is no Main, it calls Salix through the station's own MCP endpoint of the session it runs
// in (tools, describe, call: the salix_tools and salix_call tools, tools/salix.ts), with the session's token and URL
// from the agent process's environment; the HTTP side is the StationMcp service.
import { Context, Duration, Effect, Layer } from "effect";
import { SALIX_TOOL_CALL_TIMEOUT } from "./config.ts";

export const COMMA_CLIENT_CONTROL_URL_ENV = "COMMA_CLIENT_CONTROL_URL";
export const COMMA_CLIENT_CONTROL_TOKEN_ENV = "COMMA_CLIENT_CONTROL_TOKEN";
/// The session's own door to the station (agents/claude.ts, agents/codex.ts).
export const STATION_MCP_URL_ENV = "COMMA_STATION_MCP_URL";
export const STATION_MCP_TOKEN_ENV = "COMMA_STATION_MCP_TOKEN";
const MAX_RESPONSE_BYTES = 1024 * 1024;
/// A Salix tool's result may be 1 MiB; the MCP envelope around it a little more.
const MAX_MCP_RESPONSE_BYTES = 2 * 1024 * 1024;

export class ClientControl extends Context.Service<
  ClientControl,
  {
    /** POST /v1/invoke with `body`. */
    call(token: string, body: unknown): Effect.Effect<unknown, Error>;
    /** GET a path under /v1 (modules, describe). */
    get?(token: string, path: string): Effect.Effect<unknown, Error>;
    /** POST one JSON-RPC message to Main's MCP server `server`; null when it answers a notification. */
    mcp?(token: string, server: string, message: unknown): Effect.Effect<unknown, Error>;
  }
>()("station/ClientControl") {}

export class StationMcp extends Context.Service<
  StationMcp,
  {
    /** POST one JSON-RPC request to the station's MCP endpoint `url` as the session of `token`; its response. */
    call(url: string, token: string, message: unknown): Effect.Effect<unknown, Error>;
  }
>()("station/StationMcp") {}

const usage = [
  "usage (Comma desktop): comma modules | comma describe <module> | comma call <module> <api> [--json '<object>']",
  "usage (Salix, from a sandbox): comma tools | comma describe <tool> | comma call <tool> [--json '<object>'] | comma exec --credential <provider>/<alias>[:client_id]=<ENV_VAR> [--env <NAME>=<value>] [--timeout <seconds>] -- <command> [args...]",
].join("\n");
const toError = (e: unknown) => (e instanceof Error ? e : new Error(String(e)));

/** Main's control endpoint over HTTP: bounded, no redirects, 30 seconds; an MCP message has its caller's deadline. */
export function liveClientControl(endpoint: string) {
  // Interrupting the request (its deadline) aborts the fetch.
  const request = (method: string, url: string, token: string, body?: unknown, accept?: string) =>
    Effect.tryPromise({
      try: async (signal) => {
        const response = await fetch(url, {
          method,
          signal,
          redirect: "manual",
          headers: {
            authorization: `Bearer ${token}`,
            ...(body === undefined ? {} : { "content-type": "application/json" }),
            ...(accept ? { accept } : {}),
          },
          body: body === undefined ? undefined : JSON.stringify(body),
        });
        const raw = Buffer.from(await response.arrayBuffer());
        if (raw.length > MAX_RESPONSE_BYTES) throw new Error("Comma client response exceeds limit");
        if (response.status >= 400) throw new Error(`Comma client API returned HTTP ${response.status}`);
        return raw.length ? JSON.parse(raw.toString()) : null;
      },
      catch: toError,
    });
  const bounded = <A>(effect: Effect.Effect<A, Error>) => effect.pipe(Effect.timeout("30 seconds"), Effect.mapError(toError));
  return Layer.succeed(ClientControl)({
    call: (token, body) => bounded(request("POST", `${endpoint}/v1/invoke`, token, body)),
    get: (token, path) => bounded(request("GET", `${endpoint}/v1/${path}`, token)),
    // Streamable HTTP clients accept both; Main answers with plain JSON.
    mcp: (token, server, message) =>
      request("POST", `${endpoint}/v1/mcp/${encodeURIComponent(server)}`, token, message, "application/json, text/event-stream"),
  });
}

/** The station's MCP endpoint over HTTP (tools/http.ts, 127.0.0.1): bounded a little past the station's wait for a Salix tool call. */
export function liveStationMcp() {
  return Layer.succeed(StationMcp)({
    call: (url, token, message) =>
      Effect.tryPromise({
        try: async (signal) => {
          const response = await fetch(url, {
            method: "POST",
            signal,
            redirect: "manual",
            headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
            body: JSON.stringify(message),
          });
          const raw = Buffer.from(await response.arrayBuffer());
          if (raw.length > MAX_MCP_RESPONSE_BYTES) throw new Error("the station's response exceeds limit");
          if (response.status >= 400) throw new Error(`the station's MCP endpoint returned HTTP ${response.status}`);
          return raw.length ? JSON.parse(raw.toString()) : null;
        },
        catch: toError,
      }).pipe(Effect.timeout(Duration.sum(SALIX_TOOL_CALL_TIMEOUT, Duration.seconds(15))), Effect.mapError(toError)),
  });
}

type CliIo = { stdout: (text: string) => void; stderr?: (text: string) => void; exit?: (code: number) => void; cwd?: string };

export function runCommaClientCli(
  args: string[],
  io: CliIo & { env: Record<string, string | undefined> },
): Effect.Effect<void, Error, ClientControl | StationMcp> {
  return Effect.gen(function* () {
    if (args.length === 0 || ["help", "-h", "--help"].includes(args[0])) {
      io.stdout(`${usage}\n`);
      return;
    }
    const endpoint = (io.env[COMMA_CLIENT_CONTROL_URL_ENV] ?? "").trim().replace(/\/+$/, "");
    const token = (io.env[COMMA_CLIENT_CONTROL_TOKEN_ENV] ?? "").trim();
    if (endpoint && token) return yield* mainCommands(args, token, io);
    const mcpUrl = (io.env[STATION_MCP_URL_ENV] ?? "").trim();
    const mcpToken = (io.env[STATION_MCP_TOKEN_ENV] ?? "").trim();
    if (mcpUrl && mcpToken) return yield* salixCommands(args, mcpUrl, mcpToken, io);
    return yield* Effect.fail(new Error("Comma client control is unavailable in this environment"));
  });
}

/// `--json '<object>'` after `args[from]`, else `{}`; what else is there is a usage error.
function jsonOption(args: string[], from: number, usageText: string): Effect.Effect<Record<string, unknown>, Error> {
  let input = "{}";
  for (let index = from; index < args.length; index++) {
    if (args[index] !== "--json" || index + 1 >= args.length) return Effect.fail(new Error(usageText));
    input = args[++index];
  }
  let object: unknown = null;
  try {
    object = JSON.parse(input);
  } catch {
    object = null;
  }
  if (!object || typeof object !== "object" || Array.isArray(object)) return Effect.fail(new Error("--json must be a JSON object"));
  return Effect.succeed(object as Record<string, unknown>);
}

const EXEC_USAGE = "usage: comma exec --credential <provider>/<alias>[:client_id]=<ENV_VAR> [--env <NAME>=<value>] [--timeout <seconds>] -- <command> [args...]";

/// `comma exec`'s env.exec input: this sandbox runs the command, with Salix's own copy of each credential in its
/// environment for this one command. Nothing the sandbox keeps holds the credential, so a lost disk loses no login.
function execRequest(args: string[], cwd: string | undefined): Effect.Effect<Record<string, unknown>, Error> {
  const credentials: { env_var: string; provider: string; alias: string; value: string }[] = [];
  const env: Record<string, string> = {};
  let timeout: number | undefined;
  let index = 0;
  for (; index < args.length && args[index] !== "--"; index++) {
    const value = args[index + 1];
    if (value === undefined) return Effect.fail(new Error(EXEC_USAGE));
    if (args[index] === "--credential") {
      const found = /^([^/=]+)\/([^=:]+)(:client_id)?=([A-Za-z_][A-Za-z0-9_]*)$/.exec(value);
      if (!found) return Effect.fail(new Error(EXEC_USAGE));
      credentials.push({ env_var: found[4], provider: found[1], alias: found[2], value: found[3] ? "client_id" : "access_token" });
    } else if (args[index] === "--env") {
      const found = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s.exec(value);
      if (!found) return Effect.fail(new Error(EXEC_USAGE));
      env[found[1]] = found[2];
    } else if (args[index] === "--timeout") {
      timeout = Number(value);
      if (!Number.isInteger(timeout) || timeout <= 0) return Effect.fail(new Error(EXEC_USAGE));
    } else {
      return Effect.fail(new Error(EXEC_USAGE));
    }
    index++;
  }
  const command = args.slice(index + 1);
  if (command.length === 0 || credentials.length === 0) return Effect.fail(new Error(EXEC_USAGE));
  return Effect.succeed({
    device_id: "self",
    environment: "self",
    description: "comma exec",
    command: command.map(shellQuoted).join(" "),
    credential_env: credentials,
    env,
    ...(timeout === undefined ? {} : { timeout }),
    ...(cwd === undefined ? {} : { working_dir: cwd }),
  });
}

const shellQuoted = (word: string) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(word) ? word : `'${word.replaceAll("'", "'\\''")}'`);

/// env.exec's answer, when it is the finished command's.
function parsedExec(text: string): { stdout: string; stderr: string; exitCode: number } | null {
  try {
    const result = JSON.parse(text);
    if (typeof result?.exit_code !== "number") return null;
    return { stdout: String(result.stdout ?? ""), stderr: String(result.stderr ?? ""), exitCode: result.exit_code };
  } catch {
    return null;
  }
}

/// The desktop's commands, to Main's declarative API.
function mainCommands(args: string[], token: string, io: { stdout: (text: string) => void }): Effect.Effect<void, Error, ClientControl> {
  return Effect.gen(function* () {
    const control = yield* ClientControl;
    const print = (value: unknown) => io.stdout(`${JSON.stringify(value)}\n`);
    switch (args[0]) {
      case "modules": {
        if (args.length !== 1 || !control.get) return yield* Effect.fail(new Error("usage: comma modules"));
        return print(yield* control.get(token, "modules"));
      }
      case "describe": {
        if (args.length !== 2 || !args[1].trim() || !control.get) return yield* Effect.fail(new Error("usage: comma describe <module>"));
        return print(yield* control.get(token, `modules/${encodeURIComponent(args[1])}`));
      }
      case "call": {
        const callUsage = "usage: comma call <module> <api> [--json '<object>']";
        if (args.length < 3) return yield* Effect.fail(new Error(callUsage));
        const object = yield* jsonOption(args, 3, callUsage);
        return print(yield* control.call(token, { module: args[1], api: args[2], input: object }));
      }
      default:
        return yield* Effect.fail(new Error(`unknown comma command "${args[0]}"`));
    }
  });
}

/// The sandbox's commands, to Salix through the station's salix_tools and salix_call (tools/salix.ts).
function salixCommands(args: string[], url: string, token: string, io: CliIo): Effect.Effect<void, Error, StationMcp> {
  return Effect.gen(function* () {
    const mcp = yield* StationMcp;
    let nextId = 1;
    // One tool of the station's, as the session; the text it answered, or its error.
    const tool = (name: string, toolArgs: Record<string, unknown>) =>
      Effect.gen(function* () {
        const response: any = yield* mcp.call(url, token, { jsonrpc: "2.0", id: nextId++, method: "tools/call", params: { name, arguments: toolArgs } });
        if (response?.error) return yield* Effect.fail(new Error(String(response.error.message ?? response.error)));
        const text = Array.isArray(response?.result?.content) ? response.result.content.map((c: any) => (typeof c?.text === "string" ? c.text : "")).join("") : "";
        if (response?.result?.isError === true) return yield* Effect.fail(new Error(text !== "" ? text : "the tool failed"));
        return text;
      });
    const listed = () =>
      Effect.gen(function* () {
        const text = yield* tool("salix_tools", {});
        let tools: unknown;
        try {
          tools = JSON.parse(text);
        } catch {
          return yield* Effect.fail(new Error("the station answered salix_tools with something other than its tools"));
        }
        return Array.isArray(tools) ? (tools as { name?: unknown }[]) : [];
      });
    const print = (text: string) => io.stdout(text.endsWith("\n") ? text : `${text}\n`);
    switch (args[0]) {
      case "tools": {
        if (args.length !== 1) return yield* Effect.fail(new Error("usage: comma tools"));
        return print(JSON.stringify(yield* listed()));
      }
      case "describe": {
        if (args.length !== 2 || !args[1].trim()) return yield* Effect.fail(new Error("usage: comma describe <tool>"));
        const found = (yield* listed()).find((t) => t.name === args[1]);
        if (!found) return yield* Effect.fail(new Error(`no Salix tool "${args[1]}" is available here; comma tools lists them`));
        return print(JSON.stringify(found));
      }
      case "call": {
        const callUsage = "usage: comma call <tool> [--json '<object>']";
        if (args.length < 2 || !args[1].trim() || args[1].startsWith("-")) return yield* Effect.fail(new Error(callUsage));
        const object = yield* jsonOption(args, 2, callUsage);
        return print(yield* tool("salix_call", { tool: args[1], args: object }));
      }
      case "exec": {
        const request = yield* execRequest(args.slice(1), io.cwd);
        const text = yield* tool("salix_call", { tool: "env.exec", args: request });
        const result = parsedExec(text);
        if (!result) return print(text);
        if (result.stdout) io.stdout(result.stdout);
        if (result.stderr) (io.stderr ?? io.stdout)(result.stderr);
        io.exit?.(result.exitCode);
        return;
      }
      default:
        return yield* Effect.fail(new Error(`unknown comma command "${args[0]}"`));
    }
  });
}
