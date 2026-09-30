import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  appPreferencesPatchSchema,
  commaClientSettingsPatchSchema,
  defaultCommaClientSettings,
  type AppPreferences,
} from "@comma/native-bridge";
import { z } from "zod";
import type { AirDropService } from "../airdrop";
import { airDropSendInputSchema, type AirDropSendInput } from "../airdrop/sender";

const MAX_REQUEST_BYTES = 64 * 1024;
const MAX_RESPONSE_BYTES = 1024 * 1024;
const MAX_SCREENSHOT_BYTES = 5 * 1024 * 1024;
const SCREENSHOT_RING_SIZE = 8;
const CLIENT_CONTROL_CLOSE_TIMEOUT_MS = 1_000;

export interface ClientControlBrowserTarget {
  tabId: string;
  title: string;
  url: string;
  visible: boolean;
}

export interface ClientControlBrowser {
  listClientTargets(): ClientControlBrowserTarget[];
  openClientTab(input: { url: string }): Promise<ClientControlBrowserTarget>;
  sendClientCdpCommand(input: {
    method: string;
    params: Record<string, unknown>;
    tabId: string;
  }): Promise<unknown>;
  captureClientScreenshot(input: { tabId: string }): Promise<{
    pngImage: Uint8Array;
    target: ClientControlBrowserTarget;
  }>;
}

interface ClientControlPreferences {
  state(): AppPreferences | Promise<AppPreferences>;
  update(
    patch: z.output<typeof appPreferencesPatchSchema>
  ): AppPreferences | Promise<AppPreferences>;
}

interface ApiDeclaration {
  description: string;
  handler(input: unknown): Promise<unknown> | unknown;
  id: string;
  input: z.ZodType;
  usage: string;
}

interface ModuleDeclaration {
  apis: ApiDeclaration[];
  description: string;
  id: string;
}

export class CommaClientControlRegistry {
  readonly #modules: Map<string, ModuleDeclaration>;

  constructor(modules: ModuleDeclaration[]) {
    this.#modules = new Map(modules.map((module) => [module.id, module]));
  }

  list() {
    return {
      modules: [...this.#modules.values()].map(({ description, id }) => ({
        description,
        id,
      })),
    };
  }

  describe(moduleId: string) {
    const module = this.#modules.get(moduleId);
    if (!module) throw new ClientControlError(404, `Unknown module: ${moduleId}`);
    return {
      apis: module.apis.map(({ description, id, input, usage }) => ({
        description,
        id,
        inputSchema: z.toJSONSchema(input),
        usage,
      })),
      description: module.description,
      id: module.id,
    };
  }

  async invoke(request: unknown) {
    const parsed = invokeSchema.safeParse(request);
    if (!parsed.success)
      throw new ClientControlError(400, "Invalid invocation envelope.");
    const module = this.#modules.get(parsed.data.module);
    if (!module) {
      throw new ClientControlError(404, `Unknown module: ${parsed.data.module}`);
    }
    const api = module.apis.find((candidate) => candidate.id === parsed.data.api);
    if (!api) {
      throw new ClientControlError(
        404,
        `Unknown API: ${parsed.data.module}.${parsed.data.api}`
      );
    }
    const input = api.input.safeParse(parsed.data.input);
    if (!input.success) {
      throw new ClientControlError(400, "Invalid API input.");
    }
    return api.handler(input.data);
  }
}

const invokeSchema = z
  .object({
    api: z.string().trim().min(1).max(128),
    input: z.unknown(),
    module: z.string().trim().min(1).max(128),
  })
  .strict();

const emptyInputSchema = z.object({}).strict();
const globalSettingsPatchSchema = z
  .object({
    launchAtLogin: z.boolean().optional(),
    showInDock: z.boolean().optional(),
    showInMenuBar: z.boolean().optional(),
  })
  .strict()
  .refine((patch) => Object.keys(patch).length > 0, {
    message: "At least one global setting must be provided.",
  });
const browserTabInputSchema = z
  .object({
    tabId: z.string().trim().min(1).max(256),
  })
  .strict();
const browserOpenTabInputSchema = z
  .object({
    url: z
      .string()
      .trim()
      .min(1)
      .max(8_192)
      .url()
      .refine((value) => /^https?:\/\//i.test(value), {
        message: "In-app browser URLs must use http or https.",
      }),
  })
  .strict();
const cdpInputSchema = browserTabInputSchema
  .extend({
    method: z.string().trim().min(1).max(128),
    params: z.record(z.string(), z.unknown()).default({}),
  })
  .strict();

