// Computer Use: the app's helper daemon, reached over a private Unix socket with a per-process auth token. Actions map
// to daemon requests, responses to results; the helper launches as the application it prepares. Screenshots are
// temporary device files: bounded in size and count, expiring after fifteen minutes on the connector's clock.
import { randomBytes } from "node:crypto";
import { createConnection } from "node:net";
import { chmodSync, closeSync, lstatSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync, statSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { Cause, Clock, Duration, Effect } from "effect";
import { killGroup, runBounded, spawnGroup } from "./child.ts";
import { COMPUTER_USE_HELLO_MESSAGE, COMPUTER_USE_SOCKET_DIRECTORY_NAME } from "./computer-use-paths.ts";
import { Mutex } from "./locks.ts";
import { platform } from "../platform/index.ts";

export * from "./computer-use-paths.ts";

export const COMPUTER_USE_IMAGE_TTL_MS = 15 * 60_000;
export const COMPUTER_USE_IMAGE_MAX_BYTES = 5 * 1024 * 1024;
export const COMPUTER_USE_IMAGE_BUDGET = 128 * 1024 * 1024;
export const COMPUTER_USE_IMAGE_MAX_COUNT = 128;
const RESPONSE_LINE_LIMIT = 64 * 1024 * 1024;

export type ComputerUseConfig = { computerUseHelperApp: string; computerUseSocketPath: string; computerUseRuntimePath: string; env: Record<string, string | undefined> };

type Permissions = { accessibility: boolean; screenRecording: boolean };

/** A daemon response; `imageData` decoded from its base64. */
export type DaemonResponse = {
  ok?: boolean;
  error?: string;
  interrupted?: boolean;
  message?: string;
  imageData?: Buffer;
  imageContentType?: string;
  imageWidth?: number;
  imageHeight?: number;
  permissions?: Permissions;
  active?: boolean;
  state?: string;
  instructions?: string;
  coordinate?: number[];
};

type DaemonRequest = { action?: Record<string, unknown>; control?: string; display?: number; thinking?: string; auth_token?: string };
type Result = Record<string, unknown>;

const darwin = platform.hasComputerUse;
const failure = (error: string): Result => ({ ok: false, error });
const text = (value: unknown) => (typeof value === "string" ? value : "");
const isImageName = (name: string) => basename(name) === name && name.startsWith("capture-") && (name.endsWith(".png") || name.endsWith(".jpg"));

export const normalizeComputerUseAction = (action: string) => action.trim().replaceAll("-", "_");

export function computerUseHelperOpenArgs(helperApp: string, socketPath: string, runtimePath: string, authToken: string): string[] {
  const args = ["-n", "-g", "--env", `COMMA_COMPUTER_USE_SOCKET_PATH=${socketPath}`];
  if (runtimePath) args.push("--env", `COMMA_COMPUTER_USE_RUNTIME_PATH=${runtimePath}`);
  return [...args, "--env", `COMMA_COMPUTER_USE_AUTH_TOKEN=${authToken}`, helperApp];
}

export function makeComputerUse(cfg: ComputerUseConfig, fork: (effect: Effect.Effect<void>) => void) {
  let authToken = "";
  let imagesScheduled = false;
  const images = new Mutex();
  const env = Object.fromEntries(Object.entries(cfg.env).filter((e): e is [string, string] => e[1] !== undefined));
  const token = () => (authToken ||= randomBytes(32).toString("base64url"));

  const available = () => {
    if (!darwin || !cfg.computerUseHelperApp) return false;
    try {
      return statSync(cfg.computerUseHelperApp).isDirectory();
    } catch {
      return false;
    }
  };

  /** One request on a fresh connection: notice lines lift the deadline, the final line answers. */
  const send = (action: string, request: DaemonRequest): Effect.Effect<{ response: DaemonResponse; raw: Record<string, unknown>; notices: string[] }, Error> =>
    Effect.gen(function* () {
      const timeout = action === "wait" ? null : action === "hello" || action === "shutdown" ? Duration.seconds(2) : Duration.seconds(60);
      const deadline = timeout === null ? null : (yield* Clock.currentTimeMillis) + Duration.toMillis(timeout);
      const conn = yield* Effect.callback<ReturnType<typeof createConnection>, Error>((resume) => {
        const socket = createConnection({ path: cfg.computerUseSocketPath });
        socket.once("error", (error) => resume(Effect.fail(new Error(`connect computer_use daemon: ${error.message}`))));
        socket.once("connect", () => {
          socket.removeAllListeners("error");
          resume(Effect.succeed(socket));
        });
        return Effect.sync(() => void socket.destroy());
      }).pipe(
        Effect.timeoutOption(Duration.seconds(5)),
        Effect.flatMap((o) => (o._tag === "Some" ? Effect.succeed(o.value) : Effect.fail(new Error("connect computer_use daemon: i/o timeout")))),
      );
      const lines: Array<string | Error | null> = [];
      const waiters: Array<(line: string | Error | null) => void> = [];
      const push = (line: string | Error | null) => {
        const waiter = waiters.shift();
        if (waiter) waiter(line);
        else lines.push(line);
      };
      let buffer = "";
      conn.setEncoding("utf8");
      conn.on("data", (chunk: string) => {
        buffer += chunk;
        let newline = buffer.indexOf("\n");
        while (newline >= 0) {
          push(buffer.slice(0, newline));
          buffer = buffer.slice(newline + 1);
          newline = buffer.indexOf("\n");
        }
        if (buffer.length > RESPONSE_LINE_LIMIT) {
          push(new Error("read computer_use response: token too long"));
          conn.destroy();
        }
      });
      conn.on("end", () => push(buffer.trim() ? buffer : null));
      conn.on("close", () => push(null));
      conn.on("error", (error) => push(new Error(`read computer_use response: ${error.message}`)));
      const readLine = Effect.callback<string | Error | null>((done) => {
        if (lines.length) return done(Effect.succeed(lines.shift()!));
        waiters.push((line) => done(Effect.succeed(line)));
      });
      return yield* Effect.gen(function* () {
        const encoded = `${JSON.stringify({ ...request, auth_token: token() })}\n`;
        yield* Effect.callback<void, Error>((done) => void conn.write(encoded, (error) => done(error ? Effect.fail(new Error(`write computer_use request: ${error.message}`)) : Effect.void)));
        const notices: string[] = [];
        let until = deadline;
        while (true) {
          let line: string | Error | null;
          if (until === null) line = yield* readLine;
          else {
            const left = until - (yield* Clock.currentTimeMillis);
            const read = left > 0 ? yield* Effect.timeoutOption(readLine, Duration.millis(left)) : { _tag: "None" as const };
            if (read._tag === "None") return yield* Effect.fail(new Error("read computer_use response: i/o timeout"));
            line = read.value;
          }
          if (line instanceof Error) return yield* Effect.fail(line);
          if (line === null) return yield* Effect.fail(new Error("computer_use daemon closed without a final response"));
          const trimmed = line.trim();
          if (!trimmed) continue;
          let parsed: any;
          try {
            parsed = JSON.parse(trimmed);
          } catch (error) {
            return yield* Effect.fail(new Error(`decode computer_use response: ${(error as Error).message}`));
          }
          if (parsed && typeof parsed === "object" && typeof parsed.kind === "string" && parsed.kind) {
            if (parsed.kind === "notice" && text(parsed.message).trim()) {
              notices.push(parsed.message);
              until = null;
            } else if (parsed.kind === "final") {
              if (parsed.response === undefined || parsed.response === null) return yield* Effect.fail(new Error("computer_use daemon returned an empty final response"));
              return { ...decodeResponse(parsed.response), notices };
            }
            continue;
          }
          return { ...decodeResponse(parsed), notices };
        }
      }).pipe(Effect.ensuring(Effect.sync(() => void conn.destroy())));
    });

  const socketReady = send("hello", { control: "hello" }).pipe(
    Effect.map(({ response }) => response.ok === true && (response.message ?? "").trim() === COMPUTER_USE_HELLO_MESSAGE),
    Effect.orElseSucceed(() => false),
  );

  /** `open` for the application `--prepare-app` names. */
  const helperCommand = (authToken: string): Effect.Effect<{ command: string; args: string[] }, Error> =>
    Effect.gen(function* () {
      const executable = join(cfg.computerUseHelperApp, "Contents", "MacOS", "CommaComputerUseDaemon");
      const run = yield* runBounded(executable, ["--prepare-app"], { env, timeout: Duration.seconds(15), stdoutLimit: 64 * 1024 });
      if (run.timedOut || run.exit.error || run.exit.code !== 0) {
        const reason = run.timedOut ? "signal: killed" : run.exit.error ? run.exit.error.message : `exit status ${run.exit.code}`;
        return yield* Effect.fail(new Error(`prepare computer_use application: ${reason}: ${run.stderr.text().trim()}`));
      }
      const helperApp = run.stdout.toString("utf8").trim();
      if (!helperApp) return yield* Effect.fail(new Error("computer_use returned no application path"));
      return { command: "open", args: computerUseHelperOpenArgs(helperApp, cfg.computerUseSocketPath, cfg.computerUseRuntimePath, authToken) };
    });

  const prepareSocketPath = (path: string) => {
    if (!path.trim()) throw new Error("computer_use socket path is not configured");
    const dir = dirname(path);
    try {
      if (!statSync(dir).isDirectory()) throw new Error(`computer_use socket parent is not a directory: ${dir}`);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      mkdirSync(dir, { recursive: true, mode: 0o700 });
    }
    if (dir === join(tmpdir(), COMPUTER_USE_SOCKET_DIRECTORY_NAME)) {
      try {
        chmodSync(dir, 0o700);
      } catch {}
    }
  };

  const ensureDaemon: Effect.Effect<void, Error> = Effect.gen(function* () {
    if (!darwin) return yield* Effect.fail(new Error("computer_use is only supported on macOS"));
    if (!cfg.computerUseHelperApp) return yield* Effect.fail(new Error("computer_use helper app is not configured"));
    if (!available()) return yield* Effect.fail(new Error(`computer_use helper app was not found at ${cfg.computerUseHelperApp}`));
    if (yield* socketReady) return;
    yield* Effect.try({ try: () => prepareSocketPath(cfg.computerUseSocketPath), catch: (error) => error as Error });
    rmSync(cfg.computerUseSocketPath, { force: true });
    const { command, args } = yield* helperCommand(token());
    yield* Effect.acquireUseRelease(
      Effect.sync(() => spawnGroup(command, args, { env, stdout: "ignore", stderr: "ignore" })),
      ({ exited }) =>
        exited.pipe(
          Effect.flatMap((exit) =>
            exit.error || exit.code !== 0 ? Effect.fail(new Error(`launch computer_use helper: ${exit.error?.message ?? (exit.signal ? `signal: ${exit.signal}` : `exit status ${exit.code}`)}`)) : Effect.void,
          ),
        ),
      ({ child }) => Effect.sync(() => killGroup(child)),
    );
    const until = (yield* Clock.currentTimeMillis) + 15_000;
    while ((yield* Clock.currentTimeMillis) < until) {
      if (yield* socketReady) return;
      yield* Effect.sleep(Duration.millis(100));
    }
    return yield* Effect.fail(new Error("computer_use daemon did not become ready within 15s"));
  });

  const shutdown: Effect.Effect<void> = Effect.gen(function* () {
    if (!darwin || !cfg.computerUseSocketPath.trim()) return;
    if (!(yield* socketReady)) {
      rmSync(cfg.computerUseSocketPath, { force: true });
      return;
    }
    const sent = yield* Effect.exit(send("shutdown", { control: "shutdown" }));
    if (sent._tag === "Failure") return;
    rmSync(cfg.computerUseSocketPath, { force: true });
  });

  // Screenshots.

  const imageDirectory: Effect.Effect<string, Error> = Effect.try({
    try: () => {
      if (!cfg.computerUseRuntimePath) throw new Error("computer_use temporary storage is not configured");
      const dir = join(cfg.computerUseRuntimePath, "screenshots");
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      return dir;
    },
    catch: (error) => error as Error,
  });

  const expire = (path: string, delayMs: number) =>
    fork(
      Effect.sleep(Duration.millis(delayMs)).pipe(
        Effect.andThen(
          images.with(
            Effect.sync(() => {
              try {
                rmSync(path, { force: true });
              } catch {}
            }),
          ),
        ),
      ),
    );

  /** Scans the private screenshot directory (held under the images lock): expired files go, foreign ones fail it. */
  const sweep = (dir: string): Effect.Effect<{ size: number; count: number }, Error> =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis;
      return yield* Effect.try({
        try: () => {
          const entries = readdirSync(dir, { withFileTypes: true });
          if (entries.length > COMPUTER_USE_IMAGE_MAX_COUNT) throw new Error("computer_use screenshot storage is full");
          let size = 0;
          let count = 0;
          const pending: Array<[string, number]> = [];
          for (const entry of entries) {
            if (!isImageName(entry.name) || !entry.isFile()) throw new Error("unexpected file in computer_use screenshot storage");
            const path = join(dir, entry.name);
            const info = statSync(path);
            const remaining = info.mtimeMs + COMPUTER_USE_IMAGE_TTL_MS - now;
            if (remaining <= 0) rmSync(path);
            else {
              size += info.size;
              count++;
              if (!imagesScheduled) pending.push([path, remaining]);
            }
          }
          for (const [path, remaining] of pending) expire(path, remaining);
          imagesScheduled = true;
          return { size, count };
        },
        catch: (error) => error as Error,
      });
    });

  const storeImage = (response: DaemonResponse): Effect.Effect<Result, Error> =>
    images.with(
      Effect.gen(function* () {
        const data = response.imageData ?? Buffer.alloc(0);
        if (data.length > COMPUTER_USE_IMAGE_MAX_BYTES) return yield* Effect.fail(new Error("computer_use screenshot exceeds 5 MiB"));
        const mime = response.imageContentType ?? "";
        const ext = mime === "image/png" ? ".png" : mime === "image/jpeg" ? ".jpg" : null;
        if (!ext) return yield* Effect.fail(new Error("unsupported screenshot format"));
        const dir = yield* imageDirectory;
        const used = yield* sweep(dir);
        if (used.count >= COMPUTER_USE_IMAGE_MAX_COUNT || used.size + data.length > COMPUTER_USE_IMAGE_BUDGET) {
          return yield* Effect.fail(new Error("computer_use screenshot storage is full; retry after screenshots expire"));
        }
        const path = yield* Effect.try({
          try: () => {
            const path = join(dir, `capture-${randomBytes(8).toString("hex")}${ext}`);
            const fd = openSync(path, "wx", 0o600);
            try {
              writeSync(fd, data);
            } catch (error) {
              rmSync(path, { force: true });
              throw new Error(`save screenshot: ${(error as Error).message}`);
            } finally {
              closeSync(fd);
            }
            return path;
          },
          catch: (error) => error as Error,
        });
        expire(path, COMPUTER_USE_IMAGE_TTL_MS);
        return { ok: true, image_path: basename(path), image_content_type: mime, image_width: response.imageWidth ?? 0, image_height: response.imageHeight ?? 0, image_size_bytes: data.length };
      }),
    );

  const readImage = (name: string): Effect.Effect<Result> =>
    images.with(
      Effect.gen(function* () {
        if (!isImageName(name)) return failure("invalid screenshot reference");
        const dir = yield* Effect.exit(imageDirectory);
        if (dir._tag === "Failure") return failure(errorText(dir.cause));
        const swept = yield* Effect.exit(sweep(dir.value));
        if (swept._tag === "Failure") return failure(errorText(swept.cause));
        const path = join(dir.value, name);
        try {
          const info = lstatSync(path);
          if (!info.isFile()) return failure("screenshot expired or unavailable");
          if (info.size > COMPUTER_USE_IMAGE_MAX_BYTES) return failure("screenshot exceeds 5 MiB");
        } catch {
          return failure("screenshot expired or unavailable");
        }
        try {
          const body = readFileSync(path);
          if (body.length > COMPUTER_USE_IMAGE_MAX_BYTES) return failure("screenshot exceeds 5 MiB");
          return { ok: true, image_base64: body.toString("base64") };
        } catch {
          return failure("screenshot unavailable");
        }
      }),
    );

  /** The `computer_use` method: failures are results ({ ok: false, error }), as the agent reads them. */
  const call = (params: Record<string, unknown>): Effect.Effect<Result> =>
    Effect.gen(function* () {
      const action = text(params.action).trim();
      if (!action) return failure("'action' is required");
      const normalized = normalizeComputerUseAction(action);
      if (normalized === "read_image") return yield* readImage(text((params.args as Record<string, unknown> | undefined)?.path));
      if (normalized === "mode_help") return { ok: true, help: computerUseForegroundHelp() };
      let request: DaemonRequest;
      try {
        request = buildDaemonRequest(normalized, params);
      } catch (error) {
        return failure((error as Error).message);
      }
      const ready = yield* Effect.exit(ensureDaemon);
      if (ready._tag === "Failure") return failure(errorText(ready.cause));
      const sent = yield* Effect.exit(send(normalized, request));
      if (sent._tag === "Failure") return failure(errorText(sent.cause));
      const { response, raw, notices } = sent.value;
      if (response.ok && response.imageData && response.imageData.length > 0) {
        const stored = yield* Effect.exit(storeImage(response));
        return stored._tag === "Success" ? stored.value : failure(errorText(stored.cause));
      }
      return connectorResponse(normalized, response, raw, notices);
    });

  /** Clears expired screenshots left by an earlier process. */
  const sweepAtStart: Effect.Effect<void> = Effect.suspend(() => {
    if (!cfg.computerUseRuntimePath) return Effect.void;
    const dir = join(cfg.computerUseRuntimePath, "screenshots");
    try {
      statSync(dir);
    } catch {
      return Effect.void;
    }
    return images.with(sweep(dir)).pipe(Effect.asVoid, Effect.ignore);
  });

  return { available, call, shutdown, helperCommand, storeImage, readImage, imageDirectory, sweepAtStart };
}

