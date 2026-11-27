import { act, fireEvent, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import {
  BftApiError,
  createBftApi,
  orgContextSchema,
  settingsGeneralSchema,
  type BftM2squareCountry,
  type BftSettingsGeneral,
} from "./api";
import { App } from "./App";
import { ApiContext } from "./resource";
import { navigate } from "./router";
import { SettingsGeneralPage } from "./SettingsGeneralPage";

function makeOrgContext(slug: string) {
  return orgContextSchema.parse({
    user: { id: "user-1", name: "Ada", email: null },
    orgs: [{ slug, name: "Acme Robotics" }],
    org: { slug, name: "Acme Robotics", role: "owner" },
    capabilities: {
      operations: true,
      triage: true,
      information_flow: true,
      meetings: true,
      settings: true,
    },
    projects: [],
  });
}

const general = {
  organization: {
    name: "Acme Robotics",
    slug: "acme",
    icon: null,
    default_locale: null,
  },
  locale_options: [{ label: "English", value: "en" }],
  cli: {
    api_base_url: "https://bft.example",
    install_command: "install bft",
    login_command: "bft auth login",
    sessions: [],
    sessions_truncated: false,
  },
};

const brazil = {
  code: "BR",
  name_en: "Brazil",
  name_zh: "巴西",
  currency: "BRL",
  display_currency: "BRL",
  scale: 2,
  min_seats: 30,
  max_seats: 34,
  sample_min_amount: "37500.00",
  fee_rate: "0.04",
  fx_rate: "0.20",
  markup_rate: "0",
  payment_types: ["PIX"],
  id_types: ["CPF"],
} satisfies BftM2squareCountry;

const ecuador = {
  ...brazil,
  code: "EC",
  name_en: "Ecuador",
  name_zh: "厄瓜多尔",
  currency: "ECS",
  display_currency: "USD",
  max_seats: 39,
  sample_min_amount: "7619.05",
  fee_rate: "0.055",
  fx_rate: "1",
  payment_types: ["NET_BANKING", "CASH"],
  id_types: ["CI", "RUC", "PAS"],
} satisfies BftM2squareCountry;

const chile = {
  ...brazil,
  code: "CL",
  name_en: "Chile",
  name_zh: "智利",
  currency: "CLP",
  display_currency: "CLP",
  scale: 0,
  max_seats: 32,
  sample_min_amount: "7500001",
  fx_rate: "0.0009999999999",
  payment_types: ["NET_BANKING", "TD", "TC"],
  id_types: ["RUT", "PP"],
} satisfies BftM2squareCountry;

const peru = {
  ...brazil,
  code: "PE",
  name_en: "Peru",
  name_zh: "秘鲁",
  currency: "PEN",
  display_currency: "PEN",
  max_seats: 43,
  fx_rate: "0.27",
  payment_types: ["NET_BANKING", "TD", "TC"],
  id_types: ["DNI", "CE", "RUC", "PAS"],
} satisfies BftM2squareCountry;

const expired = {
  active: false,
  licensed_seats: 0,
  available: true,
  m2square_countries: [peru, ecuador, brazil, chile],
  quote_token: "quote-fixture",
  quote_ttl_seconds: 3600,
};

const quoteExpired =
  "This payment session has expired. Re-open this page to start payment again.";
const renewalButton = () => screen.getByRole("button", { name: "Renew subscription" });

function renderBilling(billing: BftSettingsGeneral["billing"]) {
  const api = createBftApi();
  // Hold the checkout response so the test can inspect the request before the redirect.
  const renew = vi
    .spyOn(api, "teamsBillingRenew")
    .mockImplementation(() => new Promise(() => {}));
  render(
    <ApiContext value={api}>
      <SettingsGeneralPage
        data={{ ...general, billing }}
        onSaved={vi.fn()}
        org="acme"
      />
    </ApiContext>
  );
  return {
    renew,
    user: userEvent.setup(),
    section: within(screen.getByRole("region", { name: "Teams subscription" })),
  };
}

function fill(label: string, value: string) {
  fireEvent.change(screen.getByRole("textbox", { name: label }), { target: { value } });
}

async function pick(
  user: ReturnType<typeof userEvent.setup>,
  name: RegExp,
  item: string
) {
  await user.click(screen.getByRole("button", { name }));
  await user.click(screen.getByRole("option", { name: item }));
}

describe("Teams billing in General settings", () => {
  it("reads an existing Stripe billing fixture and leaves the portal available", () => {
    const data = settingsGeneralSchema.parse({
      ...general,
      billing: { active: true, licensed_seats: 100, available: true },
    });
    const { section } = renderBilling(data.billing);
    expect(section.getByText("100 licensed seats")).toBeVisible();
    expect(section.getByRole("button", { name: "Manage billing" })).toBeVisible();
    expect(section.queryByRole("button", { name: "Renew subscription" })).toBeNull();
  });

  it("leaves only the portal available when Stripe billing is past due", () => {
    const { section } = renderBilling({
      ...expired,
      provider: "stripe",
      has_stripe_customer: true,
      can_renew_stripe: false,
      can_renew_m2square: false,
      detected_country: "EC",
      quote_ttl_seconds: 0,
    });
    expect(section.getByRole("button", { name: "Manage billing" })).toBeVisible();
    expect(section.queryByRole("button", { name: "Renew subscription" })).toBeNull();
    expect(section.queryByRole("textbox", { name: "Seats to purchase" })).toBeNull();
    expect(section.queryByRole("radiogroup")).toBeNull();
    expect(section.queryByRole("button", { name: /Billing country$/ })).toBeNull();
    expect(section.queryByRole("alert")).toBeNull();
  });

  it("hides the portal for a revoked M2square organization without a Stripe customer", () => {
    const { section } = renderBilling({
      ...expired,
      provider: null,
      has_stripe_customer: false,
      can_renew_stripe: true,
      can_renew_m2square: true,
    });
    expect(section.queryByRole("button", { name: "Manage billing" })).toBeNull();
    expect(section.getByRole("button", { name: "Renew subscription" })).toBeEnabled();
  });

  it("offers only Stripe renewal to a large expired organization", () => {
    const { section } = renderBilling({
      ...expired,
      member_count: 85,
      can_renew_stripe: true,
      can_renew_m2square: false,
      detected_country: "US",
    });
    const seats = section.getByRole("textbox", { name: "Seats to purchase" });
    expect(seats).toHaveValue("100");
    expect(seats).not.toHaveAttribute("aria-describedby");
    expect(section.queryByText("Enter at least 100 seats.")).toBeNull();
    expect(section.getByRole("button", { name: "Renew subscription" })).toBeEnabled();
    expect(section.queryByRole("radiogroup")).toBeNull();
    expect(
      section.queryByRole("button", { name: /Pay with a local method/ })
    ).toBeNull();
  });

  it("keeps Stripe first and selected in a supported country after expiry", async () => {
    const { renew, section, user } = renderBilling({
      ...expired,
      detected_country: "EC",
      quote_token: "stripe-quote",
      quote_ttl_seconds: 3600,
    });
    const [stripe, local] = section.getAllByRole("radio");
    expect(stripe).toHaveAccessibleName("Stripe");
    expect(stripe).toBeChecked();
    expect(local).toHaveAccessibleName("Local payment");
    expect(section.queryByRole("button", { name: /Billing country$/ })).toBeNull();
    const seats = section.getByRole("textbox", { name: "Seats to purchase" });
    expect(seats).toHaveValue("100");
    expect(seats).not.toHaveAttribute("aria-invalid", "true");
    expect(seats).not.toHaveAttribute("aria-describedby");
    const button = section.getByRole("button", { name: "Renew subscription" });
    fill("Seats to purchase", "99");
    expect(seats).toHaveAttribute("aria-invalid", "true");
    expect(seats).toHaveAccessibleDescription("Enter at least 100 seats.");
    expect(button).toBeDisabled();
    fill("Seats to purchase", "");
    expect(section.getByText("Enter at least 100 seats.")).toBeVisible();
    expect(button).toBeDisabled();
    fill("Seats to purchase", "105");
    expect(section.queryByText("Enter at least 100 seats.")).toBeNull();
    expect(button).toBeEnabled();
    await user.click(button);
    expect(renew).toHaveBeenCalledWith("acme", {
      seats: "105",
      quote_token: "stripe-quote",
    });
  });

  it("opens the local country selector from the quiet entry outside Latin America", async () => {
    const { section, user } = renderBilling({
      ...expired,
      detected_country: "US",
      member_count: 31,
    });
    expect(section.queryByRole("radiogroup")).toBeNull();
    expect(section.getByRole("textbox", { name: "Seats to purchase" })).toHaveValue(
      "100"
    );
    await user.click(
      section.getByRole("button", {
        name: "Pay with a local method in Latin America",
      })
    );
    expect(section.getByRole("radio", { name: "Local payment" })).toBeChecked();
    await user.click(section.getByRole("button", { name: /Billing country$/ }));
    expect(screen.getAllByRole("option")).toHaveLength(4);
    for (const name of ["Peru", "Ecuador", "Brazil", "Chile"]) {
      expect(screen.getByRole("option", { name })).toBeVisible();
    }
    await user.click(screen.getByRole("option", { name: "Brazil" }));
    const brazilSeats = section.getByRole("textbox", { name: "Seats to purchase" });
    expect(brazilSeats).toHaveValue("31");
    expect(brazilSeats).not.toHaveAttribute("aria-invalid", "true");
    expect(brazilSeats).not.toHaveAttribute("aria-describedby");
    expect(section.getByRole("textbox", { name: "CPF number" })).toBeVisible();
    expect(section.getByText("Estimated quarterly total: BRL 38,750.00")).toBeVisible();
    for (const invalid of ["35", "30"]) {
      fill("Seats to purchase", invalid);
      expect(brazilSeats).toHaveAccessibleDescription("Enter between 31 and 34 seats.");
      expect(section.queryByText(/Estimated quarterly total/)).toBeNull();
      expect(
        section.getByRole("button", { name: "Renew subscription" })
      ).toBeDisabled();
    }
    await pick(user, /Billing country$/, "Peru");
    fill("Seats to purchase", "40");
    expect(section.queryByText(/Enter between/)).toBeNull();
    await pick(user, /Billing country$/, "Chile");
    const chileSeats = section.getByRole("textbox", { name: "Seats to purchase" });
    expect(chileSeats).toHaveValue("40");
    expect(chileSeats).toHaveAccessibleDescription("Enter between 31 and 32 seats.");
    expect(section.queryByText(/Estimated quarterly total/)).toBeNull();
    expect(section.getByRole("button", { name: /Document type$/ })).toHaveTextContent(
      "RUT"
    );
    expect(section.queryByRole("textbox", { name: "CPF number" })).toBeNull();
    fill("Seats to purchase", "31");
    expect(section.getByText("Estimated quarterly total: CLP 7,750,001")).toBeVisible();
  });

  it("lets an active M2square organization renew early at its licensed seat floor", async () => {
    const { renew, section, user } = renderBilling({
      ...expired,
      active: true,
      licensed_seats: 33,
      provider: "m2square",
      has_stripe_customer: false,
      expires_at: "2026-11-29T23:59:00-03:00",
      expiring_soon: true,
      can_renew_m2square: true,
      detected_country: "BR",
      member_count: 31,
      quote_token: "local-quote",
      quote_ttl_seconds: 3600,
    });
    expect(section.getByText("33 licensed seats")).toBeVisible();
    expect(section.getByText("2026-11-30")).toBeVisible();
    expect(section.getByText(/Your paid term is ending soon/)).toBeVisible();
    expect(section.queryByRole("button", { name: "Manage billing" })).toBeNull();
    expect(section.queryByRole("radio", { name: "Stripe" })).toBeNull();
    const seats = section.getByRole("textbox", { name: "Seats to purchase" });
    expect(seats).toHaveValue("33");
    expect(seats).not.toHaveAttribute("aria-describedby");
    fill("First name", "Ana");
    fill("Last name", "Silva");
    fill("Email", "ana@acme.test");
    fill("Phone", "11912345678");
    fill("CPF number", "01234567890");
    const button = section.getByRole("button", { name: "Renew subscription" });
    fill("Seats to purchase", "32");
    expect(seats).toHaveAccessibleDescription("Enter between 33 and 34 seats.");
    expect(button).toBeDisabled();
    fill("Seats to purchase", "33");
    await user.click(button);
    expect(renew).toHaveBeenCalledWith("acme", {
      provider: "m2square",
      seats: "33",
      country: "BR",
      payment_type: "PIX",
      firstname: "Ana",
      lastname: "Silva",
      email: "ana@acme.test",
      phone: "11912345678",
      doc_number: "01234567890",
      quote_token: "local-quote",
    });
  });

  it("forces online banking for Ecuador passports and keeps an existing Stripe portal", async () => {
    const { renew, section, user } = renderBilling({
      ...expired,
      provider: "m2square",
      has_stripe_customer: true,
      next_period_end: "2026-11-17T12:00:00Z",
      detected_country: "EC",
    });
    expect(section.getByText("2026-11-17")).toBeVisible();
    expect(section.getByRole("button", { name: "Manage billing" })).toBeVisible();
    await user.click(section.getByRole("radio", { name: "Local payment" }));
    await pick(user, /Payment method$/, "Cash");
    await pick(user, /Document type$/, "PAS");
    expect(section.queryByRole("button", { name: /Payment method$/ })).toBeNull();
    expect(section.getByText("Online banking")).toBeVisible();
    expect(section.getByText(/6–9 local digits/)).toBeVisible();
    expect(section.getByText("Estimated quarterly total: USD 7,619.05")).toBeVisible();
    fill("First name", "Ana");
    fill("Last name", "Silva");
    fill("Email", "ana@acme.test");
    fill("Document number", "A123456789");
    fill("Phone", "+593 23456789");
    const button = section.getByRole("button", { name: "Renew subscription" });
    expect(button).toBeDisabled();
    fill("Phone", "2345 6789");
    await user.click(button);
    expect(renew).toHaveBeenCalledWith("acme", {
      provider: "m2square",
      seats: "30",
      country: "EC",
      payment_type: "NET_BANKING",
      firstname: "Ana",
      lastname: "Silva",
      email: "ana@acme.test",
      phone: "23456789",
      beneficiary_type: "PAS",
      beneficiary_id: "A123456789",
      quote_token: "quote-fixture",
    });
  });

  it("locks local inputs immediately when the route receives an already-expired quote", async () => {
    const { renew, section, user } = renderBilling({
      ...expired,
      can_renew_stripe: false,
      detected_country: "EC",
      quote_token: "expired-quote",
      quote_ttl_seconds: 0,
    });
    expect(section.getAllByRole("alert")).toHaveLength(1);
    expect(section.getByRole("alert")).toHaveTextContent(quoteExpired);
    expect(section.getByRole("button", { name: /Billing country$/ })).toBeDisabled();
    expect(section.getByRole("button", { name: /Payment method$/ })).toBeDisabled();
    expect(section.getByRole("button", { name: /Document type$/ })).toBeDisabled();
    for (const name of [
      "Seats to purchase",
      "First name",
      "Last name",
      "Email",
      "Phone",
      "Document number",
    ]) {
      expect(section.getByRole("textbox", { name })).toBeDisabled();
    }
    const button = section.getByRole("button", { name: "Renew subscription" });
    expect(button).toBeDisabled();
    await user.click(button);
    expect(renew).not.toHaveBeenCalled();
    expect(section.getByRole("button", { name: "Manage billing" })).toBeEnabled();
  });

  it("disables Stripe renewal at the end of the one-hour payment window", () => {
    const { section } = renderBilling({
      ...expired,
      quote_token: "stripe-quote",
      quote_ttl_seconds: 3600,
    });
    const seats = section.getByRole("textbox", { name: "Seats to purchase" });
    const button = section.getByRole("button", { name: "Renew subscription" });
    act(() => vi.advanceTimersByTime(3_599_999));
    expect(button).toBeEnabled();
    expect(section.queryByRole("alert")).toBeNull();
    act(() => vi.advanceTimersByTime(1));
    expect(seats).toBeDisabled();
    expect(button).toBeDisabled();
    expect(section.getByRole("alert")).toHaveTextContent(quoteExpired);
  });

  it("locks renewal and shows one expiration message if the server rejects the quote", async () => {
    const { renew, section, user } = renderBilling({
      ...expired,
      quote_token: "stripe-quote",
      quote_ttl_seconds: 3600,
    });
    const checkout = Promise.withResolvers<{ url: string }>();
    renew.mockReturnValueOnce(checkout.promise);
    const button = section.getByRole("button", { name: "Renew subscription" });
    await user.click(button);
    await act(async () =>
      checkout.reject(new BftApiError(422, "Expired", "quote_expired"))
    );
    expect(section.getByRole("alert")).toHaveTextContent(quoteExpired);
    expect(section.getAllByRole("alert")).toHaveLength(1);
    expect(section.queryByText("Expired")).toBeNull();
    expect(section.getByRole("textbox", { name: "Seats to purchase" })).toBeDisabled();
    expect(button).toBeDisabled();
    await user.click(button);
    expect(renew).toHaveBeenCalledTimes(1);
  });

  it("waits for a fresh route quote and keeps it through profile save and form reload", async () => {
    const org = { slug: "acme", name: "Acme Robotics" };
    const context = orgContextSchema.parse({
      user: { id: "user-1", name: "Ada", email: null },
      orgs: [org],
      org: { ...org, role: "owner" },
      capabilities: {
        operations: true,
        triage: true,
        information_flow: true,
        meetings: true,
        settings: true,
      },
      projects: [],
    });
    const api = createBftApi();
    vi.spyOn(api, "orgContext").mockResolvedValue(context);
    vi.spyOn(api, "settingsModels").mockImplementation(() => new Promise(() => {}));
    const fresh = Promise.withResolvers<BftSettingsGeneral>();
    const cached = {
      ...general,
      billing: { ...expired, quote_token: "cached-quote", quote_ttl_seconds: 3600 },
    };
    const freshGeneral = {
      ...general,
      organization: { ...general.organization, name: "Fresh profile" },
      billing: { ...expired, quote_token: "fresh-quote", quote_ttl_seconds: 3600 },
    };
    const getGeneral = vi
      .spyOn(api, "settingsGeneral")
      .mockResolvedValueOnce(cached)
      .mockImplementationOnce(() => fresh.promise);
    const save = vi.spyOn(api, "updateSettingsGeneral").mockResolvedValue({
      ...general,
      organization: { ...general.organization, name: "Saved profile" },
      billing: {
        ...expired,
        quote_token: "profile-reply-quote",
        quote_ttl_seconds: 3600,
      },
    });
    const renew = vi
      .spyOn(api, "teamsBillingRenew")
      .mockImplementation(() => new Promise(() => {}));

    window.history.replaceState(null, "", "/orgs/acme/settings");
    const user = userEvent.setup();
    await act(async () => {
      render(
        <ApiContext value={api}>
          <App />
        </ApiContext>
      );
    });
    expect(renewalButton()).toBeEnabled();
    act(() => navigate("/orgs/acme/settings/models"));
    act(() => navigate("/orgs/acme/settings"));
    expect(getGeneral).toHaveBeenCalledTimes(2);
    expect(screen.getByRole("button", { name: "Manage billing" })).toBeEnabled();
    expect(screen.getByRole("textbox", { name: "Seats to purchase" })).toBeDisabled();
    expect(renewalButton()).toBeDisabled();
    await user.click(renewalButton());
    expect(renew).not.toHaveBeenCalled();

    fill("Organization name", "Saved profile");
    await act(async () => fresh.resolve(freshGeneral));
    expect(renewalButton()).toBeEnabled();
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(save).toHaveBeenCalledWith("acme", { name: "Saved profile" });
    await user.click(screen.getByRole("button", { name: "Reload" }));
    expect(screen.getByRole("textbox", { name: "Organization name" })).toHaveValue(
      "Fresh profile"
    );
    expect(getGeneral).toHaveBeenCalledTimes(2);
    await user.click(renewalButton());
    expect(renew).toHaveBeenCalledWith("acme", {
      seats: "100",
      quote_token: "fresh-quote",
    });
  });

  it("disables renewal when quote_token is missing or quote_ttl_seconds is 0 while keeping Manage billing enabled", async () => {
    for (const badBilling of [
      { ...expired, quote_token: null, quote_ttl_seconds: 3600 },
      { ...expired, quote_token: "zero-ttl", quote_ttl_seconds: 0 },
    ]) {
      const api = createBftApi();
      const renew = vi
        .spyOn(api, "teamsBillingRenew")
        .mockImplementation(() => new Promise(() => {}));
      const portal = vi
        .spyOn(api, "teamsBillingPortal")
        .mockImplementation(() => new Promise(() => {}));
      const user = userEvent.setup();
      const { unmount } = render(
        <ApiContext value={api}>
          <SettingsGeneralPage
            data={{
              ...general,
              billing: { ...badBilling, has_stripe_customer: true },
            }}
            onSaved={vi.fn()}
            org="acme"
          />
        </ApiContext>
      );
      const section = within(
        screen.getByRole("region", { name: "Teams subscription" })
      );
      const button = section.getByRole("button", { name: "Renew subscription" });
      expect(button).toBeDisabled();
      await user.click(button);
      expect(renew).not.toHaveBeenCalled();

      const portalButton = section.getByRole("button", { name: "Manage billing" });
      expect(portalButton).toBeEnabled();
      await user.click(portalButton);
      expect(portal).toHaveBeenCalledWith("acme");
      unmount();
    }
  });

  it("rejects Stripe seat counts above 2147483647 with exact range error and allows 2147483647", async () => {
    const { renew, section, user } = renderBilling({
      ...expired,
      can_renew_m2square: false,
      quote_token: "stripe-max-quote",
      quote_ttl_seconds: 3600,
    });
    const button = section.getByRole("button", { name: "Renew subscription" });
    fill("Seats to purchase", "2147483648");
    expect(section.getByText("Enter between 100 and 2147483647 seats.")).toBeVisible();
    expect(button).toBeDisabled();

    fill("Seats to purchase", "2147483647");
    expect(section.queryByText("Enter between 100 and 2147483647 seats.")).toBeNull();
    expect(button).toBeEnabled();
    await user.click(button);
    expect(renew).toHaveBeenCalledWith("acme", {
      seats: "2147483647",
      quote_token: "stripe-max-quote",
    });
  });

  it("preserves original quote_token and expired lock across organization slug renames in App", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      const api = createBftApi();
      vi.spyOn(api, "orgContext").mockImplementation(async (slug) =>
        makeOrgContext(slug)
      );
      vi.spyOn(api, "settingsGeneral").mockImplementation(async (slug) => ({
        ...general,
        organization: { ...general.organization, slug },
        billing: {
          ...expired,
          quote_token: `quote-for-${slug}`,
          quote_ttl_seconds: 30,
        },
      }));
      vi.spyOn(api, "updateSettingsGeneral").mockImplementation(
        async (_org, changes) => ({
          ...general,
          organization: {
            ...general.organization,
            slug: changes.slug ?? general.organization.slug,
          },
          billing: {
            ...expired,
            quote_token: "never-adopt-from-save",
            quote_ttl_seconds: 3600,
          },
        })
      );
      const renew = vi
        .spyOn(api, "teamsBillingRenew")
        .mockImplementation(() => new Promise(() => {}));

      window.history.replaceState(null, "", "/orgs/acme/settings");
      const user = userEvent.setup({
        advanceTimers: (ms) => vi.advanceTimersByTime(ms),
      });
      await act(async () => {
        render(
          <ApiContext value={api}>
            <App />
          </ApiContext>
        );
      });
      expect(renewalButton()).toBeEnabled();

      // 1. Rename slug while unexpired ("acme" -> "acme-hq"): keeps original "quote-for-acme"
      fill("Slug", "acme-hq");
      await user.click(screen.getByRole("button", { name: "Save" }));
      expect(window.location.pathname).toBe("/orgs/acme-hq/settings");
      expect(renewalButton()).toBeEnabled();
      await user.click(renewalButton());
      expect(renew).toHaveBeenCalledWith("acme-hq", {
        seats: "100",
        quote_token: "quote-for-acme",
      });

      // 2. Advance past the original 30s TTL -> quote expires
      await act(async () => {
        vi.advanceTimersByTime(31_000);
      });
      expect(screen.getByRole("alert")).toHaveTextContent(quoteExpired);
      expect(renewalButton()).toBeDisabled();

      // 3. Rename slug again after expiry ("acme-hq" -> "acme-expired"): MUST stay locked & expired!
      fill("Slug", "acme-expired");
      await user.click(screen.getByRole("button", { name: "Save" }));
      expect(window.location.pathname).toBe("/orgs/acme-expired/settings");
      expect(screen.getByRole("alert")).toHaveTextContent(quoteExpired);
      expect(renewalButton()).toBeDisabled();
      expect(screen.getByRole("textbox", { name: "Seats to purchase" })).toBeDisabled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("carries quote A across a slug rename started while cached settings wait for the route GET", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      const api = createBftApi();
      vi.spyOn(api, "orgContext").mockImplementation(async (slug) =>
        makeOrgContext(slug)
      );
      vi.spyOn(api, "settingsModels").mockImplementation(() => new Promise(() => {}));
      const freshQuoteA = Promise.withResolvers<BftSettingsGeneral>();
      const patchRename = Promise.withResolvers<BftSettingsGeneral>();
      vi.spyOn(api, "settingsGeneral")
        .mockResolvedValueOnce({
          ...general,
          billing: {
            ...expired,
            quote_token: "stale-cache-quote",
            quote_ttl_seconds: 3600,
          },
        })
        .mockImplementationOnce(() => freshQuoteA.promise)
        .mockResolvedValueOnce({
          ...general,
          organization: { ...general.organization, slug: "acme-a" },
          billing: {
            ...expired,
            quote_token: "quote-B",
            quote_ttl_seconds: 3600,
          },
        });
      vi.spyOn(api, "updateSettingsGeneral").mockImplementation(
        () => patchRename.promise
      );
      const renew = vi
        .spyOn(api, "teamsBillingRenew")
        .mockImplementation(() => new Promise(() => {}));

      window.history.replaceState(null, "", "/orgs/acme/settings");
      const user = userEvent.setup({
        advanceTimers: (ms) => vi.advanceTimersByTime(ms),
      });
      await act(async () => {
        render(
          <ApiContext value={api}>
            <App />
          </ApiContext>
        );
      });
      expect(renewalButton()).toBeEnabled();

      // Re-enter General settings so cached data renders while the route GET is still pending.
      act(() => navigate("/orgs/acme/settings/models"));
      act(() => navigate("/orgs/acme/settings"));
      expect(renewalButton()).toBeDisabled();

      // Start the slug-rename PATCH while paymentSession is still loading.
      fill("Slug", "acme-a");
      await user.click(screen.getByRole("button", { name: "Save" }));

      // Original route GET finishes with quote A (30s TTL) before PATCH resolves.
      await act(async () => {
        freshQuoteA.resolve({
          ...general,
          billing: {
            ...expired,
            quote_token: "quote-A",
            quote_ttl_seconds: 30,
          },
        });
        await freshQuoteA.promise;
      });
      expect(renewalButton()).toBeEnabled();

      // PATCH resolves and navigates to /orgs/acme-a/settings, whose GET returns quote B (3600s).
      await act(async () => {
        patchRename.resolve({
          ...general,
          organization: { ...general.organization, slug: "acme-a" },
          billing: {
            ...expired,
            quote_token: "never-adopt-from-save",
            quote_ttl_seconds: 3600,
          },
        });
        await patchRename.promise;
      });

      expect(window.location.pathname).toBe("/orgs/acme-a/settings");
      expect(renewalButton()).toBeEnabled();
      await user.click(renewalButton());
      expect(renew).toHaveBeenCalledWith("acme-a", {
        seats: "100",
        quote_token: "quote-A",
      });

      // Advancing past quote A's original 30s TTL expires and locks the renamed route.
      await act(async () => {
        vi.advanceTimersByTime(31_000);
      });
      expect(screen.getByRole("alert")).toHaveTextContent(quoteExpired);
      expect(renewalButton()).toBeDisabled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("carries server-reported quote_expired across a slug rename started before renewal failed", async () => {
    const api = createBftApi();
    vi.spyOn(api, "orgContext").mockImplementation(async (slug) =>
      makeOrgContext(slug)
    );
    vi.spyOn(api, "settingsGeneral").mockImplementation(async (slug) => ({
      ...general,
      organization: { ...general.organization, slug },
      billing: {
        ...expired,
        quote_token: `quote-for-${slug}`,
        quote_ttl_seconds: 3600,
      },
    }));
    const patchRename = Promise.withResolvers<BftSettingsGeneral>();
    vi.spyOn(api, "updateSettingsGeneral").mockImplementation(
      () => patchRename.promise
    );
    const renew = vi
      .spyOn(api, "teamsBillingRenew")
      .mockRejectedValue(new BftApiError(422, "Expired", "quote_expired"));

    window.history.replaceState(null, "", "/orgs/acme/settings");
    const user = userEvent.setup();
    await act(async () => {
      render(
        <ApiContext value={api}>
          <App />
        </ApiContext>
      );
    });
    expect(renewalButton()).toBeEnabled();

    // Start slug-rename PATCH while paymentQuoteExpired is still false.
    fill("Slug", "acme-b");
    await user.click(screen.getByRole("button", { name: "Save" }));

    // Before PATCH returns, a concurrent renewal hits server 422 quote_expired (local TTL still has ~3600s).
    await user.click(renewalButton());
    expect(renew).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("alert")).toHaveTextContent(quoteExpired);
    expect(renewalButton()).toBeDisabled();

    // Now PATCH finishes and navigates to /orgs/acme-b/settings: MUST remain locked & expired.
    await act(async () => {
      patchRename.resolve({
        ...general,
        organization: { ...general.organization, slug: "acme-b" },
        billing: {
          ...expired,
          quote_token: "never-adopt-from-save",
          quote_ttl_seconds: 3600,
        },
      });
      await patchRename.promise;
    });

    expect(window.location.pathname).toBe("/orgs/acme-b/settings");
    expect(screen.getByRole("alert")).toHaveTextContent(quoteExpired);
    expect(renewalButton()).toBeDisabled();
    await user.click(renewalButton());
    expect(renew).toHaveBeenCalledTimes(1);
  });
});

describe("Teams billing API", () => {
  it("forwards only m2_order on the Settings read and keeps country terms", async () => {
    const billing = { ...expired, quote_token: "fresh-quote", quote_ttl_seconds: 3600 };
    const fetch = vi.fn<typeof globalThis.fetch>(async () =>
      Response.json({ ok: true, data: { ...general, billing } })
    );
    const api = createBftApi({ fetch });
    const original = window.location.href;
    window.history.replaceState(null, "", "?m2_order=order%26example&other=ignored");
    try {
      const signal = new AbortController().signal;
      const data = await api.settingsGeneral("acme co", signal);
      expect(fetch).toHaveBeenCalledWith(
        "/dashboard/api/v1/orgs/acme%20co/settings/general?m2_order=order%26example",
        expect.objectContaining({ signal })
      );
      expect(data.billing).toEqual(billing);
    } finally {
      window.history.replaceState(null, "", original);
    }
  });

  it("posts both the legacy seat count and the structured renewal", async () => {
    const response = { url: "https://pay.example/checkout" };
    const fetch = vi.fn<typeof globalThis.fetch>(async () =>
      Response.json({ ok: true, data: response })
    );
    const api = createBftApi({ fetch, csrfToken: () => "token" });
    const renewal = {
      provider: "m2square",
      country: "BR",
      seats: 30,
      payment_type: "PIX",
      firstname: "Ana",
      lastname: "Silva",
      email: "ana@acme.test",
      phone: "11912345678",
      doc_number: "01234567890",
      quote_token: "local-quote",
    } as const;
    await expect(api.teamsBillingRenew("acme", 100)).resolves.toEqual(response);
    await expect(
      api.teamsBillingRenew("acme", { seats: "105", quote_token: "stripe-quote" })
    ).resolves.toEqual(response);
    await expect(api.teamsBillingRenew("acme", renewal)).resolves.toEqual(response);
    expect(
      fetch.mock.calls.map(([path, init]) => [path, init?.method, init?.body])
    ).toEqual([
      [
        "/dashboard/api/v1/orgs/acme/settings/billing/renew",
        "POST",
        JSON.stringify({ seats: 100 }),
      ],
      [
        "/dashboard/api/v1/orgs/acme/settings/billing/renew",
        "POST",
        JSON.stringify({ seats: "105", quote_token: "stripe-quote" }),
      ],
      [
        "/dashboard/api/v1/orgs/acme/settings/billing/renew",
        "POST",
        JSON.stringify(renewal),
      ],
    ]);
  });

  it("renders a read-only unmanaged billing section without portal or renewal controls", () => {
    const parsed = settingsGeneralSchema.parse({
      ...general,
      billing: null,
      billing_policy: { mode: "unmanaged", member_count: 14 },
    });
    const api = createBftApi();
    render(
      <ApiContext value={api}>
        <SettingsGeneralPage data={parsed} onSaved={vi.fn()} org="acme" />
      </ApiContext>
    );
    const section = within(screen.getByRole("region", { name: "Teams subscription" }));
    expect(section.getByText("14 members")).toBeVisible();
    expect(
      section.getByText(
        "This organization is managed by an enterprise contract or invite code rather than self-serve billing."
      )
    ).toBeVisible();
    const contactLink = section.getByRole("link", { name: "Contact sales" });
    expect(contactLink).toHaveAttribute(
      "href",
      "https://comma.surf/enterprise#contact"
    );
    expect(section.queryByRole("button", { name: "Manage billing" })).toBeNull();
    expect(section.queryByRole("button", { name: "Renew subscription" })).toBeNull();
    expect(section.queryByRole("textbox", { name: "Seats to purchase" })).toBeNull();
  });

  it("shows the mid-quarter seat addition note for an active Stripe subscription", () => {
    const { section } = renderBilling({
      active: true,
      licensed_seats: 100,
      available: true,
      provider: "stripe",
      has_stripe_customer: true,
      expires_at: "2027-02-25T00:00:00Z",
    });
    expect(section.getByText("100 licensed seats")).toBeVisible();
    expect(
      section.getByText(
        "To add seats during the current quarter, contact sales or create a separate organization (creating a new organization does not add seats to this one)."
      )
    ).toBeVisible();
  });

  it("scrolls #teams-billing into view when the hash matches", () => {
    const scrollSpy = vi
      .spyOn(Element.prototype, "scrollIntoView")
      .mockImplementation(() => {});
    window.history.replaceState(null, "", "/orgs/acme/settings#teams-billing");
    try {
      const api = createBftApi();
      const { unmount } = render(
        <ApiContext value={api}>
          <SettingsGeneralPage
            data={{
              ...general,
              billing: null,
              billing_policy: { mode: "unmanaged", member_count: 8 },
            }}
            onSaved={vi.fn()}
            org="acme"
          />
        </ApiContext>
      );
      expect(scrollSpy).toHaveBeenCalledWith({ block: "start" });
      unmount();
    } finally {
      scrollSpy.mockRestore();
      window.history.replaceState(null, "", "/");
    }
  });
});
