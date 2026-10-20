import userEvent from "@testing-library/user-event";
import { CommaI18nProvider } from "@comma/i18n/react";
import { SettingsPanel } from "@comma/ui/components/settings-panel";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useUsageBillingCategory } from "../components/billing/useUsageBillingCategory";

vi.mock("../nativePlatformActions", () => ({
  openNativePlatformExternalUrl: vi.fn(async () => undefined),
  openNativePlatformExternalUrlFromUserAction: vi.fn(
    async (resolveUrl: () => Promise<string>) => {
      await resolveUrl();
    }
  ),
}));

afterEach(() => {
  window.location.hash = "";
});

/** The category as Settings renders it: its rows through the shared panel. */
function UsageBilling() {
  const category = useUsageBillingCategory(true);
  return <SettingsPanel sections={[...category.sections]} title={category.label} />;
}

type Summary = ReturnType<typeof billingSummary>;

/** The page over a core that says `value` for `billing` and answers calls with `calls`. */
function renderUsageBilling(
  value: unknown,
  calls: (name: string, params: Record<string, unknown>) => unknown = () => null
) {
  const seen: [string, Record<string, unknown>][] = [];
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "billing" ? value : undefined),
    calls: (name, params) => {
      seen.push([name, params as Record<string, unknown>]);
      return calls(name, params as Record<string, unknown>);
    },
  });
  render(
    core.wrap(
      <CommaI18nProvider>
        <UsageBilling />
      </CommaI18nProvider>
    )
  );
  return {
    core,
    seen,
    named: (name: string) => seen.filter(([n]) => n === name).map(([, p]) => p),
  };
}

function ready(summary: Summary, plans: unknown[] = [], allowance: unknown = null) {
  return {
    status: "ready",
    workspace: { id: "workspace-1", name: "Personal" },
    plans,
    summary,
    allowance,
  };
}

