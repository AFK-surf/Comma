import { Effect } from "effect";
import { screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import type {
  AdminApiShape,
  AdminOauthClient,
  AdminOauthClientCreation,
  AdminOauthClientSecret,
} from "../src/adminApi";
import { makeOAuthClientsModel } from "../src/OAuthClientsModel";
import { OAuthClientsView } from "../src/OAuthClientsView";
import { mountModel, ok, pending, refuse, review, settle } from "./support";

const sync: AdminOauthClient = {
  id: "oauth_sync",
  name: "Synchronicity",
  confidential: true,
  redirect_uris: ["https://sync.example.com/auth/callback/oidc"],
  disabled_at: null,
  created_at: "2026-09-01T10:00:00Z",
};

/** The create drawer, while the confirmation above it hides it from the accessibility tree. */
const lockedDrawer = () =>
  screen.getByRole("dialog", { hidden: true, name: "New OAuth client" });

async function mountOAuthClients(api: Partial<AdminApiShape>) {
  const view = mountModel(makeOAuthClientsModel, { api });
  view.render(<OAuthClientsView model={view.model} />);
  await settle();
  return view;
}

it("shows that the OAuth IdP is not enabled", async () => {
  await mountOAuthClients({
    listOauthClients: Effect.suspend(vi.fn(() => refuse(404, "not_found"))),
  });

  expect(screen.getByText("OAuth IdP isn’t enabled")).toBeVisible();
  expect(
    screen.getByText("Enable the Comma OAuth IdP before registering clients.")
  ).toBeVisible();
  expect(screen.getByRole("button", { name: "New client" })).toBeDisabled();
});

it("creates a confidential client and keeps its drawer locked until the secret arrives", async () => {
  const reply = pending<AdminOauthClientCreation>();
  const create = vi.fn(() => reply.effect);
  await mountOAuthClients({
    createOauthClient: create,
    listOauthClients: Effect.suspend(vi.fn(() => ok([sync]))),
  });
  const user = userEvent.setup({ delay: null });

  const table = screen.getByRole("table", { name: "OAuth clients" });
  expect(within(table).getByText("Synchronicity")).toBeVisible();
  expect(within(table).getByText("Confidential")).toBeVisible();
  await user.click(screen.getByRole("button", { name: "New client" }));
  await settle();
  const drawer = screen.getByRole("dialog", { name: "New OAuth client" });
  await user.click(within(drawer).getByRole("textbox", { name: "Client name" }));
  await user.paste("Support  Portal");
  await user.click(within(drawer).getByRole("textbox", { name: /^Redirect URIs/ }));
  await user.paste("https://support.example.com/oauth/callback");
  await user.click(within(drawer).getByRole("button", { name: "Review command" }));
  await settle();
  const confirmation = screen.getByRole("dialog", {
    name: "Create this OAuth client?",
  });
  await review(user, "Create this OAuth client?", "Register portal");

  expect(within(confirmation).getByRole("button", { name: "Working…" })).toBeVisible();
  expect(create).toHaveBeenCalledWith({
    confidential: true,
    confirmation: "create-oauth-client:Support Portal",
    idempotencyKey: expect.stringMatching(/^create-oauth-client:/),
    name: "Support Portal",
    reason: "Register portal",
    redirectUris: ["https://support.example.com/oauth/callback"],
  });
  expect(
    within(lockedDrawer()).queryByRole("button", { hidden: true, name: "Close" })
  ).toBeNull();
  await user.keyboard("{Escape}");
  await settle();
  expect(lockedDrawer()).toBeInTheDocument();
  expect(
    screen.getByRole("dialog", { name: "Create this OAuth client?" })
  ).toBeVisible();

  const created: AdminOauthClientSecret = {
    ...sync,
    id: "oauth_support",
    name: "Support Portal",
    client_secret: "oauth-created-secret",
    confidential: true,
  };
  reply.succeed(created);
  await settle();
  const secret = screen.getByRole("dialog", { name: "Client secret created" });
  expect(within(secret).getByText("oauth-created-secret")).toBeVisible();
  expect(JSON.stringify({ ...localStorage })).not.toContain("oauth-created-secret");
  expect(screen.getByText("Created Support Portal.")).toBeVisible();
  await user.click(within(secret).getByRole("button", { name: "Done and clear" }));
  await settle();
  expect(screen.queryByText("oauth-created-secret")).toBeNull();
  expect(within(table).getByText("Support Portal")).toBeVisible();
});

it("rotates a client secret and returns to the client once it is cleared", async () => {
  const rotated: AdminOauthClientSecret = {
    ...sync,
    confidential: true,
    client_secret: "oauth-rotated-secret",
  };
  const rotate = vi.fn(() => ok(rotated));
  const view = await mountOAuthClients({
    listOauthClients: Effect.suspend(vi.fn(() => ok([sync]))),
    rotateOauthClientSecret: rotate,
  });
  const user = userEvent.setup({ delay: null });

  await user.click(screen.getByRole("button", { name: "Manage" }));
  await settle();
  const drawer = screen.getByRole("dialog", { name: "Manage OAuth client" });
  expect(
    within(drawer).getByText("https://sync.example.com/auth/callback/oidc")
  ).toBeVisible();
  await user.click(within(drawer).getByRole("button", { name: "Rotate secret" }));
  await settle();
  expect(
    screen.getByRole("dialog", { name: "Rotate this client secret?" })
  ).toHaveTextContent("The current secret stops working at once.");
  await review(user, "Rotate this client secret?", "Rotate it", sync.name);

  expect(rotate).toHaveBeenCalledWith("oauth_sync", {
    confirmation: "rotate-oauth-client-secret:oauth_sync",
    idempotencyKey: expect.stringMatching(/^rotate-oauth-client-secret:/),
    reason: "Rotate it",
  });
  const secret = screen.getByRole("dialog", { name: "Client secret rotated" });
  expect(within(secret).getByText("oauth-rotated-secret")).toBeVisible();
  await user.click(within(secret).getByRole("button", { name: "Copy secret" }));
  await settle();
  expect(view.browser.copied).toEqual(["oauth-rotated-secret"]);
  expect(within(secret).getByRole("button", { name: "Copied" })).toBeVisible();
  await user.click(within(secret).getByRole("button", { name: "Done and clear" }));
  await settle();

  expect(screen.getByRole("dialog", { name: "Manage OAuth client" })).toBeVisible();
  expect(screen.queryByText("oauth-rotated-secret")).toBeNull();
});
