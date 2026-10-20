// Routines: a workspace's daily briefing (the recommendations envelope) as Home's rail and Settings show it, the
// refresh a person asks for, the briefing's settings, and the owner's automatic proactive messages.
//
// While a surface shows the briefing the core reads it, then again:
// - every 2 s while the server runs a generation (a read that fails is tried again every 2 s, at most 45 times in a
//   row; after that the projection is called unavailable),
// - every 1.5 s while the sources are still being discovered or a first briefing is being prepared, at most 10 times
//   per showing,
// - shortly after the next daily delivery instant (on the schedule's own clock), and
// - when a window comes back after a minute or more (`recommendations.revisit`).
// A language change is another topic (`locale`), so it reads at once.
//
// Bounds: one read in flight per showing; the reads above; a refresh is one request.
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import {
  recommendationEnvelopeSchema,
  type RecommendationEnvelope,
} from "@comma/recommendation-contract";
import { DateTime, Effect, Option, Result, Semaphore } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import type { ProactiveValue, RecommendationsValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const RUN_POLL_MS = 2_000;
const DISCOVERY_MS = 1_500;
const MAX_DISCOVERY = 10;
const REVISIT_MS = 60_000;
/** The scheduled run takes about a minute; one read this long after the delivery instant picks it up. */
export const DELIVERY_GRACE_MS = 120_000;

const recommendationsPath = (ws: string) =>
  route`/v1/comma/workspaces/${ws}/recommendations`;
const proactivePath = (group: string) => route`/v1/comma/groups/${group}/proactive`;

const refreshSchema = z
  .object({ envelope: recommendationEnvelopeSchema })
  .passthrough();
const proactiveSchema = z.object({ enabled: z.boolean() });

/**
 * Milliseconds from `now` until the next daily delivery instant, read on the schedule's own wall clock. `undefined`
 * when the timezone is unknown to this runtime.
 */
export function msUntilDailyDelivery(
  schedule: { hour: number; minute: number; timezone: string },
  now: number
): number | undefined {
  const dayMs = 86_400_000;
  try {
    const zone = DateTime.zoneMakeNamedUnsafe(schedule.timezone);
    // Wall-clock fields encoded as UTC, only for calendar arithmetic.
    const wallTime = (instant: number) => {
      const parts = DateTime.toParts(
        DateTime.makeZonedUnsafe(instant, { timeZone: zone })
      );
      return Date.UTC(
        parts.year,
        parts.month - 1,
        parts.day,
        parts.hour,
        parts.minute,
        parts.second
      );
    };
    const today = Math.floor(wallTime(now) / dayMs) * dayMs;
    const targetTime = (schedule.hour * 60 + schedule.minute) * 60_000;
    // Three calendar days, with offsets on both sides of a possible DST change: a missing spring-forward time is
    // skipped, a repeated time takes the next future occurrence.
    for (const day of [today, today + dayMs, today + 2 * dayMs]) {
      const target = day + targetTime;
      const offsets = new Set(
        [-dayMs, 0, dayMs].map((shift) => wallTime(target + shift) - (target + shift))
      );
      const candidates = [...offsets]
        .map((offset) => target - offset)
        .filter((instant) => instant > now && wallTime(instant) === target);
      if (candidates.length > 0) return Math.min(...candidates) - now;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

type Shown = {
  workspace: string;
  envelope: RecommendationEnvelope | null;
  failure: "unavailable" | "rate_limited" | null;
  discovering: boolean;
  /** The discovery checks want another read. */
  discoveryWait: boolean;
  refreshing: boolean;
  serverRefreshing: boolean;
  discoveries: number;
  pollFailures: number;
  lastLoadedAt: number;
  generation: number | null;
  reads: Semaphore.Semaphore;
};

const keyOf = (topic: Topic) =>
  `${topic.workspace}\n${topic.timezone ?? ""}\n${topic.locale ?? ""}\n${topic.reads ?? ""}`;

export class Recommendations {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  readonly #shown = new Map<string, Shown>();
  readonly #proactive = new Map<string, ProactiveValue>();
  readonly #proactiveLive: Live;
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    this.#proactiveLive = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("recommendations", {
      start: (topic) => {
        this.#shown.set(keyOf(topic), Recommendations.#empty(String(topic.workspace)));
        this.#live.run(topic, this.#keep(topic, true));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(keyOf(topic));
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    kernel.source("proactive", {
      start: (topic) => this.#proactiveLive.run(topic, this.#readProactive(topic)),
      stop: (topic) => {
        this.#proactiveLive.stop(topic);
        this.#proactive.delete(String(topic.prefer ?? ""));
      },
      compute: (topic): Value => ({
        ok: this.#proactive.get(String(topic.prefer ?? "")) ?? { kind: "loading" },
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic === "recommendations") {
          this.#live.stop(topic);
          this.#shown.set(
            keyOf(topic),
            Recommendations.#empty(String(topic.workspace))
          );
          kernel.store.invalidate(topic);
          this.#live.run(topic, this.#keep(topic, true));
        } else if (topic.topic === "proactive") {
          this.#proactiveLive.stop(topic);
          this.#proactive.delete(String(topic.prefer ?? ""));
          kernel.store.invalidate(topic);
          this.#proactiveLive.run(topic, this.#readProactive(topic));
        }
      }
    });

    kernel.calls({
      "recommendations.revisit": {
        run: () =>
          Effect.sync(() => {
            const now = ctx.now();
            for (const topic of this.#topics()) {
              const shown = this.#shown.get(keyOf(topic));
              if (!shown || now - shown.lastLoadedAt < REVISIT_MS) continue;
              this.#restart(topic, true);
            }
            return null;
          }),
      },
      // Creates the Routines (on `timezone`): the server then generates the first briefing by itself.
      "recommendations.start": {
        run: (p) => {
          const { workspace, timezone } = (p ?? {}) as {
            workspace?: unknown;
            timezone?: unknown;
          };
          if (typeof workspace !== "string" || !workspace)
            throw CoreError.invalid("workspace is required");
          const query =
            typeof timezone === "string" && timezone
              ? `?${new URLSearchParams({ timezone })}`
              : "";
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "GET",
                `${recommendationsPath(workspace)}${query}`,
                recommendationEnvelopeSchema
              )
            ),
            Effect.as(null)
          );
        },
      },
      // Home shown again: discovery checks start over, and the briefing is read at once.
      "recommendations.visit": {
        run: (p) =>
          Effect.sync(() => {
            const workspace = (p as { workspace?: unknown } | null)?.workspace;
            for (const topic of this.#topics(
              typeof workspace === "string" ? workspace : undefined
            )) {
              const shown = this.#shown.get(keyOf(topic));
              if (!shown) continue;
              shown.discoveries = 0;
              this.#restart(topic, true);
            }
            return null;
          }),
      },
      "recommendations.refresh": {
        doing: true,
        run: (p) => {
          const workspace = (p as { workspace?: unknown } | null)?.workspace;
          if (typeof workspace !== "string" || !workspace)
            throw CoreError.invalid("workspace is required");
          return this.#refresh(workspace);
        },
      },
      "recommendations.updateSettings": {
        doing: true,
        run: (p) => {
          const raw = p as { workspace?: unknown; patch?: unknown } | null;
          if (
            typeof raw?.workspace !== "string" ||
            !raw.workspace ||
            typeof raw.patch !== "object" ||
            !raw.patch
          )
            throw CoreError.invalid("workspace and patch are required");
          const workspace = raw.workspace;
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "PATCH",
                `${recommendationsPath(workspace)}/settings`,
                recommendationEnvelopeSchema,
                raw.patch
              )
            ),
            Effect.tap((envelope) =>
              Effect.sync(() => this.#adopt(workspace, envelope))
            ),
            Effect.as(null)
          );
        },
      },
      "proactive.set": {
        doing: true,
        run: (p) => {
          const raw = p as { prefer?: unknown; enabled?: unknown } | null;
          if (typeof raw?.enabled !== "boolean")
            throw CoreError.invalid("enabled is required");
          const prefer = typeof raw.prefer === "string" ? raw.prefer : "";
          const enabled = raw.enabled;
          return Effect.suspend(() => {
            const shown = this.#proactive.get(prefer);
            if (shown?.kind !== "ready")
              return Effect.fail(CoreError.invalid("not ready"));
            const group = shown.groupId;
            return ctx.session.account().pipe(
              Effect.flatMap((account) =>
                ctx.api.request(account, "PUT", proactivePath(group), proactiveSchema, {
                  enabled,
                  request_id: this.#requestId(),
                })
              ),
              Effect.tap((saved) =>
                Effect.sync(() => {
                  this.#proactive.set(prefer, {
                    kind: "ready",
                    groupId: group,
                    enabled: saved.enabled,
                  });
                  this.#invalidateProactive(prefer);
                })
              ),
              Effect.as(null)
            );
          });
        },
      },
    });
  }

  static #empty(workspace: string): Shown {
    return {
      workspace,
      envelope: null,
      failure: null,
      discovering: false,
      discoveryWait: false,
      refreshing: false,
      serverRefreshing: false,
      discoveries: 0,
      pollFailures: 0,
      lastLoadedAt: 0,
      generation: null,
      reads: Semaphore.makeUnsafe(1),
    };
  }

  #topics(workspace?: string): Topic[] {
    return this.#ctx.kernel.store
      .liveTopics()
      .filter(
        (t) =>
          t.topic === "recommendations" &&
          (workspace === undefined ||
            this.#shown.get(keyOf(t))?.workspace === workspace)
      );
  }

  #changed(topic: Topic): void {
    this.#ctx.kernel.store.invalidate(topic);
  }

  #requestId(): string {
    const bytes = new Uint8Array(16);
    this.#ctx.host.randomBytes(bytes);
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  #restart(topic: Topic, readFirst: boolean): void {
    this.#live.stop(topic);
    this.#live.run(topic, this.#keep(topic, readFirst));
  }

  /** A settings answer: every showing of that workspace takes it. */
  #adopt(workspace: string, envelope: RecommendationEnvelope): void {
    for (const topic of this.#topics(workspace)) {
      const shown = this.#shown.get(keyOf(topic));
      if (!shown) continue;
      shown.envelope = envelope;
      this.#changed(topic);
    }
  }

  /** Reads (when asked), then waits for the next reason to read, and so on while the topic lives. */
  #keep(topic: Topic, readFirst: boolean): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      let read = readFirst;
      for (;;) {
        if (read) yield* this.#read(topic);
        read = true;
        const wait = this.#nextWait(topic);
        if (wait === undefined) return;
        yield* Effect.sleep(wait);
      }
    });
  }

  /** How long until the next read, or undefined for none. */
  #nextWait(topic: Topic): number | undefined {
    const shown = this.#shown.get(keyOf(topic));
    // A glance (the composer's mention list) reads once.
    if (!shown || topic.reads === "once") return undefined;
    if (shown.serverRefreshing && shown.failure !== "unavailable") return RUN_POLL_MS;
    if (shown.discoveryWait) return DISCOVERY_MS;
    const schedule = shown.envelope?.settings.schedule;
    if (schedule?.enabled) {
      const delay = msUntilDailyDelivery(schedule, this.#ctx.now());
      if (delay !== undefined) return delay + DELIVERY_GRACE_MS;
    }
    return undefined;
  }

  #read(topic: Topic): Effect.Effect<void> {
    const key = keyOf(topic);
    const shown = this.#shown.get(key);
    if (!shown) return Effect.void;
    const ctx = this.#ctx;
    return shown.reads.withPermits(1)(
      Effect.gen({ self: this }, function* () {
        const account = yield* ctx.session.account().pipe(Effect.option);
        if (Option.isNone(account)) return;
        if (!shown.workspace) {
          // No workspace named: the account's first.
          yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
          shown.workspace = this.#workspaces.list(account.value)?.[0]?.id ?? "";
          if (!shown.workspace) {
            shown.failure = "unavailable";
            this.#changed(topic);
            return;
          }
        }
        shown.lastLoadedAt = ctx.now();
        const query = topic.timezone
          ? `?${new URLSearchParams({ timezone: String(topic.timezone) })}`
          : "";
        const answer = yield* ctx.api
          .request(
            account.value,
            "GET",
            `${recommendationsPath(shown.workspace)}${query}`,
            recommendationEnvelopeSchema
          )
          .pipe(Effect.option);
        if (this.#shown.get(key) !== shown) return;
        if (Option.isSome(answer)) {
          const next = answer.value;
          shown.pollFailures = 0;
          const generation = next.snapshot?.generation ?? null;
          const generationChanged = generation !== shown.generation;
          shown.generation = generation;
          shown.envelope = next;
          shown.serverRefreshing = next.state === "refreshing";
          // A refused refresh stays explained until a run starts or a new briefing arrives.
          shown.failure =
            shown.failure === "rate_limited" &&
            next.state !== "refreshing" &&
            !generationChanged
              ? "rate_limited"
              : null;
          // A failed generation is terminal until a refresh; the checks are for a projection still being prepared.
          const checking =
            shown.discoveries < MAX_DISCOVERY &&
            next.state !== "refreshing" &&
            next.state !== "error" &&
            (!next.settings.sourcesCheckedAt ||
              (next.snapshot === null &&
                next.settings.sources.some((source) => source.enabled)));
          if (checking) shown.discoveries += 1;
          shown.discoveryWait = checking;
          shown.discovering = checking && !next.settings.sourcesCheckedAt;
        } else {
          shown.discoveryWait = false;
          shown.pollFailures += 1;
          if (
            !shown.serverRefreshing ||
            shown.pollFailures > this.#ctx.limits.briefingReadFailures
          ) {
            shown.serverRefreshing = false;
            shown.failure = "unavailable";
          }
        }
        this.#changed(topic);
      })
    );
  }

  /** A refresh: the run it starts is followed by the reads; a refusal is explained. */
  /** Asks the workspace's recommendations again (the dev app's recommendation mock refreshes them). */
  refresh(workspace: string): Effect.Effect<{ rateLimited: boolean }, CoreError> {
    return this.#refresh(workspace);
  }

  #refresh(workspace: string): Effect.Effect<{ rateLimited: boolean }, CoreError> {
    const ctx = this.#ctx;
    return Effect.suspend(() => {
      const topics = this.#topics(workspace);
      for (const topic of topics) {
        const shown = this.#shown.get(keyOf(topic));
        if (!shown) continue;
        shown.refreshing = true;
        shown.failure = null;
        shown.discovering = false;
        shown.discoveryWait = false;
        this.#changed(topic);
      }
      const done = (change: (shown: Shown) => void) =>
        Effect.sync(() => {
          for (const topic of this.#topics(workspace)) {
            const shown = this.#shown.get(keyOf(topic));
            if (!shown) continue;
            change(shown);
            this.#changed(topic);
          }
        });
      return ctx.session.account().pipe(
        Effect.flatMap((account) =>
          ctx.api.request(
            account,
            "POST",
            `${recommendationsPath(workspace)}/refresh`,
            refreshSchema,
            {}
          )
        ),
        Effect.tap((result) =>
          Effect.gen({ self: this }, function* () {
            yield* done((shown) => {
              shown.lastLoadedAt = ctx.now();
              shown.serverRefreshing = result.envelope.state === "refreshing";
              shown.generation =
                result.envelope.snapshot?.generation ?? shown.generation;
              shown.envelope = result.envelope;
              shown.refreshing = false;
            });
            for (const topic of this.#topics(workspace)) this.#restart(topic, false);
          })
        ),
        Effect.as({ rateLimited: false }),
        Effect.catch((error: CoreError) =>
          Effect.gen({ self: this }, function* () {
            const rateLimited = error.status === 429;
            for (const topic of this.#topics(workspace)) yield* this.#read(topic);
            yield* done((shown) => {
              shown.refreshing = false;
              if (rateLimited) shown.failure = "rate_limited";
              else if (
                !shown.envelope ||
                shown.envelope.settings.sources.some((source) => source.enabled)
              )
                shown.failure = "unavailable";
            });
            for (const topic of this.#topics(workspace)) this.#restart(topic, false);
            return { rateLimited };
          })
        )
      );
    });
  }

  #value(topic: Topic): RecommendationsValue {
    const shown = this.#shown.get(keyOf(topic));
    return {
      workspace: shown?.workspace || null,
      envelope: shown?.envelope ?? null,
      failure: shown?.failure ?? null,
      discovering: shown?.discovering ?? false,
      refreshing: shown?.refreshing ?? false,
    };
  }

  // Proactive messages

  #invalidateProactive(prefer: string): void {
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "proactive" && String(topic.prefer ?? "") === prefer)
        store.invalidate(topic);
  }

  /** The owner's automatic messages: the workspace's Group setting (a non-owner is told it is the owner's). */
  #readProactive(topic: Topic): Effect.Effect<void> {
    const prefer = String(topic.prefer ?? "");
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      const list = this.#workspaces.list(account.value) ?? [];
      const workspace = list.find((w) => w.id === prefer) ?? list[0];
      let value: ProactiveValue;
      if (!workspace) value = { kind: "failed" };
      else {
        const saved = yield* ctx.api
          .request(
            account.value,
            "GET",
            proactivePath(workspace.group_id),
            proactiveSchema
          )
          .pipe(Effect.result);
        value = Result.isSuccess(saved)
          ? {
              kind: "ready",
              groupId: workspace.group_id,
              enabled: saved.success.enabled,
            }
          : saved.failure.status === 403
            ? { kind: "owner-only" }
            : { kind: "failed" };
      }
      this.#proactive.set(prefer, value);
      this.#invalidateProactive(prefer);
    });
  }
}