const valuePlan = {
  plan_key: "comma_value_v1",
  package_code: "comma_value",
  package_version: "v1",
  mode: "subscription" as const,
  name: "Comma Value",
  currency: "usd",
  amount_minor: 2_000,
  grant_credits: 20_000_000,
  billing_period: "month",
  grant_period: "current_period",
};
const proPlan = {
  plan_key: "comma_pro_v1",
  package_code: "comma_pro",
  package_version: "v1",
  mode: "subscription" as const,
  name: "Comma Pro",
  currency: "usd",
  amount_minor: 6_000,
  grant_credits: 60_000_000,
  billing_period: "month",
  grant_period: "current_period",
};
const valueAnnualPlan = {
  ...valuePlan,
  plan_key: "comma_value_annual_v1",
  package_version: "2026-09-annual",
  amount_minor: 20_000,
  billing_period: "year",
};
const topupPack = {
  plan_key: "comma_topup_700",
  package_code: "comma_topup",
  package_version: "v1",
  mode: "payment" as const,
  name: "700 credits",
  currency: "usd",
  amount_minor: 900,
  grant_credits: 700,
};
describe("useUsageBillingCategory", () => {
  it("shows an empty catalog without unavailable subscription controls", async () => {
    renderUsageBilling(ready(billingSummary({ current_credits: 20000000 })));
    expect(await screen.findByText("20,000,000")).toBeVisible();
    expect(screen.getByText("No subscription")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Manage" })).not.toBeInTheDocument();
    // Nothing in the catalog can size the balance, so no meter claims to.
    expect(screen.queryByRole("progressbar")).not.toBeInTheDocument();
    expect(screen.getByText("No subscription plans available.")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Monthly" })).not.toBeInTheDocument();
    expect(screen.getByText("No credit packs available.")).toBeVisible();
  });

  it("says billing is unavailable when the core could read nothing, and reads again on entering", async () => {
    const page = renderUsageBilling({ status: "unavailable" });
    expect(
      (
        await screen.findAllByText(
          "Billing is temporarily unavailable. Try again shortly."
        )
      )[0]
    ).toBeVisible();
    // No workspace was read, yet entering asks for the plans and the balance again.
    await waitFor(() => expect(page.named("billing.refresh")).toEqual([{}]));
  });

  it("tells the core of a billing return, even one that arrives while the category is open", async () => {
    window.location.hash = "#/settings?category=usage-billing&billing-return=success";
    const page = renderUsageBilling(ready(billingSummary()));
    await waitFor(() =>
      expect(page.named("billing.returned")).toEqual([{ workspace: "workspace-1" }])
    );
    // Read once, the parameter leaves the hash so the next return changes it again.
    expect(window.location.hash).toBe("#/settings?category=usage-billing");

    // Electron's return moves the hash in place; the page does not reload.
    act(() => {
      window.location.hash = "#/settings?category=usage-billing&billing-return=portal";
      window.dispatchEvent(new HashChangeEvent("hashchange"));
    });
    await waitFor(() => expect(page.named("billing.returned")).toHaveLength(2));
    // A cancelled checkout reads nothing again.
    act(() => {
      window.location.hash = "#/settings?category=usage-billing&billing-return=cancel";
      window.dispatchEvent(new HashChangeEvent("hashchange"));
    });
    await act(async () => {});
    expect(page.named("billing.returned")).toHaveLength(2);
  });

  it("asks the core to read the balance again on entering and when the window regains focus", async () => {
    const page = renderUsageBilling(ready(billingSummary({ current_credits: 12 })));
    expect(await screen.findByText("12")).toBeVisible();
    // Entering reads all of it, as a topic start does: the menu-bar item can
    // hold the topic, which then reads nothing as the page opens.
    await waitFor(() => expect(page.named("billing.refresh")).toEqual([{}]));
    act(() => {
      window.dispatchEvent(new FocusEvent("focus"));
    });
    await waitFor(() =>
      expect(page.named("billing.refresh")).toEqual([{}, { workspace: "workspace-1" }])
    );
    // The core's newer balance is what shows.
    act(() =>
      page.core.emit("billing", ready(billingSummary({ current_credits: 712 })))
    );
    expect(await screen.findByText("712")).toBeVisible();
  });

  it("lists plans and packs as rows of the page and redeems a code", async () => {
    const page = renderUsageBilling(
      ready(billingSummary({ current_credits: 12 }), [
        valuePlan,
        topupPack,
        valueAnnualPlan,
      ]),
      (name) =>
        name === "billing.checkout" ? { url: "https://checkout.stripe.com/test" } : null
    );

    expect(await screen.findByText("12")).toBeInTheDocument();
    expect(screen.getByText("Personal · Current balance")).toBeInTheDocument();

    expect(screen.getByRole("heading", { name: "Subscription plans" })).toBeVisible();
    expect(screen.getByText("Comma Value")).toBeInTheDocument();
    expect(
      screen.getByText("$20.00 / month · 20,000,000 credits every month")
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Subscribe" })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Annual" }));
    expect(
      screen.getByText("$200.00 / year · 20,000,000 credits every month")
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Subscribe" })).toBeInTheDocument();

    // A credit pack is a settings row of its own in the Buy credits card.
    expect(screen.getByRole("heading", { name: "Buy credits" })).toBeVisible();
    const pack = screen.getByText("700 credits").closest("[data-setting-id]");
    expect(pack).toHaveAttribute("data-setting-id", "billing.packs.comma_topup_700");
    expect(
      screen.getByText(/One-time · 700 credits · Estimated expiry/)
    ).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "$9.00" }));
    await waitFor(() => {
      expect(page.named("billing.checkout")).toEqual([
        {
          workspace: "workspace-1",
          plan: "comma_topup_700",
          return: { apiBase: expect.any(String), environment: expect.any(String) },
        },
      ]);
    });

    // Redeeming has a section of its own.
    expect(screen.getByRole("heading", { name: "Redeem credits" })).toBeVisible();
    const codeInput = screen.getByPlaceholderText("Enter redeem code");
    await userEvent.type(codeInput, " AB ");
    expect(screen.getByRole("button", { name: "Redeem" })).toBeDisabled();
    await userEvent.type(codeInput, "{Enter}");
    expect(page.named("billing.redeem")).toEqual([]);

    await userEvent.clear(codeInput);
    await userEvent.type(codeInput, " ABC ");
    expect(screen.getByRole("button", { name: "Redeem" })).toBeEnabled();
    await userEvent.click(screen.getByRole("button", { name: "Redeem" }));

    await waitFor(() => {
      expect(page.named("billing.redeem")).toEqual([
        { workspace: "workspace-1", code: "ABC" },
      ]);
    });
    expect(
      await screen.findByText("Code redeemed. Your credits are ready.")
    ).toBeInTheDocument();
  });

  it("words a refused redeem by the server's code", async () => {
    renderUsageBilling(ready(billingSummary()), (name) => {
      if (name === "billing.redeem")
        throw Object.assign(new Error("refused"), { code: "redeem_code_expired" });
      return null;
    });
    const codeInput = await screen.findByPlaceholderText("Enter redeem code");
    await userEvent.type(codeInput, "OLD-CODE");
    await userEvent.click(screen.getByRole("button", { name: "Redeem" }));
    expect(await screen.findByText("That redeem code has expired.")).toBeVisible();
  });

  it("only disables the checkout button that is currently opening", async () => {
    let resolveCheckout!: (session: { url: string }) => void;
    const checkout = new Promise<{ url: string }>((resolve) => {
      resolveCheckout = resolve;
    });
    const page = renderUsageBilling(
      ready(billingSummary({ current_credits: 12 }), [valuePlan, proPlan]),
      (name) => (name === "billing.checkout" ? checkout : null)
    );

    const buttons = await screen.findAllByRole("button", { name: "Subscribe" });
    await userEvent.click(buttons[0]!);

    expect(await screen.findByRole("button", { name: "Opening…" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Subscribe" })).toBeEnabled();
    expect(page.named("billing.checkout")[0]).toMatchObject({
      workspace: "workspace-1",
      plan: "comma_value_v1",
    });

    resolveCheckout({ url: "https://checkout.stripe.com/test" });
    await waitFor(() => {
      expect(screen.getAllByRole("button", { name: "Subscribe" })).toHaveLength(2);
    });
  });

  it("changes the existing subscription when an active subscriber upgrades", async () => {
    const preview = {
      amount_minor: 1_000,
      currency: "usd",
      proration_date: 1780272000,
      current_price_id: "price_value",
      period_end: 1782864000,
      effect: "upgrade" as const,
    };
    const page = renderUsageBilling(
      ready(
        billingSummary({
          current_credits: 20_000_000,
          active_subscription: {
            package_code: "comma_value",
            package_version: "v1",
            source_id: "sub_1",
            status: "active",
          },
        }),
        [valuePlan, proPlan]
      ),
      (name) =>
        name === "billing.previewChange"
          ? { preview, request: "change-1" }
          : name === "billing.change"
            ? { url: "https://billing.stripe.com/test/change" }
            : null
    );

    // The page names the plan you are on (once as status, once in the list)
    // and puts the way to its invoices beside the status.
    expect(await screen.findAllByText("Comma Value")).toHaveLength(2);
    expect(screen.getByText("$20.00 / month · Active")).toBeVisible();
    expect(screen.getByRole("button", { name: "Manage" })).toBeEnabled();

    // The plan you are on is a status, not a dead button.
    expect(screen.getByText("Current plan")).toBeVisible();
    expect(
      screen.queryByRole("button", { name: "Current plan" })
    ).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Upgrade to Comma Pro" }));

    expect(
      await screen.findByRole("dialog", { name: "Confirm plan change" })
    ).toBeVisible();
    expect(screen.getByText(/Pay \$10.00 now/)).toBeVisible();
    expect(page.named("billing.change")).toEqual([]);
    await userEvent.click(screen.getByRole("button", { name: /^Confirm$/ }));
    await waitFor(() => {
      expect(page.named("billing.change")).toEqual([
        {
          workspace: "workspace-1",
          plan: "comma_pro_v1",
          preview,
          request: "change-1",
          return: { apiBase: expect.any(String), environment: expect.any(String) },
        },
      ]);
    });
    expect(page.named("billing.checkout")).toEqual([]);
  });

  it("keeps a hidden annual current plan through its historical key", async () => {
    const currentPlan = {
      plan_key: "cue_max_annual_v1",
      package_code: "comma_max",
      package_version: "annual-v1",
      name: "Comma Max",
      mode: "subscription" as const,
      currency: "usd",
      amount_minor: 200_000,
      billing_period: "year",
      grant_period: "current_period",
      grant_credits: 200_000_000,
    };
    const pro = {
      ...currentPlan,
      plan_key: "comma_pro_annual_v1",
      package_code: "comma_pro",
      name: "Comma Pro",
      amount_minor: 60_000,
      grant_credits: 60_000_000,
    };
    const preview = {
      amount_minor: 0,
      currency: "usd",
      effect: "keep_current" as const,
      current_price_id: "price_historical_max",
      proration_date: 1790000000,
      period_end: 1800000000,
    };
    const page = renderUsageBilling(
      ready(
        {
          billing_account_id: "billing-1",
          current_credits: 200_000_000,
          active_grants: [],
          active_subscription: {
            package_code: currentPlan.package_code,
            package_version: currentPlan.package_version,
            status: "active",
            source_id: "sub_hidden",
            plan: currentPlan,
            source_metadata: {
              scheduled_plan: {
                package_code: pro.package_code,
                package_version: pro.package_version,
                effective_at: 1800000000,
              },
            },
          },
        } as unknown as Summary,
        [
          pro,
          {
            ...pro,
            plan_key: "comma_pro_v1",
            package_version: "v1",
            billing_period: "month",
            amount_minor: 6_000,
          },
        ]
      ),
      (name) =>
        name === "billing.previewChange"
          ? { preview, request: "keep-1" }
          : name === "billing.change"
            ? { url: null }
            : null
    );
    // The plan is no longer offered, yet its scheduled downgrade can be cleared.
    const keep = await screen.findByRole("button", { name: "Keep current plan" });
    await waitFor(() => expect(keep).toBeEnabled());
    expect(screen.getAllByText("Comma Max").length).toBeGreaterThan(0);
    expect(screen.getByText("$2,000.00 / year · Active")).toBeVisible();
    expect(screen.getByRole("button", { name: "Monthly" })).toBeDisabled();
    await userEvent.click(keep);
    await userEvent.click(
      within(
        await screen.findByRole("dialog", { name: "Confirm plan change" })
      ).getByRole("button", { name: "Confirm" })
    );
    await waitFor(() =>
      expect(page.named("billing.change")[0]).toMatchObject({
        workspace: "workspace-1",
        plan: "cue_max_annual_v1",
        preview,
        request: "keep-1",
      })
    );
  });

  it("measures active grants and separates credit expiry from billing status", async () => {
    renderUsageBilling(
      ready(
        {
          billing_account_id: "billing-1",
          current_credits: 12_000_000,
          active_subscription: {
            package_code: "comma_value",
            package_version: "v1",
            source_id: "sub_1",
            status: "active",
            plan: valuePlan,
          },
          active_grants: [
            {
              id: "grant_cycle",
              package_code: "comma_value",
              package_version: "v1",
              remaining_credits: 12_000_000,
              valid_from: "2026-09-01T12:00:00Z",
              expires_at: "2026-10-01T12:00:00Z",
              source_type: "subscription_cycle",
              source_id: "cycle_1",
            },
          ],
        } as unknown as Summary,
        [valuePlan],
        { percent: 60, total: 20_000_000 }
      )
    );

    const bar = await screen.findByRole("progressbar", {
      name: "Credits remaining",
    });
    expect(bar).toHaveAttribute("value", "60");
    expect(screen.getByText("60% left")).toBeVisible();
    expect(
      screen.getByText(
        "Personal · 20,000,000 original credits across active grants · Subscription credits expire Oct 1, 2026"
      )
    ).toBeVisible();
    expect(screen.getByText("$20.00 / month · Active")).toBeVisible();
  });
});

function billingSummary(
  overrides: Partial<{
    current_credits: number;
    active_subscription: {
      package_code: string;
      package_version: string;
      source_id: string;
      status: "active" | "trialing" | "past_due";
    };
  }> = {}
) {
  return {
    billing_account_id: "billing-1",
    current_credits: 0,
    active_grants: [],
    ...overrides,
    ...(overrides.active_subscription
      ? {
          active_subscription: {
            ...overrides.active_subscription,
            plan: [valuePlan, proPlan].find(
              (plan) =>
                plan.package_code === overrides.active_subscription?.package_code
            ),
          },
        }
      : {}),
  };
}
