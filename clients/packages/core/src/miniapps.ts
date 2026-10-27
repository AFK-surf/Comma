// Mini Apps: a Workspace's apps (the Apps list, an app's settings, its link and grants), and the broker every opened
// app's frame calls through.
//
// The host opens an app (`miniApps.session.open`) and gets a session id bound to the app, its Version, the access
// path and the window that opened it. Every effect the frame asks for is one `miniApps.invoke` with that session: the
// app's identity comes from the session, never from the frame. The broker allows only ops of the manifest's
// capabilities that this platform and viewer can use, applies the guest rules, the viewer's grants (Once: kept on the
// Install or the app; Each time: a confirm in host UI; None) and a per-app rate limit on this device, then maps the op
// to the app's own server routes, this device's storage, or an existing core call. What only the host can do (put
// text in the composer, the clipboard, a notification, a file picker, an outside link) is answered `host`: the core
// allowed it and the host does it.
//
// Bounds: one read per list or app shown (and per refresh); one request per call. At most 8 open sessions per window
// and 64 in all (the oldest goes first); 60 invocations a minute per app on this device, 5 of them notifications.
// Device storage: 1 MiB per app (32 KiB per value), for at most 128 apps per account (the least recently written
// go first). Bundles kept in memory by digest: at most 8, 64 MiB in all.
import {
  CoreError,
  fromUtf8,
  topicKey,
  utf8,
  type ClientId,
  type Topic,
  type Value,
} from "@comma/core-kernel";
import { Effect, Result } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route, type Method } from "./api.ts";
import {
  miniAppChatSchema,
  miniAppDecisionRequestSchema,
  miniAppDecisionResultSchema,
  miniAppDetailSchema,
  miniAppDocPageSchema,
  miniAppDocSchema,
  miniAppLinkReadSchema,
  miniAppLinkResolveSchema,
  miniAppLinkSchema,
  miniAppListSchema,
  miniAppOpenSchema,
  miniAppRemixSchema,
  miniAppSchema,
  miniAppSecretsSchema,
  miniAppSearchSchema,
} from "./comma/schemas.ts";
import type {
  MiniApp,
  MiniAppBundle,
  MiniAppErrorCode,
  MiniAppImageValue,
  MiniAppInvokeResult,
  MiniAppLink,
  MiniAppPlatform,
  MiniAppSessionInfo,
  MiniAppsValue,
  MiniAppValue,
  MiniAppVia,
  MiniAppVisibility,
} from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import { base64 } from "./record.ts";
import type { QuickChat } from "./quick-chat.ts";

type Scope = "app" | "user" | "device";
type Grant = "once" | "each" | "none";

/** Each capability: its ops and its grant (design §7.4). */
export const MINI_APP_CAPABILITIES: Record<string, { grant: Grant; ops: string[] }> = {
  "identity.basic": { grant: "once", ops: ["viewer"] },
  "ai.chat": { grant: "once", ops: ["ai.chat", "ai.decide"] },
  "web.search": { grant: "once", ops: ["web.search"] },
  "chat.draft": { grant: "none", ops: ["chat.draft"] },
  "tasks.create": { grant: "each", ops: ["tasks.propose"] },
  "files.pick": { grant: "each", ops: ["files.pick"] },
  "drive.app_folder": {
    grant: "once",
    ops: ["drive.list", "drive.read", "drive.write", "drive.delete"],
  },
  "calendar.read": { grant: "once", ops: ["calendar.events"] },
  notifications: { grant: "once", ops: ["notify"] },
  "clipboard.write": { grant: "none", ops: ["clipboard.write"] },
  "links.open": { grant: "each", ops: ["links.open"] },
};

const capabilityOf = new Map(
  Object.entries(MINI_APP_CAPABILITIES).flatMap(([cap, { ops }]) =>
    ops.map((op) => [op, cap] as const)
  )
);

/**
 * Whether this platform and viewer can use `capability` at all. The Mac apps Calendar is on Mac only. A guest
 * Workspace has no Task agent and no Drive; the app's Drive folder is its Workspace's, so a viewer who opened it only
 * through a link has none either.
 */
export function miniAppCapabilitySupported(
  capability: string,
  platform: MiniAppPlatform,
  guest: boolean,
  linkOnly = false
): boolean {
  if (!(capability in MINI_APP_CAPABILITIES)) return false;
  if (capability === "calendar.read") return platform === "mac" && !guest;
  if (capability === "drive.app_folder") return !guest && !linkOnly;
  if (guest && capability === "tasks.create") return false;
  return true;
}

const KEY = /^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,255}$/;
const RATE_PER_MINUTE = 60;
const NOTIFY_PER_MINUTE = 5;
const MAX_SESSIONS_PER_CLIENT = 8;
const MAX_SESSIONS = 64;
export const MINI_APP_DEVICE_MAX_BYTES = 1_048_576;
export const MINI_APP_DEVICE_VALUE_MAX_BYTES = 32_768;
const DEVICE_MAX_APPS = 128;
const DEVICE_INDEX = "miniAppDevice";
const BUNDLE_CACHE_ENTRIES = 8;
const BUNDLE_CACHE_BYTES = 64 * 1_048_576;
const BACKEND_MAX_BODY = 1_048_576;
const BUNDLE_TIMEOUT_MS = 60_000;
const ICON_CACHE_ENTRIES = 64;
/** At most 160 KiB each (the server's limit), so the kept covers stay under about 10 MB. */
const COVER_CACHE_ENTRIES = 48;
/** The only paths an app's `icon_url` and `cover_url` name (CommaCore.MiniApps): a read of anything else is refused. */
const ICON_PATH = /^\/v1\/comma\/apps\/[A-Za-z0-9_-]{1,128}\/icon\?v=[1-9][0-9]{0,9}$/;
const COVER_PATH =
  /^\/v1\/comma\/apps\/[A-Za-z0-9_-]{1,128}\/cover\?v=[1-9][0-9]{0,9}$/;

type ImageRead = { kind: "icon" | "cover"; url: string; via: MiniAppVia };

/** A `miniAppImage` topic's image: an icon or cover URL, reached through exactly one access path; null otherwise. */
function imageRead(topic: Topic): ImageRead | null {
  const url = String(topic.url ?? "");
  const workspace = String(topic.workspace ?? "");
  const link = String(topic.link ?? "");
  const kind = ICON_PATH.test(url) ? "icon" : COVER_PATH.test(url) ? "cover" : null;
  if (
    !kind ||
    (workspace === "") === (link === "") ||
    workspace.length > 256 ||
    link.length > 512
  )
    return null;
  return { kind, url, via: workspace ? { workspace } : { token: link } };
}
export const MINI_APP_DRIVE_MAX_BYTES = 20 * 1_048_576;
const DRIVE_TIMEOUT_MS = 120_000;
const CALENDAR_MAX_RANGE_MS = 366 * 86_400_000;

const driveListSchema = z
  .object({
    data: z
      .array(
        z
          .object({
            name: z.string().max(1_024),
            kind: z.enum(["file", "dir"]),
            size: z.number().int().nonnegative().nullish(),
            updated_at: z.string().max(64).nullish(),
          })
          .strip()
      )
      .max(10_000),
  })
  .strip();

type Session = {
  id: string;
  client: ClientId;
  accountKey: string;
  app: MiniApp;
  version: number;
  digest: string;
  via: MiniAppVia;
  /** The Version a Task's card previews (`x-comma-app-version` on every runtime request); the server's choice where not given. */
  pinned: number | undefined;
  platform: MiniAppPlatform;
  guest: boolean;
  viewer: MiniAppSessionInfo["viewer"];
  grants: Set<string>;
  storage: Scope[];
  paused: boolean;
};

type DeviceStore = {
  entries: Record<string, { value: unknown; version: number }>;
  bytes: number;
};