export type ComputerUse = ReturnType<typeof makeComputerUse>;

function errorText(cause: Cause.Cause<unknown>): string {
  const error = Cause.squash(cause);
  return error instanceof Error ? error.message : String(error);
}

function decodeResponse(value: unknown): { response: DaemonResponse; raw: Record<string, unknown> } {
  const raw = value && typeof value === "object" ? { ...(value as Record<string, unknown>) } : {};
  const response = raw as DaemonResponse & { imageData?: any };
  const decoded: DaemonResponse = { ...response, imageData: typeof raw.imageData === "string" ? Buffer.from(raw.imageData, "base64") : undefined };
  return { response: decoded, raw };
}

function permissionMap(permissions: Permissions | undefined): Permissions | null {
  return permissions ? { accessibility: !!permissions.accessibility, screenRecording: !!permissions.screenRecording } : null;
}

function connectorResponse(action: string, response: DaemonResponse, raw: Record<string, unknown>, notices: string[]): Result {
  const permissions = permissionMap(response.permissions);
  if (!response.ok) {
    let message = ((response.error ?? "").trim() ? response.error! : (response.message ?? "")).trim();
    if (!message && response.interrupted) message = "computer_use was interrupted";
    const result: Result = { ok: false, error: message || "computer_use failed", interrupted: !!response.interrupted };
    if (permissions) result.permissions = permissions;
    return result;
  }
  const message = [...notices, ...((response.message ?? "").trim() ? [response.message!] : [])].join("\n\n");
  const result: Result =
    action === "start"
      ? { ok: true, message: message || "session started", mode: "foreground", help: computerUseForegroundHelp(), text: render(response, raw) }
      : { ok: true, text: render(response, raw) || message };
  if (permissions) result.permissions = permissions;
  return result;
}

