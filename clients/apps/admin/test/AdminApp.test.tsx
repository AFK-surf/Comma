import { screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { observabilityLinksForApiBaseUrl } from "../src/AdminApp";
import { adminTestSession, adminTestSessionId, mountAdminApp } from "./app";
import { jsonResponse } from "./http";
import { review, settle } from "./support";

/** `query` once what is ready has run. */
async function find<T>(query: () => T): Promise<T> {
  await settle();
  return query();
}

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
    const user = userEvent.setup({ delay: null });
    const { authRequests } = await mountAdminApp(
      vi.fn(async () =>
        jsonResponse({
          data: [],
          has_more: false,
          next_cursor: null,
        })
      )
    );

    expect(
      screen.queryByRole("menuitem", { name: "Sign out" })
    ).not.toBeInTheDocument();
    await user.click(
      screen.getByRole("button", {
        name: "Account menu for owner@example.com",
      })
    );
    await user.click(
      await find(() => screen.getByRole("menuitem", { name: "Sign out" }))
    );

    await settle();

    expect(
      authRequests.filter((request) => request.path === "/v1/comma/auth/logout")
    ).toEqual([
      { body: {}, expected: adminTestSessionId, path: "/v1/comma/auth/logout" },
    ]);
    expect(
      screen.getByRole("heading", { name: "Sign in to Comma" })
    ).toBeInTheDocument();
  });

  it("signs in with an emailed code and opens the dashboard", async () => {
    const user = userEvent.setup({ delay: null });
    const { advance, authRequests } = await mountAdminApp(
      vi.fn(async () => jsonResponse({ data: [], has_more: false, next_cursor: null })),
      {
        signedIn: false,
        auth: (path, body) => {
          if (path === "/v1/comma/auth/email/login") {
            return jsonResponse({ challenge_id: "challenge_email" });
          }
          if (path === "/v1/comma/auth/email/verify") {
            return (body as { code: string }).code === "123456"
              ? adminTestSession()
              : jsonResponse({ error: "invalid_challenge" }, 401);
          }
          return undefined;
        },
      }
    );

    expect(
      screen.getByRole("heading", { name: "Sign in to Comma" })
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Retry Google sign-in" })
    ).toBeInTheDocument();
    await user.click(screen.getByLabelText("Email"));
    await user.paste("owner@example.com");
    await user.click(screen.getByRole("button", { name: "Send code" }));
    await settle();

    expect(
      screen.getByRole("heading", { name: "Check your email" })
    ).toBeInTheDocument();
    expect(screen.getByText("owner@example.com")).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("Verification code sent.");
    expect(screen.getByText("Resend in 60s")).toBeInTheDocument();
    await advance(59_000);
    expect(screen.getByText("Resend in 1s")).toBeInTheDocument();
    await advance(1_000);
    await user.click(screen.getByRole("button", { name: "Resend" }));
    await settle();
    expect(screen.getByText("Resend in 60s")).toBeInTheDocument();
    const code = screen.getByLabelText("Verification code");
    await user.type(code, "000000");
    await user.click(screen.getByRole("button", { name: "Verify code" }));
    await settle();
    expect(screen.getByRole("alert")).toHaveTextContent(
      "That verification code is invalid. Please try again."
    );

    await user.clear(code);
    await user.type(code, "123456");
    await user.click(screen.getByRole("button", { name: "Verify code" }));
    await settle();

    expect(
      screen.getByRole("button", { name: "Account menu for owner@example.com" })
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { name: "Users", level: 1 })
    ).toBeInTheDocument();
    expect(
      authRequests.filter((request) => request.path.startsWith("/v1/comma/auth/email/"))
    ).toEqual([
      {
        body: { email: "owner@example.com" },
        expected: "none",
        path: "/v1/comma/auth/email/login",
      },
      {
        body: { email: "owner@example.com" },
        expected: "none",
        path: "/v1/comma/auth/email/login",
      },
      {
        body: expect.objectContaining({
          challenge_id: "challenge_email",
          code: "000000",
        }),
        expected: "none",
        path: "/v1/comma/auth/email/verify",
      },
      {
        body: expect.objectContaining({
          challenge_id: "challenge_email",
          code: "123456",
        }),
        expected: "none",
        path: "/v1/comma/auth/email/verify",
      },
    ]);
  });

  it("signs in with Google's own button", async () => {
    const user = userEvent.setup({ delay: null });
    const { authRequests } = await mountAdminApp(
      vi.fn(async () => jsonResponse({ data: [], has_more: false, next_cursor: null })),
      { googleCredential: "google-id-token", signedIn: false }
    );

    await user.click(
      screen.getByRole("button", { name: "Continue with Google (test)" })
    );
    await settle();

    expect(
      screen.getByRole("button", { name: "Account menu for owner@example.com" })
    ).toBeInTheDocument();
    expect(
      authRequests.find((request) => request.path === "/v1/comma/auth/google")
    ).toEqual({
      body: expect.objectContaining({
        attempt_id: "google_attempt",
        credential: "google-id-token",
        nonce: "google-nonce",
      }),
      expected: "none",
      path: "/v1/comma/auth/google",
    });
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
            {
              id: "sess_watch",
              auth_method: "watch_pairing",
              session_source: "user_login",
              authenticated_at: 1_784_850_000,
              expires_at: 4_102_444_800,
              last_seen_at: 1_784_859_500,
              revoked_at: 1_784_865_000,
              client_kind: "watch",
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
      if (url.searchParams.get("query") === "targ") {
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
    const user = userEvent.setup({ delay: null });
    await mountAdminApp(fetchMock);

    const usersTable = await find(() =>
      screen.getByRole("table", { name: "Comma users" })
    );
    expect(within(usersTable).getByText("owner@example.com")).toBeInTheDocument();
    expect(within(usersTable).getByText("Email OTP · Google")).toBeInTheDocument();
    expect(screen.queryByText("Total users")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Comma product" })).toHaveAttribute(
      "href",
      "https://afksurf.grafana.net/d/comma-staging-comma-product"
    );
    expect(screen.getByRole("link", { name: "Comma product" })).toHaveAttribute(
      "target",
      "_blank"
    );
    await user.click(screen.getByRole("button", { name: "Open owner@example.com" }));

    const userPage = await find(() => screen.getByTestId("admin-user-page"));
    expect(window.location.search).toBe("?user=usr_owner");
    expect(within(userPage).getByText("usr_owner")).toBeInTheDocument();
    expect(within(userPage).getByText(/owner@gmail\.com/)).toBeInTheDocument();
    expect(
      within(userPage).getByRole("button", { name: "Support session" })
    ).toBeInTheDocument();

    await user.click(within(userPage).getByRole("tab", { name: "Sessions & devices" }));
    expect(
      await find(() => within(userPage).getByText("Web on macOS"))
    ).toBeInTheDocument();
    expect(within(userPage).getByText("Comma Desktop on Windows")).toBeInTheDocument();
    expect(within(userPage).getByText("Comma SSH")).toBeInTheDocument();
    expect(within(userPage).getByText("Comma Android app")).toBeInTheDocument();
    expect(within(userPage).getByText(/Reported Android · Google/)).toBeInTheDocument();
    expect(within(userPage).getByText("Comma on Apple Watch")).toBeInTheDocument();
    expect(
      within(userPage).getByText(/Reported Apple Watch · Paired Watch/)
    ).toBeInTheDocument();
    expect(
      within(userPage).getByText(/Reported SSH · SSH public key/)
    ).toBeInTheDocument();
    expect(within(userPage).getByText(/Reported Web · Google/)).toBeInTheDocument();
    expect(
      within(userPage).getByText(/Reported Desktop · Email OTP/)
    ).toBeInTheDocument();
    expect(within(userPage).queryByText(/comma_sess_/i)).not.toBeInTheDocument();

    const webCard = within(userPage).getByText("Web on macOS").closest("article");
    expect(webCard).not.toBeNull();
    await user.click(
      within(webCard as HTMLElement).getByRole("button", { name: "Revoke" })
    );
    await find(() => screen.getByRole("dialog", { name: "Revoke this Session?" }));
    await review(user, "Revoke this Session?", "Remove the stale browser Session");
    expect(
      await find(() => within(userPage).getByText("Revoked Web on macOS."))
    ).toBeInTheDocument();

    const revokeAll = within(userPage).getByRole("button", { name: "Revoke all" });
    await settle();
    expect(revokeAll).toBeEnabled();
    await user.click(revokeAll);
    await find(() => screen.getByRole("dialog", { name: "Revoke all Sessions?" }));
    await review(
      user,
      "Revoke all Sessions?",
      "End all remaining Sessions",
      "owner@example.com"
    );
    expect(
      await find(() => within(userPage).getByText("Revoked 2 active Sessions."))
    ).toBeInTheDocument();

    await user.click(within(userPage).getByRole("tab", { name: "Overview" }));
    expect(
      await find(() => within(userPage).getByText("Owner Workspace"))
    ).toBeInTheDocument();
    expect(within(userPage).getByText("billing_owner")).toBeInTheDocument();
    expect(within(userPage).getAllByText("1,200")).toHaveLength(2);
    expect(within(userPage).getByText("comma_monthly@v1")).toBeInTheDocument();
    await user.click(
      within(userPage).getByRole("button", { name: "Apply redeem code" })
    );

    expect(
      await find(() => screen.getByRole("heading", { name: "Redeem codes" }))
    ).toBeInTheDocument();
    const applyDrawer = await find(() =>
      screen.getByRole("dialog", {
        name: "Apply redeem code",
      })
    );
    expect(applyDrawer).toHaveTextContent("Owner Workspace");
    expect(within(applyDrawer).getByText("wsp_owner")).toBeInTheDocument();
    expect(within(applyDrawer).getByText("billing_owner")).toBeInTheDocument();
    expect(
      within(applyDrawer).queryByRole("textbox", { name: "Billing account ID" })
    ).not.toBeInTheDocument();
    expect(
      within(applyDrawer).queryByRole("textbox", { name: "Owner ID" })
    ).not.toBeInTheDocument();
    await user.click(
      within(applyDrawer).getByRole("button", { name: "Review command" })
    );
    await find(() => screen.getByRole("dialog", { name: "Apply this redeem code?" }));
    await review(user, "Apply this redeem code?", "Apply approved Workspace credit");

    await settle();
    {
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
    }

    await user.click(screen.getByRole("button", { name: "Users" }));
    await settle();

    await user.click(screen.getByRole("button", { name: "Load more" }));
    expect(
      await find(() => screen.getByText("second@example.com"))
    ).toBeInTheDocument();

    await user.click(screen.getByRole("searchbox", { name: "Search users" }));
    await user.paste("targ");
    await user.keyboard("{Enter}");

    expect(
      await find(() => screen.getByText("target@example.com"))
    ).toBeInTheDocument();
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
    const user = userEvent.setup({ delay: null });
    await mountAdminApp(fetchMock);

    await find(() => screen.getByText("No users found"));
    await user.click(screen.getByRole("button", { name: "Audit log" }));

    const table = await find(() =>
      screen.getByRole("table", {
        name: "Admin audit events",
      })
    );
    expect(within(table).getByText("Revoke user session")).toBeInTheDocument();
    expect(within(table).getByText("owner@example.com")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Audit log" })).toHaveAttribute(
      "aria-current",
      "page"
    );

    await user.click(within(table).getByRole("button", { name: "View audit event" }));
    const dialog = await find(() =>
      screen.getByRole("dialog", {
        name: "Revoke user session",
      })
    );
    expect(
      within(dialog).getByText("Remove a stale browser Session")
    ).toBeInTheDocument();
    expect(within(dialog).getByText("sess_web")).toBeInTheDocument();
    expect(within(dialog).queryByText(/request fingerprint/i)).not.toBeInTheDocument();

    await user.click(within(dialog).getByRole("button", { name: "Close" }));
    await user.click(screen.getByRole("button", { name: "Load more" }));
    expect(
      await find(() => screen.getByText("Create user", { selector: "strong" }))
    ).toBeInTheDocument();
    await user.click(
      within(screen.getByRole("table", { name: "Admin audit events" }))
        .getAllByRole("button", { name: "View audit event" })
        .at(-1)!
    );
    expect(
      await find(() => screen.getByRole("dialog", { name: "Create user" }))
    ).toHaveTextContent("invalid_confirmation");
  });

  it("lets operators collapse and restore the dashboard navigation", async () => {
    const user = userEvent.setup({ delay: null });
    // The page is wide (the test browser reports no phone width).
    await mountAdminApp(
      vi.fn(async () => {
        return jsonResponse({
          data: [],
          has_more: false,
          next_cursor: null,
        });
      })
    );

    const dashboard = await find(() => screen.getByTestId("admin-app"));
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
    const user = userEvent.setup({ delay: null });
    await mountAdminApp(fetchMock);

    await user.click(screen.getByRole("button", { name: "Redeem codes" }));
    expect(await find(() => screen.getByText("COMMA-LEGACY"))).toBeInTheDocument();
    expect(screen.getByText("comma_monthly@v1")).toBeInTheDocument();
    expect(screen.getByText(/latest 1 of up to 100 code records/i)).toBeInTheDocument();

    const manageCodeButton = screen.getByRole("button", { name: "Manage" });
    expect(manageCodeButton).toHaveClass("bg-button-secondary-bg", "border");
    await user.click(manageCodeButton);
    const dialog = await find(() =>
      screen.getByRole("dialog", { name: "COMMA-LEGACY" })
    );
    expect(await find(() => within(dialog).getByText("billing_1"))).toBeInTheDocument();
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

    const user = userEvent.setup({ delay: null });
    await mountAdminApp(
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

    await user.click(
      await find(() =>
        screen.getByRole("button", { name: "Open support-target@example.com" })
      )
    );
    const userPage = await find(() => screen.getByTestId("admin-user-page"));
    await user.click(within(userPage).getByRole("button", { name: "Support session" }));
    const drawer = await find(() =>
      screen.getByRole("dialog", { name: /^Create support Session$/ })
    );
    await user.click(within(drawer).getByRole("button", { name: "Continue…" }));
    await find(() => screen.getByRole("dialog", { name: "Create support Session?" }));
    await review(
      user,
      "Create support Session?",
      "Investigate a reported account issue",
      "support-target@example.com"
    );

    await settle();
    expect(detailReads).toBe(2);
    expect(within(userPage).getByText("comma_sess_shown_once")).toBeInTheDocument();

    await user.click(within(userPage).getByRole("button", { name: "Done and clear" }));
    expect(
      within(userPage).queryByText("comma_sess_shown_once")
    ).not.toBeInTheDocument();
    expect(
      within(userPage).getByRole("heading", {
        name: "Account couldn’t be loaded",
      })
    ).toBeInTheDocument();
  });

  it("replaces the whole dashboard with server-owned access denial", async () => {
    await mountAdminApp(vi.fn(async () => jsonResponse({ error: "forbidden" }, 403)));

    expect(
      await find(() => screen.getByRole("heading", { name: "Admin access required" }))
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("complementary", { name: "Admin navigation" })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Sign out" })).toBeInTheDocument();
  });

  it("keeps non-operator 403 errors local to the active Admin view", async () => {
    await mountAdminApp(vi.fn(async () => jsonResponse({ error: "disabled" }, 403)));

    expect(
      await find(() =>
        screen.getByRole("heading", { name: "Users couldn’t be loaded" })
      )
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
    const user = userEvent.setup({ delay: null });
    await mountAdminApp(
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

    expect(
      within(
        await find(() => screen.getByRole("table", { name: "Comma users" }))
      ).getByText("owner@example.com")
    ).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Load more" }));

    await settle();
    expect(listCalls).toBe(3);
    expect(
      within(screen.getByRole("table", { name: "Comma users" })).getByText(
        "owner@example.com"
      )
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Load more" })).toBeInTheDocument();
  });
});