export function createCommaClientControlRegistry({
  airdrop,
  airdropSender,
  appPreferences,
  artifactRoot,
  browser,
  deviceAccess,
}: {
  airdrop?: Pick<AirDropService, "status" | "files">;
  airdropSender?: {
    status(): unknown;
    find(): unknown;
    send(input: AirDropSendInput): unknown;
    operation(id: string): unknown;
    cancel(id: string): unknown;
  };
  appPreferences: ClientControlPreferences;
  artifactRoot: string;
  browser: ClientControlBrowser;
  deviceAccess?: (
    workspaceId: string,
    allow: boolean
  ) => Promise<{ allows_operations: boolean }>;
}) {
  let screenshotSequence = 0;
  let screenshotWriteTail = Promise.resolve();
  let initializedArtifacts = false;
  const retainedScreenshotPaths: string[] = [];
  const writeScreenshot = (capture: {
    pngImage: Uint8Array;
    target: ClientControlBrowserTarget;
  }) => {
    const task = screenshotWriteTail.then(async () => {
      const raw = capture.pngImage;
      if (raw.byteLength > MAX_SCREENSHOT_BYTES) {
        throw new ClientControlError(413, "Screenshot exceeds artifact limit.");
      }
      await mkdir(artifactRoot, { mode: 0o700, recursive: true });
      if (!initializedArtifacts) {
        initializedArtifacts = true;
        const stale = (await readdir(artifactRoot))
          .filter((name) => /^browser-.*\.png$/.test(name))
          .map((name) => join(artifactRoot, name));
        await Promise.all(stale.map((path) => rm(path, { force: true })));
      }

      const sequence = ++screenshotSequence;
      const nonce = randomBytes(8).toString("hex");
      const path = join(artifactRoot, `browser-${sequence}-${nonce}.png`);
      const temporary = `${path}.${process.pid}.tmp`;
      try {
        await writeFile(temporary, raw, { mode: 0o600 });
        await rename(temporary, path);
      } finally {
        await rm(temporary, { force: true }).catch(() => undefined);
      }
      retainedScreenshotPaths.push(path);
      while (retainedScreenshotPaths.length > SCREENSHOT_RING_SIZE) {
        const evicted = retainedScreenshotPaths.shift();
        if (evicted) await rm(evicted, { force: true });
      }
      return {
        mimeType: "image/png",
        path,
        size: raw.byteLength,
        target: capture.target,
      };
    });
    screenshotWriteTail = task.then(
      () => undefined,
      () => undefined
    );
    return task;
  };

  return new CommaClientControlRegistry([
    ...(airdrop
      ? [
          {
            id: "airdrop",
            description:
              "Receive files into the current chat draft after local consent. Find nearby devices and send local files when the user requests it.",
            apis: [
              {
                id: "status",
                description:
                  "Check helper availability and receiver state. Only receiving means users can send to Comma now.",
                input: emptyInputSchema,
                usage: "comma call airdrop status",
                handler: () => ({
                  ...airdrop.status(),
                  sender: airdropSender?.status(),
                }),
              },
              ...(airdropSender
                ? [
                    {
                      id: "find",
                      description:
                        "Start a bounded nearby-device scan. Returns an operationId immediately. Query operation until succeeded, then select the exact peer ID. Device names are not verified identities.",
                      input: emptyInputSchema,
                      usage: "comma call airdrop find",
                      handler: () => airDropResult(() => airdropSender.find()),
                    },
                    {
                      id: "send",
                      description:
                        "Send 1 to 50 distinct regular files, at most 1 GiB in total, to a peer from a successful scan within two minutes. The recipient gets them as one AirDrop request. Each path can be an absolute Mac file path or /drive/...; /drive uses Synch's existing local Drive mapping. Files must already be available locally. Copy Task VFS files into /drive with fs.copy_file first and allow Drive to sync. Requires the user's intended files and recipient. Use a UUID requestId and reuse it for the same API call. Returns immediately. Only a succeeded send operation confirms acknowledged delivery. No automatic retries.",
                      input: airDropSendInputSchema,
                      usage: `comma call airdrop send --json '{"requestId":"<UUID>","peerId":"<peer ID>","paths":["/drive/photo.png","/drive/report.pdf"]}'`,
                      handler: (input: unknown) =>
                        airDropResult(() =>
                          airdropSender.send(input as AirDropSendInput)
                        ),
                    },
                    {
                      id: "operation",
                      description:
                        "Query scan or send progress by operationId. Poll at most once every five seconds. Terminal states: succeeded, failed, cancelled, timed_out. Recent operations expire on sign-out or after 20 newer operations.",
                      input: z.object({ operationId: z.string().uuid() }).strict(),
                      usage: `comma call airdrop operation --json '{"operationId":"<operationId>"}'`,
                      handler: (input: unknown) =>
                        airDropResult(() =>
                          airdropSender.operation(
                            (input as { operationId: string }).operationId
                          )
                        ),
                    },
                    {
                      id: "cancel",
                      description:
                        "Cancel the active scan or send. This cannot recall files already delivered. Check the recipient before retrying an unconfirmed transfer.",
                      input: z.object({ operationId: z.string().uuid() }).strict(),
                      usage: `comma call airdrop cancel --json '{"operationId":"<operationId>"}'`,
                      handler: (input: unknown) =>
                        airDropResult(() =>
                          airdropSender.cancel(
                            (input as { operationId: string }).operationId
                          )
                        ),
                    },
                  ]
                : []),
              {
                id: "files",
                description:
                  "List completed local files for the returned receiverId. Use nextCursor as after. Recent metadata is bounded to 200 entries. truncated means older files must be listed from directory on this same device. Local save does not prove sender acknowledgement.",
                input: z
                  .object({
                    receiverId: z.string().uuid(),
                    after: z.number().int().min(0).default(0),
                    limit: z.number().int().min(1).max(100).default(50),
                  })
                  .strict(),
                usage: `comma call airdrop files --json '{"receiverId":"<receiverId>","after":0}'`,
                handler: (input: unknown) => {
                  const args = input as {
                    receiverId: string;
                    after: number;
                    limit: number;
                  };
                  return airdrop.files(args.receiverId, args.after, args.limit);
                },
              },
            ],
          },
        ]
      : []),
    ...(deviceAccess
      ? [
          {
            id: "devices",
            description: "Manage access through the local Connector owner.",
            apis: [
              {
                id: "set-access",
                description: "Set access for a locally supervised workspace Connector.",
                input: z
                  .object({
                    workspaceId: z.string().min(1).max(256),
                    allow_operations: z.boolean(),
                  })
                  .strict(),
                usage:
                  'comma call devices set-access --json \'{"workspaceId":"...","allow_operations":false}\'',
                handler: (input: unknown) => {
                  const value = input as {
                    workspaceId: string;
                    allow_operations: boolean;
                  };
                  return deviceAccess(value.workspaceId, value.allow_operations);
                },
              },
            ],
          },
        ]
      : []),
    {
      apis: [
        {
          description: "Read Main's current global application preferences.",
          handler: async () => {
            const { clientSettings: _clientSettings, ...globalSettings } =
              await appPreferences.state();
            return globalSettings;
          },
          id: "get",
          input: emptyInputSchema,
          usage: `comma call global-settings get`,
        },
        {
          description: "Update one or more Main-owned global application preferences.",
          handler: (input) =>
            appPreferences.update(input as z.output<typeof appPreferencesPatchSchema>),
          id: "update",
          input: globalSettingsPatchSchema,
          usage: `comma call global-settings update --json '{"showInDock":false}'`,
        },
      ],
      description:
        "Read or update Comma's global desktop settings through Electron Main.",
      id: "global-settings",
    },
    {
      apis: [
        {
          description:
            "Read Main's current language, appearance, Side Chat, and application shortcut settings.",
          handler: async () =>
            (await appPreferences.state()).clientSettings ??
            structuredClone(defaultCommaClientSettings),
          id: "get",
          input: emptyInputSchema,
          usage: `comma call client-settings get`,
        },
        {
          description:
            "Update language, appearance, Side Chat preferences, or the complete application shortcut override map.",
          handler: async (input) =>
            (
              await appPreferences.update({
                clientSettings: input as z.output<
                  typeof commaClientSettingsPatchSchema
                >,
              })
            ).clientSettings ?? structuredClone(defaultCommaClientSettings),
          id: "update",
          input: commaClientSettingsPatchSchema,
          usage: `comma call client-settings update --json '{"appearance":{"theme":"dark"}}'`,
        },
      ],
      description:
        "Read or update Comma's Main-owned language, appearance, Side Chat, and application shortcuts.",
      id: "client-settings",
    },
    {
      apis: [
        {
          description:
            "Open a real Comma in-app browser tab and return its stable tab id once its native page is ready.",
          handler: async (input) => ({
            target: await browser.openClientTab(
              input as z.output<typeof browserOpenTabInputSchema>
            ),
          }),
          id: "open-tab",
          input: browserOpenTabInputSchema,
          usage: `comma call in-app-browser open-tab --json '{"url":"https://example.com/"}'`,
        },
        {
          description: "List live in-app browser tabs and their stable tab ids.",
          handler: () => ({ targets: browser.listClientTargets() }),
          id: "list-targets",
          input: emptyInputSchema,
          usage: `comma call in-app-browser list-targets`,
        },
        {
          description: "Send one bounded CDP command to the exact requested tab id.",
          handler: async (input) => ({
            result: await browser.sendClientCdpCommand(
              input as z.output<typeof cdpInputSchema>
            ),
          }),
          id: "send-cdp-command",
          input: cdpInputSchema,
          usage: `comma call in-app-browser send-cdp-command --json '{"tabId":"...","method":"Runtime.evaluate","params":{"expression":"document.title"}}'`,
        },
        {
          description:
            "Capture the exact requested tab's WebContentsView into a unique bounded local PNG artifact.",
          handler: async (input) =>
            writeScreenshot(
              await browser.captureClientScreenshot(
                input as z.output<typeof browserTabInputSchema>
              )
            ),
          id: "capture-screenshot",
          input: browserTabInputSchema,
          usage: `comma call in-app-browser capture-screenshot --json '{"tabId":"..."}'`,
        },
      ],
      description:
        "Open, inspect, and control Comma's retained in-app browser tabs by stable tab id.",
      id: "in-app-browser",
    },
  ]);
}

