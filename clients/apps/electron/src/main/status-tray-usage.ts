import type {
  BillingValue,
  ModelsValue,
  PlanUsage,
  QuotaMeter,
  ResolvedWorkspace,
  ShownProfile,
} from "@comma/core/contract";
import {
  sameSessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";

/** One of the person's own plans the menu shows: its 5-hour and weekly windows. */
export interface StatusTrayAccountUsage {
  id: string;
  /** The catalog's name for its source ("Claude"). */
  provider: string;
  /** The plan as the provider reports it ("max"), when it does. */
  plan: string | null;
  /** Its name or sign-in, to tell two accounts with the same title apart. */
  name: string;
  meters: QuotaMeter[];
}

/** What the menu-bar menu shows of usage: Comma's credits, and the person's own plans. */
export interface StatusTrayUsageSnapshot {
  comma:
    | { status: "loading" | "unavailable" }
    | {
        status: "ready";
        /** The subscription's plan name ("Comma Pro"), or null without one. */
        plan: string | null;
        usage: PlanUsage | null;
        credits: number;
        /** The credits have no limit, as on a self-hosted instance. */
        unlimited: boolean;
      };
  accounts: StatusTrayAccountUsage[];
  /** When the figures shown were read (the oldest of them), and whether a read is under way or failed. */
  refresh: { state: "idle" | "updating" | "failed"; updatedAt: number | null };
}

/** The client core, as Main holds it: no token crosses here. */
export interface StatusTrayUsageClient {
  subscribe(
    topic: Record<string, unknown> & { topic: string },
    onValue: (value: unknown) => void,
    onError: (error: unknown) => void
  ): () => void;
  call(name: string, params: Record<string, unknown>): Promise<unknown>;
}

/** The plans the menu shows at most: each Refresh asks their providers again. */
export const statusTrayUsageAccountLimit = 3;
/** Opening the menu reads again at most this often. */
export const statusTrayUsageOpenRefreshMs = 60_000;

/**
 * The usage the menu-bar menu shows while the item is on for a signed-in
 * session. It holds the client core's `workspace`, `billing` and `models`
 * topics for the workspace the app works in, which read once when they start;
 * it reads again only when the menu opens (first, then at most once a minute:
 * two reads)
 * and when the person chooses Refresh (one read, and one quota request to each
 * plan's provider). One read runs at a time: a Refresh chosen during another
 * read runs when it ends. No timer runs.
 */
export class StatusTrayUsage {
  readonly #client: StatusTrayUsageClient;
  readonly #onChanged: (snapshot: StatusTrayUsageSnapshot) => void;
  readonly #now: () => number;
  #session: SessionProductLease | undefined;
  #stopWorkspace: (() => void) | undefined;
  #stopTopics: (() => void) | undefined;
  #workspace: string | null = null;
  #billing: BillingValue = { status: "loading" };
  #models: ModelsValue | null = null;
  #state: StatusTrayUsageSnapshot["refresh"]["state"] = "idle";
  #billingReadAt: number | null = null;
  #lastRead: number | null = null;
  /** Refresh was chosen while a read ran. */
  #refreshNext = false;
  /** Changes with each workspace followed: a read of an earlier one changes nothing. */
  #generation = 0;
  #snapshot: StatusTrayUsageSnapshot = emptySnapshot();

  constructor({
    client,
    onChanged,
    now = Date.now,
  }: {
    client: StatusTrayUsageClient;
    onChanged(snapshot: StatusTrayUsageSnapshot): void;
    now?: () => number;
  }) {
    this.#client = client;
    this.#onChanged = onChanged;
    this.#now = now;
  }

  /** Undefined while no session is followed, or its account has no workspace: the menu shows no usage. */
  get snapshot(): StatusTrayUsageSnapshot | undefined {
    return this.#session && this.#workspace ? this.#snapshot : undefined;
  }

  /** Follows `session`, or lets every topic go when it is undefined. */
  follow(session: SessionProductLease | undefined) {
    if (
      session === this.#session ||
      (session && this.#session && sameSessionProductLease(session, this.#session))
    ) {
      return;
    }
    this.#stopWorkspace?.();
    this.#stopWorkspace = undefined;
    this.#follow(null);
    this.#session = session;
    this.#billingReadAt = null;
    this.#lastRead = null;
    this.#refreshNext = false;
    this.#state = "idle";
    this.#publish();
    if (!session) return;
    this.#stopWorkspace = this.#client.subscribe(
      { topic: "workspace" },
      (value) =>
        this.#follow((value as ResolvedWorkspace | null)?.workspace?.id ?? null),
      () => undefined
    );
  }

  /** The menu opened: the figures are read again when the last read is a minute old. */
  opened() {
    const workspace = this.#workspace;
    if (!workspace || this.#state === "updating") return;
    const last = this.#lastRead;
    if (last !== null && this.#now() - last < statusTrayUsageOpenRefreshMs) return;
    this.#read(workspace, [this.#client.call("models.refresh", { only: "profiles" })]);
  }

  /** Refresh: the balance, and each shown plan's quota from its provider. */
  refresh() {
    const workspace = this.#workspace;
    if (!workspace) return;
    if (this.#state === "updating") {
      this.#refreshNext = true;
      return;
    }
    this.#read(
      workspace,
      this.#snapshot.accounts.map((account) =>
        this.#client.call("models.refreshQuota", { workspace, profile: account.id })
      )
    );
  }

  #read(workspace: string, others: Promise<unknown>[]) {
    const generation = this.#generation;
    this.#lastRead = this.#now();
    this.#state = "updating";
    this.#publish();
    // A balance that could not be read reads again as the topic starts: its
    // plans too, without which it shows nothing.
    const billing = this.#client
      .call(
        "billing.refresh",
        this.#billing.status === "unavailable" ? {} : { workspace }
      )
      .then(() => {
        if (this.#generation === generation) this.#billingReadAt = this.#now();
      });
    void Promise.allSettled([billing, ...others]).then((results) => {
      if (this.#generation !== generation) return;
      this.#state = results.some((result) => result.status === "rejected")
        ? "failed"
        : "idle";
      if (this.#refreshNext) {
        this.#refreshNext = false;
        this.refresh();
        return;
      }
      this.#publish();
    });
  }

  /**
   * The workspace the app works in changed: its billing and plans replace the
   * last one's, and a read of the last one still under way is forgotten, so
   * the menu and Refresh read the new one at once.
   */
  #follow(workspace: string | null) {
    if (workspace === this.#workspace) return;
    this.#stopTopics?.();
    this.#stopTopics = undefined;
    this.#generation += 1;
    this.#workspace = workspace;
    this.#billing = { status: "loading" };
    this.#models = null;
    this.#refreshNext = false;
    this.#state = "idle";
    this.#billingReadAt = null;
    this.#lastRead = null;
    if (workspace) {
      const stops = [
        this.#client.subscribe(
          { topic: "billing", prefer: workspace },
          (value) => {
            this.#billing = (value as BillingValue | null) ?? { status: "loading" };
            this.#publish();
          },
          () => undefined
        ),
        this.#client.subscribe(
          { topic: "models", prefer: workspace },
          (value) => {
            this.#models = value as ModelsValue | null;
            this.#publish();
          },
          () => undefined
        ),
      ];
      this.#stopTopics = () => stops.forEach((stop) => stop());
    }
    this.#publish();
  }

  #publish() {
    const next = this.#workspace
      ? usageSnapshot(this.#billing, this.#models, this.#state, this.#billingReadAt)
      : emptySnapshot();
    if (JSON.stringify(next) === JSON.stringify(this.#snapshot)) return;
    this.#snapshot = next;
    this.#onChanged(next);
  }
}

function emptySnapshot(): StatusTrayUsageSnapshot {
  return {
    comma: { status: "loading" },
    accounts: [],
    refresh: { state: "idle", updatedAt: null },
  };
}

function usageSnapshot(
  billing: BillingValue,
  models: ModelsValue | null,
  state: StatusTrayUsageSnapshot["refresh"]["state"],
  billingReadAt: number | null
): StatusTrayUsageSnapshot {
  const profiles = (models?.profiles ?? [])
    .filter(
      (profile) => profile.subscription && profile.usable && profile.meters.length > 0
    )
    .slice(0, statusTrayUsageAccountLimit);
  const accounts = profiles.map((profile) => accountUsage(profile, models));
  // The oldest figure shown: a plan's quota is the server's last read of it.
  // A read of a balance that could not be read does not fail when it still
  // cannot: the update failed, and there is no time to say.
  const unread = billing.status === "unavailable";
  const times = [
    unread ? null : billingReadAt,
    ...profiles.map((profile) => Date.parse(profile.quota?.observed_at ?? "")),
  ].filter((time): time is number => typeof time === "number" && Number.isFinite(time));
  return {
    comma:
      billing.status === "ready"
        ? {
            status: "ready",
            plan: billing.summary.active_subscription?.plan?.name ?? null,
            usage: billing.planUsage,
            credits: billing.summary.current_credits,
            unlimited: billing.unlimited,
          }
        : { status: billing.status },
    accounts,
    refresh: {
      state: unread && state === "idle" && billingReadAt !== null ? "failed" : state,
      updatedAt:
        unread || billingReadAt === null || times.length === 0
          ? null
          : Math.min(...times),
    },
  };
}

function accountUsage(
  profile: ShownProfile,
  models: ModelsValue | null
): StatusTrayAccountUsage {
  return {
    id: profile.id,
    provider:
      models?.catalog?.sources[profile.source]?.name ??
      profile.provider ??
      profile.source,
    plan: profile.quota?.plan_type?.trim() || null,
    name: profile.name?.trim() || profile.email?.trim() || profile.id,
    meters: profile.meters,
  };
}
