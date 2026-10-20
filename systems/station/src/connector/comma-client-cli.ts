// `comma`: the CLI agents on a desktop use to call the Comma app's declarative Main API (modules, describe, call),
// with the bearer Main launched the station with. The HTTP side is the ClientControl service.
import { Context, Effect, Layer } from "effect";

export const COMMA_CLIENT_CONTROL_URL_ENV = "COMMA_CLIENT_CONTROL_URL";
export const COMMA_CLIENT_CONTROL_TOKEN_ENV = "COMMA_CLIENT_CONTROL_TOKEN";
const MAX_RESPONSE_BYTES = 1024 * 1024;

export class ClientControl extends Context.Service<
  ClientControl,
  {
    /** POST /v1/invoke with `body`. */
    call(token: string, body: unknown): Effect.Effect<unknown, Error>;
    /** GET a path under /v1 (modules, describe). */
    get?(token: string, path: string): Effect.Effect<unknown, Error>;
  }
>()("station/ClientControl") {}

const usage = "usage: comma modules | comma describe <module> | comma call <module> <api> [--json '<object>']";
const toError = (e: unknown) => (e instanceof Error ? e : new Error(String(e)));

/** Main's control endpoint over HTTP: bounded, no redirects, 30 seconds. */
export function liveClientControl(endpoint: string) {
  const request = (method: string, url: string, token: string, body?: unknown) =>
    Effect.tryPromise({
      try: async () => {
        const response = await fetch(url, {
          method,
          redirect: "manual",
          headers: { authorization: `Bearer ${token}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
          body: body === undefined ? undefined : JSON.stringify(body),
        });
        const raw = Buffer.from(await response.arrayBuffer());
        if (raw.length > MAX_RESPONSE_BYTES) throw new Error("Comma client response exceeds limit");
        if (response.status >= 400) throw new Error(`Comma client API returned HTTP ${response.status}`);
        return raw.length ? JSON.parse(raw.toString()) : null;
      },
      catch: toError,
    }).pipe(Effect.timeout("30 seconds"), Effect.mapError(toError));
  return Layer.succeed(ClientControl)({
    call: (token, body) => request("POST", `${endpoint}/v1/invoke`, token, body),
    get: (token, path) => request("GET", `${endpoint}/v1/${path}`, token),
  });
}

export function runCommaClientCli(
  args: string[],
  io: { env: Record<string, string | undefined>; stdout: (text: string) => void },
): Effect.Effect<void, Error, ClientControl> {
  return Effect.gen(function* () {
    if (args.length === 0 || ["help", "-h", "--help"].includes(args[0])) {
      io.stdout(`${usage}\n`);
      return;
    }
    const endpoint = (io.env[COMMA_CLIENT_CONTROL_URL_ENV] ?? "").trim().replace(/\/+$/, "");
    const token = (io.env[COMMA_CLIENT_CONTROL_TOKEN_ENV] ?? "").trim();
    if (!endpoint || !token) return yield* Effect.fail(new Error("Comma client control is unavailable in this environment"));
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
        let input = "{}";
        for (let index = 3; index < args.length; index++) {
          if (args[index] !== "--json" || index + 1 >= args.length) return yield* Effect.fail(new Error(callUsage));
          input = args[++index];
        }
        let object: unknown = null;
        try {
          object = JSON.parse(input);
        } catch {
          object = null;
        }
        if (!object || typeof object !== "object" || Array.isArray(object)) return yield* Effect.fail(new Error("--json must be a JSON object"));
        return print(yield* control.call(token, { module: args[1], api: args[2], input: object }));
      }
      default:
        return yield* Effect.fail(new Error(`unknown comma command "${args[0]}"`));
    }
  });
}
