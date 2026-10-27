import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { duplexPair } from "node:stream";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  LOCAL_STATION_CHECK_TIMEOUT_MS,
  LOCAL_STATION_TIMEOUT_MS,
  LocalStationAdmin,
} from "../modules/local-station";

const TOKEN = "secret-admin-token";
const ADDRESS = "/station/run/local-admin.sock";

const runtime = (source: "none" | "local" | "endpoint" | "workspace") => ({
  source,
  workspaceAvailable: true,
  workspaceAccounts: [{ name: "Team Codex" }],
  local: {
    installed: true,
    loggedIn: true,
    email: "me@example.com",
    usable: true,
    signIn: null,
  },
});
const view = {
  workspaces: [
    {
      workspaceId: "wsp/1",
      name: "Acme",
      runtimes: {
        codex: { ...runtime("local"), chosen: true },
        claude: runtime("none"),
      },
    },
  ],
};

type Handler = (
  request: IncomingMessage & { body: string },
  response: ServerResponse
) => void;

let dir: string;
const seen: {
  socket: string;
  method?: string | undefined;
  url?: string | undefined;
  auth?: string | undefined;
  body: string;
}[] = [];

/**
 * The station's admin interface: an HTTP server in this process, reached over an in-memory stream in place of the
 * socket named in `<data>/run/local-admin.address`, with the token in `<data>/local-admin.token`.
 */
async function station(handler: Handler, onConnect?: () => void) {
  await writeFile(join(dir, "local-admin.token"), `${TOKEN}\n`, { mode: 0o600 });
  await mkdir(join(dir, "run"), { recursive: true });
  await writeFile(join(dir, "run", "local-admin.address"), `${ADDRESS}\n`);
  const server: Server = createServer((request, response) => {
    let body = "";
    request.on("data", (chunk: Buffer) => (body += chunk.toString("utf8")));
    request.on("end", () => {
      seen.push({
        socket: current,
        method: request.method,
        url: request.url,
        auth: request.headers.authorization,
        body,
      });
      handler(Object.assign(request, { body }), response);
    });
  });
  let current = "";
  return new LocalStationAdmin({
    data: dir,
    connect: (socketPath) => {
      current = socketPath;
      const [client, side] = duplexPair();
      server.emit("connection", side);
      onConnect?.();
      return client;
    },
  });
}

const answer =
  (status: number, body: unknown) => (_: unknown, response: ServerResponse) => {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify(body));
  };

beforeEach(async () => {
  // The station's answers come over in-memory streams; only the deadline is a timer.
  vi.useFakeTimers();
  dir = await mkdtemp(join(tmpdir(), "local-station-"));
  seen.length = 0;
});