const viaSchema = z.union([
  z.object({ workspace: z.string().min(1).max(256) }).strict(),
  z.object({ token: z.string().min(1).max(512) }).strict(),
]);

/** A call's `via`: the access path the app is reached by. */
const viaParam = (raw: unknown): MiniAppVia => {
  const parsed = viaSchema.safeParse((raw as { via?: unknown } | null)?.via);
  if (!parsed.success) throw CoreError.invalid("via is {workspace} or {token}");
  return parsed.data;
};

const requiredString = (raw: unknown, name: string, max = 256): string => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > max)
    throw CoreError.invalid(`${name} is required`);
  return v;
};
const optionalString = (
  raw: unknown,
  name: string,
  max: number
): string | undefined => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (v === undefined) return undefined;
  if (typeof v !== "string" || v.length > max)
    throw CoreError.invalid(`${name} is a string`);
  return v;
};
const positiveInt = (raw: unknown, name: string): number => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "number" || !Number.isSafeInteger(v) || v <= 0)
    throw CoreError.invalid(`${name} is a positive integer`);
  return v;
};
const visibilityOf = (raw: unknown): MiniAppVisibility | undefined => {
  const v = (raw as Record<string, unknown> | null)?.visibility;
  if (v === undefined) return undefined;
  if (v !== "private" && v !== "workspace" && v !== "link")
    throw CoreError.invalid("visibility is private, workspace or link");
  return v;
};

const appsPath = (workspace: string) => route`/v1/comma/workspaces/${workspace}/apps`;
const appPath = (workspace: string, app: string) =>
  route`/v1/comma/workspaces/${workspace}/apps/${app}`;
const runtimePath = (app: string) => route`/v1/comma/apps/${app}`;

/** The app's error for a refusal the server or the core answered. */
export function miniAppErrorCode(error: CoreError): MiniAppErrorCode {
  switch (error.code) {
    case "app_paused":
    case "not_granted":
    case "signup_required":
    case "rate_limited":
    case "not_found":
    case "quota_exceeded":
    case "unsupported":
    case "denied":
      return error.code;
    case "version_conflict":
    case "conflict":
      return "conflict";
    case "temporarily_unavailable":
    case "network":
    case "timeout":
    case "unavailable":
      return "unavailable";
    case "invalid":
    case "invalid_params":
      return "invalid";
    default:
      if (error.status === 404) return "not_found";
      if (error.status === 400 || error.status === 422) return "invalid";
      return "failed";
  }
}

const fail = (code: MiniAppErrorCode, message: string): MiniAppInvokeResult => ({
  status: "error",
  code,
  message,
});

const MIME: Record<string, string> = {
  html: "text/html",
  htm: "text/html",
  js: "text/javascript",
  mjs: "text/javascript",
  css: "text/css",
  json: "application/json",
  map: "application/json",
  svg: "image/svg+xml",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  avif: "image/avif",
  ico: "image/x-icon",
  woff: "font/woff",
  woff2: "font/woff2",
  ttf: "font/ttf",
  otf: "font/otf",
  txt: "text/plain",
  md: "text/markdown",
  wasm: "application/wasm",
  mp3: "audio/mpeg",
  wav: "audio/wav",
  ogg: "audio/ogg",
  mp4: "video/mp4",
  webm: "video/webm",
};

export function miniAppMime(path: string): string {
  const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  return MIME[ext] ?? "application/octet-stream";
}

/**
 * The regular files of an uncompressed ustar archive (the bundle format), by their paths relative to `dist/`. A path
 * that leaves the archive (absolute, `..`) or anything that is not a regular file is skipped.
 */
