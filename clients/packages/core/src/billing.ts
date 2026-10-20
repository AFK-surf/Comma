// Usage and billing: the plans on sale (kept on the device, `doc` "billingPlans"), each workspace's balance and
// subscription (`doc` "billingSummary:<workspace>"), the low-credit warning, and the Stripe checkout, portal, plan
// change, renewal cancel and code redeem. The UI opens the URLs these answer and words what it shows.
//
// Bounds: one summary read in flight per workspace and one plans read per core (the scheduler's); the `billing` topic
// reads once when it is shown and again on `billing.refresh` (a bare one asked while its read runs waits for that
// read); a `creditWarning` topic reads its summary once a minute while it is live (a UI drops it while its page is
// hidden), the plans once per account; after a return from Stripe, at most 6 reads over about 30 s (a webhook can
// trail the return), stopping at the first change.
import {
  CoreError,
  Priority,
  type Topic,
  topicKey,
  type Value,
} from "@comma/core-kernel";
import { Deferred, Effect, Fiber, Option } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import {
  billingChangePreviewSchema,
  billingChangeSchema,
  billingPlanSchema,
  billingSessionSchema,
  billingSummarySchema,
  redemptionResultSchema,
} from "./comma/schemas.ts";
import type {
  BillingChangePreview,
  BillingPlan,
  BillingReturn,
  BillingSummary,
  BillingValue,
  CreditAllowance,
  PlanUsage,
  CreditWarning,
} from "./contract.ts";
import { API_LANE, type Ctx, Live } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const PLANS_DOC = "billingPlans";
const summaryDoc = (workspace: string) => `billingSummary:${workspace}`;
const dismissalKey = (billingAccount: string) => `creditWarning:${billingAccount}`;

const WARNING_EVERY_MS = 60_000;
/** After a return from Stripe: the waits between reads. */
const RETURN_DELAYS_MS = [600, 1_200, 2_400, 5_000, 10_000, 10_000];

type Dismissal = { grants: string; threshold: number };

const params = {
  string(raw: unknown, name: string): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "")
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  return(raw: unknown): BillingReturn {
    const parsed = z
      .object({ apiBase: z.url(), environment: z.string().min(1).max(64) })
      .safeParse((raw as Record<string, unknown> | null)?.return);
    if (!parsed.success) throw CoreError.invalid("return is required");
    return parsed.data;
  },
  preview(raw: unknown): BillingChangePreview {
    const parsed = billingChangePreviewSchema.safeParse(
      (raw as Record<string, unknown> | null)?.preview
    );
    if (!parsed.success) throw CoreError.invalid("preview is required");
    return parsed.data;
  },
};

/** The credits the active grants started with; undefined when a grant's plan is unknown or they add to nothing. */
export function creditAllowance(
  summary: BillingSummary,
  plans: readonly BillingPlan[]
): CreditAllowance | null {
  let total = 0;
  for (const grant of summary.active_grants) {
    const plan = [summary.active_subscription?.plan, ...plans].find(
      (item) =>
        item &&
        item.package_code === grant.package_code &&
        item.package_version === grant.package_version
    );
    if (!plan) return null;
    total += plan.grant_credits;
  }
  if (total <= 0) return null;
  const percent = Math.round(
    Math.max(0, Math.min(1, summary.current_credits / total)) * 100
  );
  return { percent, total };
}

/** A subscription cycle's grants: a paid plan's, issued each cycle, and a redeemed code's, for its one period. */
const CYCLE_GRANTS = new Set(["subscription_cycle", "redeem_subscription_cycle"]);

/**
 * The current subscription cycle's credits (`PlanUsage`). Only the cycle's own
 * grants count: a spent signup grant stays among the active ones and would
 * otherwise hide every subscriber's usage. The total is what the grants were
 * issued with: an upgrade inside a cycle adds a grant of only the prorated
 * difference, not the new plan's allowance.
 */
