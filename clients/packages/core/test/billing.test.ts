import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type {
  BillingGrant,
  BillingPlan,
  BillingSummary,
  BillingValue,
  CreditWarning,
} from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { creditAllowance, planUsage } from "../src/billing.ts";
import { base64, fromBase64 } from "../src/record.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const WS = "ws-1";
const plansPath = "/v1/comma/billing/plans";
const summaryPath = (ws = WS) => `/v1/comma/workspaces/${ws}/billing/summary`;
const plan = {
  plan_key: "monthly",
  package_code: "monthly",
  package_version: "v1",
  name: "Monthly",
  mode: "subscription",
  currency: "usd",
  amount_minor: 100,
  grant_credits: 1000,
};
const back = { apiBase: "http://127.0.0.1:4200/", environment: "dev" };
const returnPage = (status: string) =>
  `http://127.0.0.1:4200/v1/comma/billing/stripe/checkout/return?environment=dev&status=${status}`;

function summary(remaining: number, id = "grant-1"): BillingSummary {
  return {
    billing_account_id: "billing-1",
    current_credits: remaining,
    active_grants: [
      {
        id,
        package_code: plan.package_code,
        package_version: plan.package_version,
        original_credits: plan.grant_credits,
        remaining_credits: remaining,
        valid_from: "2026-09-01T00:00:00Z",
        expires_at: null,
        source_type: "subscription_cycle",
        source_id: "cycle",
      },
    ],
  };
}

function setup(host = new FakeHost()) {
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [
      { id: WS, group_id: "g-1", name: "Mine", status: "ready" },
      { id: "ws-2", group_id: "g-2", name: "Team", status: "ready" },
    ],
  });
  host.api.on("GET", plansPath, { data: [plan] });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const subscriptions = new Map<string, () => void>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    subscriptions.set(
      key,
      client.subscribe(
        topic,
        (v) => values.set(key, v),
        (e) => values.set(key, { error: e.code })
      )
    );
    return () => values.get(key) as T;
  };
  const unwatch = (topic: Topic) => subscriptions.get(topicKey(topic))?.();
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch, unwatch };
}

function grant(
  id: string,
  original: number,
  remaining: number,
  source_type = "subscription_cycle"
): BillingGrant {
  return {
    id,
    package_code: plan.package_code,
    package_version: plan.package_version,
    original_credits: original,
    remaining_credits: remaining,
    valid_from: "2026-09-01T00:00:00Z",
    expires_at: "2026-10-01T00:00:00Z",
    source_type,
    source_id: "cycle",
  };
}

function usage(...grants: BillingGrant[]) {
  return planUsage({
    billing_account_id: "billing-1",
    current_credits: grants.reduce((sum, item) => sum + item.remaining_credits, 0),
    active_grants: grants,
  });
}

