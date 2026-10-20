// Settings › Model & API: the model catalog, a workspace's profiles (subscriptions and API keys, 25 a page) and its
// Agents (the Router, and the model its Tasks run when they name none), read when the page shows them and on
// `models.refresh`; what was read stays for the workspace while the account is signed in, so the page opens on it
// while it reads again. The changes a person makes: a profile's (one at a time per profile, each with the version the
// last one answered; a conflict reads the profiles again), an Agent's model, the default Task model and the default
// place to run Tasks (shown at once, saved in order per Agent and per workspace; a failure reads the Agents again), a
// quota reset (its request id kept on the device until the provider's outcome is known), a new API-key profile (an
// endpoint outside the catalog lists its models first), and a subscription's sign-in (a device code asked about at the
// interval the server says until it expires). And `router`: a workspace's Router Agent, its name for chat surfaces and
// its reply style for Settings › General (a change shows at once and saves in order per workspace; a failure reads the
// Router again).
//
// Bounds: one read in flight per page shown (three requests; a `models.refresh` asked while it runs waits for it); one
// save in flight per profile, per Agent, per workspace's Task model, Task place and reply style; one device-code
// request per sign-in waited on, at most every 5 s; at most 16 sign-ins remembered.
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Deferred, Effect, Option, Result, Semaphore } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import {
  agentModelsSchema,
  agentSelectionSchema,
  discoveredModelsSchema,
  modelCatalogSchema,
  modelProfileSchema,
  profilePageSchema,
  quotaResetSchema,
  replyStyleSchema,
  signInPollSchema,
  subscriptionSignInSchema,
  taskModelSchema,
  taskModelSelectionSchema,
  taskPlaceSchema,
  taskPlaceSelectionSchema,
} from "./comma/schemas.ts";
import type {
  AgentModels,
  AgentSelection,
  ModelCatalog,
  ModelProfile,
  ModelsValue,
  QuotaReset,
  ReplyStyle,
  SettingsAgent,
  SubscriptionSignIn,
  TaskModelSelection,
  TaskPlace,
} from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import { DEVICE_SIGN_IN, modelsView } from "./model-view.ts";
import type { Workspaces } from "./workspaces.ts";

const CATALOG = "/v1/comma/model-catalog";
const profilesPath = (ws: string) =>
  route`/v1/comma/workspaces/${ws}/subscription-accounts`;
const profilePath = (ws: string, id: string) =>
  `${profilesPath(ws)}/${encodeURIComponent(id)}`;
const agentModelsPath = (ws: string) => route`/v1/comma/workspaces/${ws}/agent-models`;
const agentPath = (ws: string, id: string) =>
  route`/v1/comma/workspaces/${ws}/agents/${id}`;
const taskModelPath = (ws: string) => route`/v1/comma/workspaces/${ws}/task-model`;
const taskPlacePath = (ws: string) => route`/v1/comma/workspaces/${ws}/task-place`;
const replyStylePath = (ws: string) => route`/v1/comma/workspaces/${ws}/reply-style`;
const signInPath = (ws: string) => `${profilesPath(ws)}/oauth`;
const resetKey = (ws: string, id: string, version: string) =>
  `modelsReset:${ws}:${id}:${version}`;
const MAX_SIGN_INS = 16;

type Raw = {
  workspace: string | null;
  catalog: ModelCatalog | null;
  profiles: ModelProfile[] | null;
  /** The next page of profiles ("" none). */
  next: string;
  agents: AgentModels | null;
  error: boolean;
};
/** `reading`: the page's read in flight. */
type Shown = Raw & { reading: Deferred.Deferred<void> | null };
type SignIn = { workspace: string; expiresAt: number; interval: number };
type Save = { lock: Semaphore.Semaphore; pending: number; version: string | undefined };
/** A workspace setting's saves: in order, and how many wait. */
type OrderedSaves = { lock: Semaphore.Semaphore; pending: number };

const params = {
  string(raw: unknown, name: string, max = 256): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  optional(raw: unknown, name: string, max = 4096): string | undefined {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (v === undefined || v === "") return undefined;
    if (typeof v !== "string" || v.length > max)
      throw CoreError.invalid(`${name} is a string`);
    return v;
  },
  boolean(raw: unknown, name: string): boolean | undefined {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (v === undefined) return undefined;
    if (typeof v !== "boolean") throw CoreError.invalid(`${name} is a boolean`);
    return v;
  },
};

const keyOf = (topic: Topic) => String(topic.prefer ?? "");
const empty = (): Raw => ({
  workspace: null,
  catalog: null,
  profiles: null,
  next: "",
  agents: null,
  error: false,
});