export function planUsage(summary: BillingSummary): PlanUsage | null {
  let total = 0;
  let remaining = 0;
  let resetsAt: string | null = null;
  let resetsAtMs = Number.POSITIVE_INFINITY;
  let redeemed = false;
  for (const grant of summary.active_grants) {
    if (!CYCLE_GRANTS.has(grant.source_type)) continue;
    if (grant.original_credits === undefined) return null;
    total += grant.original_credits;
    remaining += grant.remaining_credits;
    const expiry = grant.expires_at ? Date.parse(grant.expires_at) : Number.NaN;
    if (expiry < resetsAtMs) {
      resetsAtMs = expiry;
      resetsAt = grant.expires_at ?? null;
      redeemed = grant.source_type === "redeem_subscription_cycle";
    }
  }
  if (total <= 0) return null;
  const metadata = summary.active_subscription?.source_metadata;
  const periodEnd = metadata?.current_period_end;
  return {
    usedPercent: Math.round(Math.max(0, Math.min(1, 1 - remaining / total)) * 100),
    resetsAt,
    // A redeemed code's subscription has one period: nothing renews it. An annual plan's monthly grant expires
    // before the subscription ends: its credits reset then.
    ends:
      redeemed ||
      (metadata?.cancel_at_period_end === true &&
        typeof periodEnd === "number" &&
        resetsAtMs >= periodEnd * 1000),
    otherCredits: Math.max(0, summary.current_credits - remaining),
  };
}

function threshold(percent: number): CreditWarning["threshold"] | undefined {
  return percent <= 5 ? 5 : percent <= 10 ? 10 : percent <= 50 ? 50 : undefined;
}

/** Which grants a dismissal holds for: new grants show the warning again. */
function grantScope(summary: BillingSummary): string {
  return JSON.stringify(summary.active_grants.map((grant) => grant.id).toSorted());
}

/** The warning a summary calls for, before any dismissal. */
export function creditWarning(
  summary: BillingSummary,
  plans: readonly BillingPlan[]
): CreditWarning | null {
  const allowance = creditAllowance(summary, plans);
  // The summary lists only unexpired grants. With none left there is no allowance to compare against, but billed work
  // is already refused, so that reads as exhausted rather than unknown.
  const exhausted =
    summary.current_credits <= 0 &&
    (allowance !== null || summary.active_grants.length === 0);
  if (!allowance && !exhausted) return null;
  // The actual ratio: display rounding must not warn early.
  const ratio = allowance ? (summary.current_credits / allowance.total) * 100 : 0;
  const level = exhausted ? 0 : threshold(ratio);
  if (level === undefined) return null;
  return { percent: allowance?.percent ?? 0, threshold: level };
}

/** What a balance shows that a webhook changes: a read after a return stops once it differs. */
function summaryShape(summary: BillingSummary): string {
  return JSON.stringify({
    grants: summary.active_grants
      .map((grant) => [
        grant.id,
        grant.expires_at ?? null,
        grant.package_code,
        grant.package_version,
        grant.remaining_credits,
        grant.source_id,
        grant.source_type,
        grant.valid_from,
      ])
      .toSorted((a, b) => String(a[0]).localeCompare(String(b[0]))),
    subscription: summary.active_subscription
      ? [
          summary.active_subscription.package_code,
          summary.active_subscription.package_version,
          summary.active_subscription.source_id,
          summary.active_subscription.status,
        ]
      : null,
    credits: summary.current_credits,
  });
}

function returnUrl(
  to: BillingReturn,
  status: "cancel" | "portal" | "subscription" | "success"
) {
  const query = new URLSearchParams({ environment: to.environment, status });
  return `${to.apiBase.replace(/\/+$/, "")}/v1/comma/billing/stripe/checkout/return?${query}`;
}

