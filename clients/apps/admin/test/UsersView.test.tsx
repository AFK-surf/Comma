import { screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import type {
  AdminApiShape,
  AdminSession,
  AdminSupportSession,
  AdminUser,
} from "../src/adminApi";
import { makeUsersModel } from "../src/UsersModel";
import { UsersView } from "../src/UsersView";
import { mountModel, ok, pending, refuse, review, settle } from "./support";

const owner: AdminUser = {
  id: "usr_owner",
  email: "owner@example.com",
  name: "Comma Owner",
  status: "active",
  login_methods: [{ method: "email_otp", email: "owner@example.com" }],
  admin_access: { allowed: true, decision: null, source: "domain_default" },
};
const second: AdminUser = { id: "usr_second", email: "second@example.com" };

const webSession: AdminSession = {
  id: "sess_web",
  auth_method: "google",
  session_source: "user_login",
  authenticated_at: 10,
  expires_at: 3_600,
  last_seen_at: 20,
  revoked_at: null,
  client_kind: "web",
  device_label: "Web on macOS",
  restricted: false,
};

const page = <T,>(data: T[], nextCursor?: string) =>
  ok({ data, hasMore: Boolean(nextCursor), ...(nextCursor ? { nextCursor } : {}) });

type User = ReturnType<typeof userEvent.setup>;

beforeEach(() => {
  window.history.replaceState(null, "", "/");
});

async function mountUsers(api: Partial<AdminApiShape>) {
  const view = mountModel(makeUsersModel, { api });
  view.render(<UsersView model={view.model} />);
  await settle();
  return view;
}

async function openOwner(user: User) {
  await user.click(screen.getByRole("button", { name: "Open owner@example.com" }));
  await settle();
  return screen.getByTestId("admin-user-page");
}

/** Opens an account command's drawer from the page, then continues to its review. */
async function startCommand(
  user: User,
  userPage: HTMLElement,
  action: string,
  title: string
) {
  if (action === "Support session") {
    await user.click(within(userPage).getByRole("button", { name: action }));
  } else {
    await user.click(
      within(userPage).getByRole("button", { name: "More account actions" })
    );
    await user.click(screen.getByRole("menuitem", { name: action }));
  }
  await settle();
  const drawer = screen.getByRole("dialog", { name: title });
  await user.click(within(drawer).getByRole("button", { name: "Continue…" }));
  await settle();
  return drawer;
}

it("pages users, searches by a fragment, and restarts from a stale cursor", async () => {
  const listUsers = vi
    .fn()
    .mockReturnValueOnce(page([owner], "page-2"))
    .mockReturnValueOnce(page([second], "page-3"))
    .mockReturnValueOnce(refuse(400, "invalid_cursor"))
    .mockReturnValueOnce(page([owner], "page-2"))
    .mockReturnValueOnce(page([owner]));
  await mountUsers({ listUsers });
  const user = userEvent.setup({ delay: null });

  const table = screen.getByRole("table", { name: "Comma users" });
  expect(within(table).getByText("owner@example.com")).toBeInTheDocument();
  await user.click(screen.getByRole("button", { name: "Load more" }));
  await settle();
  expect(within(table).getByText("second@example.com")).toBeInTheDocument();
  expect(screen.getByText("2 users")).toBeInTheDocument();

  await user.click(screen.getByRole("button", { name: "Load more" }));
  await settle();
  expect(listUsers).toHaveBeenNthCalledWith(3, { cursor: "page-3", limit: 50 });
  expect(listUsers).toHaveBeenNthCalledWith(4, { limit: 50 });
  expect(screen.queryByText("second@example.com")).not.toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Load more" })).toBeInTheDocument();

  await user.click(screen.getByRole("searchbox", { name: "Search users" }));
  await user.paste(" Owner ");
  await user.keyboard("{Enter}");
  await settle();
  expect(listUsers).toHaveBeenLastCalledWith({ limit: 50, query: "Owner" });
  expect(screen.getByRole("button", { name: "Clear" })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Load more" })).not.toBeInTheDocument();
});

it("creates a user, then opens its page and refreshes the list", async () => {
  const listUsers = vi.fn(() => page([owner]));
  const createUser = vi.fn(() => ok(second));
  const getUser = vi.fn(() => ok(second));
  await mountUsers({
    createUser,
    getUser,
    getUserWorkspaceBilling: vi.fn(() => ok({ billing: null, workspace: null })),
    listUsers,
  });
  const user = userEvent.setup({ delay: null });

  await user.click(screen.getByRole("button", { name: "New user" }));
  await settle();
  const drawer = screen.getByRole("dialog", { name: "New user" });
  await user.click(within(drawer).getByRole("textbox", { name: "Email" }));
  await user.paste(" Second@Example.com");
  await user.selectOptions(
    within(drawer).getByRole("combobox", { name: /^Admin access/ }),
    "allow"
  );
  await user.click(within(drawer).getByRole("button", { name: "Create user…" }));
  await settle();
  // Granting Admin access asks for the account's email.
  await review(user, "Create this user?", "Approved account", "second@example.com");

  expect(createUser).toHaveBeenCalledWith({
    adminAccess: "allow",
    confirmation: "create-user:second@example.com",
    email: "second@example.com",
    idempotencyKey: expect.stringMatching(/^create-user:/),
    reason: "Approved account",
    status: "active",
  });
  expect(screen.queryByRole("dialog", { name: "New user" })).not.toBeInTheDocument();
  const userPage = screen.getByTestId("admin-user-page");
  expect(within(userPage).getByText("usr_second")).toBeInTheDocument();
  expect(window.location.search).toBe("?user=usr_second");
  expect(getUser).toHaveBeenCalledWith("usr_second");
  expect(screen.getByText("Created second@example.com.")).toBeInTheDocument();
  expect(listUsers).toHaveBeenCalledTimes(2);

  await user.click(within(userPage).getByRole("button", { name: "Users" }));
  await settle();
  expect(window.location.search).toBe("");
  expect(screen.getByRole("table", { name: "Comma users" })).toBeInTheDocument();
});

it("opens the account page named in the URL", async () => {
  window.history.replaceState(null, "", "/?user=usr_owner");
  const listUsers = vi.fn(() => page([owner]));
  await mountUsers({
    getUser: vi.fn(() => ok(owner)),
    getUserWorkspaceBilling: vi.fn(() => ok({ billing: null, workspace: null })),
    listUsers,
  });
  expect(
    screen.getByRole("heading", { name: "owner@example.com", level: 1 })
  ).toBeInTheDocument();
  // The list is read only when the operator goes back to it.
  expect(listUsers).not.toHaveBeenCalled();
});

it("keeps a one-time support token visible when the user refetch fails", async () => {
  const getUser = vi
    .fn()
    .mockReturnValueOnce(ok(owner))
    .mockReturnValueOnce(refuse(503, "workspace_unavailable", "Workspace unavailable"));
  const support = pending<AdminSupportSession>();
  const createSupportSession = vi.fn(() => support.effect);
  const view = await mountUsers({
    createSupportSession,
    getUser,
    getUserWorkspaceBilling: vi.fn(() => ok({ billing: null, workspace: null })),
    listUsers: vi.fn(() => page([owner])),
  });
  const user = userEvent.setup({ delay: null });

  const userPage = await openOwner(user);
  const drawer = await startCommand(
    user,
    userPage,
    "Support session",
    "Create support Session"
  );
  expect(
    screen.getByRole("dialog", { name: "Create support Session?" })
  ).toHaveTextContent("The token acts as owner@example.com for at most 900 seconds.");
  await review(
    user,
    "Create support Session?",
    "Investigate a reported account issue",
    "owner@example.com"
  );

  expect(screen.getByRole("button", { name: "Working…" })).toBeInTheDocument();
  expect(
    within(drawer).queryByRole("button", { name: "Close", hidden: true })
  ).not.toBeInTheDocument();
  support.succeed({
    id: "sess_support_once",
    token: "comma_sess_shown_once",
    expires_at: 1_784_880_900,
    restricted: true,
    interaction_budget_remaining: 10,
  });
  await settle();

  expect(createSupportSession).toHaveBeenCalledWith("usr_owner", {
    budget: 10,
    confirmation: "support-session:usr_owner",
    expiresInSeconds: 900,
    idempotencyKey: expect.stringMatching(/^user-support:/),
    reason: "Investigate a reported account issue",
  });
  expect(getUser).toHaveBeenCalledTimes(2);
  expect(drawer).not.toBeInTheDocument();
  expect(within(userPage).getByText("comma_sess_shown_once")).toBeInTheDocument();
  await user.click(within(userPage).getByRole("button", { name: "Copy token" }));
  await settle();
  expect(view.browser.copied).toEqual(["comma_sess_shown_once"]);
  expect(within(userPage).getByRole("button", { name: "Copied" })).toBeInTheDocument();

  await user.click(within(userPage).getByRole("button", { name: "Done and clear" }));
  await settle();
  expect(within(userPage).queryByText("comma_sess_shown_once")).not.toBeInTheDocument();
  expect(
    within(userPage).getByRole("heading", { name: "Account couldn’t be loaded" })
  ).toBeInTheDocument();
});

it("revokes a Session and shows Sessions past their expiry as expired", async () => {
  const listUserSessions = vi.fn(() => page([webSession]));
  const revokeUserSession = vi.fn(() =>
    ok({ revoked: true as const, session_id: "sess_web" })
  );
  const ensureDefaultWorkspace = vi.fn(() =>
    ok({ status: "ready" as const, workspace: { id: "wsp_owner", status: "ready" } })
  );
  const view = await mountUsers({
    ensureDefaultWorkspace,
    getUser: vi.fn(() => ok(owner)),
    // No default Workspace yet: the page offers to ensure one.
    getUserWorkspaceBilling: vi.fn(() => ok({ billing: null, workspace: null })),
    listUserSessions,
    listUsers: vi.fn(() => page([owner])),
    revokeUserSession,
  });
  const user = userEvent.setup({ delay: null });

  const userPage = await openOwner(user);
  await user.click(within(userPage).getByRole("tab", { name: "Sessions & devices" }));
  await settle();
  expect(listUserSessions).toHaveBeenCalledWith("usr_owner", {
    clientKind: "all",
    limit: 20,
    sort: "last_seen_at",
    status: "active",
  });
  const card = within(userPage)
    .getByText("Web on macOS")
    .closest("article") as HTMLElement;
  await user.click(within(card).getByRole("button", { name: "Revoke" }));
  await settle();
  await review(user, "Revoke this Session?", "Stale browser");

  expect(revokeUserSession).toHaveBeenCalledWith("usr_owner", "sess_web", {
    confirmation: "revoke-session:sess_web",
    idempotencyKey: expect.stringMatching(/^revoke-session:/),
    reason: "Stale browser",
  });
  expect(within(userPage).getByText("Revoked Web on macOS.")).toBeInTheDocument();

  // A reopened tab starts afresh, and reads the time from the Clock.
  await view.advance("2 hours");
  await user.click(within(userPage).getByRole("tab", { name: "Overview" }));
  await settle();
  await user.click(within(userPage).getByRole("tab", { name: "Sessions & devices" }));
  await settle();
  expect(within(userPage).queryByText("Revoked Web on macOS.")).not.toBeInTheDocument();
  const expiredCard = within(userPage)
    .getByText("Web on macOS")
    .closest("article") as HTMLElement;
  expect(within(expiredCard).getByText("Expired")).toBeInTheDocument();
  expect(within(expiredCard).getByRole("button", { name: "Revoke" })).toBeDisabled();

  // Filters are read by the server; an empty filtered page offers every Session.
  listUserSessions.mockImplementation(() => page<typeof webSession>([]));
  await user.click(within(userPage).getByRole("button", { name: /Filter by status/ }));
  await user.click(await screen.findByRole("option", { name: "Revoked" }));
  await settle();
  expect(listUserSessions).toHaveBeenLastCalledWith("usr_owner", {
    clientKind: "all",
    limit: 20,
    sort: "last_seen_at",
    status: "revoked",
  });
  expect(within(userPage).getByText("No matching Sessions")).toBeInTheDocument();
  await user.click(within(userPage).getByRole("button", { name: "Show all Sessions" }));
  await settle();
  expect(listUserSessions).toHaveBeenLastCalledWith("usr_owner", {
    clientKind: "all",
    limit: 20,
    sort: "last_seen_at",
    status: "all",
  });

  await user.click(within(userPage).getByRole("tab", { name: "Overview" }));
  await settle();
  await user.click(
    within(userPage).getByRole("button", { name: "Ensure default Workspace" })
  );
  await settle();
  await user.click(
    within(screen.getByRole("dialog", { name: "Ensure default Workspace" })).getByRole(
      "button",
      { name: "Continue…" }
    )
  );
  await settle();
  await review(user, "Ensure default Workspace?", "Bootstrap");
  expect(ensureDefaultWorkspace).toHaveBeenCalledWith("usr_owner", {
    confirmation: "default-workspace:usr_owner",
    idempotencyKey: expect.stringMatching(/^user-workspace:/),
    reason: "Bootstrap",
  });
  expect(
    within(userPage).getAllByText("Default Workspace wsp_owner is ready.")
  ).not.toHaveLength(0);
});

it("guards disabling an account and granting Admin access, not a rename", async () => {
  const updateUser = vi.fn(() => ok(owner));
  const setAdminAccess = vi.fn(() => ok(owner));
  await mountUsers({
    getUser: vi.fn(() => ok({ ...owner, admin_access: undefined })),
    getUserWorkspaceBilling: vi.fn(() => ok({ billing: null, workspace: null })),
    listUsers: vi.fn(() => page([owner])),
    setAdminAccess,
    updateUser,
  });
  const user = userEvent.setup({ delay: null });
  const userPage = await openOwner(user);

  await user.click(
    within(userPage).getByRole("button", { name: "More account actions" })
  );
  await user.click(screen.getByRole("menuitem", { name: "Edit account" }));
  await settle();
  let drawer = screen.getByRole("dialog", { name: "Edit account" });
  await user.selectOptions(
    within(drawer).getByRole("combobox", { name: "Account status" }),
    "disabled"
  );
  await user.click(within(drawer).getByRole("button", { name: "Continue…" }));
  await settle();
  const disable = screen.getByRole("dialog", { name: "Edit account?" });
  expect(disable).toHaveTextContent("Account statusActive→Disabled");
  expect(
    within(disable).getByRole("textbox", {
      name: "Type “owner@example.com” to confirm",
    })
  ).toBeInTheDocument();
  await user.click(within(disable).getByRole("button", { name: "Cancel" }));
  await settle();
  await user.selectOptions(
    within(drawer).getByRole("combobox", { name: "Account status" }),
    "active"
  );
  await user.clear(within(drawer).getByRole("textbox", { name: "Display name" }));
  await user.click(within(drawer).getByRole("textbox", { name: "Display name" }));
  await user.paste("Owner");
  await user.click(within(drawer).getByRole("button", { name: "Continue…" }));
  await settle();
  expect(screen.queryByRole("textbox", { name: /to confirm/ })).not.toBeInTheDocument();
  await review(user, "Edit account?", "Shorter name");
  expect(updateUser).toHaveBeenCalledWith(
    "usr_owner",
    expect.objectContaining({ name: "Owner", reason: "Shorter name", status: "active" })
  );

  drawer = await startCommand(
    user,
    userPage,
    "Change Admin access",
    "Change Admin access"
  );
  expect(
    screen.getByRole("textbox", { name: "Type “owner@example.com” to confirm" })
  ).toBeInTheDocument();
});
