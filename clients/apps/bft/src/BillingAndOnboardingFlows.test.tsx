import { act, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  BftApiError,
  createBftApi,
  orgContextSchema,
  type BftMembers,
  type BftWizard,
  type BftWizardIntegrations,
} from "./api";
import { App } from "./App";
import { MembersPage } from "./MembersPage";
import { OnboardingWizard, wizardPath } from "./OnboardingWizard";
import { ApiContext } from "./resource";
import { isSpaPath } from "./router";
import { Shell } from "./Shell";

afterEach(() => {
  window.history.replaceState(null, "", "/");
});

const membersFixture: BftMembers = {
  viewer: {
    user_id: "user-1",
    role: "owner",
    can_manage: true,
    can_grant_owner: true,
  },
  members: [
    {
      user_id: "user-1",
      name: "Mei Chen",
      email: "mei@acme.test",
      mobile: null,
      role: "owner",
      joined_at: "2026-09-01T00:00:00Z",
      sso: false,
      sso_provider: null,
    },
  ],
};

function makeWizard(step: BftWizard["step"] = "capabilities"): BftWizard {
  return {
    status: "in_progress",
    step,
    capabilities: { "inbox.label_new_mail": true },
    capability_groups: [{ key: "inbox", capabilities: ["inbox.label_new_mail"] }],
    user: { name: "Mei Chen", email: "mei@team-b.test" },
    org: { slug: "team-b", name: "Team B", role: "owner" },
    teammates: { total: 1, sample: [] },
  };
}

const wizardIntegrationsFixture: BftWizardIntegrations = {
  project: { id: "prj-1", name: "Team B Swarm" },
  can_connect: true,
  org_admin: true,
  composio: { status: "ok", configured: true },
  toolkits: [{ toolkit: "gmail", state: "connectable" }],
  messaging: [{ provider: "slack", connected: false }],
  connected_providers: [],
};

describe("MembersPage billing error links", () => {
  it("shows a direct link to Settings billing on 409 teams_seat_limit and closes dialog on click", async () => {
    const invite = vi
      .fn()
      .mockRejectedValue(
        new BftApiError(
          409,
          "Your organization has reached its licensed seat limit.",
          "teams_seat_limit"
        )
      );
    window.history.replaceState(null, "", "/orgs/acme%20co/members");
    const user = userEvent.setup();
    render(
      <MembersPage
        members={{ state: "ready", data: membersFixture }}
        onRetry={vi.fn()}
        org="acme co"
        orgName="Acme Co"
        writes={{
          invite,
          changeRole: vi.fn(),
          remove: vi.fn(),
        }}
      />
    );

    await user.click(screen.getByRole("button", { name: "Invite member" }));
    const dialog = screen.getByRole("dialog", { name: "Invite member" });
    await user.type(
      within(dialog).getByRole("textbox", { name: "Email" }),
      "a@acme.test"
    );
    await user.click(within(dialog).getByRole("button", { name: "Invite" }));

    expect(within(dialog).getByRole("alert")).toHaveTextContent(
      "Your organization has reached its licensed seat limit."
    );
    const link = within(dialog).getByRole("link", {
      name: "Manage seats in Settings",
    });
    expect(link).toHaveAttribute("href", "/orgs/acme%20co/settings#teams-billing");

    await user.click(link);
    expect(window.location.pathname).toBe("/orgs/acme%20co/settings");
    expect(window.location.hash).toBe("#teams-billing");
    expect(screen.queryByRole("dialog", { name: "Invite member" })).toBeNull();
  });

  it("shows a renewal link on 402 teams_subscription_required", async () => {
    const invite = vi
      .fn()
      .mockRejectedValue(
        new BftApiError(
          402,
          "Your Teams subscription has expired.",
          "teams_subscription_required"
        )
      );
    const user = userEvent.setup();
    render(
      <MembersPage
        members={{ state: "ready", data: membersFixture }}
        onRetry={vi.fn()}
        org="acme"
        orgName="Acme Robotics"
        writes={{
          invite,
          changeRole: vi.fn(),
          remove: vi.fn(),
        }}
      />
    );

    await user.click(screen.getByRole("button", { name: "Invite member" }));
    const dialog = screen.getByRole("dialog", { name: "Invite member" });
    await user.type(
      within(dialog).getByRole("textbox", { name: "Email" }),
      "b@acme.test"
    );
    await user.click(within(dialog).getByRole("button", { name: "Invite" }));

    const link = within(dialog).getByRole("link", {
      name: "Renew subscription in Settings",
    });
    expect(link).toHaveAttribute("href", "/orgs/acme/settings#teams-billing");
  });
});

