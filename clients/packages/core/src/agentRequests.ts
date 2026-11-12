// An Agent's requests to a person in a Conversation (`/v1/comma/groups/:g/conversations/:c/requests*`): the Capability
// Requests its Agent raised there, for the app's request cards. The server owns each one's status and outcome (the
// first decision wins); the core only shows them and passes a person's decline on. Connecting an account ends its
// request on the server, when the provider's callback verifies it.
//
// `agentLocationRequests` is what an open phone answers on its own: the pending location requests the person's own
// messages led to, in every Group, without their coordinates.
//
// Bounds: one stream per shown Conversation (an `agentRequests` topic while a surface shows it) and one for
// `agentLocationRequests` while the app is open, each opened again after 1 s, 5 s, then every 30 s while it fails; a
// snapshot holds at most what one Group listing returns (100), and at most 20 location requests.
import { lazySchema } from "@comma/chat-contract";
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import type {
  AgentRequest,
  AgentRequestInput,
  AgentLocationRequestsValue,
  AgentRequestsValue,
} from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import { readEvents } from "./sse.ts";

const eventsPath = (group: string, conversation: string) =>
  route`/v1/comma/groups/${group}/conversations/${conversation}/requests/events`;
const declinePath = (group: string, conversation: string, request: string) =>
  route`/v1/comma/groups/${group}/conversations/${conversation}/requests/${request}/decline`;
const fillPath = (group: string, conversation: string, request: string) =>
  route`/v1/comma/groups/${group}/conversations/${conversation}/requests/${request}/input`;
const locationPath = (group: string, conversation: string, request: string) =>
  route`/v1/comma/groups/${group}/conversations/${conversation}/requests/${request}/location`;
const decidePath = (group: string, conversation: string, request: string) =>
  route`/v1/comma/groups/${group}/conversations/${conversation}/requests/${request}/decision`;

const LOCATION_EVENTS_PATH = route`/v1/comma/location-requests/events`;

const RETRY_MS = [1_000, 5_000, 30_000];

const text = lazySchema(() => z.string().max(4_096));
// A page it opens in the system browser: only https.
const httpsPage = lazySchema(() =>
  z
    .string()
    .max(8_192)
    .refine((url) => url.startsWith("https://"))
    .optional()
    .catch(undefined)
);

/** A request as the server projects it; one the app cannot draw is left out. */
const requestSchema = lazySchema(() =>
  z.object({
    id: z.string().min(1).max(512),
    type: z.literal("oauth_authorization"),
    status: z.enum(["pending", "completed", "expired", "cancelled", "failed"]),
    outcome: z.enum(["connected", "declined"]).nullish(),
    expires_at: z.number().int().nullish(),
    created_at: z.number().int().nullish(),
    source_message_id: z.string().max(512).nullish(),
    oauth: z.object({
      provider: text,
      alias: text,
      reason: z.string().max(4_000),
      scopes: z.array(text).max(64).default([]),
      authorization_url: httpsPage,
      account: text.optional(),
      label: text.optional(),
      // One it cannot draw is left out: the card then offers the page, if there is one.
      input: z
        .discriminatedUnion("kind", [
          z.object({
            kind: z.literal("secret"),
            label: text.optional(),
            help_url: httpsPage,
          }),
          z.object({
            kind: z.literal("app"),
            help_url: httpsPage,
            redirect_uri: text.optional(),
          }),
          z.object({ kind: z.literal("device"), code: text }),
          z.object({ kind: z.literal("open") }),
          z.object({ kind: z.literal("paste") }),
        ])
        .optional()
        .catch(undefined),
    }),
  })
);

const locationRequestSchema = lazySchema(() =>
  z.object({
    id: z.string().min(1).max(512),
    type: z.literal("location"),
    status: z.enum(["pending", "completed", "expired", "cancelled", "failed"]),
    outcome: z.enum(["shared", "declined"]).nullish(),
    expires_at: z.number().int().nullish(),
    created_at: z.number().int().nullish(),
    source_message_id: z.string().max(512).nullish(),
    location: z.object({ reason: z.string().max(4_000) }),
  })
);

