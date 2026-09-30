import userEvent from "@testing-library/user-event";
import { CommaI18nProvider } from "@comma/i18n/react";
import { SettingsPanel } from "@comma/ui";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { StrictMode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient } from "../api";
import { useUsageBillingCategory } from "../components/billing/useUsageBillingCategory";

vi.mock("../runtime-chat/nativePlatformActions", () => ({
  openNativePlatformExternalUrl: vi.fn(async () => undefined),
  openNativePlatformExternalUrlFromUserAction: vi.fn(
    async (resolveUrl: () => Promise<string>) => {
      await resolveUrl();
    }
  ),
}));

afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
  window.location.hash = "";
});

/** The category as Settings renders it: its rows through the shared panel. */
function UsageBilling({ api }: { api: CommaApiClient }) {
  const category = useUsageBillingCategory(api, true);
  return <SettingsPanel sections={[...category.sections]} title={category.label} />;
}

function renderUsageBilling(api: CommaApiClient, strict = false) {
  const tree = (
    <CommaI18nProvider>
      <UsageBilling api={api} />
    </CommaI18nProvider>
  );
  return render(strict ? <StrictMode>{tree}</StrictMode> : tree);
}

function abortOnFirstCall<T>(value: T) {
  let calls = 0;
  return vi.fn((options?: { signal?: AbortSignal }) => {
    calls += 1;
    if (calls > 1) return Promise.resolve(value);
    return new Promise<T>((_resolve, reject) => {
      options?.signal?.addEventListener(
        "abort",
        () => reject(new TypeError("Failed to fetch")),
        { once: true }
      );
    });
  });
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
const workspaces = [{ id: "workspace-1", group_id: "group-1", name: "Personal" }];

describe("useUsageBillingCategory", () => {
  it("shows an empty catalog without unavailable subscription controls", async () => {
    renderUsageBilling(
      billingApi(vi.fn(async () => billingSummary({ current_credits: 20000000 })))
    );
    expect(await screen.findByText("20,000,000")).toBeVisible();
    expect(screen.getByText("No subscription")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Manage" })).not.toBeInTheDocument();
    // Nothing in the catalog can size the balance, so no meter claims to.
    expect(screen.queryByRole("progressbar")).not.toBeInTheDocument();
    expect(screen.getByText("No subscription plans available.")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Monthly" })).not.toBeInTheDocument();
    expect(screen.getByText("No credit packs available.")).toBeVisible();
  });

  it("keeps polling a billing return when positive credits have not changed from baseline", async () => {
    vi.useFakeTimers();
    window.location.hash = "#/settings?category=usage-billing&billing-return=success";

    const baseline = billingSummary({ current_credits: 12 });
    const changed = billingSummary({ current_credits: 712 });
    const getBillingSummary = vi
      .fn()
      .mockResolvedValueOnce(baseline)
      .mockResolvedValueOnce(baseline)
      .mockResolvedValue(changed);

    renderUsageBilling(billingApi(getBillingSummary));

    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(getBillingSummary).toHaveBeenCalledTimes(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(600);
    });
    expect(getBillingSummary).toHaveBeenCalledTimes(2);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_200);
    });
    expect(getBillingSummary).toHaveBeenCalledTimes(3);
    expect(screen.getByText("712")).toBeInTheDocument();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });
    expect(getBillingSummary).toHaveBeenCalledTimes(3);
  });

  it("keeps polling a billing return when the active subscription matches baseline", async () => {
    vi.useFakeTimers();
    window.location.hash =
      "#/settings?category=usage-billing&billing-return=subscription";

    const baseline = billingSummary({
      current_credits: 20_000_000,
      active_subscription: {
        package_code: "comma_value",
        package_version: "v1",
        source_id: "sub_1",
        status: "active",
      },
    });
    const changed = billingSummary({
      current_credits: 20_000_000,
      active_subscription: {
        package_code: "comma_pro",
        package_version: "v1",
        source_id: "sub_1",
        status: "active",
      },
    });
    const getBillingSummary = vi
      .fn()
      .mockResolvedValueOnce(baseline)
      .mockResolvedValueOnce(baseline)
      .mockResolvedValue(changed);

    renderUsageBilling(billingApi(getBillingSummary));

    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
      await vi.advanceTimersByTimeAsync(600);
    });
    expect(getBillingSummary).toHaveBeenCalledTimes(2);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_200);
    });
    expect(getBillingSummary).toHaveBeenCalledTimes(3);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });
    expect(getBillingSummary).toHaveBeenCalledTimes(3);
  });

  it("does not show a billing outage when StrictMode cancels the first load", async () => {
    const api = {
      listBillingPlans: abortOnFirstCall([topupPack]),
      listWorkspaces: abortOnFirstCall(workspaces),
      getBillingSummary: vi.fn(async () => billingSummary({ current_credits: 12 })),
    } as unknown as CommaApiClient;

    renderUsageBilling(api, true);

    expect(await screen.findByText("12")).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("lists plans and packs as rows of the page and refreshes credits after redemption", async () => {
    const getBillingSummary = vi
      .fn()
      .mockResolvedValueOnce(billingSummary({ current_credits: 12 }))
      .mockResolvedValueOnce(billingSummary({ current_credits: 712 }));
    const redeemBillingCode = vi.fn(async () => ({ idempotent: false }));
    const createBillingCheckout = vi.fn(async () => ({
      url: "https://checkout.stripe.com/test",
    }));
    const api = {
      listBillingPlans: vi.fn(async () => [valuePlan, topupPack, valueAnnualPlan]),
      listWorkspaces: vi.fn(async () => workspaces),
      getBillingSummary,
      redeemBillingCode,
      createBillingCheckout,
    } as unknown as CommaApiClient;

    renderUsageBilling(api);

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
    expect(screen.getByText("One-time · 700 credits")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "$9.00" }));
    await waitFor(() => {
      expect(createBillingCheckout).toHaveBeenCalledWith(
        "workspace-1",
        "comma_topup_700"
      );
    });

    // Redeeming has a section of its own.
    expect(screen.getByRole("heading", { name: "Redeem credits" })).toBeVisible();
    const codeInput = screen.getByPlaceholderText("Enter redeem code");
    await userEvent.type(codeInput, " AB ");
    expect(screen.getByRole("button", { name: "Redeem" })).toBeDisabled();
    await userEvent.type(codeInput, "{Enter}");
    expect(redeemBillingCode).not.toHaveBeenCalled();

    await userEvent.clear(codeInput);
    await userEvent.type(codeInput, " ABC ");
    expect(screen.getByRole("button", { name: "Redeem" })).toBeEnabled();
    await userEvent.click(screen.getByRole("button", { name: "Redeem" }));

    await waitFor(() => {
      expect(redeemBillingCode).toHaveBeenCalledWith("workspace-1", "ABC");
    });
    expect(getBillingSummary).toHaveBeenCalledTimes(2);
    expect(
      screen.getByText("Code redeemed. Your credits are ready.")
    ).toBeInTheDocument();
  });

  it("only disables the checkout button that is currently opening", async () => {
    let resolveCheckout!: (session: { url: string }) => void;
    const checkout = new Promise<{ url: string }>((resolve) => {
      resolveCheckout = resolve;
    });
    const createBillingCheckout = vi.fn(() => checkout);
    const api = {
      listBillingPlans: vi.fn(async () => [valuePlan, proPlan]),
      listWorkspaces: vi.fn(async () => workspaces),
      getBillingSummary: vi.fn(async () => billingSummary({ current_credits: 12 })),
      createBillingCheckout,
    } as unknown as CommaApiClient;

    renderUsageBilling(api);

    const buttons = await screen.findAllByRole("button", { name: "Subscribe" });
    await userEvent.click(buttons[0]!);

    expect(await screen.findByRole("button", { name: "Opening…" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Subscribe" })).toBeEnabled();
    expect(createBillingCheckout).toHaveBeenCalledWith("workspace-1", "comma_value_v1");

    resolveCheckout({ url: "https://checkout.stripe.com/test" });
    await waitFor(() => {
      expect(screen.getAllByRole("button", { name: "Subscribe" })).toHaveLength(2);
    });
  });

  it("changes the existing subscription when an active subscriber upgrades", async () => {
    const createBillingCheckout = vi.fn();
    const changeBillingSubscription = vi.fn(async () => ({
      url: "https://billing.stripe.com/test/change",
    }));
    const api = {
      listBillingPlans: vi.fn(async () => [valuePlan, proPlan]),
      listWorkspaces: vi.fn(async () => workspaces),
      getBillingSummary: vi.fn(async () =>
        billingSummary({
          current_credits: 20_000_000,
          active_subscription: {
            package_code: "comma_value",
            package_version: "v1",
            source_id: "sub_1",
            status: "active",
          },
        })
      ),
      createBillingCheckout,
      changeBillingSubscription,
    } as unknown as CommaApiClient;

    renderUsageBilling(api);

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

    await waitFor(() => {
      expect(changeBillingSubscription).toHaveBeenCalledWith(
        "workspace-1",
        "comma_pro_v1"
      );
    });
    expect(createBillingCheckout).not.toHaveBeenCalled();
  });

  it("measures active grants and separates credit expiry from billing status", async () => {
    const api = {
      listBillingPlans: vi.fn(async () => [valuePlan]),
      listWorkspaces: vi.fn(async () => workspaces),
      getBillingSummary: vi.fn(async () => ({
        billing_account_id: "billing-1",
        current_credits: 12_000_000,
        active_subscription: {
          package_code: "comma_value",
          package_version: "v1",
          source_id: "sub_1",
          status: "active",
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
      })),
    } as unknown as CommaApiClient;

    renderUsageBilling(api);

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
  };
}

function billingApi(getBillingSummary: ReturnType<typeof vi.fn>): CommaApiClient {
  return {
    listBillingPlans: vi.fn(async () => []),
    listWorkspaces: vi.fn(async () => workspaces),
    getBillingSummary,
  } as unknown as CommaApiClient;
}