describe("OnboardingWizard explicit ?org propagation", () => {
  it("preserves ?org across wizardPath and all wizard API methods", async () => {
    expect(wizardPath("capabilities", "team-b")).toBe("/onboarding?org=team-b");
    expect(wizardPath("profile", "team-b")).toBe("/onboarding/profile?org=team-b");
    expect(wizardPath("integrations", "team b")).toBe(
      "/onboarding/integrations?org=team%20b"
    );

    const fetchMock = vi.fn<typeof globalThis.fetch>(async (input) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url.includes("/onboarding/integrations")) {
        return new Response(
          JSON.stringify({ ok: true, data: wizardIntegrationsFixture }),
          {
            status: 200,
            headers: { "content-type": "application/json" },
          }
        );
      }
      if (url.includes("/onboarding/connect")) {
        return new Response(
          JSON.stringify({
            ok: true,
            data: { redirect_url: "https://connect.example" },
          }),
          { status: 200, headers: { "content-type": "application/json" } }
        );
      }
      if (url.includes("/onboarding/complete") || url.includes("/onboarding/skip")) {
        return new Response(
          JSON.stringify({
            ok: true,
            data: { redirect: "/orgs/team-b", notice: null },
          }),
          { status: 200, headers: { "content-type": "application/json" } }
        );
      }
      return new Response(JSON.stringify({ ok: true, data: makeWizard() }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });

    const api = createBftApi({ fetch: fetchMock });
    await api.wizard(undefined, "team-b");
    await api.wizardIntegrations(undefined, "team-b");
    await api.saveWizardCapabilities({ "inbox.label_new_mail": true }, "team-b");
    await api.saveWizardProfile("team-b");
    await api.connectWizardToolkit("gmail", "team-b");
    await api.completeWizard("team-b");
    await api.skipWizard("team-b");

    const urls = fetchMock.mock.calls.map(([input]) => String(input));
    expect(urls).toEqual([
      "/dashboard/api/v1/onboarding?org=team-b",
      "/dashboard/api/v1/onboarding/integrations?org=team-b",
      "/dashboard/api/v1/onboarding/capabilities?org=team-b",
      "/dashboard/api/v1/onboarding/profile?org=team-b",
      "/dashboard/api/v1/onboarding/connect?org=team-b",
      "/dashboard/api/v1/onboarding/complete?org=team-b",
      "/dashboard/api/v1/onboarding/skip?org=team-b",
    ]);
  });

  it("propagates ?org=team-b through step navigation and back links in App", async () => {
    const api = createBftApi();
    const wizardSpy = vi
      .spyOn(api, "wizard")
      .mockResolvedValue(makeWizard("capabilities"));
    const saveCapSpy = vi
      .spyOn(api, "saveWizardCapabilities")
      .mockResolvedValue(makeWizard("profile"));
    const integrationsSpy = vi
      .spyOn(api, "wizardIntegrations")
      .mockResolvedValue(wizardIntegrationsFixture);
    const saveProfileSpy = vi
      .spyOn(api, "saveWizardProfile")
      .mockResolvedValue(makeWizard("integrations"));
    const completeSpy = vi
      .spyOn(api, "completeWizard")
      .mockResolvedValue({ redirect: "/orgs/team-b", notice: null });
    vi.spyOn(api, "orgContext").mockImplementation(() => new Promise(() => {}));
    vi.spyOn(api, "overview").mockImplementation(() => new Promise(() => {}));

    window.history.replaceState(null, "", "/onboarding?org=team-b");
    const user = userEvent.setup();
    await act(async () => {
      render(
        <ApiContext value={api}>
          <App />
        </ApiContext>
      );
    });

    expect(wizardSpy).toHaveBeenCalledWith(expect.any(AbortSignal), "team-b");

    await user.click(screen.getByRole("button", { name: "Continue" }));
    expect(saveCapSpy).toHaveBeenCalledWith(expect.any(Object), "team-b");
    expect(window.location.pathname).toBe("/onboarding/profile");
    expect(window.location.search).toBe("?org=team-b");
    expect(integrationsSpy).toHaveBeenCalledWith(expect.any(AbortSignal), "team-b");

    await user.click(screen.getByRole("button", { name: "Continue" }));
    expect(saveProfileSpy).toHaveBeenCalledWith("team-b");
    expect(window.location.pathname).toBe("/onboarding/integrations");
    expect(window.location.search).toBe("?org=team-b");

    await user.click(screen.getByRole("button", { name: "Back" }));
    expect(window.location.pathname).toBe("/onboarding/profile");
    expect(window.location.search).toBe("?org=team-b");

    await user.click(screen.getByRole("button", { name: "Continue" }));
    await user.click(screen.getByRole("button", { name: "Finish" }));
    expect(completeSpy).toHaveBeenCalledWith("team-b");
  });

  it("renders a non-retry unavailable state on 403 organization_unavailable without redirecting", async () => {
    const api = createBftApi();
    vi.spyOn(api, "wizard").mockRejectedValue(
      new BftApiError(403, "Forbidden", "organization_unavailable")
    );
    window.history.replaceState(null, "", "/onboarding?org=forbidden-org");

    await act(async () => {
      render(
        <ApiContext value={api}>
          <OnboardingWizard pathname="/onboarding" step="capabilities" />
        </ApiContext>
      );
    });

    expect(
      screen.getByRole("heading", { name: "Organization unavailable" })
    ).toBeVisible();
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
    const backLink = screen.getByRole("link", { name: "Back to organizations" });
    expect(backLink).toHaveAttribute("href", "/orgs");
    expect(window.location.pathname).toBe("/onboarding");
    expect(window.location.search).toBe("?org=forbidden-org");
  });

  it("terminates into Organization unavailable when a write step returns 403 organization_unavailable", async () => {
    const api = createBftApi();
    vi.spyOn(api, "wizard").mockResolvedValue(makeWizard("capabilities"));
    vi.spyOn(api, "saveWizardCapabilities").mockRejectedValue(
      new BftApiError(403, "Forbidden", "organization_unavailable")
    );
    window.history.replaceState(null, "", "/onboarding?org=team-b");

    const user = userEvent.setup();
    await act(async () => {
      render(
        <ApiContext value={api}>
          <OnboardingWizard pathname="/onboarding" step="capabilities" />
        </ApiContext>
      );
    });

    await user.click(screen.getByRole("button", { name: "Continue" }));
    expect(
      screen.getByRole("heading", { name: "Organization unavailable" })
    ).toBeVisible();
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Continue" })).toBeNull();
    expect(screen.getByRole("link", { name: "Back to organizations" })).toHaveAttribute(
      "href",
      "/orgs"
    );
  });

  it("keeps inline error on 403 forbidden (connect) and 403 csrf_rejected (capabilities) without switching to Organization unavailable", async () => {
    const api = createBftApi();
    vi.spyOn(api, "wizard").mockResolvedValue(makeWizard("integrations"));
    vi.spyOn(api, "wizardIntegrations").mockResolvedValue(wizardIntegrationsFixture);
    vi.spyOn(api, "connectWizardToolkit").mockRejectedValue(
      new BftApiError(403, "Only owners can connect toolkits.", "forbidden")
    );
    window.history.replaceState(null, "", "/onboarding/integrations?org=team-b");

    const user = userEvent.setup();
    const { unmount } = await act(async () =>
      render(
        <ApiContext value={api}>
          <OnboardingWizard pathname="/onboarding/integrations" step="integrations" />
        </ApiContext>
      )
    );

    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Connect Gmail" }));
    });
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Only owners can connect toolkits."
    );
    expect(
      screen.queryByRole("heading", { name: "Organization unavailable" })
    ).toBeNull();
    unmount();

    const apiCsrf = createBftApi();
    vi.spyOn(apiCsrf, "wizard").mockResolvedValue(makeWizard("capabilities"));
    vi.spyOn(apiCsrf, "saveWizardCapabilities").mockRejectedValue(
      new BftApiError(403, "HTTP 403", "csrf_rejected")
    );
    window.history.replaceState(null, "", "/onboarding?org=team-b");

    await act(async () => {
      render(
        <ApiContext value={apiCsrf}>
          <OnboardingWizard pathname="/onboarding" step="capabilities" />
        </ApiContext>
      );
    });

    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Continue" }));
    });
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Reload the page and try again."
    );
    expect(
      screen.queryByRole("heading", { name: "Organization unavailable" })
    ).toBeNull();
    expect(screen.getByRole("button", { name: "Continue" })).toBeVisible();
  });

  it("preserves explicit empty ?org= query and renders Organization unavailable without falling back", async () => {
    const fetchMock = vi.fn<typeof globalThis.fetch>(async () => {
      return new Response(
        JSON.stringify({
          ok: false,
          error: {
            code: "organization_unavailable",
            message: "You do not have access to that organization.",
          },
        }),
        { status: 403, headers: { "content-type": "application/json" } }
      );
    });
    const api = createBftApi({ fetch: fetchMock });
    window.history.replaceState(null, "", "/onboarding?org=");

    await act(async () => {
      render(
        <ApiContext value={api}>
          <OnboardingWizard pathname="/onboarding" step="capabilities" />
        </ApiContext>
      );
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/dashboard/api/v1/onboarding?org=",
      expect.any(Object)
    );
    expect(
      screen.getByRole("heading", { name: "Organization unavailable" })
    ).toBeVisible();
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
  });
});

