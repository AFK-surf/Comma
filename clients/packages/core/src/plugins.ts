// Plugins: a workspace's catalog (kept on the device, `doc` "plugins:<workspace>", read again each time a page shows
// it and every 10 s while a read fails), installs and their browser authorization, uninstalls, and an installed
// plugin's personal connections. What is under way belongs to the core, not to a window: an authorization started in
// the onboarding window is still checked after that window closes, and each failure is said once, by one window
// (`pluginNotices`, `plugin.notice.claim`).
//
// Bounds: one catalog read in flight per workspace; one install, reconnect or uninstall request in flight per plugin;
// one authorization under way per core, checked every 2 s (and when a window gets the focus back) until it is done or
// its 2-minute deadline, at most 60 checks; one personal-sources read in flight per plugin page.
import {
  CoreError,
  Priority,
  type ClientId,
  type Topic,
  type Value,
  topicKey,
} from "@comma/core-kernel";
import { Effect, Fiber, Option } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import {
  pageSchema,
  pluginAccountConfirmationSchema,
  pluginAuthorizationSchema,
  pluginConfirmedAccountSchema,
  pluginInstallResultSchema,
  pluginPersonalSourcesSchema,
  pluginSchema,
} from "./comma/schemas.ts";
import type {
  OnboardingPluginList,
  OnboardingPluginRow,
  Plugin,
  PluginActivity,
  PluginCategory,
  PluginFailureReason,
  PluginInstallOrigin,
  PluginInstallAnswer,
  PluginCredentialSetup,
  PluginNotice,
  PluginRow,
  PluginSourcesValue,
  PluginsValue,
} from "./contract.ts";
import { API_LANE, type Ctx, Live } from "./ctx.ts";
import {
  ONBOARDING_WORKSPACE,
  type Workspaces,
  workspaceUsable,
} from "./workspaces.ts";

const REQUEST_TIMEOUT_MS = 30_000;
const AUTHORIZATION_MS = 120_000;
const CHECK_EVERY_MS = 2_000;
const CATALOG_TIMEOUT_MS = 20_000;
const CATALOG_RETRY_MS = 10_000;

/** The integrations most people reach for first; the rest follow in catalog order. */
const PREFERRED_ORDER = ["google", "github", "notion", "slack", "linear", "feishu"];
/** Plugins the Plugins page does not list. */
// Comma on a Mac lists the Mac apps plugin itself; nowhere else lists it.
const UNLISTED = new Set(["feishu", "lark", "mac-apps"]);

const catalogDoc = (workspace: string) => `plugins:${workspace}`;
const sourcesDoc = (workspace: string, plugin: string) =>
  `pluginSources:${workspace}:${plugin}`;
const targetKey = (workspace: string, plugin: string) => `${workspace}\n${plugin}`;

type Target = { workspace: string; plugin: string };
type Operation = "install" | "reauthorize";
type Authorization = Target & {
  operation: Operation;
  origin: PluginInstallOrigin;
  /** The UI that started it: what it ends with is said there while it is connected. */
  owner: ClientId;
  connection?: string;
  state: string;
  expiresAt: number;
};
type Request = Target & {
  operation: Operation | "uninstall";
  connection?: string;
  fiber: Fiber.Fiber<unknown, unknown> | null;
};
type SourcesState = Omit<PluginSourcesValue, "sources">;
type InstallAnswer = {
  plugin: Plugin;
  authorization: { state: string; authorizationUrl?: string | undefined } | null;
  configuration?: PluginCredentialSetup | undefined;
};

const installAnswerSchema = z.union([pluginInstallResultSchema, pluginSchema]);
const cancelledSchema = z.object({ cancelled: z.literal(true) });

const params = {
  configValues(raw: unknown): Record<string, string> | undefined {
    const values = (raw as { configValues?: unknown } | null)?.configValues;
    if (values === undefined) return undefined;
    const parsed = z
      .record(z.string().min(1).max(128), z.string().min(1).max(4096))
      .safeParse(values);
    if (!parsed.success || Object.keys(parsed.data).length !== 1)
      throw CoreError.invalid("one plugin credential is required");
    return parsed.data;
  },
  /** The Comma desktop app's own device, for a plugin that runs on it (the Mac apps). */
  deviceId(raw: unknown): string | undefined {
    const value = (raw as { deviceId?: unknown } | null)?.deviceId;
    if (value === undefined) return undefined;
    if (typeof value !== "string" || !value.trim() || value.length > 256)
      throw CoreError.invalid("deviceId must be a device id");
    return value.trim();
  },
  target(raw: unknown): Target {
    const p = raw as Record<string, unknown> | null;
    if (
      typeof p?.workspace !== "string" ||
      typeof p.plugin !== "string" ||
      !p.workspace ||
      !p.plugin
    )
      throw CoreError.invalid("workspace and plugin are required");
    return { workspace: p.workspace, plugin: p.plugin };
  },
  string(raw: unknown, name: string): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "")
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
};

