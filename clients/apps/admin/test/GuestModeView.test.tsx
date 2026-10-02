import { render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import { GuestModeView } from "../src/GuestModeView";
import {
  AdminApiError,
  type AdminApi,
  type GuestModePolicy,
  type GuestModeSettings,
} from "../src/adminApi";

const loaded: GuestModePolicy = {
  enabled: false,
  salix_tenant_id: "tenant_guest_a",
  daily_creation_limit: 500,
  tenant_concurrency: 8,
  session_ttl_seconds: 604_800,
  pow_difficulty: 14,
  revision: 3,
  created_today: 12,
};

type User = ReturnType<typeof userEvent.setup>;

async function confirm(user: User, title: string, value: string) {
  const dialog = screen.getByRole("dialog", { name: title });
  await user.type(within(dialog).getByRole("textbox"), value);
  await user.click(within(dialog).getByRole("button", { name: "Confirm" }));
}

function policyForm(policy: HTMLElement) {
  const scope = within(policy);
  return {
    concurrency: scope.getByRole("spinbutton", { name: /Tenant concurrency/ }),
    daily: scope.getByRole("spinbutton", { name: /Daily creation limit/ }),
    enabled: scope.getByRole("switch", { name: /Guest mode enabled/ }),
    lifetime: scope.getByRole("spinbutton", { name: /Guest session lifetime/ }),
    powDifficulty: scope.getByRole("spinbutton", { name: /Proof-of-work difficulty/ }),
    reason: scope.getByRole("textbox", { name: /^Reason/ }),
    save: scope.getByRole("button", { name: "Save guest mode" }),
  };
}

it("loads guest mode and saves the edited policy with its revision", async () => {
  const update = vi.fn(async (settings: GuestModeSettings) => ({
    ...loaded,
    ...settings,
    revision: settings.revision + 1,
  }));
  const api = {
    getGuestMode: vi.fn(async () => loaded),
    updateGuestMode: update,
  } as unknown as AdminApi;
  const openFreeRouterModels = vi.fn();
  const user = userEvent.setup();
  render(
    <GuestModeView
      api={api}
      onAccessDenied={vi.fn()}
      onOpenFreeRouterModels={openFreeRouterModels}
    />
  );

  const tenant = await screen.findByRole("region", { name: "Guest tenant" });
  expect(within(tenant).getByText("tenant_guest_a")).toBeVisible();
  expect(within(tenant).getByText("12 of 500")).toBeVisible();
  const policy = screen.getByRole("region", { name: "Guest mode policy" });
  const form = policyForm(policy);
  expect(form.enabled).not.toBeChecked();
  expect(form.daily).toHaveValue(500);
  expect(form.concurrency).toHaveValue(8);
  expect(form.lifetime).toHaveValue(7);
  expect(form.powDifficulty).toHaveValue(14);

  const freeRouterLink = within(policy).getByRole("button", {
    name: "Open Free Router models",
  });
  await user.click(freeRouterLink);
  expect(openFreeRouterModels).toHaveBeenCalled();

  await user.click(form.enabled);
  await user.clear(form.concurrency);
  await user.type(form.concurrency, "600");
  await user.type(form.reason, "Open trial");
  expect(within(policy).getByText("Enter a whole number from 1 to 512.")).toBeVisible();
  expect(form.save).toBeDisabled();
  await user.clear(form.concurrency);
  await user.type(form.concurrency, "16");
  await user.clear(form.lifetime);
  await user.type(form.lifetime, "2");
  await user.clear(form.powDifficulty);
  await user.type(form.powDifficulty, "25");
  expect(within(policy).getByText("Enter a whole number from 8 to 24.")).toBeVisible();
  expect(form.save).toBeDisabled();
  await user.clear(form.powDifficulty);
  await user.type(form.powDifficulty, "16");
  await user.click(form.save);
  await confirm(user, "Save guest mode?", "update-guest-policy:comma");

  await screen.findByText("Saved. New guest sessions use these settings.");
  expect(update).toHaveBeenCalledWith(
    {
      enabled: true,
      daily_creation_limit: 500,
      tenant_concurrency: 16,
      session_ttl_seconds: 172_800,
      pow_difficulty: 16,
      revision: 3,
    },
    expect.objectContaining({
      confirmation: "update-guest-policy:comma",
      reason: "Open trial",
    })
  );
  expect(policyForm(policy).save).toBeDisabled();
});

it("reloads the latest policy when the saved revision is stale", async () => {
  const latest = { ...loaded, daily_creation_limit: 50, revision: 4 };
  const getGuestMode = vi
    .fn<AdminApi["getGuestMode"]>()
    .mockResolvedValueOnce(loaded)
    .mockResolvedValueOnce(latest);
  const update = vi.fn(async () => {
    throw new AdminApiError(409, "guest_policy_conflict", "guest_policy_conflict");
  });
  const api = { getGuestMode, updateGuestMode: update } as unknown as AdminApi;
  const user = userEvent.setup();
  render(<GuestModeView api={api} onAccessDenied={vi.fn()} />);

  const policy = await screen.findByRole("region", { name: "Guest mode policy" });
  const form = policyForm(policy);
  await user.clear(form.daily);
  await user.type(form.daily, "1000");
  await user.type(form.reason, "Raise cap");
  await user.click(form.save);
  await confirm(user, "Save guest mode?", "update-guest-policy:comma");

  await screen.findByText(/Guest mode changed after this page loaded/);
  await waitFor(() =>
    expect(screen.getByRole("spinbutton", { name: /Daily creation/ })).toHaveValue(50)
  );
  expect(getGuestMode).toHaveBeenCalledTimes(2);
  expect(update).toHaveBeenCalledTimes(1);
});

it("blocks enabling guest mode until a guest tenant exists", async () => {
  const api = {
    getGuestMode: vi.fn(async () => ({ ...loaded, salix_tenant_id: null })),
  } as unknown as AdminApi;
  const user = userEvent.setup();
  render(<GuestModeView api={api} onAccessDenied={vi.fn()} />);

  const policy = await screen.findByRole("region", { name: "Guest mode policy" });
  const form = policyForm(policy);
  await user.click(form.enabled);
  await user.type(form.reason, "Open trial");
  expect(within(policy).getByRole("alert")).toHaveTextContent(
    "Create a guest tenant before you enable guest mode."
  );
  expect(form.save).toBeDisabled();
});

it("creates a new guest tenant after an explained confirmation", async () => {
  const create = vi.fn(async (revision: number) => ({
    ...loaded,
    salix_tenant_id: "tenant_guest_b",
    revision: revision + 1,
  }));
  const api = {
    getGuestMode: vi.fn(async () => loaded),
    createGuestTenant: create,
  } as unknown as AdminApi;
  const user = userEvent.setup();
  render(<GuestModeView api={api} onAccessDenied={vi.fn()} />);

  const tenant = await screen.findByRole("region", { name: "Guest tenant" });
  const scope = within(tenant);
  await user.type(scope.getByRole("textbox", { name: /^Reason/ }), "Rotate");
  await user.click(scope.getByRole("button", { name: "Create new guest tenant" }));
  const dialog = screen.getByRole("dialog", { name: "Create new guest tenant?" });
  expect(dialog).toHaveTextContent(
    "New guests go to the new tenant. Existing guest workspaces stay"
  );
  await confirm(user, "Create new guest tenant?", "create-guest-tenant:comma");

  expect(await scope.findByText("tenant_guest_b")).toBeVisible();
  expect(create).toHaveBeenCalledWith(
    3,
    expect.objectContaining({
      confirmation: "create-guest-tenant:comma",
      reason: "Rotate",
    })
  );
});