/** A name's host, for a Custom endpoint's profile. */
const endpointHost = (url: string) => {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
};

/** The model ids an endpoint lists, as many as a profile keeps (500, each at most 200 bytes). */
function listedIds(data: { id: string }[]): string[] {
  const encoder = new TextEncoder();
  return [
    ...new Set(
      data
        .map((model) => model.id)
        .filter((id) => id && encoder.encode(id).length <= 200)
    ),
  ].slice(0, 500);
}

export class Models {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  readonly #shown = new Map<string, Shown>();
  /** What was last read for each workspace a page preferred: a page shown again starts from it. */
  readonly #held = new Map<string, Raw>();
  readonly #saves = new Map<string, Save>();
  readonly #agentSaves = new Map<string, Semaphore.Semaphore>();
  /** Each workspace's Task model saves: in order, and how many wait. */
  readonly #taskModelSaves = new Map<string, OrderedSaves>();
  /** Each workspace's Task place saves: in order, and how many wait. */
  readonly #taskPlaceSaves = new Map<string, OrderedSaves>();
  /** Each workspace's reply style saves: in order, and how many wait. */
  readonly #replyStyleSaves = new Map<string, OrderedSaves>();
  readonly #signIns = new Map<string, SignIn>();
  /** Each workspace's Router Agent id, from its Agents. */
  readonly #routers = new Map<string, string>();
  readonly #router = new Map<
    string,
    { agent: string; name: string; reply_style?: ReplyStyle } | null
  >();
  /** Renames of each workspace's Router: a read that started before one does not show the name it replaced. */
  readonly #renames = new Map<string, number>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("models", {
      start: (topic) => {
        const held = this.#held.get(String(topic.prefer ?? ""));
        this.#shown.set(keyOf(topic), { ...(held ?? empty()), reading: null });
        this.#live.run(topic, this.#load(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(keyOf(topic));
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    kernel.source("router", {
      start: (topic) => this.#live.run(topic, this.#readRouter(topic)),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#router.delete(routerKey(topic));
      },
      compute: (topic): Value => ({ ok: this.#router.get(routerKey(topic)) ?? null }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#held.clear();
      this.#saves.clear();
      this.#agentSaves.clear();
      this.#taskModelSaves.clear();
      this.#taskPlaceSaves.clear();
      this.#replyStyleSaves.clear();
      this.#signIns.clear();
      this.#routers.clear();
      this.#router.clear();
      this.#renames.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic === "models") {
          this.#live.stop(topic);
          this.#shown.set(keyOf(topic), { ...empty(), reading: null });
          kernel.store.invalidate(topic);
          this.#live.run(topic, this.#load(topic));
        } else if (topic.topic === "router") {
          this.#live.stop(topic);
          kernel.store.invalidate(topic);
          this.#live.run(topic, this.#readRouter(topic));
        }
      }
    });

