// An Agent's requests to a person in a Conversation (`/v1/comma/groups/:g/conversations/:c/requests*`): the Capability
// Requests its Agent raised there, for the app's request cards. The server owns each one's status and outcome (the
// first decision wins); the core only shows them and passes a person's decline on. Connecting an account ends its
// request on the server, when the provider's callback verifies it.
//
// Bounds: one stream per shown Conversation (an `agentRequests` topic while a surface shows it), each opened again
// after 1 s, 5 s, then every 30 s while it fails; a snapshot holds at most what one Group listing returns (100).
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import type { AgentRequest, AgentRequestsValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import { readEvents } from "./sse.ts";

const eventsPath = (group: string, conversation: string) =>
  route`/v1/comma/groups/${group}/conversations/${conversation}/requests/events`;
const declinePath = (group: string, conversation: string, request: string) =>
  route`/v1/comma/groups/${group}/conversations/${conversation}/requests/${request}/decline`;

const RETRY_MS = [1_000, 5_000, 30_000];

const text = z.string().max(4_096);

/** A request as the server projects it; one the app cannot draw is left out. */
const requestSchema = z.object({
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
    // It opens in the system browser: only an https page.
    authorization_url: z
      .string()
      .max(8_192)
      .refine((url) => url.startsWith("https://"))
      .optional()
      .catch(undefined),
    account: text.optional(),
  }),
});

const snapshotSchema = z.object({ data: z.array(z.unknown()).max(500) });

function decode(raw: unknown): AgentRequest | undefined {
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
    },
  };
}

const keyOf = (group: string, conversation: string) => `${group}\u0000${conversation}`;

export class AgentRequests {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** Conversation → its requests, newest first, as the server last said. */
  readonly #state = new Map<string, AgentRequestsValue>();
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
    // Another account sees none of this one's requests.
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#state.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "agentRequests") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#follow(topic));
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

function param(raw: unknown, name: string): string {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > 512)
    throw CoreError.invalid(`${name} is required`);
  return v;
}
