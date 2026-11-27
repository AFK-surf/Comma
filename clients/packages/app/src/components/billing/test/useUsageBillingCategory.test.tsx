import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import { SettingsPanel } from "@comma/ui/components/settings-panel";
import type { BillingPlan } from "@comma/core-client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { teamsSignupUrl, useUsageBillingCategory } from "../useUsageBillingCategory";

const openExternal = vi.hoisted(() => vi.fn(async () => undefined));
const activeChannel = vi.hoisted(() => ({
  current: "prod" as "prod" | "staging" | "dev",
}));

vi.mock("../../../nativePlatformActions", () => ({
  openNativePlatformExternalUrl: openExternal,
  openNativePlatformExternalUrlFromUserAction: vi.fn(async () => undefined),
}));

vi.mock("@comma/config", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@comma/config")>();
  return {
    ...actual,
    getActiveCommaConfig: () => ({
      ...actual.getActiveCommaConfig(),
      channel: activeChannel.current,
    }),
  };
});

afterEach(() => {
  openExternal.mockClear();
  activeChannel.current = "prod";
});

const hostedSubscriptionPlan: BillingPlan = {
  plan_key: "comma_pro_plus:1:month",
  package_code: "comma_pro_plus",
  package_version: "1",
  name: "Comma Pro Plus",
  currency: "usd",
  amount_minor: 8000,
  grant_credits: 80_000_000,
  mode: "subscription",
  billing_period: "month",
};

const creditPackPlan: BillingPlan = {
  plan_key: "comma_addon_4m:1:once",
  package_code: "comma_addon_4m",
  package_version: "1",
  name: "Comma 4M Credit Pack",
  currency: "usd",
  amount_minor: 499,
  grant_credits: 4_000_000,
  mode: "payment",
  billing_period: "once",
};

function BillingHarness() {
  const category = useUsageBillingCategory(true);
  return <SettingsPanel sections={[...category.sections]} title={category.label} />;
}

function renderBilling(plans: BillingPlan[]) {
  const core = createScriptedCore({
    values: (topic) => {
      if (topic.topic === "workspace") {
        return {
          status: "ready",
          workspace: { id: "ws-1", name: "Personal" },
        };
      }
      if (topic.topic === "billing") {
        return {
          status: "ready",
          workspace: { id: "ws-1", name: "Personal" },
          plans,
          summary: {
            current_credits: 12_000_000,
            active_grants: [],
          },
          allowance: null,
        };
      }
      return undefined;
    },
    calls: () => null,
  });
  return render(core.wrap(<BillingHarness />));
}

describe("teamsSignupUrl", () => {
  it("maps prod, staging, and dev channels with optional zh-CN locale", () => {
    expect(teamsSignupUrl("prod", false)).toBe(
      "https://teams.bridge.surf/signup/teams?from=personal"
    );
    expect(teamsSignupUrl("prod", true)).toBe(
      "https://teams.bridge.surf/signup/teams?from=personal&locale=zh_Hans"
    );
    expect(teamsSignupUrl("staging", false)).toBe(
      "https://teams-staging.bridge.surf/signup/teams?from=personal"
    );
    expect(teamsSignupUrl("staging", true)).toBe(
      "https://teams-staging.bridge.surf/signup/teams?from=personal&locale=zh_Hans"
    );
    const devUrl = new URL(teamsSignupUrl("dev", false));
    expect(devUrl.protocol).toBe("http:");
    expect(devUrl.hostname).toBe("127.0.0.1");
    expect(devUrl.port).toBe(String(4101));
    expect(devUrl.pathname).toBe("/signup/teams");
    expect(devUrl.searchParams.get("from")).toBe("personal");
    expect(devUrl.searchParams.get("locale")).toBeNull();

    const devZhUrl = new URL(teamsSignupUrl("dev", true));
    expect(devZhUrl.protocol).toBe("http:");
    expect(devZhUrl.hostname).toBe("127.0.0.1");
    expect(devZhUrl.port).toBe(String(4101));
    expect(devZhUrl.pathname).toBe("/signup/teams");
    expect(devZhUrl.searchParams.get("from")).toBe("personal");
    expect(devZhUrl.searchParams.get("locale")).toBe("zh_Hans");
  });
});

describe("useUsageBillingCategory Comma for Teams section", () => {
  it("shows Comma for Teams at the end when hosted subscription plans exist and opens the channel URL", async () => {
    activeChannel.current = "staging";
    renderBilling([hostedSubscriptionPlan, creditPackPlan]);

    expect(await screen.findByText("Comma for Teams")).toBeVisible();
    expect(screen.getByText("Buy seats for your team")).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: "Buy seats" }));
    expect(openExternal).toHaveBeenCalledWith(
      "https://teams-staging.bridge.surf/signup/teams?from=personal"
    );
  });

  it("hides Comma for Teams when no hosted subscription plan is present", async () => {
    renderBilling([creditPackPlan]);
    expect(await screen.findByText("No subscription plans available.")).toBeVisible();
    expect(screen.queryByText("Comma for Teams")).not.toBeInTheDocument();
  });

  it("hides Comma for Teams when the catalog is empty (self-hosted)", async () => {
    renderBilling([]);
    expect(await screen.findByText("No subscription plans available.")).toBeVisible();
    expect(screen.queryByText("Comma for Teams")).not.toBeInTheDocument();
  });
});