class ClientControlError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message);
  }
}

// Preserve actionable local errors for the comma CLI, which hides HTTP error bodies.
async function airDropResult(operation: () => unknown) {
  try {
    return await operation();
  } catch (error) {
    return {
      status: "failed",
      error: error instanceof Error ? error.message : "AirDrop could not start.",
    };
  }
}

export class ClientControlApiServer {
  readonly endpoint: string;
  readonly #server: ReturnType<typeof createServer>;
  #closePromise: Promise<void> | undefined;

  private constructor(server: ReturnType<typeof createServer>, endpoint: string) {
    this.#server = server;
    this.endpoint = endpoint;
  }

  static async open({
    registry,
    token,
  }: {
    registry: CommaClientControlRegistry;
    token: string;
  }) {
    if (!token) throw new Error("Client-control bearer is required.");
    const server = createServer((request, response) => {
      void handleRequest(request, response, registry, token);
    });
    server.headersTimeout = 5_000;
    server.keepAliveTimeout = 1_000;
    server.requestTimeout = 10_000;
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => {
        server.off("error", reject);
        resolve();
      });
    });
    const address = server.address();
    if (!address || typeof address === "string") {
      server.close();
      throw new Error("Client-control server did not bind a TCP address.");
    }
    return new ClientControlApiServer(server, `http://127.0.0.1:${address.port}`);
  }

  async close() {
    this.#closePromise ??= new Promise<void>((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        clearTimeout(forceClose);
        resolve();
      };
      const forceClose = setTimeout(() => {
        this.#server.closeAllConnections();
        finish();
      }, CLIENT_CONTROL_CLOSE_TIMEOUT_MS);
      this.#server.close(() => finish());
      this.#server.closeIdleConnections();
    });
    await this.#closePromise;
  }
}