describe("the plan's usage, as the menu-bar item shows it", () => {
  const plans: BillingPlan[] = [{ ...plan, mode: "subscription" }];

  it("counts the subscription cycle alone, so a spent signup grant hides nothing", () => {
    const cycle = summary(400);
    cycle.active_grants[0]!.expires_at = "2026-10-01T00:00:00Z";
    const withSignup: BillingSummary = {
      ...cycle,
      current_credits: 400 + 250,
      active_grants: [
        ...cycle.active_grants,
        {
          id: "signup",
          package_code: null,
          package_version: null,
          original_credits: 250,
          remaining_credits: 250,
          valid_from: "2026-08-01T00:00:00Z",
          expires_at: null,
          source_type: "comma_signup",
          source_id: null,
        },
      ],
    };
    expect(planUsage(withSignup)).toEqual({
      usedPercent: 60,
      resetsAt: "2026-10-01T00:00:00Z",
      ends: false,
      otherCredits: 250,
    });
    // The low-credit warning is unchanged: it still knows no plan for the signup grant.
    expect(creditAllowance(withSignup, plans)).toBeNull();
  });

  it("counts an upgrade by the prorated credits it granted, not the new plan's allowance", () => {
    // A 20M plan upgraded to a 40M one with 14 of 30 days left: the cycle gains 40M × 14/30.
    expect(
      usage(
        grant("value", 20_000_000, 20_000_000),
        grant("upgrade", 18_666_667, 18_666_667)
      )?.usedPercent
    ).toBe(0);
    expect(
      usage(grant("value", 20_000_000, 0), grant("upgrade", 18_666_667, 3_866_667))
        ?.usedPercent
    ).toBe(90);
  });

  it("counts a redeemed code's cycle, and is unknown without a cycle or what it was issued with", () => {
    expect(
      usage(grant("redeemed", 1000, 250, "redeem_subscription_cycle"))
    ).toMatchObject({
      usedPercent: 75,
      otherCredits: 0,
    });
    expect(usage(grant("signup", 500, 500, "comma_signup"))).toBeNull();
    // An older server does not send what a grant was issued with: the menu shows the balance.
    expect(
      usage({ ...grant("cycle", 1000, 250), original_credits: undefined })
    ).toBeNull();
  });

  it("says a cancelled plan ends only when the cycle's credits last to the end of the period", () => {
    const cancelled = (expiresAt: string): BillingSummary => ({
      ...summary(1000),
      active_grants: [{ ...grant("cycle", 1000, 1000), expires_at: expiresAt }],
      active_subscription: {
        package_code: plan.package_code,
        package_version: plan.package_version,
        status: "active",
        source_id: "sub",
        source_metadata: {
          cancel_at_period_end: true,
          current_period_end: Date.parse("2027-09-01T00:00:00Z") / 1000,
        },
      },
    });
    expect(planUsage(cancelled("2027-09-01T00:00:00Z"))?.ends).toBe(true);
    // An annual plan's monthly grant expires first: its credits reset then.
    expect(planUsage(cancelled("2026-10-01T00:00:00Z"))?.ends).toBe(false);
  });

  it("says a redeemed code's plan ends when its credits expire: nothing renews it", () => {
    expect(
      usage(grant("redeemed", 1000, 250, "redeem_subscription_cycle"))
    ).toMatchObject({ resetsAt: "2026-10-01T00:00:00Z", ends: true });
  });

  it("says a self-hosted workspace's credits have no limit", async () => {
    const t = setup();
    t.api.on("GET", summaryPath(), {
      billing_account_id: "billing-1",
      current_credits: 0,
      active_grants: [
        {
          id: "selfhost",
          package_code: null,
          package_version: null,
          original_credits: 0,
          remaining_credits: 0,
          valid_from: "2020-01-01T00:00:00Z",
          expires_at: "9999-12-31T23:59:59Z",
          source_type: "selfhost",
          source_id: WS,
        },
      ],
    });
    const page = t.watch<BillingValue>({ topic: "billing" });
    await t.time.pass(100);
    expect(page()).toMatchObject({ status: "ready", unlimited: true, planUsage: null });
  });
});