function render(response: DaemonResponse, raw: Record<string, unknown>): string {
  const parts: string[] = [];
  if ((response.message ?? "").trim()) parts.push(response.message!.trim());
  const word = (granted: boolean) => (granted ? "granted" : "missing");
  if (response.permissions) parts.push(`Permissions\n  Accessibility: ${word(!!response.permissions.accessibility)}\n  Screen Recording: ${word(!!response.permissions.screenRecording)}`);
  if (response.active !== undefined || response.state) {
    const runtime: string[] = [];
    if (response.active !== undefined) runtime.push(`Active: ${response.active ? "yes" : "no"}`);
    if (response.state) runtime.push(`State: ${response.state}`);
    parts.push(`Runtime\n  ${runtime.join("\n  ")}`);
  }
  if ((response.coordinate ?? []).length >= 2) parts.push(`Cursor\n  Position: (${response.coordinate![0]}, ${response.coordinate![1]})`);
  if ((response.instructions ?? "").trim()) parts.push(`How to fix it\n  ${response.instructions!.trim().replaceAll("\n", "\n  ")}`);
  if (parts.length) return parts.join("\n\n");
  const { imageData: _image, ...rest } = raw;
  return JSON.stringify(rest, null, 2);
}

// Request building.

function intValue(value: unknown): number | null | "invalid" {
  if (value === undefined || value === null) return null;
  if (typeof value === "number") return Number.isInteger(value) ? value : "invalid";
  if (typeof value === "string") {
    if (!value.trim()) return null;
    return /^[+-]?\d+$/.test(value.trim()) ? Number.parseInt(value.trim(), 10) : "invalid";
  }
  return "invalid";
}