async function handleRequest(
  request: IncomingMessage,
  response: ServerResponse,
  registry: CommaClientControlRegistry,
  token: string
) {
  try {
    if (request.socket.remoteAddress !== "127.0.0.1") {
      throw new ClientControlError(403, "Loopback access required.");
    }
    if (!validBearer(request.headers.authorization, token)) {
      throw new ClientControlError(401, "Unauthorized.");
    }
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    let result: unknown;
    if (request.method === "GET" && url.pathname === "/v1/modules") {
      result = registry.list();
    } else if (request.method === "GET" && url.pathname.startsWith("/v1/modules/")) {
      result = registry.describe(
        decodeURIComponent(url.pathname.slice("/v1/modules/".length))
      );
    } else if (request.method === "POST" && url.pathname === "/v1/invoke") {
      result = await registry.invoke(
        JSON.parse((await readBody(request)).toString("utf8"))
      );
    } else {
      throw new ClientControlError(404, "Not found.");
    }
    writeJson(response, 200, result);
  } catch (error) {
    if (error instanceof ClientControlError) {
      writeJson(response, error.status, { error: error.message });
    } else if (error instanceof SyntaxError) {
      writeJson(response, 400, { error: "Invalid JSON body." });
    } else {
      writeJson(response, 500, { error: "Client-control request failed." });
    }
  }
}

function validBearer(header: string | undefined, token: string) {
  const presented = header?.startsWith("Bearer ") ? header.slice(7) : "";
  const left = Buffer.from(presented);
  const right = Buffer.from(token);
  return left.length === right.length && timingSafeEqual(left, right);
}

async function readBody(request: IncomingMessage) {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > MAX_REQUEST_BYTES) {
      throw new ClientControlError(413, "Request body exceeds limit.");
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

function writeJson(response: ServerResponse, status: number, value: unknown) {
  let body = Buffer.from(JSON.stringify(value));
  if (body.byteLength > MAX_RESPONSE_BYTES) {
    status = 413;
    body = Buffer.from(JSON.stringify({ error: "Response exceeds limit." }));
  }
  response.statusCode = status;
  response.setHeader("content-type", "application/json; charset=utf-8");
  response.setHeader("content-length", String(body.byteLength));
  response.setHeader("cache-control", "no-store");
  response.end(body);
}