describe("the low-credit warning", () => {
  it("warns at each lower threshold, stays closed once dismissed, and comes back for new grants", async () => {
    const t = setup();
    let current = summary(500);
    t.api.on("GET", summaryPath(), () => json(200, current));
    const topic = { topic: "creditWarning", workspace: WS };
    const warning = t.watch<CreditWarning | null>(topic);
    await t.time.pass(100);
    expect(warning()).toEqual({ percent: 50, threshold: 50 });

    await t.client.call("billing.dismissWarning", { workspace: WS });
    await t.time.pass(100);
    expect(warning()).toBeNull();
    // Still at 50%: a read a minute later shows nothing.
    await t.time.pass(60_000, 1_000);
    expect(warning()).toBeNull();

    for (const [remaining, threshold] of [
      [100, 10],
      [50, 5],
    ] as const) {
      current = summary(remaining);
      await t.client.call("billing.refresh", { workspace: WS });
      await t.time.pass(100);
      expect(warning()).toEqual({ percent: remaining / 10, threshold });
      await t.client.call("billing.dismissWarning", { workspace: WS });
      await t.time.pass(100);
      expect(warning()).toBeNull();
    }

    // The dismissal is kept on the device: a new core does not warn again for the same grants.
    t.core.close();
    const again = setup(t.host);
    again.api.on("GET", summaryPath(), () => json(200, current));
    const shown = again.watch<CreditWarning | null>(topic);
    await again.time.pass(100);
    expect(shown()).toBeNull();
    current = summary(500, "grant-2");
    await again.client.call("billing.refresh", { workspace: WS });
    await again.time.pass(100);
    expect(shown()).toEqual({ percent: 50, threshold: 50 });
  });

  it("does not warn early from rounding, guess at unknown grants, or keep a warning after a failed read", async () => {
    const t = setup();
    let current: BillingSummary | null = summary(501);
    t.api.on("GET", summaryPath(), () => (current ? json(200, current) : offline()));
    const warning = t.watch<CreditWarning | null>({
      topic: "creditWarning",
      workspace: WS,
    });
    await t.time.pass(100);
    expect(warning()).toBeNull();

    current = summary(100);
    current.active_grants[0]!.package_code = null;
    await t.client.call("billing.refresh", { workspace: WS });
    await t.time.pass(100);
    expect(warning()).toBeNull();

    current = summary(100);
    await t.client.call("billing.refresh", { workspace: WS });
    await t.time.pass(100);
    expect(warning()).toEqual({ percent: 10, threshold: 10 });

    current = null;
    await t.time.pass(60_000, 1_000);
    expect(warning()).toBeNull();
  });

  it("calls spent credits or every grant expired out of credits, even after a low warning was closed", async () => {
    const t = setup();
    let current: BillingSummary = summary(50);
    t.api.on("GET", summaryPath(), () => json(200, current));
    const warning = t.watch<CreditWarning | null>({
      topic: "creditWarning",
      workspace: WS,
    });
    await t.time.pass(100);
    expect(warning()).toEqual({ percent: 5, threshold: 5 });
    await t.client.call("billing.dismissWarning", { workspace: WS });

    current = summary(0);
    await t.client.call("billing.refresh", { workspace: WS });
    await t.time.pass(100);
    expect(warning()).toEqual({ percent: 0, threshold: 0 });

    current = { ...summary(0), active_grants: [] };
    await t.client.call("billing.refresh", { workspace: WS });
    await t.time.pass(100);
    expect(warning()).toEqual({ percent: 0, threshold: 0 });

    // A spent grant whose package is unknown stays silent: it may be unlimited.
    current = summary(0, "grant-unknown");
    current.active_grants[0]!.package_code = null;
    await t.client.call("billing.refresh", { workspace: WS });
    await t.time.pass(100);
    expect(warning()).toBeNull();
  });

  it("reads the balance once a minute while watched, the plans once, and nothing once let go", async () => {
    const t = setup();
    t.api.on("GET", summaryPath(), summary(1000));
    const topic = { topic: "creditWarning", workspace: WS };
    t.watch(topic);
    await t.time.pass(100);
    expect(t.api.seen("GET", summaryPath())).toHaveLength(1);
    await t.time.pass(60_000, 1_000);
    expect(t.api.seen("GET", summaryPath())).toHaveLength(2);
    expect(t.api.seen("GET", plansPath)).toHaveLength(1);
    // Let go, the topic is kept a minute more (a page that comes straight back), then nothing is read.
    t.unwatch(topic);
    await t.time.pass(180_000, 10_000);
    expect(t.api.seen("GET", summaryPath())).toHaveLength(3);
  });
});