function requiredInt(args: Record<string, unknown>, key: string): number {
  if (!(key in args)) throw new Error(`'${key}' is required`);
  const value = intValue(args[key]);
  if (value === null || value === "invalid") throw new Error(`'${key}' must be an integer`);
  return value;
}

function optionalInt(args: Record<string, unknown>, key: string): number | null {
  const value = intValue(args[key]);
  if (value === "invalid") throw new Error(`'${key}' must be an integer`);
  return value;
}

function requiredFloat(args: Record<string, unknown>, key: string): number {
  if (!(key in args)) throw new Error(`'${key}' is required`);
  const value = args[key];
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value.trim()))) return Number(value.trim());
  throw new Error(`'${key}' must be a number`);
}

function requiredText(args: Record<string, unknown>, key: string): string {
  const value = text(args[key]).trim();
  if (!value) throw new Error(`'${key}' is required`);
  return value;
}

function buildDaemonRequest(action: string, params: Record<string, unknown>): DaemonRequest {
  const args = params.args && typeof params.args === "object" && !Array.isArray(params.args) ? (params.args as Record<string, unknown>) : {};
  const request: DaemonRequest = {};
  for (const source of [args, params]) {
    if (!("display" in source)) continue;
    const display = intValue(source.display);
    if (display === "invalid") throw new Error("'display' must be an integer");
    if (display !== null) {
      request.display = display;
      break;
    }
  }
  const thinking = text(params.thinking).trim();
  if (thinking) request.thinking = thinking;
  const act = (name: string, payload: Record<string, unknown> = {}) => (request.action = { [name]: payload });
  const xy = () => ({ x: requiredInt(args, "x"), y: requiredInt(args, "y") });
  const withModifier = (payload: Record<string, unknown>) => {
    const modifier = text(args.modifier).trim();
    return modifier ? { ...payload, modifier } : payload;
  };
  switch (action) {
    case "open_permission_flow":
      request.control = "open-permission-flow";
      break;
    case "start":
      act("start", { apps: Array.isArray(args.apps) ? args.apps.map((a) => text(a).trim()).filter(Boolean) : [] });
      break;
    case "end":
    case "stop":
      act("end");
      break;
    case "status":
    case "permissions_status":
    case "list_windows":
    case "wait":
      act(action);
      break;
    case "list_applications":
    case "list_apps":
      act("list_applications");
      break;
    case "screenshot":
    case "get_screenshot":
      act("get_screenshot");
      break;
    case "screen_size":
    case "get_screen_size":
      act("get_screen_size");
      break;
    case "cursor_position":
    case "get_cursor_position":
      act("get_cursor_position");
      break;
    case "zoom":
      act("zoom", { x1: requiredInt(args, "x1"), y1: requiredInt(args, "y1"), x2: requiredInt(args, "x2"), y2: requiredInt(args, "y2") });
      break;
    case "click":
    case "left_click":
    case "right_click":
    case "middle_click":
      act(action === "click" ? "left_click" : action, withModifier(xy()));
      break;
    case "double_click":
    case "triple_click":
    case "mouse_move":
      act(action, xy());
      break;
    case "left_click_drag":
      act("left_click_drag", { from_x: requiredInt(args, "from_x"), from_y: requiredInt(args, "from_y"), to_x: requiredInt(args, "to_x"), to_y: requiredInt(args, "to_y") });
      break;
    case "left_mouse_down":
    case "left_mouse_up": {
      const payload: Record<string, unknown> = {};
      const x = optionalInt(args, "x");
      const y = optionalInt(args, "y");
      if (x !== null) payload.x = x;
      if (y !== null) payload.y = y;
      act(action, payload);
      break;
    }
    case "scroll": {
      const position = xy();
      const direction = requiredText(args, "direction");
      act("scroll", withModifier({ direction, ...position, amount: optionalInt(args, "amount") ?? 3 }));
      break;
    }
    case "key":
      act("key", { combo: requiredText(args, "combo") });
      break;
    case "type":
    case "thinking":
      act(action, { text: requiredText(args, "text") });
      break;
    case "focus":
      act("focus", { app: requiredText(args, "app"), window: requiredText(args, "window") });
      break;
    case "hold_key":
      act("hold_key", { key: requiredText(args, "key"), duration: requiredFloat(args, "duration") });
      break;
    case "wait_action":
      act("wait_action", { duration: requiredFloat(args, "duration") });
      break;
    default:
      throw new Error(`unsupported computer_use action ${JSON.stringify(action)}`);
  }
  return request;
}