export class Billing {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  /** The `billing` topics whose last read failed (they show `unavailable` when the device kept nothing). */
  readonly #failed = new Set<string>();
  /** Each `billing` topic's read in flight, by topic: a bare `billing.refresh` asked meanwhile waits for it. */
  readonly #reading = new Map<string, Deferred.Deferred<void>>();
  /** Workspaces whose last summary read for a warning failed: no warning is shown from an old balance. */
  readonly #warningFailed = new Set<string>();
  #plansRead = false;
  #returning: Fiber.Fiber<unknown, unknown> | null = null;
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("billing", {
      start: (topic) => this.#live.run(topic, this.#read(topic, Priority.shown)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({ ok: this.#billingValue(topic) }),
    });
    kernel.source("creditWarning", {
      start: (topic) => this.#live.run(topic, this.#watch(topic.workspace as string)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({
        ok: this.#warningValue(topic.workspace as string),
      }),
    });
    workspaces.onChange(() => this.#invalidate("billing"));
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      // Another account (or none): nothing read for the one before is shown or continued.
      this.#accountKey = key;
      if (this.#returning) ctx.runner.interrupt(this.#returning);
      this.#returning = null;
      this.#failed.clear();
      this.#warningFailed.clear();
      this.#plansRead = false;
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "billing" && topic.topic !== "creditWarning") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(
          topic,
          topic.topic === "billing"
            ? this.#read(topic, Priority.shown)
            : this.#watch(topic.workspace as string)
        );
      }
    });

    kernel.calls({
      "billing.refresh": {
        run: (p) => {
          const workspace = (p as { workspace?: unknown } | null)?.workspace;
          if (typeof workspace === "string" && workspace)
            return this.#readSummary(workspace, Priority.asked).pipe(Effect.as(null));
          return Effect.forEach(
            kernel.store.liveTopics().filter((t) => t.topic === "billing"),
            (topic) => this.#read(topic, Priority.asked, true)
          ).pipe(Effect.as(null));
        },
      },
      "billing.returned": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return Effect.sync(() => {
            if (this.#returning) ctx.runner.interrupt(this.#returning);
            this.#returning = ctx.runner.fork(this.#afterReturn(workspace));
            return null;
          });
        },
      },
      "billing.checkout": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const plan = params.string(p, "plan");
          const to = params.return(p);
          return this.#post(
            route`/v1/comma/workspaces/${workspace}/billing/checkout`,
            billingSessionSchema,
            {
              plan_key: plan,
              success_url: returnUrl(to, "success"),
              cancel_url: returnUrl(to, "cancel"),
              client_request_id: this.#requestId(),
            }
          ).pipe(Effect.map((session) => ({ url: session.url })));
        },
      },
      "billing.portal": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const to = params.return(p);
          return this.#post(
            route`/v1/comma/workspaces/${workspace}/billing/portal`,
            billingSessionSchema,
            {
              return_url: returnUrl(to, "portal"),
              client_request_id: this.#requestId(),
            }
          ).pipe(Effect.map((session) => ({ url: session.url })));
        },
      },
      "billing.previewChange": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const plan = params.string(p, "plan");
          return this.#post(
            route`/v1/comma/workspaces/${workspace}/billing/subscription/preview`,
            billingChangePreviewSchema,
            { plan_key: plan, client_request_id: this.#requestId() }
          ).pipe(Effect.map((preview) => ({ preview, request: this.#requestId() })));
        },
      },
      "billing.change": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const plan = params.string(p, "plan");
          const preview = params.preview(p);
          const request = params.string(p, "request");
          const to = params.return(p);
          return this.#post(
            route`/v1/comma/workspaces/${workspace}/billing/subscription/change`,
            billingChangeSchema,
            {
              plan_key: plan,
              current_price_id: preview.current_price_id,
              proration_date: preview.proration_date,
              period_end: preview.period_end,
              success_url: returnUrl(to, "subscription"),
              client_request_id: request,
            }
          ).pipe(
            Effect.tap(() => this.#reread(workspace)),
            Effect.map((change) => ({ url: change.url ?? null }))
          );
        },
      },
      "billing.cancelRenewal": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#post(
            route`/v1/comma/workspaces/${workspace}/billing/subscription/cancel`,
            billingChangeSchema,
            { client_request_id: this.#requestId() }
          ).pipe(
            Effect.tap(() => this.#reread(workspace)),
            Effect.as(null)
          );
        },
      },
      "billing.redeem": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const code = params.string(p, "code").trim();
          if (code.length < 3) throw CoreError.invalid("code is too short");
          return this.#post(
            route`/v1/comma/workspaces/${workspace}/billing/redeem`,
            redemptionResultSchema,
            { code, client_request_id: this.#requestId() }
          ).pipe(
            Effect.tap(() =>
              this.#readSummary(workspace, Priority.asked).pipe(Effect.ignore)
            ),
            Effect.as(null)
          );
        },
      },
      "billing.dismissWarning": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return Effect.sync(() => {
            const account = ctx.session.current();
            const summary = account?.doc<BillingSummary>(summaryDoc(workspace))?.value;
            const warning = this.#warningValue(workspace);
            if (!account || !summary || !warning) return null;
            account.setMeta(dismissalKey(summary.billing_account_id), {
              grants: grantScope(summary),
              threshold: warning.threshold,
            } satisfies Dismissal);
            this.#invalidate("creditWarning");
            return null;
          });
        },
      },
    });
  }

  #requestId(): string {
    const bytes = new Uint8Array(16);
    this.#ctx.host.randomBytes(bytes);
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  #post<S extends z.ZodType>(
    path: string,
    schema: S,
    body: unknown
  ): Effect.Effect<z.output<S>, CoreError> {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, "POST", path, schema, body)
        )
      );
  }

  #invalidate(name: "billing" | "creditWarning"): void {
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === name) store.invalidate(topic);
  }

  #changed(): void {
    this.#invalidate("billing");
    this.#invalidate("creditWarning");
  }

  /** The workspace a `billing` topic shows: the one it prefers when the account has it, else the first. */
  #workspaceOf(topic: Topic, account: Account) {
    const list = this.#workspaces.list(account);
    if (!list) return undefined;
    return list.find((w) => w.id === topic.prefer) ?? list[0] ?? null;
  }

  /**
   * Reads a `billing` topic (`#load`), as its read in flight until it ends. With `join`, a read still running (the
   * topic's start, or another refresh) reads what this one would, and is waited on instead.
   */
  #read(topic: Topic, priority: number, join = false): Effect.Effect<void> {
    const key = topicKey(topic);
    return Effect.gen({ self: this }, function* () {
      const done = yield* Deferred.make<void>();
      const running = this.#reading.get(key);
      if (join && running) return yield* Deferred.await(running);
      this.#reading.set(key, done);
      yield* this.#load(topic, priority).pipe(
        Effect.ensuring(
          Effect.suspend(() => {
            if (this.#reading.get(key) === done) this.#reading.delete(key);
            return Deferred.succeed(done, undefined);
          })
        )
      );
    });
  }

  /** Reads what a `billing` topic shows: the workspaces, the plans and the chosen workspace's summary. */
  #load(topic: Topic, priority: number): Effect.Effect<void> {
    const key = String(topic.prefer ?? "");
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const read = Effect.gen({ self: this }, function* () {
        yield* Effect.all(
          [this.#workspaces.refresh(priority), this.#readPlans(priority)],
          {
            concurrency: "unbounded",
          }
        );
        const workspace = this.#workspaceOf(topic, account.value);
        if (!workspace)
          return yield* Effect.fail(new CoreError("not_found", "no workspace"));
        yield* this.#readSummary(workspace.id, priority);
      });
      const ok = yield* read.pipe(
        Effect.as(true),
        Effect.orElseSucceed(() => false)
      );
      if (ok) this.#failed.delete(key);
      else this.#failed.add(key);
      this.#invalidate("billing");
    });
  }

  #readPlans(priority: number): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.scheduler.ask(
          API_LANE,
          `${account.dbName}:${PLANS_DOC}`,
          priority,
          ctx.api
            .request(
              account,
              "GET",
              "/v1/comma/billing/plans",
              z.object({ data: z.array(billingPlanSchema) })
            )
            .pipe(
              Effect.tap((page) =>
                Effect.sync(() => {
                  if (!account.putDoc(PLANS_DOC, page.data, ctx.now())) return;
                  this.#plansRead = true;
                  this.#changed();
                })
              ),
              Effect.asVoid
            )
        )
      )
    );
  }

  /** Reads a workspace's balance: one read at a time per workspace. */
  #readSummary(
    workspace: string,
    priority: number
  ): Effect.Effect<BillingSummary, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.scheduler
          .ask(
            API_LANE,
            `${account.dbName}:${summaryDoc(workspace)}`,
            priority,
            ctx.api
              .request(
                account,
                "GET",
                route`/v1/comma/workspaces/${workspace}/billing/summary`,
                billingSummarySchema
              )
              .pipe(
                Effect.tap((summary) =>
                  Effect.sync(() => {
                    if (!account.putDoc(summaryDoc(workspace), summary, ctx.now()))
                      return;
                    this.#warningFailed.delete(workspace);
                    this.#changed();
                  })
                ),
                Effect.asVoid
              )
          )
          .pipe(
            Effect.flatMap(() => {
              const kept = account.doc<BillingSummary>(summaryDoc(workspace));
              return kept
                ? Effect.succeed(kept.value)
                : Effect.fail(CoreError.invalid("no summary"));
            })
          )
      )
    );
  }

  /** After a plan change or cancel: the plans and the balance again; a failed read leaves what is shown. */
  #reread(workspace: string): Effect.Effect<void> {
    return Effect.all(
      [this.#readPlans(Priority.asked), this.#readSummary(workspace, Priority.asked)],
      { concurrency: "unbounded" }
    ).pipe(Effect.ignore);
  }

  /** Keeps a `creditWarning` topic current: the plans once, the balance now and once a minute. */
  #watch(workspace: string): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      for (;;) {
        const account = yield* this.#ctx.session.account().pipe(Effect.option);
        if (Option.isNone(account)) return;
        const plans = this.#plansRead
          ? Effect.void
          : this.#readPlans(Priority.background);
        const ok = yield* Effect.all(
          [plans, this.#readSummary(workspace, Priority.background)],
          { concurrency: "unbounded" }
        ).pipe(
          Effect.as(true),
          Effect.orElseSucceed(() => false)
        );
        if (!ok) {
          // A balance that could not be read must not hold chat up or show an old warning.
          this.#warningFailed.add(workspace);
          this.#invalidate("creditWarning");
        }
        yield* Effect.sleep(WARNING_EVERY_MS);
      }
    });
  }

  /** Reads the balance on a backoff until it differs from the one before the return. */
  #afterReturn(workspace: string): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const account = this.#ctx.session.current();
      const before = account?.doc<BillingSummary>(summaryDoc(workspace))?.value;
      const baseline = before ? summaryShape(before) : null;
      for (const delay of RETURN_DELAYS_MS) {
        yield* Effect.sleep(delay);
        const next = yield* this.#readSummary(workspace, Priority.shown).pipe(
          Effect.option
        );
        if (Option.isSome(next) && summaryShape(next.value) !== baseline) return;
      }
    });
  }

  #billingValue(topic: Topic): BillingValue {
    const account = this.#ctx.session.current();
    if (!account) return { status: "loading" };
    const failed = this.#failed.has(String(topic.prefer ?? ""));
    const workspace = this.#workspaceOf(topic, account);
    if (workspace === null) return { status: "unavailable" };
    const plans = account.doc<BillingPlan[]>(PLANS_DOC)?.value;
    const summary = workspace
      ? account.doc<BillingSummary>(summaryDoc(workspace.id))?.value
      : undefined;
    if (!workspace || !plans || !summary)
      return failed ? { status: "unavailable" } : { status: "loading" };
    return {
      status: "ready",
      workspace: { id: workspace.id, name: workspace.name },
      plans,
      summary,
      allowance: creditAllowance(summary, plans),
      planUsage: planUsage(summary),
      unlimited: summary.active_grants.some(
        (grant) => grant.source_type === "selfhost"
      ),
    };
  }

  #warningValue(workspace: string): CreditWarning | null {
    const account = this.#ctx.session.current();
    if (!account || this.#warningFailed.has(workspace)) return null;
    const summary = account.doc<BillingSummary>(summaryDoc(workspace))?.value;
    const plans = account.doc<BillingPlan[]>(PLANS_DOC)?.value;
    if (!summary || !plans) return null;
    const warning = creditWarning(summary, plans);
    if (!warning) return null;
    const dismissal = account.meta<Dismissal>(dismissalKey(summary.billing_account_id));
    if (
      dismissal?.grants === grantScope(summary) &&
      warning.threshold >= dismissal.threshold
    )
      return null;
    return warning;
  }
}