/** Why an install or reconnect failed, from the server's code or status; a code with no wording of its own is general. */
export function failureReason(error: CoreError): PluginFailureReason {
  switch (error.code) {
    case "plugin_credential_rejected":
      return "credential_rejected";
    case "authorization_callback_in_progress":
    case "stale_plugin_operation":
      return "busy";
    case "missing_oauth_client":
    case "not_configured":
      return "not_configured";
    case "forbidden":
      return "forbidden";
    case "not_found":
      return "not_found";
  }
  if (error.status !== undefined && error.code.endsWith("_unavailable"))
    return "unavailable";
  switch (error.status) {
    case 403:
      return "forbidden";
    case 404:
      return "not_found";
    case 409:
      return "busy";
    case 412:
      return "not_configured";
    case 502:
    case 503:
    case 504:
      return "unavailable";
    default:
      return "generic";
  }
}

export class Plugins {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  /** The last catalog read failed with this, while nothing was read before, by workspace. */
  readonly #failures = new Map<string, CoreError>();
  /** Requests in flight, by plugin. */
  readonly #requests = new Map<string, Request>();
  #authorization: Authorization | null = null;
  /** The authorization being checked now (its request in flight). */
  #checking: Authorization | null = null;
  #checker: Fiber.Fiber<unknown, unknown> | null = null;
  #notices: PluginNotice[] = [];
  /** Who each notice is for first (the UI that started what it is about), by notice. */
  readonly #owners = new Map<number, ClientId>();
  #nextNotice = 0;
  readonly #sources = new Map<string, SourcesState>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("plugins", {
      start: (topic) => this.#live.run(topic, this.#keepCatalog(topic)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({ ok: this.#catalogValue(topic) }),
    });
    kernel.source("onboardingApps", {
      start: (topic) => this.#live.run(topic, this.#keepOnboardingApps()),
      stop: (topic) => this.#live.stop(topic),
      compute: (): Value => ({ ok: this.#onboardingApps() }),
    });
    kernel.source("pluginSources", {
      start: (topic) =>
        this.#live.run(
          topic,
          this.#readSources(topic.workspace as string, topic.plugin as string)
        ),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#cancelConfirmation(topic.workspace as string, topic.plugin as string);
      },
      compute: (topic): Value => ({
        ok: this.#sourcesValue(topic.workspace as string, topic.plugin as string),
      }),
    });
    kernel.source("pluginNotices", {
      start() {},
      stop() {},
      compute: (): Value => ({ ok: { notices: this.#notices } }),
    });
    workspaces.onChange(() => this.#invalidateCatalogs());
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      // Another account (or none): what was under way for the one before stops, and nothing of it is shown.
      this.#accountKey = key;
      for (const request of this.#requests.values())
        if (request.fiber) ctx.runner.interrupt(request.fiber);
      this.#requests.clear();
      this.#stopAuthorization();
      this.#failures.clear();
      this.#sources.clear();
      this.#notices = [];
      this.#owners.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (
          topic.topic === "plugins" ||
          topic.topic === "onboardingApps" ||
          topic.topic === "pluginSources"
        ) {
          this.#live.stop(topic);
          kernel.store.invalidate(topic);
          this.#restart(topic);
        }
      }
      kernel.store.invalidate({ topic: "pluginNotices" });
    });
    kernel.calls({
      "plugins.refresh": {
        run: (p) => {
          // With no workspace: the list of workspaces is read again (a page that could not tell which to show).
          const workspace = (p as { workspace?: unknown } | null)?.workspace;
          return typeof workspace === "string" && workspace
            ? this.#refreshCatalog(workspace, Priority.asked)
            : this.#workspaces.refresh(Priority.asked).pipe(Effect.as(null));
        },
      },
      "plugin.install": {
        run: (p, call) => {
          const target = params.target(p);
          const origin =
            (p as { origin?: unknown }).origin === "onboarding"
              ? "onboarding"
              : "plugins";
          return this.#start(
            call.client,
            target,
            "install",
            origin,
            undefined,
            params.configValues(p),
            params.deviceId(p)
          );
        },
      },
      "plugin.reauthorize": {
        run: (p, call) =>
          this.#start(
            call.client,
            params.target(p),
            "reauthorize",
            "plugins",
            params.string(p, "connection")
          ),
      },
      "plugin.uninstall": {
        doing: true,
        run: (p, call) => this.#uninstall(call.client, params.target(p)),
      },
      "plugin.cancel": {
        run: (p) =>
          Effect.sync(() => this.#cancel(params.target(p))).pipe(Effect.as(null)),
      },
      "plugin.authorization.check": {
        run: () => Effect.sync(() => this.#checkNow()).pipe(Effect.as(null)),
      },
      "plugin.notice.claim": {
        // The UI that started what a notice is about says it while it is connected; any other once it is gone.
        run: (p, call) =>
          Effect.sync(() => {
            const id = (p as { id?: unknown } | null)?.id;
            const at = this.#notices.findIndex((n) => n.id === id);
            if (at < 0) return false;
            const owner = this.#owners.get(id as number);
            if (owner !== undefined && owner !== call.client && kernel.connected(owner))
              return false;
            this.#owners.delete(id as number);
            this.#notices = this.#notices.filter((_, i) => i !== at);
            kernel.store.invalidate({ topic: "pluginNotices" });
            return true;
          }),
      },
      "plugin.sources.refresh": {
        run: (p) => {
          const { workspace, plugin } = params.target(p);
          return this.#readSources(workspace, plugin).pipe(Effect.as(null));
        },
      },
      "plugin.sources.prepare": {
        doing: true,
        run: (p) =>
          this.#prepare(
            params.target(p),
            params.string(p, "toolkit"),
            params.string(p, "account")
          ),
      },
      "plugin.sources.confirm": {
        doing: true,
        run: (p) => this.#confirm(params.target(p)),
      },
      "plugin.sources.cancel": {
        run: (p) =>
          Effect.sync(() => {
            const { workspace, plugin } = params.target(p);
            this.#cancelConfirmation(workspace, plugin);
            return null;
          }),
      },
    });
  }

  #restart(topic: Topic): void {
    if (topic.topic === "plugins") this.#live.run(topic, this.#keepCatalog(topic));
    else if (topic.topic === "onboardingApps")
      this.#live.run(topic, this.#keepOnboardingApps());
    else if (topic.topic === "pluginSources")
      this.#live.run(
        topic,
        this.#readSources(topic.workspace as string, topic.plugin as string)
      );
  }

  #invalidateCatalogs(): void {
    this.#ctx.kernel.store.invalidateAll(
      (t) => t.topic === "plugins" || t.topic === "onboardingApps"
    );
  }

  #notice(owner: ClientId, notice: Omit<PluginNotice, "id">): void {
    const id = ++this.#nextNotice;
    this.#owners.set(id, owner);
    this.#notices = [...this.#notices, { ...notice, id }];
    this.#ctx.kernel.store.invalidate({ topic: "pluginNotices" });
  }

  // ── the catalog ──

  /** The workspace a `plugins` topic is about: its own, or the one it prefers when that can have plugins, else the first that can; null while the list is unknown, "" when none can. */
  #workspaceOf(topic: Topic, account: Account): string | null {
    if (topic.workspace) return topic.workspace as string;
    const list = this.#workspaces.list(account);
    if (!list) return null;
    const usable =
      list.find((w) => w.id === topic.prefer && workspaceUsable(w)) ??
      list.find(workspaceUsable);
    return usable?.id ?? "";
  }

  /** Keeps a `plugins` topic current: the list of workspaces when it needs one, then its catalog; a failed read is tried again every 10 s. */
  #keepCatalog(topic: Topic): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      for (;;) {
        const account = yield* this.#ctx.session.account().pipe(Effect.option);
        if (Option.isNone(account)) return;
        let ok = true;
        if (!topic.workspace) {
          ok = yield* this.#workspaces.refresh().pipe(
            Effect.as(true),
            Effect.orElseSucceed(() => false)
          );
        }
        const workspace = this.#workspaceOf(topic, account.value);
        if (workspace) {
          ok = yield* this.#refreshCatalog(workspace, Priority.shown).pipe(
            Effect.as(true),
            Effect.orElseSucceed(() => false)
          );
        }
        if (ok && workspace !== null) return;
        yield* Effect.sleep(CATALOG_RETRY_MS);
      }
    });
  }

  /** Reads a workspace's catalog again: one read at a time, given up after 20 s. */
  #refreshCatalog(workspace: string, priority: number): Effect.Effect<null, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.scheduler.ask(
          API_LANE,
          `${account.dbName}:${catalogDoc(workspace)}`,
          priority,
          ctx.api
            .request(
              account,
              "GET",
              route`/v1/comma/workspaces/${workspace}/plugins`,
              pageSchema(pluginSchema),
              undefined,
              CATALOG_TIMEOUT_MS
            )
            .pipe(
              Effect.tap((page) =>
                Effect.sync(() => {
                  if (!account.putDoc(catalogDoc(workspace), page.data, ctx.now()))
                    return;
                  this.#failures.delete(workspace);
                  this.#invalidateCatalogs();
                })
              ),
              Effect.tapError((error) =>
                Effect.sync(() => {
                  if (account.closed || account.doc(catalogDoc(workspace))) return;
                  this.#failures.set(workspace, error);
                  this.#invalidateCatalogs();
                })
              ),
              Effect.asVoid
            )
        )
      ),
      Effect.as(null)
    );
  }

  #catalog(account: Account, workspace: string): Plugin[] | null {
    return account.doc<Plugin[]>(catalogDoc(workspace))?.value ?? null;
  }

  /** Puts a plugin as an answer gave it into its workspace's catalog. */
  #keepPlugin(account: Account, workspace: string, plugin: Plugin): void {
    if (
      account.updateDoc<Plugin[]>(
        catalogDoc(workspace),
        (list) => list.map((p) => (p.id === plugin.id ? plugin : p)),
        this.#ctx.now()
      )
    )
      this.#invalidateCatalogs();
  }

  #activity(
    workspace: string,
    plugin: string
  ): { activity: PluginActivity; reauthorizing?: string } {
    const request = this.#requests.get(targetKey(workspace, plugin));
    if (request?.operation === "uninstall") return { activity: "uninstalling" };
    if (request?.operation === "install") return { activity: "installing" };
    if (request?.operation === "reauthorize")
      return {
        activity: "reauthorizing",
        ...(request.connection ? { reauthorizing: request.connection } : {}),
      };
    // Waiting on the browser: nothing is asked of the server but the checks.
    const a = this.#authorization;
    if (a && a.workspace === workspace && a.plugin === plugin) {
      if (this.#checking !== a) return { activity: "authorizing" };
      return {
        activity: "verifying",
        ...(a.operation === "reauthorize" && a.connection
          ? { reauthorizing: a.connection }
          : {}),
      };
    }
    return { activity: "idle" };
  }

  #catalogValue(topic: Topic): PluginsValue {
    const account = this.#ctx.session.current();
    if (!account) return { status: "loading" };
    const workspace = this.#workspaceOf(topic, account);
    if (workspace === null) {
      const failure = this.#workspaces.listFailure();
      return failure
        ? { status: "error", workspace: null, error: failure.toJSON() }
        : { status: "loading" };
    }
    if (workspace === "") return { status: "empty" };
    const catalog = this.#catalog(account, workspace);
    if (!catalog) {
      const failure = this.#failures.get(workspace);
      return failure
        ? { status: "error", workspace, error: failure.toJSON() }
        : { status: "loading" };
    }
    const plugins: PluginRow[] = catalog.map((p) => ({
      ...p,
      ...this.#activity(workspace, p.id),
    }));
    const listed = catalog.filter((p) => !UNLISTED.has(p.id));
    const categories = new Map<string, PluginCategory>();
    for (const p of listed) {
      if (p.installed) continue;
      const source = p.category.trim();
      const id = source || "Integrations";
      let category = categories.get(id);
      if (!category) {
        category = {
          id: id.toLocaleLowerCase().replace(/[^a-z0-9]+/g, "-"),
          name: id === "Integrations" ? null : id,
          plugins: [],
        };
        categories.set(id, category);
      }
      category.plugins.push(p.id);
    }
    return {
      status: "ready",
      workspace,
      plugins,
      installed: listed.filter((p) => p.installed).map((p) => p.id),
      categories: [...categories.values()],
    };
  }

  // ── the onboarding's apps ──

  #keepOnboardingApps(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      // Its workspace is the onboarding's: watched while this is live, its catalog read once it is ready.
      let done: string | null = null;
      const follow = () => {
        const next = this.#workspaces.onboarding();
        if (next.status === "ready" && next.workspaceId !== done) {
          done = next.workspaceId;
          this.#live.run(
            { topic: "onboardingApps" },
            this.#keepCatalog({
              topic: "plugins",
              workspace: next.workspaceId,
              prefer: "",
            })
          );
        }
        this.#ctx.kernel.store.invalidate({ topic: "onboardingApps" });
      };
      const watch = this.#ctx.kernel.store.watch(ONBOARDING_WORKSPACE, follow);
      follow();
      yield* Effect.addFinalizer(() => Effect.sync(() => watch.drop()));
      return yield* Effect.never;
    }).pipe(Effect.scoped);
  }

  #onboardingApps(): OnboardingPluginList {
    const workspace = this.#workspaces.onboarding();
    if (workspace.status === "unavailable") return { status: "unavailable" };
    if (workspace.status !== "ready")
      return workspace.unreachable
        ? { status: "preparing", unreachable: true }
        : { status: "preparing" };
    const account = this.#ctx.session.current();
    const catalog = account ? this.#catalog(account, workspace.workspaceId) : null;
    if (!catalog)
      return this.#failures.has(workspace.workspaceId)
        ? { status: "unavailable" }
        : { status: "loading" };
    const rank = (p: Plugin) => {
      const at = PREFERRED_ORDER.indexOf(p.id);
      return at === -1 ? PREFERRED_ORDER.length : at;
    };
    const rows = catalog
      .filter((p) => {
        const category = p.category.trim();
        return !p.locked && (category === "" || category === "Integrations");
      })
      .toSorted((a, b) => rank(a) - rank(b))
      .map((p): OnboardingPluginRow => {
        const { activity } = this.#activity(workspace.workspaceId, p.id);
        return {
          brand: p.brand,
          connection: p.installed
            ? "connected"
            : activity === "installing" ||
                activity === "authorizing" ||
                activity === "verifying"
              ? "connecting"
              : "idle",
          id: p.id,
          name: p.name,
          summary: p.summary,
        };
      });
    return { status: "ready", rows };
  }

  // ── installs and reconnects ──

  /** Starts an install or reconnect: answers once the server has (with where to authorize, when it needs that). */
  #start(
    owner: ClientId,
    target: Target,
    operation: Operation,
    origin: PluginInstallOrigin,
    connection?: string,
    configValues?: Record<string, string>,
    deviceId?: string
  ): Effect.Effect<PluginInstallAnswer, CoreError> {
    const key = targetKey(target.workspace, target.plugin);
    // The same install asked again (a second press) is the one under way.
    if (operation === "install" && this.#requests.get(key)?.operation === "install")
      return Effect.succeed(configValues ? { failure: "busy" } : {});
    // One authorization at a time: a new one replaces what was under way.
    this.#stopAuthorization();
    return this.#ctx.session.account().pipe(
      Effect.flatMap((account) => {
        const request: Request = {
          ...target,
          operation,
          ...(connection ? { connection } : {}),
          fiber: null,
        };
        const work = this.#ask(
          account,
          target,
          operation,
          connection,
          null,
          REQUEST_TIMEOUT_MS,
          configValues,
          deviceId
        ).pipe(
          Effect.ensuring(
            Effect.sync(() => {
              if (this.#requests.get(key) === request) this.#requests.delete(key);
              this.#invalidateCatalogs();
            })
          ),
          Effect.flatMap((answer) =>
            Effect.sync((): PluginInstallAnswer => {
              this.#keepPlugin(account, target.workspace, answer.plugin);
              if (answer.configuration) {
                this.#notice(owner, {
                  kind: "configure",
                  origin,
                  plugin: target.plugin,
                  configuration: {
                    workspace: target.workspace,
                    plugin: answer.plugin,
                    setup: answer.configuration,
                  },
                });
                return {};
              }
              if (!answer.authorization) {
                if (operation === "reauthorize") this.#sourcesChanged(target);
                return {};
              }
              this.#authorize({
                ...target,
                operation,
                origin,
                owner,
                ...(connection ? { connection } : {}),
                state: answer.authorization.state,
                expiresAt: this.#ctx.now() + AUTHORIZATION_MS,
              });
              return answer.authorization.authorizationUrl
                ? { authorizationUrl: answer.authorization.authorizationUrl }
                : {};
            })
          ),
          Effect.catch((error: CoreError) =>
            Effect.sync((): PluginInstallAnswer => {
              if (account.closed) return {};
              // The credential form shows its failure in place and retains no core-side secret.
              if (configValues) return { failure: failureReason(error) };
              if (error.code === "member_account_not_personal")
                this.#notice(owner, {
                  kind: "not_personal",
                  origin,
                  plugin: target.plugin,
                });
              else if (error.code === "timeout")
                this.#notice(owner, {
                  kind: "install_timed_out",
                  origin,
                  plugin: target.plugin,
                });
              else
                this.#notice(owner, {
                  kind:
                    operation === "reauthorize"
                      ? "reauthorize_failed"
                      : "install_failed",
                  origin,
                  plugin: target.plugin,
                  reason: failureReason(error),
                });
              return {};
            })
          )
        );
        // Its own fiber, so `plugin.cancel` (or another install) can stop it whoever waits on the call.
        this.#requests.set(key, request);
        this.#invalidateCatalogs();
        const fiber = this.#ctx.runner.fork(work);
        request.fiber = fiber as Fiber.Fiber<unknown, unknown>;
        return Fiber.join(fiber);
      })
    );
  }

  /** The install or reconnect request; `state` verifies an authorization under way rather than starting one. */
  #ask(
    account: Account,
    target: Target,
    operation: Operation,
    connection: string | undefined,
    state: string | null,
    timeoutMs: number,
    configValues?: Record<string, string>,
    deviceId?: string
  ): Effect.Effect<InstallAnswer, CoreError> {
    const { api } = this.#ctx;
    const path = route`/v1/comma/workspaces/${target.workspace}/plugins/${target.plugin}`;
    const verify = state ? { authorization_state: state, verify_only: true } : {};
    if (operation === "reauthorize")
      return api.request(
        account,
        "POST",
        `${path}/reauthorize`,
        pluginInstallResultSchema,
        { ...(connection ? { connection_id: connection } : {}), ...verify },
        timeoutMs
      );
    return api
      .request(
        account,
        "POST",
        `${path}/install`,
        installAnswerSchema,
        {
          contract: "unified_v1",
          ...verify,
          ...(configValues ? { config_values: configValues } : {}),
          ...(deviceId ? { device_id: deviceId } : {}),
        },
        timeoutMs
      )
      .pipe(
        Effect.filterOrElse(
          (answer) => "plugin" in answer,
          (answer) => this.#legacyInstall(account, path, answer, state !== null)
        )
      );
  }

  /** A server from before the one install answered the plugin alone: its former Connect step is finished here, so the product still has one Install. */
  #legacyInstall(
    account: Account,
    path: string,
    plugin: Plugin,
    verifyOnly: boolean
  ): Effect.Effect<InstallAnswer, CoreError> {
    const { api } = this.#ctx;
    const rollBack = api.request(account, "DELETE", path, pluginSchema);
    const authorize: Effect.Effect<InstallAnswer, CoreError> = api
      .request(account, "POST", `${path}/authorize`, pluginAuthorizationSchema, {})
      .pipe(
        Effect.flatMap(
          (authorization): Effect.Effect<InstallAnswer, CoreError> =>
            // It cannot verify an exact attempt (each authorize starts another): a verification rolls the install back.
            verifyOnly
              ? rollBack.pipe(
                  Effect.map((back) => ({ plugin: back, authorization: null }))
                )
              : Effect.succeed({
                  plugin: { ...plugin, installed: false },
                  authorization,
                })
        )
      );
    return authorize.pipe(
      Effect.catch((error: CoreError): Effect.Effect<InstallAnswer, CoreError> => {
        if (
          error.status === 400 &&
          (error.code === "this plugin has no connectable data source" ||
            error.code === "all plugin data sources are already connected")
        )
          return Effect.succeed({ plugin, authorization: null });
        return rollBack.pipe(Effect.ignore, Effect.andThen(Effect.fail(error)));
      })
    );
  }

  #authorize(authorization: Authorization): void {
    this.#authorization = authorization;
    this.#invalidateCatalogs();
    this.#checker = this.#ctx.runner.fork(
      Effect.gen({ self: this }, function* () {
        for (;;) {
          const left = authorization.expiresAt - this.#ctx.now();
          if (left <= 0) break;
          yield* Effect.sleep(Math.min(CHECK_EVERY_MS, left));
          if (this.#authorization !== authorization) return;
          if (authorization.expiresAt - this.#ctx.now() <= 0) break;
          yield* this.#check(authorization);
          if (this.#authorization !== authorization) return;
        }
        // Ended here: not interrupted by its own stop.
        this.#checker = null;
        this.#stopAuthorization();
        this.#notice(authorization.owner, {
          kind: "authorization_timed_out",
          origin: authorization.origin,
          plugin: authorization.plugin,
        });
      })
    );
  }

  /** Checks an authorization under way once (one check at a time). */
  #check(authorization: Authorization): Effect.Effect<void> {
    if (this.#checking) return Effect.void;
    this.#checking = authorization;
    this.#invalidateCatalogs();
    const ctx = this.#ctx;
    const timeout = Math.min(REQUEST_TIMEOUT_MS, authorization.expiresAt - ctx.now());
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        this.#ask(
          account,
          authorization,
          authorization.operation,
          authorization.connection,
          authorization.state,
          Math.max(0, timeout)
        ).pipe(
          Effect.flatMap((answer) =>
            Effect.sync(() => {
              if (
                this.#authorization !== authorization ||
                ctx.now() >= authorization.expiresAt
              )
                return;
              this.#keepPlugin(account, authorization.workspace, answer.plugin);
              if (answer.authorization) {
                // Still waiting on the browser; a new attempt the server started (the next account of a plugin with
                // several) has a deadline of its own, and its page is opened by one window.
                if (answer.authorization.state !== authorization.state) {
                  this.#authorize({
                    ...authorization,
                    state: answer.authorization.state,
                    expiresAt: ctx.now() + AUTHORIZATION_MS,
                  });
                  if (answer.authorization.authorizationUrl)
                    this.#notice(authorization.owner, {
                      kind: "authorize",
                      origin: authorization.origin,
                      plugin: authorization.plugin,
                      url: answer.authorization.authorizationUrl,
                    });
                }
                return;
              }
              this.#stopAuthorization();
              if (authorization.operation === "reauthorize")
                this.#sourcesChanged(authorization);
            })
          ),
          // A failed check does not cancel the provider's authorization: the same attempt is checked again until its deadline.
          Effect.catch((error: CoreError) =>
            Effect.sync(() => {
              if (
                this.#authorization !== authorization ||
                error.code !== "member_account_not_personal"
              )
                return;
              this.#stopAuthorization();
              this.#notice(authorization.owner, {
                kind: "not_personal",
                origin: authorization.origin,
                plugin: authorization.plugin,
              });
            })
          )
        )
      ),
      Effect.ignore,
      Effect.ensuring(
        Effect.sync(() => {
          if (this.#checking === authorization) this.#checking = null;
          this.#invalidateCatalogs();
        })
      )
    );
  }

  #checkNow(): void {
    const authorization = this.#authorization;
    if (authorization && this.#ctx.now() < authorization.expiresAt)
      this.#ctx.runner.fork(this.#check(authorization));
  }

  #stopAuthorization(): void {
    if (this.#checker) this.#ctx.runner.interrupt(this.#checker);
    this.#checker = null;
    if (this.#authorization) {
      this.#authorization = null;
      this.#invalidateCatalogs();
    }
  }

  /** Stops an install or reconnect of `target` under way; a reconnect's authorization is let go on the server too. */
  #cancel(target: Target): void {
    const key = targetKey(target.workspace, target.plugin);
    const request = this.#requests.get(key);
    if (request && request.operation !== "uninstall") {
      this.#requests.delete(key);
      if (request.fiber) this.#ctx.runner.interrupt(request.fiber);
    }
    const a = this.#authorization;
    if (a && a.workspace === target.workspace && a.plugin === target.plugin) {
      if (a.operation === "reauthorize") this.#letGo(target, a.state);
      this.#stopAuthorization();
    }
    this.#invalidateCatalogs();
  }

  /** Lets an operation's authorization go on the server, whoever waits (nothing does). */
  #letGo(target: Target, state: string): void {
    const ctx = this.#ctx;
    ctx.runner.fork(
      ctx.session.account().pipe(
        Effect.flatMap((account) =>
          ctx.api.request(
            account,
            "POST",
            route`/v1/comma/workspaces/${target.workspace}/plugins/${target.plugin}/personal-sources/cancel`,
            cancelledSchema,
            { state }
          )
        ),
        Effect.ignore
      )
    );
  }

  #uninstall(owner: ClientId, target: Target): Effect.Effect<null, CoreError> {
    const key = targetKey(target.workspace, target.plugin);
    if (this.#requests.get(key)?.operation === "uninstall") return Effect.succeed(null);
    this.#cancel(target);
    return this.#ctx.session.account().pipe(
      Effect.flatMap((account) => {
        const request: Request = { ...target, operation: "uninstall", fiber: null };
        this.#requests.set(key, request);
        this.#invalidateCatalogs();
        return this.#ctx.api
          .request(
            account,
            "DELETE",
            route`/v1/comma/workspaces/${target.workspace}/plugins/${target.plugin}`,
            pluginSchema
          )
          .pipe(
            Effect.tap((plugin) =>
              Effect.sync(() => this.#keepPlugin(account, target.workspace, plugin))
            ),
            Effect.tapError((error) =>
              Effect.sync(() =>
                this.#notice(owner, {
                  kind: "uninstall_failed",
                  origin: "plugins",
                  plugin: target.plugin,
                  message: error.message,
                })
              )
            ),
            Effect.ensuring(
              Effect.sync(() => {
                if (this.#requests.get(key) === request) this.#requests.delete(key);
                this.#invalidateCatalogs();
              })
            )
          );
      }),
      Effect.as(null)
    );
  }

  // ── personal sources ──

  #sourcesState(workspace: string, plugin: string): SourcesState {
    const key = targetKey(workspace, plugin);
    let state = this.#sources.get(key);
    if (!state) {
      state = { error: null, confirmation: null, pending: null };
      this.#sources.set(key, state);
    }
    return state;
  }

  #sourcesTopic(workspace: string, plugin: string): Topic {
    return { topic: "pluginSources", workspace, plugin };
  }

  #setSources(workspace: string, plugin: string, change: Partial<SourcesState>): void {
    Object.assign(this.#sourcesState(workspace, plugin), change);
    this.#ctx.kernel.store.invalidate(this.#sourcesTopic(workspace, plugin));
  }

  #sourcesValue(workspace: string, plugin: string): PluginSourcesValue {
    const account = this.#ctx.session.current();
    const kept =
      account?.doc<PluginSourcesValue["sources"]>(sourcesDoc(workspace, plugin))
        ?.value ?? null;
    return { sources: kept, ...this.#sourcesState(workspace, plugin) };
  }

  /** A reconnect finished: the plugin's connections are read again where a page shows them. */
  #sourcesChanged(target: Target): void {
    const topic = this.#sourcesTopic(target.workspace, target.plugin);
    if (this.#live.live(topic))
      this.#live.run(topic, this.#readSources(target.workspace, target.plugin));
  }

  /** Reads a plugin's connections; a confirmation waiting on the read, and what was pending, end with it. */
  #readSources(workspace: string, plugin: string): Effect.Effect<void> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.scheduler.ask(
          API_LANE,
          `${account.dbName}:${sourcesDoc(workspace, plugin)}`,
          Priority.shown,
          ctx.api
            .request(
              account,
              "GET",
              route`/v1/comma/workspaces/${workspace}/plugins/${plugin}/personal-sources`,
              pluginPersonalSourcesSchema
            )
            .pipe(
              Effect.tap((result) =>
                Effect.sync(() => {
                  if (
                    !account.putDoc(
                      sourcesDoc(workspace, plugin),
                      result.sources,
                      ctx.now()
                    )
                  )
                    return;
                  this.#setSources(workspace, plugin, {
                    error: null,
                    confirmation: null,
                    pending: null,
                  });
                })
              ),
              Effect.tapError(() =>
                Effect.sync(() => {
                  if (!account.closed)
                    this.#setSources(workspace, plugin, {
                      error: "load_failed",
                      confirmation: null,
                      pending: null,
                    });
                })
              ),
              Effect.asVoid
            )
        )
      ),
      Effect.ignore
    );
  }

  #prepare(
    target: Target,
    toolkit: string,
    accountId: string
  ): Effect.Effect<null, CoreError> {
    const { workspace, plugin } = target;
    if (this.#sourcesState(workspace, plugin).pending) return Effect.succeed(null);
    this.#setSources(workspace, plugin, {
      pending: { type: "prepare", accountId },
      error: null,
    });
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api
          .request(
            account,
            "POST",
            route`/v1/comma/workspaces/${workspace}/plugins/${plugin}/personal-sources/prepare`,
            pluginAccountConfirmationSchema,
            { toolkit, connection_id: accountId }
          )
          .pipe(
            Effect.tap((confirmation) =>
              Effect.sync(() =>
                this.#setSources(workspace, plugin, { confirmation, pending: null })
              )
            ),
            Effect.tapError((error) =>
              Effect.sync(() =>
                this.#setSources(workspace, plugin, {
                  error:
                    error.code === "member_account_not_personal"
                      ? "not_personal"
                      : "confirm_failed",
                  pending: null,
                })
              )
            )
          )
      ),
      Effect.as(null)
    );
  }

  #confirm(target: Target): Effect.Effect<null, CoreError> {
    const { workspace, plugin } = target;
    const state = this.#sourcesState(workspace, plugin);
    const confirmation = state.confirmation;
    if (!confirmation || state.pending) return Effect.succeed(null);
    this.#setSources(workspace, plugin, { pending: { type: "confirm" }, error: null });
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api
          .request(
            account,
            "POST",
            route`/v1/comma/workspaces/${workspace}/plugins/${plugin}/personal-sources/confirm`,
            pluginConfirmedAccountSchema,
            { state: confirmation.state }
          )
          .pipe(
            // Its panel and pending state last until the connections read again replace them.
            Effect.flatMap(() => this.#readSources(workspace, plugin)),
            Effect.tapError((error) =>
              Effect.sync(() =>
                this.#setSources(workspace, plugin, {
                  error:
                    error.code === "member_account_not_personal"
                      ? "not_personal"
                      : "confirm_failed",
                  pending: null,
                })
              )
            )
          )
      ),
      Effect.as(null)
    );
  }

  #cancelConfirmation(workspace: string, plugin: string): void {
    const state = this.#sources.get(targetKey(workspace, plugin));
    const active = state?.confirmation;
    if (!state || !active) return;
    this.#setSources(workspace, plugin, { confirmation: null });
    this.#letGo({ workspace, plugin }, active.state);
  }
}

export { topicKey };