describe("OrgSwitcher and RootRedirect create-organization links", () => {
  it("adds a full-page Create new organization item to OrgSwitcher", async () => {
    expect(isSpaPath("/signup/teams")).toBe(false);
    const context = orgContextSchema.parse({
      user: { id: "user-1", name: "Mei Chen", email: "mei@acme.test" },
      orgs: [
        { slug: "acme", name: "Acme Robotics" },
        { slug: "globex", name: "Globex Labs" },
      ],
      org: { slug: "acme", name: "Acme Robotics", role: "owner" },
      capabilities: {
        operations: true,
        triage: true,
        information_flow: true,
        meetings: true,
        settings: true,
      },
      projects: [],
    });

    const user = userEvent.setup();
    render(
      <Shell context={context} pathname="/orgs/acme">
        <div>body</div>
      </Shell>
    );

    await user.click(
      screen.getByRole("button", { name: "Switch organization: Acme Robotics" })
    );
    const createItem = screen.getByRole("menuitem", {
      name: "+ Create new organization",
    });
    expect(createItem).toHaveAttribute("href", "/signup/teams?mode=new&from=dashboard");
  });

  it("shows Create organization primary link alongside Sign out in RootRedirect 0-org state", async () => {
    const api = createBftApi();
    vi.spyOn(api, "session").mockResolvedValue({
      user: { id: "user-1", name: "Mei Chen", email: "mei@acme.test" },
      orgs: [],
    });
    window.history.replaceState(null, "", "/");

    await act(async () => {
      render(
        <ApiContext value={api}>
          <App />
        </ApiContext>
      );
    });

    const createLink = screen.getByRole("link", { name: "Create organization" });
    expect(createLink).toHaveAttribute("href", "/signup/teams?mode=new&from=dashboard");
    expect(screen.getByRole("button", { name: "Sign out" })).toBeVisible();
  });
});
