import type { BillingValue, ModelsValue, ShownProfile } from "@comma/core/contract";
import type { SessionProductLease } from "@comma/session-contract";
import { describe, expect, it, vi } from "vitest";
import { StatusTrayUsage, type StatusTrayUsageSnapshot } from "../status-tray-usage";

const lease = (generation: number): SessionProductLease => ({
  audience: "https://api.comma.test",
  authorityInstanceId: "main",
  generation,
  sessionId: "ses_1",
});

/** The client core: each topic it holds, and each call, answered when the test says. */
function fakeClient() {
  const topics: Array<{
    topic: Record<string, unknown>;
    onValue(value: unknown): void;
    stop: ReturnType<typeof vi.fn>;
  }> = [];
  const answers: Array<{
    name: string;
    params: Record<string, unknown>;
    resolve(): void;
    reject(): void;
  }> = [];
  const client = {
    subscribe: vi.fn(
      (topic: Record<string, unknown>, onValue: (value: unknown) => void) => {
        const stop = vi.fn();
        topics.push({ onValue, stop, topic });
        return stop;
      }
    ),
    call: vi.fn(
      (name: string, params: Record<string, unknown>) =>
        new Promise<unknown>((resolve, reject) => {
          answers.push({
            name,
            params,
            reject: () => reject(new Error("offline")),
            resolve: () => resolve(null),
          });
        })
    ),
  };
  const topic = (name: string) => topics.findLast((held) => held.topic.topic === name)!;
  const calls = () => answers.map(({ name, params }) => [name, params]);
  // Answers every call made so far, and lets their results land: they land
  // through a few promise steps, and no timer.
  const answer = async (outcome: "resolve" | "reject" = "resolve") => {
    answers.splice(0).forEach((call) => call[outcome]());
    for (let step = 0; step < 10; step += 1) await Promise.resolve();
  };
  return { answer, answers, calls, client, topic, topics };
}

const billing = (usedPercent: number): BillingValue =>
  ({
    status: "ready",
    planUsage: { ends: false, otherCredits: 0, resetsAt: null, usedPercent },
    unlimited: false,
    summary: {
      active_subscription: { plan: { name: "Comma Pro" } },
      current_credits: 900,
    },
  }) as unknown as BillingValue;

const profile = (
  id: string,
  { observedAt, ...rest }: Partial<ShownProfile> & { observedAt?: string } = {}
): ShownProfile =>
  ({
    credential_kind: "subscription_oauth",
    id,
    meters: [{ percent: 80, window: "5h" }],
    name: `Account ${id}`,
    quota: { observed_at: observedAt ?? null, plan_type: "max" },
    source: "anthropic",
    subscription: true,
    usable: true,
    ...rest,
  }) as ShownProfile;

const models = (profiles: ShownProfile[]): ModelsValue =>
  ({
    catalog: { sources: { anthropic: { name: "Claude" } } },
    profiles,
  }) as unknown as ModelsValue;

function harness(start = Date.parse("2026-10-13T08:00:00Z")) {
  const fake = fakeClient();
  let time = start;
  const changes: StatusTrayUsageSnapshot[] = [];
  const usage = new StatusTrayUsage({
    client: fake.client,
    now: () => time,
    onChanged: (snapshot) => changes.push(snapshot),
  });
  const advance = (ms: number) => {
    time += ms;
  };
  return { ...fake, advance, changes, now: () => time, usage };
}