describe("LocalStationAdmin", () => {
  it("asks the station with its token and returns the view, without this Mac's login unless its source is local", async () => {
    const admin = await station(answer(200, view));

    const read = await admin.accounts();
    expect(seen[0]).toMatchObject({
      socket: ADDRESS,
      method: "GET",
      url: "/local/accounts",
      auth: `Bearer ${TOKEN}`,
    });
    expect(read.workspaces[0]?.runtimes.codex.local?.email).toBe("me@example.com");
    // The station must not show the machine's login for `none`; Main drops it if it does.
    expect(read.workspaces[0]?.runtimes.claude.local).toBeNull();
    // A recorded choice passes through; a station that sends no `chosen` has none recorded.
    expect(read.workspaces[0]?.runtimes.codex.chosen).toBe(true);
    expect(read.workspaces[0]?.runtimes.claude.chosen).toBe(false);

    await admin.setAccountSource({
      workspaceId: "wsp/1",
      runtime: "claude",
      source: "workspace",
    });
    await admin.signIn({ workspaceId: "wsp/1", runtime: "codex" });
    await admin.stopSignIn({ workspaceId: "wsp/1", runtime: "codex" });
    expect(seen.slice(1).map(({ method, url, body }) => [method, url, body])).toEqual([
      ["PUT", "/local/accounts/wsp%2F1/claude", '{"source":"workspace"}'],
      ["POST", "/local/accounts/wsp%2F1/codex/sign-in", ""],
      ["DELETE", "/local/accounts/wsp%2F1/codex/sign-in", ""],
    ]);
  });

  it("maps 409 to a conflict, and a refused token or a bad answer to a retryable error without the token", async () => {
    const admin = await station((request, response) => {
      if (request.method === "PUT")
        return answer(409, { error: "workspace_accounts_unavailable" })(
          request,
          response
        );
      if (request.url === "/local/accounts")
        return answer(401, { error: "unauthorized" })(request, response);
      return answer(200, { workspaces: "not a list" })(request, response);
    });

    await expect(
      admin.setAccountSource({
        workspaceId: "wsp_1",
        runtime: "codex",
        source: "workspace",
      })
    ).rejects.toMatchObject({ code: "LOCAL_STATION_CONFLICT" });
    const refused = await admin.accounts().catch((error: unknown) => error);
    expect(refused).toMatchObject({ code: "LOCAL_STATION_UNAVAILABLE" });
    expect(String((refused as Error).message)).not.toContain(TOKEN);
    await expect(
      admin.signIn({ workspaceId: "wsp_1", runtime: "codex" })
    ).rejects.toMatchObject({ code: "LOCAL_STATION_UNAVAILABLE" });
  });

  it("gives a model server's address and key to the station and waits past the usual deadline for its check of it", async () => {
    let held: ServerResponse | undefined;
    const admin = await station((_request, response) => {
      held = response;
    });
    const endpoint = {
      address: "http://ollama.test",
      keyed: true,
      state: "ok",
      detail: "2 models",
      models: ["qwen3:8b", "gemma3"],
    };
    let settled = false;
    const chosen = admin
      .setAccountSource({
        workspaceId: "wsp/1",
        runtime: "claude",
        source: "endpoint",
        endpoint: "http://ollama.test",
        key: "sk-local",
      })
      .finally(() => (settled = true));
    await vi.advanceTimersByTimeAsync(LOCAL_STATION_TIMEOUT_MS);
    expect([held !== undefined, settled]).toEqual([true, false]);
    const [workspace] = view.workspaces;
    answer(200, {
      workspaces: [
        {
          ...workspace,
          runtimes: {
            ...workspace!.runtimes,
            claude: { ...runtime("endpoint"), chosen: true, local: null, endpoint },
          },
        },
      ],
    })(undefined, held!);
    const read = await chosen;
    expect(seen.map(({ method, url, body }) => [method, url, body])).toEqual([
      [
        "PUT",
        "/local/accounts/wsp%2F1/claude",
        '{"source":"endpoint","endpoint":"http://ollama.test","key":"sk-local"}',
      ],
    ]);
    expect(read.workspaces[0]?.runtimes.claude.endpoint).toEqual(endpoint);
    // A station from before sends none.
    expect(read.workspaces[0]?.runtimes.codex.endpoint).toBeNull();
    expect(LOCAL_STATION_CHECK_TIMEOUT_MS).toBeGreaterThan(15_000);
  });

  it("fails fast with a retryable error when the station does not answer or has not started", async () => {
    // Takes the request and never answers.
    let connected!: () => void;
    const reached = new Promise<void>((resolve) => (connected = resolve));
    const silent = await station(
      () => undefined,
      () => connected()
    );
    const read = silent.accounts().catch((error: unknown) => error);
    await reached;
    // The deadline is set with the request; past it the call fails, it does not wait on.
    await vi.advanceTimersByTimeAsync(LOCAL_STATION_TIMEOUT_MS);
    expect(await read).toMatchObject({ code: "LOCAL_STATION_UNAVAILABLE" });

    // No token or address file: the station has not started.
    const empty = await mkdtemp(join(tmpdir(), "local-station-"));
    await expect(
      new LocalStationAdmin({ data: empty }).accounts()
    ).rejects.toMatchObject({ code: "LOCAL_STATION_UNAVAILABLE" });
    await expect(
      new LocalStationAdmin({ data: undefined }).accounts()
    ).rejects.toMatchObject({ code: "LOCAL_STATION_UNAVAILABLE" });
  });
});