export function computerUseForegroundHelp(): string {
  return `ComputerUse foreground mode

Use action names exactly as shown below. Pass action-specific inputs under args, and pass a short top-level thinking string on each step when useful.

Session:
- start: args.apps? = [app names], args.display? = display number
- status or permissions-status: inspect permissions, display metadata, and session state
- open-permission-flow: open CommaComputerUse's guided permission flow
- end or stop: end the session and restore hidden apps
- wait: wait while the user is operating the screen

Screen:
- get_screenshot: capture the current display
- get_screen_size: return image dimensions
- get_cursor_position: return cursor coordinates in screenshot image space
- zoom: args.x1, args.y1, args.x2, args.y2

Mouse and keyboard:
- left_click/right_click/middle_click/click: args.x, args.y, args.modifier?
- double_click/triple_click/mouse_move: args.x, args.y
- left_click_drag: args.from_x, args.from_y, args.to_x, args.to_y
- left_mouse_down/left_mouse_up: args.x?, args.y?
- scroll: args.direction, args.x, args.y, args.amount?, args.modifier?
- key: args.combo
- type: args.text
- hold_key: args.key, args.duration
- wait_action: args.duration
- focus: args.app, args.window
- thinking: args.text

Coordinates are screenshot image-space coordinates from get_screenshot/get_screen_size. Screenshot and zoom actions return an image envelope to Salix; the agent receives a temporary device image reference valid for 15 minutes.`;
}