    kernel.calls({
      "models.refresh": {
        run: (p) => {
          const only = (p as { only?: unknown } | null)?.only;
          if (only !== undefined && only !== "profiles")
            throw CoreError.invalid("only is profiles");
          if (only === "profiles")
            return Effect.forEach(this.#workspacesShown(), (ws) =>
              this.#reloadProfiles(ws).pipe(Effect.ignore)
            ).pipe(Effect.as(null));
          return Effect.forEach(this.#topics(), (t) => this.#load(t)).pipe(
            Effect.as(null)
          );
        },
      },
      "models.moreProfiles": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return Effect.suspend(() => {
            const after = [...this.#shown.values()].find(
              (s) => s.workspace === workspace && s.next
            )?.next;
            if (!after) return Effect.succeed(null);
            return this.#send(
              "GET",
              `${profilesPath(workspace)}?view=profiles&after=${encodeURIComponent(after)}`,
              profilePageSchema
            ).pipe(
              Effect.tap((page) =>
                Effect.sync(() =>
                  this.#each(workspace, (s) => {
                    const known = s.profiles ?? [];
                    s.profiles = [
                      ...known,
                      ...page.accounts.filter((a) => !known.some((k) => k.id === a.id)),
                    ];
                    s.next = page.next;
                  })
                )
              ),
              Effect.as(null)
            );
          });
        },
      },
      "models.updateProfile": {
        // Not `doing`: its params carry a secret, and `doing` shows them to every window.
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const profile = params.string(p, "profile");
          const disabled = params.boolean(p, "disabled");
          const name = params.optional(p, "name", 200)?.trim();
          const apiKey = params.optional(p, "api_key")?.trim();
          if (disabled === undefined && !name && !apiKey)
            throw CoreError.invalid("nothing to change");
          return this.#save(workspace, profile, false, () => ({
            ...(disabled !== undefined ? { disabled } : {}),
            ...(name ? { name } : {}),
            ...(apiKey ? { api_key: apiKey } : {}),
          }));
        },
      },
      "models.offer": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const profile = params.string(p, "profile");
          const ids = (p as { models?: unknown } | null)?.models;
          const on = params.boolean(p, "on");
          if (
            !Array.isArray(ids) ||
            ids.length > 500 ||
            !ids.every((id) => typeof id === "string") ||
            on === undefined
          )
            throw CoreError.invalid("models and on are required");
          return this.#save(workspace, profile, true, () => {
            // From what shows now, choices still on their way included.
            const off = this.#profile(workspace, profile)?.disabled_models ?? [];
            const disabled = on
              ? off.filter((id) => !ids.includes(id))
              : [...new Set([...off, ...(ids as string[])])];
            this.#each(workspace, (s) => {
              s.profiles = (s.profiles ?? []).map((a) =>
                a.id === profile ? { ...a, disabled_models: disabled } : a
              );
            });
            return { disabled_models: disabled };
          });
        },
      },
      "models.refreshQuota": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const profile = params.string(p, "profile");
          return Effect.suspend(() => {
            if (
              this.#profile(workspace, profile)?.credential_kind !==
              "subscription_oauth"
            )
              return this.#reloadProfiles(workspace);
            return this.#send(
              "POST",
              `${profilePath(workspace, profile)}/quota`,
              modelProfileSchema,
              {}
            ).pipe(
              Effect.tap((updated) =>
                Effect.sync(() => this.#replace(workspace, updated))
              ),
              this.#reloadOnConflict(workspace)
            );
          }).pipe(Effect.as(null));
        },
      },
      "models.deleteProfile": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const profile = params.string(p, "profile");
          return Effect.suspend(() => {
            const version = this.#profile(workspace, profile)?.version;
            if (!version)
              return Effect.fail(new CoreError("not_found", "No such profile."));
            return this.#send(
              "DELETE",
              profilePath(workspace, profile),
              z.object({ deleted: z.literal(true) }),
              { version }
            ).pipe(
              Effect.tap(() =>
                Effect.sync(() =>
                  this.#each(workspace, (s) => {
                    s.profiles = (s.profiles ?? []).filter((a) => a.id !== profile);
                  })
                )
              ),
              this.#reloadOnConflict(workspace),
              Effect.as(null)
            );
          });
        },
      },
      "models.resetQuota": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const profile = params.string(p, "profile");
          return this.#resetQuota(workspace, profile);
        },
      },
      "models.createProfile": {
        // Not `doing`: its params carry a secret, and `doing` shows them to every window.
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const source = params.string(p, "source", 128);
          const name = params.optional(p, "name", 200)?.trim();
          const apiKey = params.optional(p, "api_key")?.trim();
          const baseUrl = params.optional(p, "base_url", 2048)?.trim();
          const protocol = (p as { protocol?: unknown } | null)?.protocol;
          if (
            protocol !== undefined &&
            protocol !== "anthropic" &&
            protocol !== "chat_completions" &&
            protocol !== "responses"
          )
            throw CoreError.invalid("protocol is unknown");
          const discover = params.boolean(p, "discover") === true;
          if (discover && (!baseUrl || !protocol))
            throw CoreError.invalid(
              "base_url and protocol are required to list models"
            );
          return this.#createProfile(workspace, {
            source,
            name: name || (baseUrl ? endpointHost(baseUrl) : undefined),
            apiKey,
            baseUrl,
            protocol,
            discover,
          });
        },
      },
      "models.setAgentModel": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const agent = params.string(p, "agent");
          const parsed = agentSelectionSchema.safeParse(
            (p as { selection?: unknown } | null)?.selection
          );
          if (!parsed.success) throw CoreError.invalid("selection is not a choice");
          return this.#setAgentModel(workspace, agent, parsed.data);
        },
      },
      "models.setTaskModel": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const parsed = taskModelSelectionSchema.safeParse(
            (p as { selection?: unknown } | null)?.selection
          );
          if (!parsed.success) throw CoreError.invalid("selection is not a choice");
          return this.#setTaskModel(workspace, parsed.data);
        },
      },
      "models.setTaskPlace": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const parsed = taskPlaceSelectionSchema.safeParse(
            (p as { place?: unknown } | null)?.place
          );
          if (!parsed.success) throw CoreError.invalid("place is not a place");
          return this.#setTaskPlace(workspace, parsed.data);
        },
      },
      "models.setReplyStyle": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const parsed = replyStyleSchema.safeParse(
            (p as { style?: unknown } | null)?.style
          );
          if (!parsed.success) throw CoreError.invalid("style is default or concise");
          return this.#setReplyStyle(workspace, parsed.data);
        },
      },
      "models.renameAgent": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const given = params.optional(p, "agent");
          const name = params.string(p, "name", 200).trim();
          if (!name) throw CoreError.invalid("name is required");
          return this.#renameAgent(workspace, given, name);
        },
      },
      "models.signIn.begin": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const provider = params.string(p, "provider", 128);
          const account = params.optional(p, "account");
          const version = params.optional(p, "version");
          return this.#send("POST", signInPath(workspace), subscriptionSignInSchema, {
            provider,
            // A device code is shown first; the person opens the page with it.
            ...(DEVICE_SIGN_IN.has(provider) ? { mode: "device" } : {}),
            ...(account ? { account_id: account } : {}),
            ...(version ? { version } : {}),
          }).pipe(
            Effect.tap((attempt) =>
              Effect.sync(() => {
                if (this.#signIns.size >= MAX_SIGN_INS)
                  this.#signIns.delete(this.#signIns.keys().next().value!);
                this.#signIns.set(attempt.id, {
                  workspace,
                  expiresAt: Date.parse(attempt.expires_at),
                  interval: attempt.interval ?? 5,
                });
              })
            ),
            Effect.map((attempt): SubscriptionSignIn => attempt)
          );
        },
      },
      "models.signIn.wait": {
        cancellable: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const attempt = params.string(p, "attempt");
          return this.#waitSignIn(workspace, attempt);
        },
      },
      "models.signIn.complete": {
        // Not `doing`: its params carry a secret, and `doing` shows them to every window.
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const attempt = params.string(p, "attempt");
          const code = params.string(p, "code", 8192).trim();
          return this.#send(
            "POST",
            `${signInPath(workspace)}/${encodeURIComponent(attempt)}`,
            modelProfileSchema,
            { code }
          ).pipe(
            Effect.tap(() =>
              Effect.sync(() => this.#signIns.delete(attempt)).pipe(
                Effect.andThen(this.#reloadProfiles(workspace).pipe(Effect.ignore))
              )
            ),
            Effect.map((profile): ModelProfile => profile)
          );
        },
      },
    });
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === "models");
  }

  #workspacesShown(): string[] {
    return [
      ...new Set(
        [...this.#shown.values()].flatMap((s) => (s.workspace ? [s.workspace] : []))
      ),
    ];
  }

  #send<S extends z.ZodType>(
    method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
    path: string,
    schema: S,
    body?: unknown
  ) {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, schema, body)
        )
      );
  }

  #requestId(): string {
    const bytes = new Uint8Array(16);
    this.#ctx.host.randomBytes(bytes);
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  #value(topic: Topic): ModelsValue {
    const shown = this.#shown.get(keyOf(topic)) ?? empty();
    return {
      workspace: shown.workspace,
      catalog: shown.catalog,
      ...modelsView(shown.catalog, shown.profiles),
      moreProfiles: !!shown.next,
      agents: shown.agents,
      error: shown.error,
    };
  }

  /** What changed shows on every page of the workspace, and is held for it. */
  #publish(key: string, shown: Shown): void {
    const { reading: _reading, ...raw } = shown;
    this.#held.set(key, raw);
    for (const topic of this.#topics())
      if (keyOf(topic) === key) this.#ctx.kernel.store.invalidate(topic);
  }

  #each(workspace: string, change: (shown: Shown) => void): void {
    for (const [key, shown] of this.#shown) {
      if (shown.workspace !== workspace) continue;
      change(shown);
      this.#publish(key, shown);
    }
  }

  #profile(workspace: string, id: string): ModelProfile | undefined {
    for (const shown of this.#shown.values())
      if (shown.workspace === workspace) {
        const found = shown.profiles?.find((a) => a.id === id);
        if (found) return found;
      }
    return undefined;
  }

  #replace(workspace: string, updated: ModelProfile): void {
    this.#each(workspace, (s) => {
      s.profiles = (s.profiles ?? []).map((a) => (a.id === updated.id ? updated : a));
    });
  }

  #workspaceOf(account: Account, prefer: string): Effect.Effect<string | null> {
    return Effect.gen({ self: this }, function* () {
      if (!this.#workspaces.list(account)?.some((w) => w.id === prefer))
        yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      const list = this.#workspaces.list(account) ?? [];
      return (list.find((w) => w.id === prefer) ?? list[0])?.id ?? null;
    });
  }

  /** The Router and the default Task model. */
  #readAgents(account: Account, workspace: string) {
    return this.#ctx.api
      .request(account, "GET", agentModelsPath(workspace), agentModelsSchema)
      .pipe(
        Effect.map((agents) => {
          this.#routers.set(workspace, agents.agents.router.agent_id);
          return agents as AgentModels;
        })
      );
  }

  /**
   * One read of a page: the catalog, the first page of profiles and the Agents, all of them or none. Asked while the
   * page's read runs (its start's, or another refresh's), it waits for that read.
   */
  #load(topic: Topic): Effect.Effect<void> {
    const key = keyOf(topic);
    const shown = this.#shown.get(key);
    if (!shown) return Effect.void;
    return Effect.gen({ self: this }, function* () {
      const reading = yield* Deferred.make<void>();
      if (shown.reading) return yield* Deferred.await(shown.reading);
      shown.reading = reading;
      yield* Effect.gen({ self: this }, function* () {
        const ctx = this.#ctx;
        const account = yield* ctx.session.account().pipe(Effect.option);
        if (Option.isNone(account) || this.#shown.get(key) !== shown) return;
        const workspace = yield* this.#workspaceOf(
          account.value,
          String(topic.prefer ?? "")
        );
        if (!workspace) {
          shown.error = true;
          this.#publish(key, shown);
          return;
        }
        if (shown.workspace !== workspace) Object.assign(shown, empty());
        shown.workspace = workspace;
        const read = yield* Effect.all(
          [
            ctx.api.request(account.value, "GET", CATALOG, modelCatalogSchema),
            ctx.api.request(
              account.value,
              "GET",
              `${profilesPath(workspace)}?view=profiles&after=`,
              profilePageSchema
            ),
            this.#readAgents(account.value, workspace),
          ],
          { concurrency: "unbounded" }
        ).pipe(Effect.option);
        if (this.#shown.get(key) !== shown) return;
        if (Option.isNone(read)) shown.error = true;
        else {
          const [catalog, page, agents] = read.value;
          Object.assign(shown, {
            catalog: catalog as ModelCatalog,
            profiles: page.accounts as ModelProfile[],
            next: page.next,
            agents,
            error: false,
          });
        }
        this.#publish(key, shown);
      }).pipe(
        Effect.ensuring(
          Effect.suspend(() => {
            shown.reading = null;
            return Deferred.succeed(reading, undefined);
          })
        )
      );
    });
  }

  /** The first page of profiles again, on every page of the workspace. */
  /** The profiles again on every page of the workspace (a sign-in elsewhere added one); a failed read leaves them. */
  reloadProfiles(workspace: string): Effect.Effect<void> {
    return this.#reloadProfiles(workspace).pipe(Effect.ignore);
  }

  #reloadProfiles(workspace: string): Effect.Effect<void, CoreError> {
    return this.#send(
      "GET",
      `${profilesPath(workspace)}?view=profiles&after=`,
      profilePageSchema
    ).pipe(
      Effect.tap((page) =>
        Effect.sync(() =>
          this.#each(workspace, (s) => {
            s.profiles = page.accounts as ModelProfile[];
            s.next = page.next;
          })
        )
      ),
      Effect.asVoid
    );
  }

  /** A change refused as a conflict (the profile changed elsewhere) reads the profiles again before it fails. */
  #reloadOnConflict(workspace: string) {
    return <A>(effect: Effect.Effect<A, CoreError>) =>
      effect.pipe(
        Effect.tapError((e) =>
          e.code === "conflict"
            ? this.#reloadProfiles(workspace).pipe(Effect.ignore)
            : Effect.void
        )
      );
  }

  /**
   * A change to a profile. A profile's changes go one at a time, each with the version the last one answered; an answer
   * shows once no later change waits (a later choice on its way stays on the page). `models`: a choice of its models
   * (shown at once by `patch`), whose failure reads the profiles again whatever the reason.
   */
  #save(
    workspace: string,
    id: string,
    models: boolean,
    patch: () => Record<string, unknown>
  ): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const key = `${workspace}\n${id}`;
      let save = this.#saves.get(key);
      if (!save) {
        save = { lock: Semaphore.makeUnsafe(1), pending: 0, version: undefined };
        this.#saves.set(key, save);
      }
      const slot = save;
      slot.pending += 1;
      const body = patch();
      return slot.lock
        .withPermits(1)(
          Effect.gen({ self: this }, function* () {
            const version = slot.version ?? this.#profile(workspace, id)?.version;
            if (!version)
              return yield* Effect.fail(new CoreError("not_found", "No such profile."));
            const answer = yield* this.#send(
              "PATCH",
              profilePath(workspace, id),
              modelProfileSchema,
              { version, ...body }
            ).pipe(Effect.result);
            if (Result.isSuccess(answer)) {
              slot.version = answer.success.version;
              if (slot.pending === 1) this.#replace(workspace, answer.success);
              return null;
            }
            slot.version = undefined;
            if (models || answer.failure.code === "conflict")
              yield* this.#reloadProfiles(workspace).pipe(Effect.ignore);
            return yield* Effect.fail(answer.failure);
          })
        )
        .pipe(
          Effect.ensuring(
            Effect.sync(() => {
              slot.pending -= 1;
              if (slot.pending === 0 && this.#saves.get(key) === slot)
                this.#saves.delete(key);
            })
          )
        );
    });
  }

  #resetQuota(workspace: string, id: string): Effect.Effect<QuotaReset, CoreError> {
    return Effect.suspend(() => {
      const account = this.#ctx.session.current();
      if (!account)
        return Effect.fail(new CoreError("signed_out", "No one is signed in."));
      const profile = this.#profile(workspace, id);
      if (!profile) return Effect.fail(new CoreError("not_found", "No such profile."));
      const slot = resetKey(workspace, id, profile.version);
      // A reset whose outcome is not known yet is asked again with the same id: the provider redeems one credit at most.
      const requestId =
        profile.reset_attempt?.outcome === "pending"
          ? profile.reset_attempt.request_id
          : (account.meta<string>(slot) ?? this.#requestId());
      account.setMeta(slot, requestId);
      return this.#send(
        "POST",
        `${profilePath(workspace, id)}/quota/reset`,
        quotaResetSchema,
        { version: profile.version, request_id: requestId }
      ).pipe(
        Effect.tap((answer) =>
          Effect.sync(() => {
            account.setMeta(slot, null);
            this.#replace(workspace, answer.account);
          })
        ),
        Effect.tapError((e) =>
          Effect.suspend(() => {
            // An answered refusal ran nothing: the next reset is a new one.
            if (e.status !== undefined && e.status >= 400 && e.status < 500)
              account.setMeta(slot, null);
            // The profile changed, or another reset holds it: show what holds now.
            return e.status === 409
              ? this.#reloadProfiles(workspace).pipe(Effect.ignore)
              : Effect.void;
          })
        ),
        Effect.map(
          (answer): QuotaReset => ({
            outcome: answer.outcome,
            quota_refreshed: answer.quota_refreshed,
          })
        )
      );
    });
  }

  #createProfile(
    workspace: string,
    input: {
      source: string;
      name: string | undefined;
      apiKey: string | undefined;
      baseUrl: string | undefined;
      protocol: string | undefined;
      discover: boolean;
    }
  ): Effect.Effect<ModelProfile, CoreError> {
    return Effect.gen({ self: this }, function* () {
      // An endpoint outside the catalog lists its models first; the profile serves those ids.
      let listed: string[] | undefined;
      if (input.discover) {
        const found = yield* this.#send(
          "POST",
          route`/v1/comma/workspaces/${workspace}/model-discovery`,
          discoveredModelsSchema,
          {
            base_url: input.baseUrl,
            protocol: input.protocol,
            ...(input.apiKey ? { api_key: input.apiKey } : {}),
          }
        );
        listed = listedIds(found.data);
        if (!listed.length)
          return yield* Effect.fail(
            new CoreError("no_models", "The endpoint lists no models.")
          );
      }
      const created = (yield* this.#send(
        "POST",
        profilesPath(workspace),
        modelProfileSchema,
        {
          credential_kind: "provider_api_key",
          source: input.source,
          ...(input.apiKey ? { api_key: input.apiKey } : {}),
          ...(input.name ? { name: input.name } : {}),
          ...(input.baseUrl ? { base_url: input.baseUrl } : {}),
          ...(input.protocol ? { protocol: input.protocol } : {}),
          ...(listed ? { models: listed } : {}),
        }
      )) as ModelProfile;
      this.#each(workspace, (s) => {
        s.profiles = [...(s.profiles ?? []), created];
      });
      return created;
    });
  }

  #patchAgent(workspace: string, agent: string, patch: Partial<SettingsAgent>): void {
    this.#each(workspace, (s) => {
      if (!s.agents) return;
      const { router } = s.agents.agents;
      s.agents = {
        ...s.agents,
        agents: {
          router: router.agent_id === agent ? { ...router, ...patch } : router,
        },
      };
    });
  }

  #showTaskModel(workspace: string, selection: TaskModelSelection): void {
    this.#each(workspace, (s) => {
      if (s.agents) s.agents = { ...s.agents, task_model: { selection } };
    });
  }

  #showTaskPlace(workspace: string, place: TaskPlace): void {
    this.#each(workspace, (s) => {
      if (s.agents) s.agents = { ...s.agents, task_place: { place } };
    });
  }

  /** Shown at once; saves for one Agent go in order, so the server ends on the last choice. */
  #setAgentModel(
    workspace: string,
    agent: string,
    selection: AgentSelection
  ): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      this.#patchAgent(workspace, agent, { selection });
      const key = `${workspace}\n${agent}`;
      let lock = this.#agentSaves.get(key);
      if (!lock) {
        lock = Semaphore.makeUnsafe(1);
        this.#agentSaves.set(key, lock);
      }
      return lock.withPermits(1)(
        this.#send("PUT", `${agentPath(workspace, agent)}/model`, z.unknown(), {
          selection,
        }).pipe(
          // A success is what the server holds now, even after an earlier failure read the Agents again.
          Effect.tap(() =>
            Effect.sync(() => this.#patchAgent(workspace, agent, { selection }))
          ),
          Effect.tapError(() => this.#reloadAgents(workspace)),
          Effect.as(null)
        )
      );
    });
  }

  /** The default Task model: shown at once, saved in order per workspace. */
  #setTaskModel(
    workspace: string,
    selection: TaskModelSelection
  ): Effect.Effect<null, CoreError> {
    return this.#saveInOrder(
      this.#taskModelSaves,
      workspace,
      () => this.#showTaskModel(workspace, selection),
      this.#send("PUT", taskModelPath(workspace), taskModelSchema, { selection }),
      (saved) => this.#showTaskModel(workspace, saved.selection as TaskModelSelection)
    );
  }

  /** The default place to run Tasks: shown at once, saved in order per workspace. */
  #setTaskPlace(workspace: string, place: TaskPlace): Effect.Effect<null, CoreError> {
    return this.#saveInOrder(
      this.#taskPlaceSaves,
      workspace,
      () => this.#showTaskPlace(workspace, place),
      this.#send("PUT", taskPlacePath(workspace), taskPlaceSchema, { place }),
      (saved) => this.#showTaskPlace(workspace, saved.place as TaskPlace)
    );
  }

  /** How the Router writes: shown at once, saved in order per workspace; a failure reads the Router again. */
  #setReplyStyle(workspace: string, style: ReplyStyle): Effect.Effect<null, CoreError> {
    return this.#saveInOrder(
      this.#replyStyleSaves,
      workspace,
      () => this.#showReplyStyle(workspace, style),
      this.#send(
        "PUT",
        replyStylePath(workspace),
        z.object({ reply_style: replyStyleSchema }),
        { reply_style: style }
      ).pipe(Effect.tapError(() => this.#rereadRouter(workspace))),
      (saved) => this.#showReplyStyle(workspace, saved.reply_style)
    );
  }

  #showReplyStyle(workspace: string, style: ReplyStyle): void {
    this.#each(workspace, (s) => {
      if (s.agents)
        s.agents = {
          ...s.agents,
          agents: { router: { ...s.agents.agents.router, reply_style: style } },
        };
    });
    for (const topic of this.#ctx.kernel.store.liveTopics()) {
      if (topic.topic !== "router" || topic.workspace !== workspace) continue;
      const shown = this.#router.get(routerKey(topic));
      if (!shown) continue;
      this.#router.set(routerKey(topic), { ...shown, reply_style: style });
      this.#ctx.kernel.store.invalidate(topic);
    }
  }

  /** Every shown Router of the workspace read again; a failed read leaves what it showed. */
  #rereadRouter(workspace: string): Effect.Effect<void> {
    return Effect.forEach(
      this.#ctx.kernel.store
        .liveTopics()
        .filter((topic) => topic.topic === "router" && topic.workspace === workspace),
      (topic) => this.#readRouter(topic),
      { discard: true }
    );
  }

  /**
   * A workspace setting: `show` at once; saves for one workspace go in order, so the server ends on the last choice.
   * What the server stored shows (`stored`) once no later choice waits; a failure reads the Agents again.
   */
  #saveInOrder<A>(
    saves: Map<string, OrderedSaves>,
    workspace: string,
    show: () => void,
    put: Effect.Effect<A, CoreError>,
    stored: (saved: A) => void
  ): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      show();
      let save = saves.get(workspace);
      if (!save) {
        save = { lock: Semaphore.makeUnsafe(1), pending: 0 };
        saves.set(workspace, save);
      }
      const slot = save;
      slot.pending += 1;
      return slot.lock
        .withPermits(1)(
          put.pipe(
            // A success is what the server holds now, even after an earlier failure read the Agents again.
            Effect.tap((saved) =>
              Effect.sync(() => {
                if (slot.pending === 1) stored(saved);
              })
            ),
            Effect.tapError(() => this.#reloadAgents(workspace)),
            Effect.as(null)
          )
        )
        .pipe(
          Effect.ensuring(
            Effect.sync(() => {
              slot.pending -= 1;
              if (slot.pending === 0 && saves.get(workspace) === slot)
                saves.delete(workspace);
            })
          )
        );
    });
  }

  /** The Agents again on every page of the workspace; a failed read leaves them. */
  #reloadAgents(workspace: string): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account) || !this.#workspacesShown().includes(workspace))
        return;
      const agents = yield* this.#readAgents(account.value, workspace).pipe(
        Effect.option
      );
      if (Option.isNone(agents)) return;
      this.#each(workspace, (s) => {
        s.agents = agents.value;
      });
    });
  }

  #renameAgent(
    workspace: string,
    given: string | undefined,
    name: string
  ): Effect.Effect<null, CoreError> {
    return Effect.gen({ self: this }, function* () {
      let agent = given ?? this.#routers.get(workspace);
      if (!agent) {
        const account = yield* this.#ctx.session.account();
        agent = (yield* this.#readAgents(account, workspace)).agents.router.agent_id;
      }
      yield* this.#send("PATCH", agentPath(workspace, agent), z.unknown(), { name });
      this.#patchAgent(workspace, agent, { name });
      if (agent === this.#routers.get(workspace)) {
        this.#renames.set(workspace, (this.#renames.get(workspace) ?? 0) + 1);
        for (const topic of this.#ctx.kernel.store.liveTopics()) {
          if (topic.topic !== "router" || topic.workspace !== workspace) continue;
          this.#router.set(routerKey(topic), {
            ...this.#router.get(routerKey(topic)),
            agent,
            name,
          });
          this.#ctx.kernel.store.invalidate(topic);
        }
      }
      return null;
    });
  }

  /** Asks about a device-code sign-in at the interval the server says, until it is done or expires. */
  #waitSignIn(workspace: string, id: string): Effect.Effect<ModelProfile, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const attempt = this.#signIns.get(id);
      if (!attempt || attempt.workspace !== workspace)
        return yield* Effect.fail(CoreError.invalid("no such sign-in"));
      let interval = attempt.interval;
      for (;;) {
        yield* Effect.sleep(interval * 1000);
        if (this.#ctx.now() >= attempt.expiresAt) {
          this.#signIns.delete(id);
          return yield* Effect.fail(
            new CoreError("authorization_expired", "The sign-in expired.")
          );
        }
        const answer = yield* this.#send(
          "POST",
          `${signInPath(workspace)}/${encodeURIComponent(id)}`,
          signInPollSchema,
          { code: "" }
        ).pipe(Effect.tapError(() => Effect.sync(() => this.#signIns.delete(id))));
        if ("id" in answer) {
          this.#signIns.delete(id);
          yield* this.#reloadProfiles(workspace).pipe(Effect.ignore);
          return answer as ModelProfile;
        }
        interval = answer.interval;
      }
    });
  }

  #readRouter(topic: Topic): Effect.Effect<void> {
    const key = routerKey(topic);
    const workspace = String(topic.workspace ?? "");
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account) || !workspace) return;
      const renames = this.#renames.get(workspace) ?? 0;
      const agents = yield* this.#readAgents(account.value, workspace).pipe(
        Effect.option
      );
      // A failed read leaves the label the UI had.
      if (Option.isNone(agents) || (this.#renames.get(workspace) ?? 0) !== renames)
        return;
      const { router } = agents.value.agents;
      this.#router.set(key, {
        agent: router.agent_id,
        name: router.name,
        // Left out when a server older than the setting does not say.
        ...(router.reply_style ? { reply_style: router.reply_style } : {}),
      });
      this.#ctx.kernel.store.invalidate(topic);
    });
  }
}

const routerKey = (topic: Topic) => `${topic.workspace ?? ""}\n${topic.read ?? ""}`;