/** A location request as an open phone answers it: where it is, and whether it still waits. */
const ownLocationRequestSchema = lazySchema(() =>
  z.object({
    id: z.string().min(1).max(512),
    status: z.enum(["pending", "completed", "expired", "cancelled", "failed"]),
    group_id: z.string().min(1).max(512),
    conversation_id: z.string().min(1).max(512),
  })
);

/** A phone's consent: an Agent asks to use a person's phone in the Conversation. */
const phoneSchema = lazySchema(() =>
  z.object({
    id: z.string().min(1).max(512),
    type: z.literal("computer_use_start"),
    status: z.enum(["pending", "completed", "expired", "cancelled", "failed"]),
    outcome: z.enum(["allowed", "denied"]).nullish(),
    expires_at: z.number().int().nullish(),
    created_at: z.number().int().nullish(),
    source_message_id: z.string().max(512).nullish(),
    phone: z.object({
      title: text.nullish(),
      target: text.nullish(),
      device_id: text.nullish(),
    }),
  })
);

/** A Router's ask to install a plugin. */
const pluginSchema = lazySchema(() =>
  z.object({
    id: z.string().min(1).max(512),
    type: z.literal("plugin_install"),
    status: z.enum(["pending", "completed", "expired", "cancelled", "failed"]),
    outcome: z.enum(["installed", "declined"]).nullish(),
    expires_at: z.number().int().nullish(),
    created_at: z.number().int().nullish(),
    source_message_id: z.string().max(512).nullish(),
    plugin: z.object({
      id: text,
      name: text,
      reason: z.string().max(4_000),
      brand: text.nullish(),
      workspace_id: text,
    }),
  })
);

const snapshotSchema = lazySchema(() =>
  z.object({ data: z.array(z.unknown()).max(500) })
);

function decodeInput(
  input: NonNullable<z.infer<typeof requestSchema>["oauth"]["input"]>
): AgentRequestInput {
  if (input.kind === "device") return { kind: "device", code: input.code };
  if (input.kind === "open" || input.kind === "paste") return { kind: input.kind };
  const helpUrl = input.help_url ? { helpUrl: input.help_url } : {};
  return input.kind === "secret"
    ? { kind: "secret", ...(input.label ? { label: input.label } : {}), ...helpUrl }
    : {
        kind: "app",
        ...helpUrl,
        ...(input.redirect_uri ? { redirectUri: input.redirect_uri } : {}),
      };
}

function decode(raw: unknown): AgentRequest | undefined {
  const location = locationRequestSchema.safeParse(raw);
  if (location.success) {
    const r = location.data;
    return {
      id: r.id,
      type: r.type,
      status: r.status,
      outcome: r.outcome ?? null,
      expiresAt: r.expires_at == null ? null : r.expires_at * 1000,
      createdAt: r.created_at == null ? null : r.created_at * 1000,
      sourceMessageId: r.source_message_id ?? null,
      location: { reason: r.location.reason },
    };
  }
  const phone = phoneSchema.safeParse(raw);
  if (phone.success) {
    const r = phone.data;
    return {
      id: r.id,
      type: r.type,
      status: r.status,
      outcome: r.outcome ?? null,
      expiresAt: r.expires_at == null ? null : r.expires_at * 1000,
      createdAt: r.created_at == null ? null : r.created_at * 1000,
      sourceMessageId: r.source_message_id ?? null,
      phone: {
        title: r.phone.title ?? "",
        target: r.phone.target ?? "",
        deviceId: r.phone.device_id ?? "",
      },
    };
  }
  const plugin = pluginSchema.safeParse(raw);
  if (plugin.success) {
    const r = plugin.data;
    return {
      id: r.id,
      type: r.type,
      status: r.status,
      outcome: r.outcome ?? null,
      expiresAt: r.expires_at == null ? null : r.expires_at * 1000,
      createdAt: r.created_at == null ? null : r.created_at * 1000,
      sourceMessageId: r.source_message_id ?? null,
      plugin: {
        id: r.plugin.id,
        name: r.plugin.name,
        reason: r.plugin.reason,
        brand: r.plugin.brand ?? null,
        workspace: r.plugin.workspace_id,
      },
    };
  }
  const parsed = requestSchema.safeParse(raw);
  if (!parsed.success) return undefined;
  const r = parsed.data;
  return {
    id: r.id,
    type: r.type,
    status: r.status,
    outcome: r.outcome ?? null,
    expiresAt: r.expires_at == null ? null : r.expires_at * 1000,
    createdAt: r.created_at == null ? null : r.created_at * 1000,
    sourceMessageId: r.source_message_id ?? null,
    oauth: {
      provider: r.oauth.provider,
      alias: r.oauth.alias,
      reason: r.oauth.reason,
      scopes: r.oauth.scopes,
      ...(r.oauth.authorization_url
        ? { authorizationUrl: r.oauth.authorization_url }
        : {}),
      ...(r.oauth.account ? { account: r.oauth.account } : {}),
      ...(r.oauth.label ? { label: r.oauth.label } : {}),
      ...(r.oauth.input ? { input: decodeInput(r.oauth.input) } : {}),
    },
  };
}

