import { render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AdminApp, observabilityLinksForApiBaseUrl } from "../src/AdminApp";

const auth = vi.hoisted(() => {
  const reportSessionRejection = vi.fn();
  return {
    reportSessionRejection,
    sessionTransport: {
      credentials: "include" as const,
      signal: new AbortController().signal,
      applyHeaders(headers: Record<string, string>) {
        headers["x-comma-expected-auth-session-id"] =
          "11111111-1111-4111-8111-111111111111";
        headers["x-comma-session-lifecycle-version"] = "1";
        headers["x-comma-session-transport"] = "cookie";
      },
      reportSessionRejection,
    },
    signOut: vi.fn(),
  };
});

vi.mock("@comma/app/auth", () => ({
  CommaAuthGate: ({ children }: { children: ReactNode }) => children,
  useCommaAuth: () => ({
    apiBaseUrl: "http://127.0.0.1:4200",
    sessionTransport: auth.sessionTransport,
    signOut: auth.signOut,
    userEmail: "owner@example.com",
  }),
}));

describe("AdminApp", () => {
  it("does not expose staging observability links for the production API", () => {
    expect(observabilityLinksForApiBaseUrl("https://salix.comma.surf")).toEqual([]);
    expect(observabilityLinksForApiBaseUrl("https://unknown.example")).toEqual([]);
    expect(observabilityLinksForApiBaseUrl("not a URL")).toEqual([]);
  });

  beforeEach(() => {
    vi.clearAllMocks();
    // Navigation writes the active section into the URL, which jsdom keeps.
    window.history.replaceState(null, "", "/");
  });

  it("keeps sign out inside the sidebar account menu", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({
          data: [],
          has_more: false,
          next_cursor: null,
        })
      )
    );
    const user = userEvent.setup();

    render(<AdminApp />);

    expect(
      screen.queryByRole("menuitem", { name: "Sign out" })
    ).not.toBeInTheDocument();
    await user.click(
      screen.getByRole("button", {
        name: "Account menu for owner@example.com",
      })
    );
    await user.click(await screen.findByRole("menuitem", { name: "Sign out" }));

    expect(auth.signOut).toHaveBeenCalledOnce();
  });

  it("supports exact-email pagination and exposes the user operations drawer", async () => {
    const revokedSessions = new Set<string>();
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      const method = init?.method ?? "GET";

      if (url.pathname === "/v1/comma/admin/users/usr_owner") {
        return jsonResponse({
          id: "usr_owner",
          email: "owner@example.com",
          name: "Comma Owner",
          status: "active",
          created_at: 1_784_880_000,
          updated_at: 1_784_880_500,
          login_methods: [
            { method: "email_otp", email: "owner@example.com" },
            {
              method: "google",
              email_snapshot: "owner@gmail.com",
              email_verified: true,
              linked_at: 1_784_880_000,
              last_authenticated_at: 1_784_880_500,
            },
          ],
          admin_access: {
            allowed: true,
            decision: null,
            source: "domain_default",
          },
        });
      }
      if (
        method === "GET" &&
        url.pathname === "/v1/comma/admin/users/usr_owner/workspaces"
      ) {
        return jsonResponse({
          workspace: {
            id: "wsp_owner",
            name: "Owner Workspace",
            status: "ready",
            tenant_id: "tnt_owner",
            group_id: "grp_owner",
            billing_account_id: "billing_owner",
            created_at: 1_784_880_000,
            updated_at: 1_784_880_500,
          },
          billing: {
            account_id: "billing_owner",
            account_status: "active",
            current_credits: 1200,
            active_grants: [
              {
                id: "grant_owner",
                package_code: "comma_monthly",
                package_version: "v1",
                remaining_credits: 1200,
                valid_from: "2026-07-01T00:00:00Z",
                expires_at: "2026-08-01T00:00:00Z",
                source_type: "redeem_code",
                source_id: "redemption_owner",
              },
            ],
            has_more: false,
          },
        });
      }
      if (
        method === "GET" &&
        url.pathname === "/v1/comma/admin/users/usr_owner/sessions"
      ) {
        return jsonResponse({
          data: [
            {
              id: "sess_web",
              auth_method: "google",
              session_source: "user_login",
              authenticated_at: 1_784_880_000,
              expires_at: 4_102_444_800,
              last_seen_at: 1_784_880_500,
              revoked_at: revokedSessions.has("sess_web") ? 1_784_881_000 : null,
              client_kind: "web",
              device_label: "Web on macOS",
              restricted: false,
            },
            {
              id: "sess_desktop",
              auth_method: "email_otp",
              session_source: "user_login",
              authenticated_at: 1_784_870_000,
              expires_at: 4_102_444_800,
              last_seen_at: 1_784_879_500,
              revoked_at: revokedSessions.has("sess_desktop") ? 1_784_881_000 : null,
              client_kind: "electron",
              device_label: "Comma Desktop on Windows",
              restricted: false,
            },
            {
              id: "sess_ssh",
              auth_method: "ssh_public_key",
              session_source: "user_login",
              authenticated_at: 1_784_870_000,
              expires_at: 4_102_444_800,
              last_seen_at: 1_784_879_500,
              revoked_at: revokedSessions.has("sess_ssh") ? 1_784_881_000 : null,
              client_kind: "ssh",
              device_label: null,
              restricted: false,
            },
            {
              id: "sess_android",
              auth_method: "google",
              session_source: "user_login",
              authenticated_at: 1_784_860_000,
              expires_at: 4_102_444_800,
              last_seen_at: 1_784_869_500,
              revoked_at: 1_784_875_000,
              client_kind: "android",
              device_label: null,
              restricted: false,
            },
          ],
          has_more: false,
          next_cursor: null,
        });
      }
      if (
        method === "POST" &&
        url.pathname === "/v1/comma/admin/users/usr_owner/sessions/sess_web/revoke"
      ) {
        revokedSessions.add("sess_web");
        return jsonResponse({ revoked: true, session_id: "sess_web" });
      }
      if (
        method === "POST" &&
        url.pathname === "/v1/comma/admin/users/usr_owner/sessions/revoke-all"
      ) {
        const activeCount = ["sess_web", "sess_desktop", "sess_ssh"].filter(
          (id) => !revokedSessions.has(id)
        ).length;
        revokedSessions.add("sess_web");
        revokedSessions.add("sess_desktop");
        revokedSessions.add("sess_ssh");
        return jsonResponse({ revoked_count: activeCount });
      }
      if (url.pathname === "/v1/comma/admin/billing/package-versions") {
        return jsonResponse({
          data: [
            {
              id: "pkg_v1",
              package_code: "comma_monthly",
              package_name: "Comma Monthly",
              version: "v1",
              surface: "comma",
              kind: "subscription",
              grant_credits: 1200,
              grant_period: "month",
              status: "active",
            },
          ],
        });
      }
      if (method === "GET" && url.pathname === "/v1/comma/admin/billing/redeem-codes") {
        return jsonResponse({
          data: [
            {
              id: "code_owner",
              display_prefix: "COMMA-OWNER",
              package_code: "comma_monthly",
              package_version: "v1",
              status: "active",
            },
          ],
        });
      }
      if (
        method === "POST" &&
        url.pathname === "/v1/comma/admin/billing/redeem-codes/apply"
      ) {
        const body = JSON.parse(String(init?.body));
        return jsonResponse({
          idempotent: false,
          redemption: {
            id: "redemption_applied",
            redeem_code_id: body.id,
            billing_account_id: body.billing_account_id,
            status: "applied",
          },
        });
      }
      if (url.pathname === "/v1/comma/admin/billing/redemptions") {
        return jsonResponse({ data: [] });
      }
      if (url.searchParams.get("email") === "target@example.com") {
        return jsonResponse({
          data: [
            {
              id: "usr_target",
              email: "target@example.com",
              name: "Target",
              status: "active",
              login_methods: [{ method: "email_otp", email: "target@example.com" }],
              admin_access: {
                allowed: false,
                decision: null,
                source: "none",
              },
            },
          ],
          has_more: false,
          next_cursor: null,
        });
      }
      if (url.searchParams.get("cursor") === "opaque-page-2") {
        return jsonResponse({
          data: [
            {
              id: "usr_second",
              email: "second@example.com",
              name: "Second",
              status: "disabled",
              admin_access: {
                allowed: false,
                decision: null,
                source: "disabled",
              },
            },
          ],
          has_more: false,
          next_cursor: null,
        });
      }

      return jsonResponse({
        data: [
          {
            id: "usr_owner",
            email: "owner@example.com",
            name: "Comma Owner",
            status: "active",
            created_at: 1_784_880_000,
            login_methods: [
              { method: "email_otp", email: "owner@example.com" },
              {
                method: "google",
                email_snapshot: "owner@gmail.com",
                email_verified: true,
                linked_at: 1_784_880_000,
                last_authenticated_at: 1_784_880_500,
              },
            ],
            admin_access: {
              allowed: true,
              decision: null,
              source: "domain_default",
            },
          },
        ],
        has_more: true,
        next_cursor: "opaque-page-2",
      });
    });
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();

    render(<AdminApp />);

    const usersTable = await screen.findByRole("table", { name: "Comma users" });
    expect(within(usersTable).getByText("owner@example.com")).toBeInTheDocument();
    expect(within(usersTable).getByText("Email OTP")).toBeInTheDocument();
    expect(within(usersTable).getByText("Google")).toBeInTheDocument();
    expect(screen.queryByText("Total users")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Comma product" })).toHaveAttribute(
      "href",
      "https://afksurf.grafana.net/d/comma-staging-comma-product"
    );
    expect(screen.getByRole("link", { name: "Comma product" })).toHaveAttribute(
      "target",
      "_blank"
    );
    const manageUserButton = screen.getByRole("button", { name: "Manage" });
    expect(manageUserButton).toHaveClass("bg-button-secondary-bg", "border");
    await user.click(manageUserButton);

    const dialog = await screen.findByRole("dialog", { name: "Manage user" });
    expect(within(dialog).getByText("usr_owner")).toBeInTheDocument();
    expect(within(dialog).getByText("owner@gmail.com")).toBeInTheDocument();
    expect(within(dialog).getByText("Verified")).toBeInTheDocument();
    expect(within(dialog).getByText("Support session")).toBeInTheDocument();
    expect(within(dialog).getByText("Workspace & billing")).toBeInTheDocument();

    const sessionsTask = within(dialog)
      .getByText("Sessions & devices")
      .closest("article");
    expect(sessionsTask).not.toBeNull();
    await user.click(
      within(sessionsTask as HTMLElement).getByRole("button", { name: "Open" })
    );

    expect(await within(dialog).findByText("Web on macOS")).toBeInTheDocument();
    expect(within(dialog).getByText("Comma Desktop on Windows")).toBeInTheDocument();
    expect(within(dialog).getByText("Comma SSH")).toBeInTheDocument();
    expect(within(dialog).getByText("Comma Android app")).toBeInTheDocument();
    expect(within(dialog).getByText(/Reported Android · Google/)).toBeInTheDocument();
    expect(
      within(dialog).getByText(/Reported SSH · SSH public key/)
    ).toBeInTheDocument();
    expect(within(dialog).getByText(/labels derived by Comma/)).toBeInTheDocument();
    expect(within(dialog).getByText(/Reported Web · Google/)).toBeInTheDocument();
    expect(
      within(dialog).getByText(/Reported Desktop · Email OTP/)
    ).toBeInTheDocument();
    expect(within(dialog).queryByText(/comma_sess_/i)).not.toBeInTheDocument();

    await user.type(
      within(dialog).getByRole("textbox", { name: "Reason" }),
      "Remove the stale browser Session"
    );
    const webCard = within(dialog).getByText("Web on macOS").closest("article");
    expect(webCard).not.toBeNull();
    await user.click(
      within(webCard as HTMLElement).getByRole("button", { name: "Revoke" })
    );

    let confirmation = await screen.findByRole("dialog", {
      name: "Revoke this Session?",
    });
    await user.type(
      within(confirmation).getByRole("textbox", { name: /Confirmation/ }),
      "revoke-session:sess_web"
    );
    await user.click(within(confirmation).getByRole("button", { name: "Confirm" }));
    expect(
      await within(dialog).findByText("Revoked Web on macOS.")
    ).toBeInTheDocument();

    await user.type(
      within(dialog).getByRole("textbox", { name: "Reason" }),
      "End all remaining Sessions"
    );
    const revokeAll = within(dialog).getByRole("button", { name: "Revoke all" });
    await waitFor(() => expect(revokeAll).toBeEnabled());
    await user.click(revokeAll);

    confirmation = await screen.findByRole("dialog", {
      name: "Revoke all Sessions?",
    });
    await user.type(
      within(confirmation).getByRole("textbox", { name: /Confirmation/ }),
      "revoke-all-sessions:usr_owner"
    );
    await user.click(within(confirmation).getByRole("button", { name: "Confirm" }));
    expect(
      await within(dialog).findByText("Revoked 2 active Sessions.")
    ).toBeInTheDocument();

    await user.click(within(dialog).getByRole("button", { name: "Back" }));
    const workspaceTask = within(dialog)
      .getByText("Workspace & billing")
      .closest("article");
    expect(workspaceTask).not.toBeNull();
    await user.click(
      within(workspaceTask as HTMLElement).getByRole("button", { name: "Open" })
    );

    expect(await within(dialog).findByText("Owner Workspace")).toBeInTheDocument();
    expect(within(dialog).getByText("billing_owner")).toBeInTheDocument();
    expect(within(dialog).getAllByText("1,200")).toHaveLength(2);
    expect(within(dialog).getByText("comma_monthly@v1")).toBeInTheDocument();
    await user.click(within(dialog).getByRole("button", { name: "Apply redeem code" }));

    expect(
      await screen.findByRole("heading", { name: "Redeem codes" })
    ).toBeInTheDocument();
    const applyDrawer = await screen.findByRole("dialog", {
      name: "Apply redeem code",
    });
    expect(applyDrawer).toHaveTextContent("Owner Workspace");
    expect(within(applyDrawer).getByText("wsp_owner")).toBeInTheDocument();
    expect(within(applyDrawer).getByText("billing_owner")).toBeInTheDocument();
    expect(
      within(applyDrawer).queryByRole("textbox", { name: "Billing account ID" })
    ).not.toBeInTheDocument();
    expect(
      within(applyDrawer).queryByRole("textbox", { name: "Owner ID" })
    ).not.toBeInTheDocument();
    await user.type(
      within(applyDrawer).getByRole("textbox", { name: /Reason/ }),
      "Apply approved Workspace credit"
    );
    await user.click(
      within(applyDrawer).getByRole("button", { name: "Review command" })
    );

    confirmation = await screen.findByRole("dialog", {
      name: "Apply this redeem code?",
    });
    await user.type(
      within(confirmation).getByRole("textbox", { name: /Confirmation/ }),
      "apply-redeem-code:billing_owner"
    );
    await user.click(within(confirmation).getByRole("button", { name: "Confirm" }));

    await waitFor(() => {
      const applyRequest = fetchMock.mock.calls.find(([input, init]) => {
        const url = new URL(String(input));
        return (
          init?.method === "POST" &&
          url.pathname === "/v1/comma/admin/billing/redeem-codes/apply"
        );
      });
      expect(applyRequest).toBeDefined();
      expect(JSON.parse(String(applyRequest?.[1]?.body))).toMatchObject({
        billing_account_id: "billing_owner",
        product_owner_id: "wsp_owner",
        product_owner_type: "workspace",
      });
    });

    await user.click(screen.getByRole("button", { name: "Users" }));

    await user.click(screen.getByRole("button", { name: "Load more" }));
    expect(await screen.findByText("second@example.com")).toBeInTheDocument();

    await user.type(
      screen.getByRole("textbox", { name: "Filter users by email" }),
      "target@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Search" }));

    expect(await screen.findByText("target@example.com")).toBeInTheDocument();
    expect(screen.queryByText("second@example.com")).not.toBeInTheDocument();
  }, 10_000);

  it("opens the bounded Audit log and a redacted event detail drawer", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input));

      if (url.pathname === "/v1/comma/admin/users") {
        return jsonResponse({
          data: [],
          has_more: false,
          next_cursor: null,
        });
      }
      if (url.pathname === "/v1/comma/admin/audit-events") {
        if (url.searchParams.get("cursor") === "audit-page-2") {
          return jsonResponse({
            data: [
              {
                id: "audit_older",
                action: "create_user",
                outcome: "rejected",
                actor: {
                  type: "comma_user",
                  user_id: "usr_admin",
                  email: "owner@example.com",
                },
                target: { type: "user", id: "target@example.com" },
                reason: "Request did not pass validation",
                error_code: "invalid_confirmation",
                created_at: 1_784_879_000,
                updated_at: 1_784_879_001,
              },
            ],
            has_more: false,
            next_cursor: null,
          });
        }

        expect(url.searchParams.get("limit")).toBe("50");
        return jsonResponse({
          data: [
            {
              id: "audit_newest",
              action: "revoke_user_session",
              outcome: "succeeded",
              actor: {
                type: "comma_user",
                user_id: "usr_admin",
                email: "owner@example.com",
              },
              target: { type: "session", id: "sess_web" },
              reason: "Remove a stale browser Session",
              error_code: null,
              created_at: 1_784_880_000,
              updated_at: 1_784_880_001,
            },
          ],
          has_more: true,
          next_cursor: "audit-page-2",
        });
      }

      return jsonResponse({ error: "not_found" }, 404);
    });
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();

    render(<AdminApp />);

    await screen.findByText("No users found");
    await user.click(screen.getByRole("button", { name: "Audited operations" }));

    const table = await screen.findByRole("table", {
      name: "Admin audit events",
    });
    expect(within(table).getByText("Revoke user session")).toBeInTheDocument();
    expect(within(table).getByText("owner@example.com")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Audit log" })).toHaveAttribute(
      "aria-current",
      "page"
    );

    await user.click(within(table).getByRole("button", { name: "View audit event" }));
    const dialog = await screen.findByRole("dialog", {
      name: "Revoke user session",
    });
    expect(
      within(dialog).getByText("Remove a stale browser Session")
    ).toBeInTheDocument();
    expect(within(dialog).getByText("sess_web")).toBeInTheDocument();
    expect(within(dialog).queryByText(/request fingerprint/i)).not.toBeInTheDocument();

    await user.click(within(dialog).getByRole("button", { name: "Close" }));
    await user.click(screen.getByRole("button", { name: "Load more" }));
    expect(await screen.findByText("Create user")).toBeInTheDocument();
    await user.click(
      within(screen.getByRole("table", { name: "Admin audit events" }))
        .getAllByRole("button", { name: "View audit event" })
        .at(-1)!
    );
    expect(
      await screen.findByRole("dialog", { name: "Create user" })
    ).toHaveTextContent("invalid_confirmation");
  });

  it("lets operators collapse and restore the dashboard navigation", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        return jsonResponse({
          data: [],
          has_more: false,
          next_cursor: null,
        });
      })
    );
    vi.stubGlobal(
      "matchMedia",
      vi.fn(() => ({ matches: false }))
    );
    const user = userEvent.setup();

    render(<AdminApp />);

    const dashboard = await screen.findByTestId("admin-app");
    expect(dashboard).toHaveAttribute("data-sidebar-collapsed", "false");

    await user.click(screen.getByRole("button", { name: "Toggle navigation" }));
    expect(dashboard).toHaveAttribute("data-sidebar-collapsed", "true");

    await user.click(screen.getByRole("button", { name: "Toggle navigation" }));
    expect(dashboard).toHaveAttribute("data-sidebar-collapsed", "false");
  });

  it("uses a bounded codes table and scopes redemptions to the selected code", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input));

      switch (url.pathname) {
        case "/v1/comma/admin/users":
          return jsonResponse({
            data: [],
            has_more: false,
            next_cursor: null,
          });
        case "/v1/comma/admin/billing/redeem-codes":
          return jsonResponse({
            data: [
              {
                id: "code_legacy",
                display_prefix: "COMMA-LEGACY",
                package_code: "comma_monthly",
                package_version: "v1",
                code_type: "credit_grant",
                status: "active",
              },
            ],
          });
        case "/v1/comma/admin/billing/package-versions":
          return jsonResponse({
            data: [
              {
                id: "pkg_v2",
                package_code: "comma_monthly",
                package_name: "Comma Monthly",
                version: "v2",
                surface: "comma",
                kind: "subscription",
                grant_credits: 100,
                grant_period: "month",
                status: "active",
              },
            ],
          });
        case "/v1/comma/admin/billing/redemptions":
          expect(url.searchParams.get("redeem_code_id")).toBe("code_legacy");
          expect(url.searchParams.get("limit")).toBe("100");
          return jsonResponse({
            data: [
              {
                id: "redemption_1",
                redeem_code_id: "code_legacy",
                billing_account_id: "billing_1",
                product_owner_type: "workspace",
                product_owner_id: "workspace_1",
                source_type: "redeem_code",
                status: "applied",
              },
            ],
          });
        default:
          return jsonResponse({ error: "not_found" }, 404);
      }
    });
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();

    render(<AdminApp />);

    await user.click(screen.getByRole("button", { name: "Redeem codes" }));
    expect(await screen.findByText("COMMA-LEGACY")).toBeInTheDocument();
    expect(screen.getByText("comma_monthly@v1")).toBeInTheDocument();
    expect(screen.getByText(/latest 1 of up to 100 code records/i)).toBeInTheDocument();

    const manageCodeButton = screen.getByRole("button", { name: "Manage" });
    expect(manageCodeButton).toHaveClass("bg-button-secondary-bg", "border");
    await user.click(manageCodeButton);
    const dialog = await screen.findByRole("dialog", { name: "COMMA-LEGACY" });
    expect(await within(dialog).findByText("billing_1")).toBeInTheDocument();
    expect(within(dialog).getByText("workspace:workspace_1")).toBeInTheDocument();
    expect(
      within(dialog).getByText(/latest 1 of up to 100 scoped records/i)
    ).toBeInTheDocument();
  });

  it("keeps a one-time support token visible when the user refetch fails", async () => {
    let detailReads = 0;
    const supportUser = {
      id: "usr_support",
      email: "support-target@example.com",
      name: "Support Target",
      status: "active",
      created_at: 1_784_880_000,
      updated_at: 1_784_880_500,
      login_methods: [{ method: "email_otp", email: "support-target@example.com" }],
      admin_access: {
        allowed: false,
        decision: null,
        source: "none",
      },
    };

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(String(input));
        const method = init?.method ?? "GET";

        if (method === "GET" && url.pathname === "/v1/comma/admin/users") {
          return jsonResponse({
            data: [supportUser],
            has_more: false,
            next_cursor: null,
          });
        }

        if (method === "GET" && url.pathname === "/v1/comma/admin/users/usr_support") {
          detailReads += 1;
          return detailReads === 1
            ? jsonResponse(supportUser)
            : jsonResponse({ error: "workspace_unavailable" }, 503);
        }

        if (
          method === "POST" &&
          url.pathname === "/v1/comma/admin/users/usr_support/support-sessions"
        ) {
          return jsonResponse(
            {
              id: "sess_support_once",
              token: "comma_sess_shown_once",
              expires_at: 1_784_880_900,
              restricted: true,
              interaction_budget_remaining: 10,
              tool_allowlist: [],
            },
            201
          );
        }

        return jsonResponse({ error: "not_found" }, 404);
      })
    );
    const user = userEvent.setup();

    render(<AdminApp />);

    await user.click(await screen.findByRole("button", { name: "Manage" }));
    const dialog = await screen.findByRole("dialog", { name: "Manage user" });
    const supportTask = within(dialog).getByText("Support session").closest("article");
    expect(supportTask).not.toBeNull();
    await user.click(
      within(supportTask as HTMLElement).getByRole("button", { name: "Open" })
    );

    await user.type(
      within(dialog).getByRole("textbox", { name: /Reason/ }),
      "Investigate a reported account issue"
    );
    await user.click(within(dialog).getByRole("button", { name: "Review command" }));

    const confirmation = await screen.findByRole("dialog", {
      name: "Create support Session?",
    });
    await user.type(
      within(confirmation).getByRole("textbox", { name: /Confirmation/ }),
      "support-session:usr_support"
    );
    await user.click(within(confirmation).getByRole("button", { name: "Confirm" }));

    await waitFor(() => expect(detailReads).toBe(2));
    expect(within(dialog).getByText("comma_sess_shown_once")).toBeInTheDocument();
    expect(
      within(dialog).queryByRole("heading", {
        name: "Record couldn’t be loaded",
      })
    ).not.toBeInTheDocument();

    await user.click(within(dialog).getByRole("button", { name: "Done and clear" }));
    expect(within(dialog).queryByText("comma_sess_shown_once")).not.toBeInTheDocument();
    expect(
      within(dialog).getByRole("heading", {
        name: "Record couldn’t be loaded",
      })
    ).toBeInTheDocument();
  });

  it("replaces the whole dashboard with server-owned access denial", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ error: "forbidden" }, 403))
    );

    render(<AdminApp />);

    expect(
      await screen.findByRole("heading", { name: "Admin access required" })
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("complementary", { name: "Admin navigation" })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Sign out" })).toBeInTheDocument();
  });

  it("keeps non-operator 403 errors local to the active Admin view", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ error: "disabled" }, 403))
    );

    render(<AdminApp />);

    expect(
      await screen.findByRole("heading", { name: "Users couldn’t be loaded" })
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { name: "Admin access required" })
    ).not.toBeInTheDocument();
    expect(
      screen.getByRole("complementary", { name: "Admin navigation" })
    ).toBeInTheDocument();
  });

  it("resets to the first user page when the server rejects a stale cursor", async () => {
    let listCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = new URL(String(input));
        if (url.pathname !== "/v1/comma/admin/users") {
          return jsonResponse({ error: "not_found" }, 404);
        }

        listCalls += 1;
        if (url.searchParams.has("cursor")) {
          return jsonResponse({ error: "invalid_cursor" }, 400);
        }

        return jsonResponse({
          data: [
            {
              id: "usr_owner",
              email: "owner@example.com",
              status: "active",
            },
          ],
          has_more: true,
          next_cursor: "stale-cursor",
        });
      })
    );
    const user = userEvent.setup();

    render(<AdminApp />);

    expect(
      within(await screen.findByRole("table", { name: "Comma users" })).getByText(
        "owner@example.com"
      )
    ).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Load more" }));

    await waitFor(() => expect(listCalls).toBe(3));
    expect(
      within(screen.getByRole("table", { name: "Comma users" })).getByText(
        "owner@example.com"
      )
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Load more" })).toBeInTheDocument();
  });
});

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status,
  });
}