describe("StatusTrayUsage", () => {
  it("follows the workspace the app works in, and lets every topic go when the session ends", () => {
    const { calls, client, topic, topics, usage } = harness();

    usage.follow(lease(1));
    usage.follow(lease(1));
    expect(client.subscribe).toHaveBeenCalledOnce();
    expect(usage.snapshot).toBeUndefined();

    topic("workspace").onValue({ workspace: { id: "wsp_1" } });
    expect(topics.map((held) => held.topic)).toEqual([
      { topic: "workspace" },
      { prefer: "wsp_1", topic: "billing" },
      { prefer: "wsp_1", topic: "models" },
    ]);
    // The topics read as they start; nothing more is read until the menu opens.
    expect(calls()).toEqual([]);
    expect(usage.snapshot?.refresh).toEqual({ state: "idle", updatedAt: null });

    // Another workspace: its billing and plans replace the last one's.
    topic("billing").onValue(billing(6));
    topic("workspace").onValue({ workspace: { id: "wsp_2" } });
    expect(topics[1]!.stop).toHaveBeenCalledOnce();
    expect(topics[2]!.stop).toHaveBeenCalledOnce();
    expect(usage.snapshot?.comma).toEqual({ status: "loading" });

    usage.follow(undefined);
    expect(topics.every((held) => held.stop.mock.calls.length === 1)).toBe(true);
    expect(usage.snapshot).toBeUndefined();
  });

  it("reads again as the menu opens at most once a minute, and Refresh asks each shown plan's provider", async () => {
    const { advance, answer, calls, topic, usage } = harness();
    usage.follow(lease(1));
    topic("workspace").onValue({ workspace: { id: "wsp_1" } });

    topic("billing").onValue(billing(6));
    topic("models").onValue(
      models([
        profile("p1", { observedAt: "2026-10-13T07:50:00Z" }),
        profile("key", { credential_kind: "provider_api_key", subscription: false }),
        profile("off", { usable: false }),
        profile("empty", { meters: [] }),
        profile("p2"),
        profile("p3"),
        profile("p4"),
      ])
    );
    const shown = usage.snapshot!;
    expect(shown.comma).toEqual({
      credits: 900,
      plan: "Comma Pro",
      status: "ready",
      unlimited: false,
      usage: { ends: false, otherCredits: 0, resetsAt: null, usedPercent: 6 },
    });
    // Signed-in plans with a meter, three at most.
    expect(
      shown.accounts.map((account) => [account.id, account.provider, account.plan])
    ).toEqual([
      ["p1", "Claude", "max"],
      ["p2", "Claude", "max"],
      ["p3", "Claude", "max"],
    ]);
    expect(shown.refresh).toEqual({ state: "idle", updatedAt: null });

    usage.opened();
    expect(calls()).toEqual([
      ["models.refresh", { only: "profiles" }],
      ["billing.refresh", { workspace: "wsp_1" }],
    ]);
    // One read at a time: Refresh chosen during the open's read runs after it.
    usage.refresh();
    expect(calls()).toHaveLength(2);
    await answer();
    expect(calls()).toEqual([
      ["models.refreshQuota", { profile: "p1", workspace: "wsp_1" }],
      ["models.refreshQuota", { profile: "p2", workspace: "wsp_1" }],
      ["models.refreshQuota", { profile: "p3", workspace: "wsp_1" }],
      ["billing.refresh", { workspace: "wsp_1" }],
    ]);
    // The oldest figure shown: a plan the server read before the balance.
    expect(usage.snapshot?.refresh).toEqual({
      state: "updating",
      updatedAt: Date.parse("2026-10-13T07:50:00Z"),
    });
    await answer("reject");
    expect(usage.snapshot?.refresh.state).toBe("failed");

    advance(59_000);
    usage.opened();
    expect(calls()).toEqual([]);
    advance(1_000);
    usage.opened();
    expect(calls()).toHaveLength(2);
  });

  it("forgets a read of the last workspace: the new one reads as the menu opens, and Refresh reads again", async () => {
    const { answers, calls, topic, usage } = harness();
    usage.follow(lease(1));
    topic("workspace").onValue({ workspace: { id: "wsp_1" } });
    usage.opened();
    expect(usage.snapshot?.refresh.state).toBe("updating");
    const first = answers.splice(0);

    // The workspace changes while wsp_1's read runs.
    topic("workspace").onValue({ workspace: { id: "wsp_2" } });
    expect(usage.snapshot?.refresh).toEqual({ state: "idle", updatedAt: null });
    usage.opened();
    expect(calls()).toEqual([
      ["models.refresh", { only: "profiles" }],
      ["billing.refresh", { workspace: "wsp_2" }],
    ]);

    // wsp_1's read ends, failed: wsp_2's read is still under way.
    first.forEach((call) => call.reject());
    for (let step = 0; step < 10; step += 1) await Promise.resolve();
    expect(usage.snapshot?.refresh.state).toBe("updating");

    answers.splice(0).forEach((call) => call.resolve());
    for (let step = 0; step < 10; step += 1) await Promise.resolve();
    expect(usage.snapshot?.refresh.state).toBe("idle");
    usage.refresh();
    expect(calls()).toEqual([["billing.refresh", { workspace: "wsp_2" }]]);
  });

  it("reads a balance that could not be read as the topic starts: its plans too", async () => {
    const { answer, calls, topic, usage } = harness();
    usage.follow(lease(1));
    topic("workspace").onValue({ workspace: { id: "wsp_1" } });
    await answer();
    topic("billing").onValue({ status: "unavailable" });

    usage.refresh();
    expect(calls()).toEqual([["billing.refresh", {}]]);
    // The call does not fail when the balance still cannot be read.
    await answer();
    expect(usage.snapshot?.refresh).toEqual({ state: "failed", updatedAt: null });
  });
});