const keyOf = (group: string, conversation: string) => `${group}\u0000${conversation}`;

export class AgentRequests {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** Conversation → its requests, newest first, as the server last said. */
  readonly #state = new Map<string, AgentRequestsValue>();
  #own: AgentLocationRequestsValue = { requests: [] };
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("agentRequests", {
      start: (topic) => this.#live.run(topic, this.#follow(topic)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({
        ok: this.#state.get(
          keyOf(topic.group as string, topic.conversation as string)
        ) ?? {
          requests: [],
          loading: true,
          error: false,
        },
      }),
    });
    kernel.source("agentLocationRequests", {
      start: (topic) => this.#live.run(topic, this.#followOwn()),
      stop: (topic) => this.#live.stop(topic),
      compute: (): Value => ({ ok: this.#own }),
    });
    // Another account sees none of this one's requests.
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#state.clear();
      this.#own = { requests: [] };
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic === "agentLocationRequests") {
          this.#live.stop(topic);
          kernel.store.invalidate(topic);
          this.#live.run(topic, this.#followOwn());
        } else if (topic.topic === "agentRequests") {
          this.#live.stop(topic);
          kernel.store.invalidate(topic);
          this.#live.run(topic, this.#follow(topic));
        }
      }
    });

    kernel.calls({
      "agentRequests.decline": {
        doing: true,
        run: (p) => {
          const group = param(p, "group");
          const conversation = param(p, "conversation");
          const request = param(p, "request");
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                declinePath(group, conversation, request),
                z.unknown()
              )
            ),
            Effect.tap((raw) =>
              Effect.sync(() => {
                const settled = decode(raw);
                if (settled) this.#upsert(group, conversation, settled);
              })
            ),
            Effect.as(null)
          );
        },
      },
      "agentRequests.decide": {
        doing: true,
        run: (p) => {
          const group = param(p, "group");
          const conversation = param(p, "conversation");
          const request = param(p, "request");
          const approved = (p as { approved?: unknown }).approved;
          if (typeof approved !== "boolean")
            throw CoreError.invalid("approved is required");
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                decidePath(group, conversation, request),
                z.unknown(),
                { approved }
              )
            ),
            Effect.tap((raw) =>
              Effect.sync(() => {
                const decided = decode(raw);
                if (decided) this.#upsert(group, conversation, decided);
              })
            ),
            Effect.as(null)
          );
        },
      },
      // Not `doing`: that list would keep what was filled in.
      "agentRequests.fill": {
        run: (p) => {
          const group = param(p, "group");
          const conversation = param(p, "conversation");
          const request = param(p, "request");
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                fillPath(group, conversation, request),
                z.unknown(),
                (p as { values: unknown }).values
              )
            ),
            Effect.tap((raw) =>
              Effect.sync(() => {
                const answered = decode(raw);
                if (answered) this.#upsert(group, conversation, answered);
              })
            ),
            Effect.as(null)
          );
        },
      },
      // Not `doing`: that list would keep the position.
      "agentRequests.shareLocation": {
        run: (p) => {
          const group = param(p, "group");
          const conversation = param(p, "conversation");
          const request = param(p, "request");
          const { latitude, longitude, accuracy } = p as {
            latitude: number;
            longitude: number;
            accuracy?: number;
          };
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                locationPath(group, conversation, request),
                z.unknown(),
                {
                  latitude,
                  longitude,
                  ...(accuracy === undefined ? {} : { accuracy_m: accuracy }),
                }
              )
            ),
            Effect.tap((raw) =>
              Effect.sync(() => {
                const shared = decode(raw);
                if (shared) this.#upsert(group, conversation, shared);
              })
            ),
            Effect.as(null)
          );
        },
      },
    });
  }

  /** The Conversation's requests while it is shown: a snapshot, then each change; a lost stream opens again. */
  #follow(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const group = topic.group as string;
    const conversation = topic.conversation as string;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      let backoff = 0;
      const once = Effect.scoped(
        Effect.gen({ self: this }, function* () {
          const body = yield* ctx.api.stream(
            account.value,
            eventsPath(group, conversation)
          );
          yield* readEvents(body, (value, event) =>
            Effect.sync(() => {
              backoff = 0;
              if (event === "snapshot") {
                const snapshot = snapshotSchema.safeParse(value);
                if (snapshot.success)
                  this.#replace(group, conversation, snapshot.data.data);
              } else if (event === "request") {
                const request = decode(value);
                if (request) this.#upsert(group, conversation, request);
              }
            })
          );
        })
      );
      for (;;) {
        const result = yield* Effect.result(once);
        if (account.value.closed) return;
        if (Result.isFailure(result)) this.#failed(group, conversation);
        // A stream the server ends at once waits too: it must not spin.
        yield* Effect.sleep(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]!);
        backoff++;
      }
    });
  }

  /** The person's own pending location requests while the app is open; a lost stream opens again. */
  #followOwn(): Effect.Effect<void> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      let backoff = 0;
      const once = Effect.scoped(
        Effect.gen({ self: this }, function* () {
          const body = yield* ctx.api.stream(account.value, LOCATION_EVENTS_PATH);
          yield* readEvents(body, (value, event) =>
            Effect.sync(() => {
              backoff = 0;
              if (event === "snapshot") {
                const snapshot = snapshotSchema.safeParse(value);
                if (!snapshot.success) return;
                this.#setOwn(
                  snapshot.data.data.flatMap((item) => {
                    const own = ownLocationRequestSchema.safeParse(item);
                    return own.success && own.data.status === "pending"
                      ? [ownRequest(own.data)]
                      : [];
                  })
                );
              } else if (event === "request") {
                const own = ownLocationRequestSchema.safeParse(value);
                if (!own.success) return;
                const others = this.#own.requests.filter((r) => r.id !== own.data.id);
                this.#setOwn(
                  own.data.status === "pending"
                    ? [ownRequest(own.data), ...others]
                    : others
                );
              }
            })
          );
        })
      );
      for (;;) {
        yield* Effect.result(once);
        if (account.value.closed) return;
        // A stream the server ends at once waits too: it must not spin.
        yield* Effect.sleep(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]!);
        backoff++;
      }
    });
  }

  #setOwn(requests: AgentLocationRequestsValue["requests"]): void {
    this.#own = { requests };
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "agentLocationRequests") store.invalidate(topic);
  }

  #replace(group: string, conversation: string, raw: readonly unknown[]): void {
    const requests = raw.flatMap((item) => decode(item) ?? []);
    this.#set(group, conversation, { requests, loading: false, error: false });
  }

  #upsert(group: string, conversation: string, request: AgentRequest): void {
    const current = this.#state.get(keyOf(group, conversation));
    const others = (current?.requests ?? []).filter((r) => r.id !== request.id);
    this.#set(group, conversation, {
      requests: [request, ...others],
      loading: false,
      error: current?.error ?? false,
    });
  }

  #failed(group: string, conversation: string): void {
    const current = this.#state.get(keyOf(group, conversation));
    this.#set(group, conversation, {
      requests: current?.requests ?? [],
      loading: false,
      error: true,
    });
  }

  #set(group: string, conversation: string, value: AgentRequestsValue): void {
    this.#state.set(keyOf(group, conversation), value);
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (
        topic.topic === "agentRequests" &&
        topic.group === group &&
        topic.conversation === conversation
      )
        store.invalidate(topic);
  }
}

function ownRequest(
  own: z.infer<typeof ownLocationRequestSchema>
): AgentLocationRequestsValue["requests"][number] {
  return { id: own.id, group: own.group_id, conversation: own.conversation_id };
}

function param(raw: unknown, name: string): string {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > 512)
    throw CoreError.invalid(`${name} is required`);
  return v;
}