export function untarMiniAppBundle(tar: Uint8Array): MiniAppBundle["files"] {
  const files: MiniAppBundle["files"] = [];
  const text = (from: number, length: number) => {
    let end = from;
    while (end < from + length && tar[end] !== 0) end++;
    return fromUtf8(tar.subarray(from, end));
  };
  let at = 0;
  while (at + 512 <= tar.length) {
    if (tar.subarray(at, at + 512).every((b) => b === 0)) break;
    const name = text(at, 100);
    const size = Number.parseInt(text(at + 124, 12).trim() || "0", 8);
    const type = tar[at + 156];
    const magic = text(at + 257, 6);
    const prefix = magic.startsWith("ustar") ? text(at + 345, 155) : "";
    if (!Number.isFinite(size) || size < 0)
      throw new CoreError("invalid", "bad bundle");
    const start = at + 512;
    if (start + size > tar.length) throw new CoreError("invalid", "bad bundle");
    const path = (prefix ? `${prefix}/${name}` : name).replace(/^\.\//, "");
    if (
      (type === 0x30 || type === 0) &&
      path &&
      !path.startsWith("/") &&
      !path.split("/").includes("..")
    )
      files.push({
        path,
        mime: miniAppMime(path),
        data: tar.slice(start, start + size),
      });
    at = start + Math.ceil(size / 512) * 512;
  }
  return files;
}

/** The bytes a bundle's files hold. */
function bundleSize(files: MiniAppBundle["files"]): number {
  return files.reduce((n, file) => n + file.data.length, 0);
}

/** JSON text of a stored value, or undefined when the value is no JSON. */
function jsonText(value: unknown): string | undefined {
  try {
    const text = JSON.stringify(value);
    return typeof text === "string" ? text : undefined;
  } catch {
    return undefined;
  }
}

function record(args: unknown): Record<string, unknown> {
  return args && typeof args === "object" && !Array.isArray(args)
    ? (args as Record<string, unknown>)
    : {};
}

export class MiniApps {
  readonly #ctx: Ctx;
  readonly #quickChat: QuickChat;
  readonly #live: Live;
  readonly #lists = new Map<string, MiniAppsValue>();
  readonly #apps = new Map<string, MiniAppValue>();
  readonly #sessions = new Map<string, Session>();
  /** Grants a link viewer gave, kept while the core runs: a link without an Install has nowhere else to keep them. */
  readonly #linkGrants = new Map<string, Set<string>>();
  /** Invocation times per app on this device, the last minute's. */
  readonly #calls = new Map<string, number[]>();
  readonly #notifies = new Map<string, number[]>();
  readonly #bundles = new Map<string, MiniAppBundle["files"]>();
  /** Icons and covers read, as `data:` URLs (null: the app has none), by access path and URL. */
  readonly #icons = new Map<string, string | null>();
  readonly #covers = new Map<string, string | null>();
  /** The `miniAppImage` topics shown, by topic key. */
  readonly #images = new Map<string, MiniAppImageValue>();
  #accountKey: string | null = null;
  #nextSession = 0;

  constructor(ctx: Ctx, quickChat: QuickChat) {
    this.#ctx = ctx;
    this.#quickChat = quickChat;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("miniApps", {
      start: (topic) => {
        this.#lists.set(topicKey(topic), { status: "loading", apps: [], error: null });
        this.#live.run(topic, this.#readList(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#lists.delete(topicKey(topic));
      },
      compute: (topic): Value => ({
        ok: this.#lists.get(topicKey(topic)) ?? {
          status: "loading",
          apps: [],
          error: null,
        },
      }),
    });
    kernel.source("miniApp", {
      start: (topic) => {
        this.#apps.set(topicKey(topic), MiniApps.#loadingApp());
        this.#live.run(topic, this.#readApp(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#apps.delete(topicKey(topic));
      },
      compute: (topic): Value => ({
        ok: this.#apps.get(topicKey(topic)) ?? MiniApps.#loadingApp(),
      }),
    });
    kernel.source("miniAppImage", {
      start: (topic) => {
        const read = imageRead(topic);
        if (!read) return;
        this.#images.set(topicKey(topic), { status: "loading", src: null });
        this.#live.run(topic, this.#readImage(topic, read));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#images.delete(topicKey(topic));
      },
      compute: (topic): Value =>
        imageRead(topic)
          ? {
              ok: this.#images.get(topicKey(topic)) ?? {
                status: "loading",
                src: null,
              },
            }
          : { err: CoreError.invalid("url is not an app's icon or cover") },
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Another account: nothing opened for the last one runs on.
      this.#sessions.clear();
      this.#linkGrants.clear();
      this.#icons.clear();
      this.#covers.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic === "miniApps") {
          this.#live.stop(topic);
          this.#lists.set(topicKey(topic), {
            status: "loading",
            apps: [],
            error: null,
          });
          kernel.store.invalidate(topic);
          this.#live.run(topic, this.#readList(topic));
        } else if (topic.topic === "miniApp") {
          this.#live.stop(topic);
          this.#apps.set(topicKey(topic), MiniApps.#loadingApp());
          kernel.store.invalidate(topic);
          this.#live.run(topic, this.#readApp(topic));
        } else if (topic.topic === "miniAppImage") {
          const read = imageRead(topic);
          if (!read) continue;
          this.#live.stop(topic);
          this.#images.set(topicKey(topic), { status: "loading", src: null });
          kernel.store.invalidate(topic);
          this.#live.run(topic, this.#readImage(topic, read));
        }
      }
    });

    const ws = (p: unknown) => requiredString(p, "workspace");
    const id = (p: unknown) => requiredString(p, "app");
    kernel.calls({
      "miniApps.refresh": {
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            return Effect.forEach(
              this.#topics("miniApps").filter((t) => t.workspace === workspace),
              (topic) => this.#readList(topic)
            ).pipe(Effect.as(null));
          }),
      },
      "miniApp.refresh": {
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            return Effect.forEach(
              this.#topics("miniApp").filter(
                (t) => t.workspace === workspace && t.app === app
              ),
              (topic) => this.#readApp(topic)
            ).pipe(Effect.as(null));
          }),
      },
      "miniApps.create": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const name = requiredString(p, "name", 60);
            const description = optionalString(p, "description", 4000);
            const repo = (p as { repo?: unknown }).repo;
            const body: Record<string, unknown> = { name };
            if (description !== undefined) body.description = description;
            if (repo !== undefined) {
              const r = z
                .object({
                  owner: z.string().min(1).max(100),
                  name: z.string().min(1).max(100),
                })
                .strict()
                .safeParse(repo);
              if (!r.success) throw CoreError.invalid("repo is {owner, name}");
              body.repo = r.data;
            }
            return this.#appChange(workspace, "POST", appsPath(workspace), body);
          }),
      },
      "miniApps.update": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            const body: Record<string, unknown> = {};
            const name = optionalString(p, "name", 60);
            const description = optionalString(p, "description", 4000);
            const visibility = visibilityOf(p);
            if (name !== undefined) body.name = name;
            if (description !== undefined) body.description = description;
            if (visibility !== undefined) body.visibility = visibility;
            return this.#appChange(workspace, "PATCH", appPath(workspace, app), body);
          }),
      },
      "miniApps.delete": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            return this.#send("DELETE", appPath(workspace, app), z.unknown()).pipe(
              Effect.tap(() => Effect.sync(() => this.#gone(workspace, app))),
              Effect.as(null)
            );
          }),
      },
      "miniApps.publish": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            const visibility = visibilityOf(p);
            const body: Record<string, unknown> = {
              group_id: requiredString(p, "group"),
              conversation_id: requiredString(p, "conversation"),
              review_version: positiveInt(p, "reviewVersion"),
              version: positiveInt(p, "version"),
            };
            if (visibility !== undefined) body.visibility = visibility;
            return this.#appChange(
              workspace,
              "POST",
              `${appPath(workspace, app)}/publish`,
              body,
              true
            );
          }),
      },
      "miniApps.rollback": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            return this.#appChange(
              workspace,
              "POST",
              `${appPath(workspace, app)}/rollback`,
              { version: positiveInt(p, "version") },
              true
            );
          }),
      },
      "miniApps.disable": {
        doing: true,
        run: (p) =>
          Effect.suspend(() =>
            this.#appChange(ws(p), "POST", `${appPath(ws(p), id(p))}/disable`, {})
          ),
      },
      "miniApps.enable": {
        doing: true,
        run: (p) =>
          Effect.suspend(() =>
            this.#appChange(ws(p), "POST", `${appPath(ws(p), id(p))}/enable`, {})
          ),
      },
      "miniApps.link.publish": {
        doing: true,
        run: (p) => Effect.suspend(() => this.#linkChange(ws(p), id(p), "PUT", "")),
      },
      "miniApps.link.reset": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => this.#linkChange(ws(p), id(p), "POST", "/reset")),
      },
      "miniApps.link.revoke": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            return this.#send(
              "DELETE",
              `${appPath(workspace, app)}/link`,
              z.unknown()
            ).pipe(
              Effect.tap(() =>
                Effect.sync(() => this.#eachApp(workspace, app, (v) => (v.link = null)))
              ),
              Effect.as(null)
            );
          }),
      },
      "miniApps.grants.set": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            const grants = z
              .array(z.string().max(64))
              .max(32)
              .safeParse((p as { grants?: unknown }).grants);
            if (!grants.success) throw CoreError.invalid("grants is a list");
            return this.#appChange(
              workspace,
              "PUT",
              `${appPath(workspace, app)}/grants`,
              { grants: grants.data.filter((g) => g in MINI_APP_CAPABILITIES) }
            ).pipe(
              Effect.tap((changed) =>
                Effect.sync(() => {
                  // A revoke takes effect on what runs now.
                  for (const session of this.#sessions.values())
                    if (
                      session.app.id === app &&
                      "workspace" in session.via &&
                      session.via.workspace === workspace
                    )
                      session.grants = new Set(changed.grants);
                })
              )
            );
          }),
      },
      "miniApps.secret.set": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            const name = requiredString(p, "name", 64);
            if (!/^[A-Z][A-Z0-9_]{0,63}$/.test(name))
              throw CoreError.invalid("name is an upper-case secret name");
            const value = requiredString(p, "value", 8192);
            return this.#secretChange(workspace, app, "PUT", name, { value });
          }),
      },
      "miniApps.secret.delete": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            const name = requiredString(p, "name", 64);
            return this.#secretChange(workspace, app, "DELETE", name, undefined);
          }),
      },
      "miniApps.install": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const body: Record<string, unknown> = {
              token: requiredString(p, "token", 512),
            };
            if ((p as { pinnedVersion?: unknown }).pinnedVersion !== undefined)
              body.pinned_version = positiveInt(p, "pinnedVersion");
            return this.#appChange(
              workspace,
              "POST",
              `${appsPath(workspace)}/install`,
              body
            );
          }),
      },
      "miniApps.uninstall": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            const app = id(p);
            return this.#send(
              "DELETE",
              `${appPath(workspace, app)}/install`,
              z.unknown()
            ).pipe(
              Effect.tap(() => Effect.sync(() => this.#gone(workspace, app))),
              Effect.as(null)
            );
          }),
      },
      "miniApps.remix": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const workspace = ws(p);
            return this.#send(
              "POST",
              `${appsPath(workspace)}/remix`,
              miniAppRemixSchema,
              { token: requiredString(p, "token", 512) }
            ).pipe(
              Effect.tap((made) =>
                Effect.sync(() => this.#applyApp(workspace, made.app as MiniApp))
              ),
              Effect.map((made) => ({ app: made.app as MiniApp, task: made.task }))
            );
          }),
      },
      "miniApps.report": {
        doing: true,
        run: (p) =>
          Effect.suspend(() =>
            this.#send("POST", `${appPath(ws(p), id(p))}/report`, z.unknown(), {
              reason: requiredString(p, "reason", 2000),
            }).pipe(Effect.as(null))
          ),
      },
      "miniApps.link.resolve": {
        run: (p) =>
          Effect.suspend(() =>
            this.#send(
              "GET",
              route`/v1/comma/apps/links/${requiredString(p, "token", 512)}`,
              miniAppLinkResolveSchema
            ).pipe(Effect.map((r) => ({ app: r.app as MiniApp, version: r.version })))
          ),
      },
      "miniApps.session.open": {
        run: (p, call) => Effect.suspend(() => this.#open(p, call.client)),
      },
      "miniApps.session.close": {
        run: (p, call) =>
          Effect.sync(() => {
            const session = this.#sessions.get(requiredString(p, "session"));
            if (session?.client === call.client) this.#sessions.delete(session.id);
            return null;
          }),
      },
      "miniApps.bundle": {
        run: (p, call) =>
          Effect.suspend(() => this.#bundle(this.#session(p, call.client))),
      },
      "miniApps.invoke": {
        run: (p, call) =>
          Effect.suspend(() => {
            const session = this.#sessions.get(
              String((p as { session?: unknown } | null)?.session ?? "")
            );
            if (!session || session.client !== call.client)
              return Effect.succeed(fail("invalid", "The app is not open here."));
            const { op, args, confirmed } = (p ?? {}) as {
              op?: unknown;
              args?: unknown;
              confirmed?: unknown;
            };
            if (typeof op !== "string" || op.length > 64)
              return Effect.succeed(fail("invalid", "op is required"));
            return this.#invoke(session, op, args, confirmed === true);
          }),
      },
      "miniApps.grant": {
        doing: true,
        run: (p, call) =>
          Effect.suspend(() => {
            const session = this.#session(p, call.client);
            const capability = requiredString(p, "capability", 64);
            if (
              MINI_APP_CAPABILITIES[capability]?.grant !== "once" ||
              !session.app.capabilities.includes(capability)
            )
              throw CoreError.invalid("capability is not one the app asks for");
            return this.#grant(session, capability);
          }),
      },
    });
  }

  static #loadingApp(): MiniAppValue {
    return { status: "loading", app: null, versions: [], link: null, error: null };
  }

  #topics(name: "miniApps" | "miniApp"): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === name);
  }

  #send<S extends z.ZodType>(
    method: Method,
    path: string,
    schema: S,
    body?: unknown,
    headers: [string, string][] = []
  ): Effect.Effect<z.output<S>, CoreError> {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, schema, body, undefined, headers)
        )
      );
  }

  // --- The Apps list and an app's settings -------------------------------------------------------------------------

  #setList(topic: Topic, value: MiniAppsValue): void {
    if (!this.#lists.has(topicKey(topic))) return;
    this.#lists.set(topicKey(topic), value);
    this.#ctx.kernel.store.invalidate(topic);
  }

  #setApp(topic: Topic, value: MiniAppValue): void {
    if (!this.#apps.has(topicKey(topic))) return;
    this.#apps.set(topicKey(topic), value);
    this.#ctx.kernel.store.invalidate(topic);
  }

  #readList(topic: Topic): Effect.Effect<void> {
    const workspace = String(topic.workspace ?? "");
    return this.#send("GET", appsPath(workspace), miniAppListSchema).pipe(
      Effect.match({
        onSuccess: (page): MiniAppsValue => ({
          status: "ready",
          apps: page.data as MiniApp[],
          error: null,
        }),
        onFailure: (e): MiniAppsValue => ({
          status: "failed",
          apps: this.#lists.get(topicKey(topic))?.apps ?? [],
          error: e.message,
        }),
      }),
      Effect.tap((value) => Effect.sync(() => this.#setList(topic, value))),
      Effect.asVoid
    );
  }

  #readApp(topic: Topic): Effect.Effect<void> {
    const workspace = String(topic.workspace ?? "");
    const app = String(topic.app ?? "");
    return Effect.gen({ self: this }, function* () {
      const detail = yield* this.#send(
        "GET",
        appPath(workspace, app),
        miniAppDetailSchema
      ).pipe(Effect.result);
      if (Result.isFailure(detail)) {
        const e = detail.failure;
        this.#setApp(topic, {
          ...MiniApps.#loadingApp(),
          status: e.status === 404 ? "missing" : "failed",
          error: e.message,
        });
        return;
      }
      const { versions, ...rest } = detail.success;
      const shown = rest as MiniApp;
      // Only the owner's Workspace sees the link; any refusal here shows none.
      const link =
        shown.workspace_id === workspace
          ? yield* this.#send(
              "GET",
              `${appPath(workspace, app)}/link`,
              miniAppLinkReadSchema
            ).pipe(
              Effect.map((r): MiniAppLink | null => ("token" in r ? r : null)),
              Effect.orElseSucceed(() => null)
            )
          : null;
      this.#setApp(topic, {
        status: "ready",
        app: shown,
        versions,
        link,
        error: null,
      });
    });
  }

  /** A change the server answered with the app: every list and settings page of the Workspace shows it. */
  #appChange(
    workspace: string,
    method: Method,
    path: string,
    body: unknown,
    readVersions = false
  ): Effect.Effect<MiniApp, CoreError> {
    return this.#send(method, path, miniAppSchema, body).pipe(
      Effect.map((app) => app as MiniApp),
      Effect.tap((app) =>
        Effect.sync(() => {
          this.#applyApp(workspace, app);
          // A publish or rollback moves the live Version: the Versions are read again.
          if (readVersions)
            for (const topic of this.#topics("miniApp"))
              if (topic.workspace === workspace && topic.app === app.id)
                this.#live.run(topic, this.#readApp(topic));
        })
      )
    );
  }

  #applyApp(workspace: string, app: MiniApp): void {
    for (const topic of this.#topics("miniApps")) {
      if (topic.workspace !== workspace) continue;
      const shown = this.#lists.get(topicKey(topic));
      if (!shown) continue;
      const at = shown.apps.findIndex((a) => a.id === app.id);
      const apps =
        at >= 0 ? shown.apps.map((a, i) => (i === at ? app : a)) : [app, ...shown.apps];
      this.#setList(topic, { ...shown, apps });
    }
    this.#eachApp(workspace, app.id, (v) => {
      v.app = app;
      v.status = "ready";
    });
  }

  #eachApp(
    workspace: string,
    app: string,
    change: (value: MiniAppValue) => void
  ): void {
    for (const topic of this.#topics("miniApp")) {
      if (topic.workspace !== workspace || topic.app !== app) continue;
      const shown = this.#apps.get(topicKey(topic));
      if (!shown) continue;
      const next = { ...shown };
      change(next);
      this.#setApp(topic, next);
    }
  }

  /** The app left the Workspace (deleted or removed). */
  #gone(workspace: string, app: string): void {
    for (const topic of this.#topics("miniApps")) {
      if (topic.workspace !== workspace) continue;
      const shown = this.#lists.get(topicKey(topic));
      if (shown?.apps.some((a) => a.id === app))
        this.#setList(topic, {
          ...shown,
          apps: shown.apps.filter((a) => a.id !== app),
        });
    }
    this.#eachApp(workspace, app, (v) => {
      v.status = "missing";
      v.app = null;
      v.versions = [];
      v.link = null;
    });
  }

  #linkChange(
    workspace: string,
    app: string,
    method: "PUT" | "POST",
    suffix: string
  ): Effect.Effect<MiniAppLink, CoreError> {
    return this.#send(
      method,
      `${appPath(workspace, app)}/link${suffix}`,
      miniAppLinkSchema,
      method === "PUT" ? {} : undefined
    ).pipe(
      Effect.tap((link) =>
        Effect.sync(() => this.#eachApp(workspace, app, (v) => (v.link = link)))
      )
    );
  }

  #secretChange(
    workspace: string,
    app: string,
    method: "PUT" | "DELETE",
    name: string,
    body: unknown
  ): Effect.Effect<{ secrets: string[] }, CoreError> {
    return this.#send(
      method,
      `${appPath(workspace, app)}/secrets/${encodeURIComponent(name)}`,
      miniAppSecretsSchema,
      body
    ).pipe(
      Effect.tap(({ secrets }) =>
        Effect.sync(() => {
          for (const topic of this.#topics("miniApps")) {
            if (topic.workspace !== workspace) continue;
            const shown = this.#lists.get(topicKey(topic));
            if (!shown) continue;
            this.#setList(topic, {
              ...shown,
              apps: shown.apps.map((a) => (a.id === app ? { ...a, secrets } : a)),
            });
          }
          this.#eachApp(workspace, app, (v) => {
            if (v.app) v.app = { ...v.app, secrets };
          });
        })
      )
    );
  }

  // --- Opened apps -------------------------------------------------------------------------------------------------

  #session(p: unknown, client: ClientId): Session {
    const session = this.#sessions.get(requiredString(p, "session"));
    if (!session || session.client !== client)
      throw new CoreError("not_found", "The app is not open here.");
    return session;
  }

  /** The access path of a runtime request, and the Version it asks for when the host pinned one. */
  #viaHeader(via: MiniAppVia, pinned?: number): [string, string][] {
    return [
      [
        "x-comma-app-via",
        "workspace" in via ? `workspace/${via.workspace}` : `link/${via.token}`,
      ],
      ...(pinned === undefined
        ? []
        : [["x-comma-app-version", String(pinned)] as [string, string]]),
    ];
  }

  #open(p: unknown, client: ClientId): Effect.Effect<MiniAppSessionInfo, CoreError> {
    const app = requiredString(p, "app");
    const via = viaParam(p);
    const platform = (p as { platform?: unknown }).platform;
    if (platform !== "mac" && platform !== "web")
      throw CoreError.invalid("platform is mac or web");
    // A Task's card previews the Version its agent deployed; anything else opens what the server serves.
    const version =
      (p as { version?: unknown }).version === undefined
        ? undefined
        : positiveInt(p, "version");
    return Effect.gen({ self: this }, function* () {
      const opened = yield* this.#send(
        "POST",
        `${runtimePath(app)}/open`,
        miniAppOpenSchema,
        {},
        this.#viaHeader(via, version)
      );
      const accountKey = this.#ctx.session.accountKey() ?? "";
      const shown = opened.app as MiniApp;
      if (shown.id !== app)
        return yield* Effect.fail(new CoreError("not_found", "app"));
      const grants = new Set(
        shown.grants.filter((g) => shown.capabilities.includes(g))
      );
      if ("token" in via)
        for (const g of this.#linkGrants.get(`${accountKey}\u0000${app}`) ?? [])
          grants.add(g);
      const session: Session = {
        id: `mas-${++this.#nextSession}`,
        client,
        accountKey,
        app: shown,
        version: opened.version,
        digest: opened.digest,
        via,
        pinned: version,
        platform,
        guest: opened.guest,
        viewer: {
          id: opened.viewer.id,
          name: opened.guest ? "Guest" : opened.viewer.name,
          avatarUrl: opened.viewer.avatar_url ?? null,
          guest: opened.guest,
        },
        grants,
        storage: shown.storage,
        paused: false,
      };
      this.#keep(session);
      return this.#info(session);
    });
  }

  /** Keeps a session within the bounds: the window's oldest, then anyone's oldest, go first. */
  #keep(session: Session): void {
    const own = [...this.#sessions.values()].filter((s) => s.client === session.client);
    if (own.length >= MAX_SESSIONS_PER_CLIENT) this.#sessions.delete(own[0]!.id);
    if (this.#sessions.size >= MAX_SESSIONS)
      this.#sessions.delete(this.#sessions.keys().next().value!);
    this.#sessions.set(session.id, session);
  }

  #info(session: Session): MiniAppSessionInfo {
    return {
      session: session.id,
      app: session.app,
      version: session.version,
      digest: session.digest,
      guest: session.guest,
      viewer: session.viewer,
      capabilities: session.app.capabilities.filter((c) =>
        miniAppCapabilitySupported(
          c,
          session.platform,
          session.guest,
          "token" in session.via
        )
      ),
      grants: [...session.grants],
      storage: session.storage,
      backend: session.app.has_backend,
    };
  }

  #bundle(session: Session): Effect.Effect<MiniAppBundle, CoreError> {
    const cached = this.#bundles.get(session.digest);
    if (cached) {
      this.#bundles.delete(session.digest);
      this.#bundles.set(session.digest, cached);
      return Effect.succeed({ digest: session.digest, files: cached });
    }
    const path =
      "workspace" in session.via
        ? `${appPath(session.via.workspace, session.app.id)}/versions/${session.version}/bundle`
        : `${route`/v1/comma/apps/links/${session.via.token}`}/bundle`;
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.raw(account, "GET", path, {
          headers: [["accept", "application/x-tar"]],
          timeoutMs: BUNDLE_TIMEOUT_MS,
        })
      ),
      Effect.map((response) => {
        const files = untarMiniAppBundle(response.body);
        if (!files.some((f) => f.path === "index.html"))
          throw new CoreError("invalid", "The bundle has no index.html.");
        this.#cacheBundle(session.digest, files);
        return { digest: session.digest, files };
      })
    );
  }

  #cacheBundle(digest: string, files: MiniAppBundle["files"]): void {
    if (bundleSize(files) > BUNDLE_CACHE_BYTES) return;
    this.#bundles.set(digest, files);
    let total = [...this.#bundles.values()].reduce((n, f) => n + bundleSize(f), 0);
    while (this.#bundles.size > BUNDLE_CACHE_ENTRIES || total > BUNDLE_CACHE_BYTES) {
      const [oldest, gone] = this.#bundles.entries().next().value!;
      this.#bundles.delete(oldest);
      total -= bundleSize(gone);
    }
  }

  /** A shown `miniAppImage` topic's read: the image, or null when it could not be read (a later showing reads again). */
  #readImage(topic: Topic, read: ImageRead): Effect.Effect<void> {
    const kept = read.kind === "icon" ? this.#icons : this.#covers;
    const entries = read.kind === "icon" ? ICON_CACHE_ENTRIES : COVER_CACHE_ENTRIES;
    return this.#image(kept, entries, read.url, read.via).pipe(
      Effect.orElseSucceed(() => null),
      Effect.flatMap((src) =>
        Effect.sync(() => {
          if (!this.#images.has(topicKey(topic))) return;
          this.#images.set(topicKey(topic), { status: "ready", src });
          this.#ctx.kernel.store.invalidate(topic);
        })
      )
    );
  }

  /**
   * An app's icon or cover, read with the account's session and the access path, as an `<img>` cannot: the server
   * answers its `icon_url` and `cover_url` only to a signed-in viewer that names how it reaches the app. A URL names
   * one Version's image, so a read is kept for the account's session, the `entries` most recent in `cache`.
   */
  #image(
    cache: Map<string, string | null>,
    entries: number,
    url: string,
    via: MiniAppVia
  ): Effect.Effect<string | null, CoreError> {
    const key = `${this.#viaHeader(via)[0]![1]}\u0000${url}`;
    const cached = cache.get(key);
    if (cached !== undefined) {
      cache.delete(key);
      cache.set(key, cached);
      return Effect.succeed(cached);
    }
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.raw(account, "GET", url, { headers: this.#viaHeader(via) })
      ),
      Effect.map((response): string | null => {
        const type =
          response.headers
            .find(([name]) => name.toLowerCase() === "content-type")?.[1]
            .split(";")[0]!
            .trim()
            .toLowerCase() ?? "";
        return /^image\/[a-z0-9.+-]+$/.test(type) && response.body.length > 0
          ? `data:${type};base64,${base64(response.body)}`
          : null;
      }),
      // An app without an image to show here (removed, a Version not live) shows none.
      Effect.catchIf(
        (error) => error.status === 404,
        () => Effect.succeed(null)
      ),
      Effect.tap((image) =>
        Effect.sync(() => {
          cache.set(key, image);
          if (cache.size > entries) cache.delete(cache.keys().next().value!);
        })
      )
    );
  }

  #grant(
    session: Session,
    capability: string
  ): Effect.Effect<{ grants: string[] }, CoreError> {
    const next = [...new Set([...session.grants, capability])];
    const apply = (grants: string[]) => {
      for (const s of this.#sessions.values())
        if (s.app.id === session.app.id && s.accountKey === session.accountKey)
          s.grants = new Set(grants.filter((g) => s.app.capabilities.includes(g)));
      return { grants };
    };
    if ("token" in session.via) {
      // A link without an Install: the grant lasts while the core runs.
      const key = `${session.accountKey}\u0000${session.app.id}`;
      const kept = this.#linkGrants.get(key) ?? new Set<string>();
      kept.add(capability);
      this.#linkGrants.set(key, kept);
      return Effect.succeed(apply(next));
    }
    const workspace = session.via.workspace;
    return this.#appChange(
      workspace,
      "PUT",
      `${appPath(workspace, session.app.id)}/grants`,
      { grants: next }
    ).pipe(Effect.map((app) => apply(app.grants)));
  }

  /** Counts a call against the app's minute on this device: false past the bound. */
  #admit(bucket: Map<string, number[]>, app: string, limit: number): boolean {
    const now = this.#ctx.now();
    const recent = (bucket.get(app) ?? []).filter((t) => now - t < 60_000);
    if (recent.length >= limit) {
      bucket.set(app, recent);
      return false;
    }
    recent.push(now);
    bucket.set(app, recent);
    // Apps that went quiet leave the map.
    if (bucket.size > 256)
      for (const [key, times] of bucket)
        if (!times.some((t) => now - t < 60_000)) bucket.delete(key);
    return true;
  }

  #invoke(
    session: Session,
    op: string,
    args: unknown,
    confirmed: boolean
  ): Effect.Effect<MiniAppInvokeResult> {
    if (session.paused)
      return Effect.succeed(fail("app_paused", "This app is paused."));
    if (!this.#admit(this.#calls, session.app.id, RATE_PER_MINUTE))
      return Effect.succeed(fail("rate_limited", "Too many calls; wait a minute."));
    let work: Effect.Effect<MiniAppInvokeResult, CoreError>;
    try {
      work = this.#route(session, op, record(args), confirmed);
    } catch (e) {
      return Effect.succeed(
        e instanceof CoreError
          ? fail(miniAppErrorCode(e), e.message)
          : fail("failed", String(e))
      );
    }
    return work.pipe(
      Effect.catch((e: CoreError) =>
        Effect.sync(() => {
          const code = miniAppErrorCode(e);
          // The owner's Workspace is out of credit: every call of this app stops until it opens again.
          if (code === "app_paused")
            for (const s of this.#sessions.values())
              if (s.app.id === session.app.id) s.paused = true;
          return fail(code, e.message);
        })
      )
    );
  }

  #route(
    session: Session,
    op: string,
    args: Record<string, unknown>,
    confirmed: boolean
  ): Effect.Effect<MiniAppInvokeResult, CoreError> {
    const storage = /^storage\.(app|user|device)\.(get|put|delete|list)$/.exec(op);
    if (storage) {
      const scope = storage[1] as Scope;
      if (!session.storage.includes(scope))
        return Effect.succeed(
          fail("unsupported", `The app's manifest has no ${scope} storage.`)
        );
      return this.#storage(session, scope, storage[2]!, args);
    }
    if (op === "backend.fetch") {
      if (!session.app.has_backend)
        return Effect.succeed(fail("unsupported", "The app has no backend."));
      return this.#backend(session, args);
    }
    const capability = capabilityOf.get(op);
    if (!capability) return Effect.succeed(fail("unsupported", `${op} is not an op.`));
    if (!session.app.capabilities.includes(capability))
      return Effect.succeed(
        fail("not_granted", `The app's manifest does not ask for ${capability}.`)
      );
    if (
      !miniAppCapabilitySupported(
        capability,
        session.platform,
        session.guest,
        "token" in session.via
      )
    )
      return Effect.succeed(
        fail("unsupported", `${capability} is not available here.`)
      );
    if (session.guest && capability === "ai.chat")
      return Effect.succeed(fail("signup_required", "Sign up to use AI in apps."));
    if (session.guest && capability === "web.search")
      return Effect.succeed(
        fail("signup_required", "Sign up to search the web in apps.")
      );
    const grant = MINI_APP_CAPABILITIES[capability]!.grant;
    if (grant === "once" && !session.grants.has(capability))
      return Effect.succeed({ status: "grant", capability });
    const checked = this.#checkArgs(op, args);
    if (checked) return Effect.succeed(checked);
    if (grant === "each" && !confirmed)
      return Effect.succeed({ status: "confirm", capability, op, args });
    switch (op) {
      case "viewer":
        return Effect.succeed({ status: "done", value: session.viewer });
      case "ai.decide":
        return this.#runtime(
          session,
          "POST",
          "/ai/decide",
          miniAppDecisionResultSchema,
          args
        ).pipe(Effect.map((value) => ({ status: "done" as const, value })));
      case "web.search":
        return this.#runtime(session, "POST", "/web/search", miniAppSearchSchema, {
          query: (args.query as string).trim(),
        }).pipe(
          Effect.map(({ results }) => ({ status: "done" as const, value: results }))
        );
      case "ai.chat":
        return this.#runtime(session, "POST", "/ai/chat", miniAppChatSchema, {
          messages: args.messages,
        }).pipe(
          Effect.map(({ message }) => ({
            status: "done" as const,
            value: { role: "assistant", content: message.content },
          }))
        );
      case "tasks.propose":
        return this.#quickChat
          .send(
            this.#requestId(),
            String(args.text),
            "workspace" in session.via ? session.via.workspace : undefined
          )
          .pipe(Effect.as({ status: "done" as const, value: { created: true } }));
      case "drive.list":
      case "drive.read":
      case "drive.write":
      case "drive.delete":
        return this.#drive(session, op, args);
      case "notify":
        if (!this.#admit(this.#notifies, session.app.id, NOTIFY_PER_MINUTE))
          return Effect.succeed(fail("rate_limited", "Too many notifications."));
        return Effect.succeed({ status: "host", op, args });
      default:
        // chat.draft, clipboard.write, files.pick, links.open, calendar.events (Main's): the host's own effects.
        return Effect.succeed({ status: "host", op, args });
    }
  }

  /** Why an op's args cannot be used, or undefined when they can. */
  #checkArgs(
    op: string,
    args: Record<string, unknown>
  ): MiniAppInvokeResult | undefined {
    const text = (name: string, max: number) =>
      typeof args[name] === "string" && (args[name] as string).length <= max;
    switch (op) {
      case "ai.decide": {
        try {
          if (
            utf8(JSON.stringify(args)).length <= 12 * 1024 &&
            miniAppDecisionRequestSchema.safeParse(args).success
          )
            return undefined;
        } catch {
          /* A decision request must be JSON. */
        }
        return fail("invalid", "Use state and 1 to 8 typed questions within 12 KiB.");
      }
      case "web.search":
        return text("query", 2000) && (args.query as string).trim()
          ? undefined
          : fail("invalid", "query must contain 1 to 2,000 characters.");
      case "ai.chat": {
        const messages = z
          .array(
            z
              .object({
                role: z.enum(["user", "assistant", "system"]),
                content: z.string().max(100_000),
              })
              .strict()
          )
          .min(1)
          .max(100)
          .safeParse(args.messages);
        return messages.success ? undefined : fail("invalid", "messages is a list");
      }
      case "chat.draft":
      case "tasks.propose":
        return text("text", 4000) && (args.text as string).trim()
          ? undefined
          : fail("invalid", "text is required");
      case "clipboard.write":
        return text("text", 100_000) ? undefined : fail("invalid", "text is required");
      case "notify":
        return text("title", 200) && (args.body === undefined || text("body", 1000))
          ? undefined
          : fail("invalid", "title is required");
      case "links.open": {
        if (!text("url", 4000)) return fail("invalid", "url is required");
        try {
          const url = new URL(args.url as string);
          return url.protocol === "https:" && !url.username && !url.password
            ? undefined
            : fail("invalid", "Only https links open.");
        } catch {
          return fail("invalid", "url is not a URL");
        }
      }
      case "drive.list":
      case "drive.read":
      case "drive.write":
      case "drive.delete": {
        const path = args.path;
        if (
          typeof path !== "string" ||
          path.length > 1024 ||
          path.includes("\\") ||
          path.split("/").some((part) => part === ".." || part === ".") ||
          (op !== "drive.list" && !path.replace(/^\/+/, ""))
        )
          return fail("invalid", "path is a path inside the app's folder");
        if (op !== "drive.write") return undefined;
        const data = args.data;
        if (
          typeof data !== "string" &&
          !(data instanceof ArrayBuffer) &&
          !(data instanceof Uint8Array)
        )
          return fail("invalid", "data is text or bytes");
        return undefined;
      }
      case "calendar.events": {
        const from = typeof args.from === "string" ? Date.parse(args.from) : Number.NaN;
        const to = typeof args.to === "string" ? Date.parse(args.to) : Number.NaN;
        return Number.isFinite(from) &&
          Number.isFinite(to) &&
          to > from &&
          to - from <= CALENDAR_MAX_RANGE_MS
          ? undefined
          : fail("invalid", "from and to are ISO times at most 366 days apart");
      }
      case "files.pick": {
        const accept = args.accept;
        if (
          accept !== undefined &&
          !(
            Array.isArray(accept) &&
            accept.length <= 20 &&
            accept.every((a) => typeof a === "string" && a.length <= 100)
          )
        )
          return fail("invalid", "accept is a list of types");
        if (args.multiple !== undefined && typeof args.multiple !== "boolean")
          return fail("invalid", "multiple is true or false");
        return undefined;
      }
      default:
        return undefined;
    }
  }

  #requestId(): string {
    const bytes = new Uint8Array(16);
    this.#ctx.host.randomBytes(bytes);
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  /** A runtime route of the opened app, through its access path. */
  #runtime<S extends z.ZodType>(
    session: Session,
    method: Method,
    suffix: string,
    schema: S,
    body?: unknown
  ): Effect.Effect<z.output<S>, CoreError> {
    return this.#send(
      method,
      `${runtimePath(session.app.id)}${suffix}`,
      schema,
      body,
      this.#viaHeader(session.via, session.pinned)
    );
  }

  /** The app's own Drive folder (`Apps/<app name>/`), which the server confines it to. */
  #drive(
    session: Session,
    op: string,
    args: Record<string, unknown>
  ): Effect.Effect<MiniAppInvokeResult, CoreError> {
    const path = String(args.path).replace(/^\/+/, "");
    const query = `?${new URLSearchParams({ path })}`;
    const base = `${runtimePath(session.app.id)}/drive`;
    if (op === "drive.list")
      return this.#runtime(session, "GET", `/drive${query}`, driveListSchema).pipe(
        Effect.map((page) => ({
          status: "done" as const,
          value: page.data.map((entry) => ({
            name: entry.name,
            kind: entry.kind === "dir" ? ("folder" as const) : ("file" as const),
            size: entry.size ?? null,
            updatedAt: entry.updated_at ?? null,
          })),
        }))
      );
    if (op === "drive.delete")
      return this.#runtime(session, "DELETE", `/drive/file${query}`, z.unknown()).pipe(
        Effect.as({ status: "done" as const, value: null })
      );
    const ctx = this.#ctx;
    const headers = this.#viaHeader(session.via, session.pinned);
    if (op === "drive.read")
      return ctx.session.account().pipe(
        Effect.flatMap((account) =>
          ctx.api.raw(account, "GET", `${base}/file${query}`, {
            headers,
            timeoutMs: DRIVE_TIMEOUT_MS,
          })
        ),
        Effect.map((response) => ({
          status: "done" as const,
          value: {
            data: response.body,
            mime:
              response.headers.find(
                ([name]) => name.toLowerCase() === "content-type"
              )?.[1] ?? "application/octet-stream",
          },
        }))
      );
    const data = args.data;
    const body =
      typeof data === "string"
        ? utf8(data)
        : data instanceof Uint8Array
          ? data
          : new Uint8Array(data as ArrayBuffer);
    if (body.length > MINI_APP_DRIVE_MAX_BYTES)
      return Effect.succeed(fail("quota_exceeded", "A Drive file is at most 20 MiB."));
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.raw(account, "PUT", `${base}/file${query}`, {
          headers: [
            ...headers,
            [
              "content-type",
              typeof data === "string"
                ? "text/plain; charset=utf-8"
                : "application/octet-stream",
            ],
          ],
          body,
          timeoutMs: DRIVE_TIMEOUT_MS,
        })
      ),
      Effect.as({ status: "done" as const, value: null })
    );
  }

  #backend(
    session: Session,
    args: Record<string, unknown>
  ): Effect.Effect<MiniAppInvokeResult, CoreError> {
    const raw = args.path;
    if (typeof raw !== "string" || raw.length > 2048 || raw.includes("\\"))
      return Effect.succeed(fail("invalid", "path is required"));
    let target: URL;
    try {
      target = new URL(raw.replace(/^\/+/, ""), "https://app.invalid/");
    } catch {
      return Effect.succeed(fail("invalid", "path is not a path"));
    }
    if (target.host !== "app.invalid" || raw.split(/[/?#]/).includes(".."))
      return Effect.succeed(fail("invalid", "path stays inside the backend"));
    const method = typeof args.method === "string" ? args.method.toUpperCase() : "GET";
    if (!["GET", "POST", "PUT", "PATCH", "DELETE"].includes(method))
      return Effect.succeed(fail("invalid", "method is not one a backend takes"));
    const body =
      args.body === undefined || args.body === null
        ? new Uint8Array()
        : typeof args.body === "string"
          ? utf8(args.body)
          : args.body instanceof Uint8Array
            ? args.body
            : args.body instanceof ArrayBuffer
              ? new Uint8Array(args.body)
              : undefined;
    if (!body) return Effect.succeed(fail("invalid", "body is text or bytes"));
    if (body.length > BACKEND_MAX_BODY)
      return Effect.succeed(fail("invalid", "body is at most 1 MiB"));
    const headers: [string, string][] = [
      ...this.#viaHeader(session.via, session.pinned),
      ["x-comma-app-method", method],
    ];
    const type = Object.entries(record(args.headers)).find(
      ([name]) => name.toLowerCase() === "content-type"
    )?.[1];
    if (typeof type === "string" && type.length <= 256)
      headers.push(["content-type", type]);
    const path = `${runtimePath(session.app.id)}/backend${target.pathname}${target.search}`;
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account: Account) =>
        ctx.api.raw(account, "POST", path, { headers, body, anyStatus: true })
      ),
      Effect.flatMap((response) => {
        const contentType = response.headers.find(
          ([name]) => name.toLowerCase() === "content-type"
        )?.[1];
        // Comma's own refusals; any other answer is the backend's.
        if ([402, 403, 429, 503].includes(response.status)) {
          let code: unknown;
          try {
            code = (JSON.parse(fromUtf8(response.body)) as { error?: unknown }).error;
          } catch {
            code = undefined;
          }
          if (
            (response.status === 402 && code === "app_paused") ||
            (response.status === 403 &&
              (code === "not_granted" || code === "signup_required")) ||
            (response.status === 429 && code === "rate_limited") ||
            (response.status === 503 && code === "temporarily_unavailable")
          )
            return Effect.fail(
              new CoreError(
                String(code),
                `The backend answered ${response.status}`,
                response.status
              )
            );
        }
        return Effect.succeed<MiniAppInvokeResult>({
          status: "done",
          value: {
            status: response.status,
            headers: contentType ? { "content-type": contentType } : {},
            body: response.body,
          },
        });
      })
    );
  }

  #storage(
    session: Session,
    scope: Scope,
    action: string,
    args: Record<string, unknown>
  ): Effect.Effect<MiniAppInvokeResult, CoreError> {
    const key = args.key;
    if (action !== "list" && (typeof key !== "string" || !KEY.test(key)))
      return Effect.succeed(fail("invalid", "key is 1–256 letters, digits and ._/-"));
    if (action === "list") {
      const prefix = args.prefix;
      const after = args.after;
      const limit = args.limit ?? 100;
      if (
        (prefix !== undefined && (typeof prefix !== "string" || prefix.length > 256)) ||
        (after !== undefined && (typeof after !== "string" || after.length > 256)) ||
        typeof limit !== "number" ||
        !Number.isInteger(limit) ||
        limit < 1 ||
        limit > 1000
      )
        return Effect.succeed(fail("invalid", "list takes prefix, after and limit"));
      if (scope === "device")
        return Effect.sync(() =>
          this.#deviceList(
            session,
            prefix as string | undefined,
            after as string | undefined,
            limit
          )
        );
      const query = new URLSearchParams();
      if (prefix) query.set("prefix", prefix as string);
      if (after) query.set("after", after as string);
      query.set("limit", String(limit));
      return this.#runtime(
        session,
        "GET",
        `/storage/${scope}?${query}`,
        miniAppDocPageSchema
      ).pipe(
        Effect.map((page) => ({
          status: "done" as const,
          value: {
            items: page.data.map((d) => ({
              key: d.key,
              value: d.value,
              version: d.version,
            })),
            hasMore: page.has_more,
          },
        }))
      );
    }
    const k = key as string;
    if (action === "put") {
      const text = jsonText(args.value);
      if (text === undefined) return Effect.succeed(fail("invalid", "value is JSON"));
      const ifVersion = args.ifVersion;
      if (
        ifVersion !== undefined &&
        (typeof ifVersion !== "number" || !Number.isInteger(ifVersion))
      )
        return Effect.succeed(fail("invalid", "ifVersion is a version"));
      if (scope === "device")
        return Effect.sync(() =>
          this.#devicePut(session, k, text, ifVersion as number | undefined)
        );
      return this.#runtime(
        session,
        "PUT",
        `/storage/${scope}/${encodeURIComponent(k)}`,
        miniAppDocSchema,
        {
          value: JSON.parse(text),
          ...(ifVersion !== undefined ? { if_version: ifVersion } : {}),
        }
      ).pipe(
        Effect.map((doc) => ({
          status: "done" as const,
          value: { version: doc.version },
        }))
      );
    }
    if (action === "get") {
      if (scope === "device")
        return Effect.sync(() => {
          const entry = this.#deviceStore(session).entries[k];
          return {
            status: "done" as const,
            value: entry ? { value: entry.value, version: entry.version } : null,
          };
        });
      return this.#runtime(
        session,
        "GET",
        `/storage/${scope}/${encodeURIComponent(k)}`,
        miniAppDocSchema
      ).pipe(
        Effect.map(
          (doc): MiniAppInvokeResult => ({
            status: "done",
            value: { value: doc.value, version: doc.version },
          })
        ),
        Effect.catchIf(
          (e: CoreError) => e.status === 404 && e.code === "not_found",
          () => Effect.succeed<MiniAppInvokeResult>({ status: "done", value: null })
        )
      );
    }
    if (scope === "device") return Effect.sync(() => this.#deviceDelete(session, k));
    return this.#runtime(
      session,
      "DELETE",
      `/storage/${scope}/${encodeURIComponent(k)}`,
      z.unknown()
    ).pipe(Effect.as({ status: "done" as const, value: null }));
  }

  // --- Device storage ------------------------------------------------------------------------------------------------

  #deviceDoc(session: Session): string {
    const where = "workspace" in session.via ? session.via.workspace : "link";
    return `miniAppDevice:${JSON.stringify([where, session.app.id])}`;
  }

  #deviceStore(session: Session): DeviceStore {
    const account = this.#ctx.session.current();
    return (
      account?.doc<DeviceStore>(this.#deviceDoc(session))?.value ?? {
        entries: {},
        bytes: 0,
      }
    );
  }

  #deviceSave(session: Session, store: DeviceStore): boolean {
    const account = this.#ctx.session.current();
    if (!account || this.#ctx.session.accountKey() !== session.accountKey) return false;
    const now = this.#ctx.now();
    const name = this.#deviceDoc(session);
    if (!account.putDoc(name, store, now)) return false;
    // The stores in the order they were last written: the first is the next to go.
    const order = (account.doc<string[]>(DEVICE_INDEX)?.value ?? []).filter(
      (n) => n !== name
    );
    order.push(name);
    for (const gone of order.splice(0, Math.max(0, order.length - DEVICE_MAX_APPS)))
      account.deleteDoc(gone);
    account.putDoc(DEVICE_INDEX, order, now);
    return true;
  }

  #devicePut(
    session: Session,
    key: string,
    text: string,
    ifVersion: number | undefined
  ): MiniAppInvokeResult {
    const size = utf8(text).length;
    if (size > MINI_APP_DEVICE_VALUE_MAX_BYTES)
      return fail("quota_exceeded", "A device value is at most 32 KiB.");
    const store = this.#deviceStore(session);
    const was = store.entries[key];
    if (ifVersion !== undefined && (was?.version ?? 0) !== ifVersion)
      return fail("conflict", "The value changed since it was read.");
    const wasSize = was ? utf8(key).length + utf8(JSON.stringify(was.value)).length : 0;
    const bytes = store.bytes - wasSize + utf8(key).length + size;
    if (bytes > MINI_APP_DEVICE_MAX_BYTES)
      return fail("quota_exceeded", "Device storage is at most 1 MiB per app.");
    const version = (was?.version ?? 0) + 1;
    const next: DeviceStore = {
      entries: { ...store.entries, [key]: { value: JSON.parse(text), version } },
      bytes,
    };
    if (!this.#deviceSave(session, next)) return fail("unavailable", "Signed out.");
    return { status: "done", value: { version } };
  }

  #deviceDelete(session: Session, key: string): MiniAppInvokeResult {
    const store = this.#deviceStore(session);
    const was = store.entries[key];
    if (!was) return { status: "done", value: null };
    const { [key]: _gone, ...entries } = store.entries;
    const bytes =
      store.bytes - utf8(key).length - utf8(JSON.stringify(was.value)).length;
    if (!this.#deviceSave(session, { entries, bytes }))
      return fail("unavailable", "Signed out.");
    return { status: "done", value: null };
  }

  #deviceList(
    session: Session,
    prefix: string | undefined,
    after: string | undefined,
    limit: number
  ): MiniAppInvokeResult {
    const store = this.#deviceStore(session);
    const keys = Object.keys(store.entries)
      .filter((k) => (!prefix || k.startsWith(prefix)) && (!after || k > after))
      .toSorted();
    return {
      status: "done",
      value: {
        items: keys.slice(0, limit).map((k) => ({
          key: k,
          value: store.entries[k]!.value,
          version: store.entries[k]!.version,
        })),
        hasMore: keys.length > limit,
      },
    };
  }
}