describe("the usage and billing page", () => {
  it("shows the preferred workspace's plans and balance, kept on the device for the next run", async () => {
    const t = setup();
    t.api.on("GET", summaryPath("ws-2"), summary(250));
    const page = t.watch<BillingValue>({ topic: "billing", prefer: "ws-2" });
    await t.time.pass(100);
    expect(page()).toMatchObject({
      status: "ready",
      workspace: { id: "ws-2", name: "Team" },
      plans: [{ plan_key: "monthly" }],
      summary: { current_credits: 250 },
      allowance: { percent: 25, total: 1000 },
      unlimited: false,
    });
    t.core.close();

    // Offline next time: what was read shows.
    const host = t.host;
    const again = setup(host);
    host.api.on("GET", summaryPath("ws-2"), offline());
    host.api.on("GET", plansPath, offline());
    host.api.on("GET", "/v1/comma/workspaces", offline());
    const cached = again.watch<BillingValue>({ topic: "billing", prefer: "ws-2" });
    await again.time.pass(100);
    expect(cached()).toMatchObject({
      status: "ready",
      summary: { current_credits: 250 },
    });
  });

  it("says it is unavailable when nothing could be read, and reads again when asked", async () => {
    const t = setup();
    let up = false;
    t.api.on("GET", summaryPath(), () => (up ? json(200, summary(1000)) : offline()));
    const page = t.watch<BillingValue>({ topic: "billing" });
    await t.time.pass(100);
    expect(page()).toEqual({ status: "unavailable" });
    up = true;
    await t.client.call("billing.refresh", {});
    await t.time.pass(100);
    expect(page()).toMatchObject({ status: "ready", workspace: { id: WS } });
  });

  it("reads once for a page refreshed as it opens, and again for a refresh after that read", async () => {
    const t = setup();
    t.api.on("GET", summaryPath(), summary(1000));
    const reads = () =>
      ["/v1/comma/workspaces", plansPath, summaryPath()].map(
        (path) => t.api.seen("GET", path).length
      );
    // The page starts the topic, and its entry asks again while that read runs.
    const release = t.api.hold("GET", summaryPath());
    const page = t.watch<BillingValue>({ topic: "billing" });
    await t.time.pass(100);
    const entered = t.client.call("billing.refresh", {});
    await t.time.pass(100);
    release();
    await t.time.pass(100);
    await entered;
    expect(page()).toMatchObject({
      status: "ready",
      summary: { current_credits: 1000 },
    });
    expect(reads()).toEqual([1, 1, 1]);

    const again = t.client.call("billing.refresh", {});
    await t.time.pass(100);
    await again;
    expect(reads()).toEqual([2, 2, 2]);
  });

  it("sends Stripe back to the API's return page for this environment", async () => {
    const t = setup();
    t.api.on("POST", `/v1/comma/workspaces/${WS}/billing/checkout`, {
      id: "cs_1",
      provider: "stripe",
      url: "https://checkout.stripe.com/c/pay/cs_1",
    });
    t.api.on("POST", `/v1/comma/workspaces/${WS}/billing/portal`, {
      id: "bps_1",
      provider: "stripe",
      url: "https://billing.stripe.com/p/session/1",
    });
    const checkout = t.client.call("billing.checkout", {
      workspace: WS,
      plan: "monthly",
      return: back,
    });
    const portal = t.client.call("billing.portal", { workspace: WS, return: back });
    await t.time.pass(100);
    expect(await checkout).toEqual({ url: "https://checkout.stripe.com/c/pay/cs_1" });
    expect(await portal).toEqual({ url: "https://billing.stripe.com/p/session/1" });
    expect(
      t.api.seen("POST", `/v1/comma/workspaces/${WS}/billing/checkout`)[0]!.body
    ).toMatchObject({
      plan_key: "monthly",
      success_url: returnPage("success"),
      cancel_url: returnPage("cancel"),
    });
    expect(
      t.api.seen("POST", `/v1/comma/workspaces/${WS}/billing/portal`)[0]!.body
    ).toMatchObject({
      return_url: returnPage("portal"),
    });
  });

  it("confirms a quoted plan change with the quote's own request id, then reads the balance again", async () => {
    const t = setup();
    t.api.on("GET", summaryPath(), summary(1000));
    const preview = {
      amount_minor: 1000,
      currency: "usd",
      effect: "upgrade",
      current_price_id: "price_current",
      proration_date: 1234,
      period_end: 5678,
    };
    t.api.on(
      "POST",
      `/v1/comma/workspaces/${WS}/billing/subscription/preview`,
      preview
    );
    t.api.on("POST", `/v1/comma/workspaces/${WS}/billing/subscription/change`, {
      id: "change-1",
      provider: "stripe",
      effect: "payment_required",
      url: "https://checkout.stripe.com/pay/upgrade",
    });
    const quoted = t.client.call("billing.previewChange", {
      workspace: WS,
      plan: "pro",
    });
    await t.time.pass(100);
    const quote = (await quoted) as { preview: unknown; request: string };
    expect(quote.preview).toEqual(preview);
    const changed = t.client.call("billing.change", {
      workspace: WS,
      plan: "pro",
      preview: quote.preview,
      request: quote.request,
      return: back,
    });
    await t.time.pass(100);
    expect(await changed).toEqual({ url: "https://checkout.stripe.com/pay/upgrade" });
    expect(
      t.api.seen("POST", `/v1/comma/workspaces/${WS}/billing/subscription/change`)[0]!
        .body
    ).toEqual({
      plan_key: "pro",
      current_price_id: "price_current",
      proration_date: 1234,
      period_end: 5678,
      success_url: returnPage("subscription"),
      client_request_id: quote.request,
    });
    expect(t.api.seen("GET", summaryPath())).toHaveLength(1);
  });

  it("refuses a redeem with the server's code, and reads the balance after one that worked", async () => {
    const t = setup();
    const redeemPath = `/v1/comma/workspaces/${WS}/billing/redeem`;
    t.api.on("GET", summaryPath(), summary(1000));
    t.api.on("POST", redeemPath, json(404, { error: "redeem_code_not_found" }));
    const refused = expect(
      t.client.call("billing.redeem", { workspace: WS, code: "NOPE" })
    ).rejects.toMatchObject({ code: "redeem_code_not_found" });
    await t.time.pass(100);
    await refused;
    t.api.on("POST", redeemPath, { grant: { remaining_credits: 500 } });
    const redeemed = t.client.call("billing.redeem", { workspace: WS, code: " GIFT " });
    await t.time.pass(100);
    await redeemed;
    expect(t.api.seen("POST", redeemPath)[1]!.body).toMatchObject({ code: "GIFT" });
    expect(t.api.seen("GET", summaryPath())).toHaveLength(1);
  });

  it("after a return from Stripe, reads the balance on a backoff until it changes", async () => {
    const t = setup();
    let current = summary(1000);
    t.api.on("GET", summaryPath(), () => json(200, current));
    const page = t.watch<BillingValue>({ topic: "billing" });
    await t.time.pass(100);
    expect(t.api.seen("GET", summaryPath())).toHaveLength(1);
    await t.client.call("billing.returned", { workspace: WS });
    // 600 ms, then 1.2 s more: the webhook has not landed.
    await t.time.pass(1_900, 100);
    expect(t.api.seen("GET", summaryPath())).toHaveLength(3);
    current = summary(2000, "grant-2");
    await t.time.pass(2_500, 100);
    expect(t.api.seen("GET", summaryPath())).toHaveLength(4);
    expect(page()).toMatchObject({ summary: { current_credits: 2000 } });
    // It changed: no more reads.
    await t.time.pass(40_000, 1_000);
    expect(t.api.seen("GET", summaryPath())).toHaveLength(4);
  });
});

describe("a run of the billing page and warning, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    let current = summary(80);
    t.api.on("GET", summaryPath(), () => json(200, current));
    t.watch({ topic: "billing" });
    await t.time.pass(100);
    t.watch({ topic: "creditWarning", workspace: WS });
    await t.time.pass(100);
    await t.client.call("billing.dismissWarning", { workspace: WS });
    current = summary(40);
    await t.time.pass(60_000, 1_000);
    await t.client.call("billing.returned", { workspace: WS });
    await t.time.pass(5_000, 100);

    const recorded = t.core.recorder!;
    const kinds = new Set(recorded.inputs.map((input) => input.kind));
    expect([...kinds]).toEqual(expect.arrayContaining(["tick", "response", "ui"]));
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    // A log told differently plays to different outputs: the comparison sees what the core showed.
    const told = structuredClone(recorded.inputs);
    const first = told.find(
      (input) => input.kind === "response" && input.request.path === summaryPath()
    )!;
    if (first.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(first.body));
    expect(body).toContain('"current_credits":80');
    first.body = base64(
      new TextEncoder().encode(
        body.replace('"current_credits":80', '"current_credits":800')
      )
    );
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
