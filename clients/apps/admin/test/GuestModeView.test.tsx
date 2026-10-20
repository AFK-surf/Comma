import { Effect } from "effect";
import { screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import type {
  AdminApiShape,
  GuestModePolicy,
  GuestModeSettings,
} from "../src/adminApi";
import { makeGuestModeModel } from "../src/GuestModeModel";
import { GuestModeView } from "../src/GuestModeView";
import { mountModel, ok, refuse, review, settle } from "./support";

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

function policyForm(policy: HTMLElement) {
  const scope = within(policy);
  return {
    concurrency: scope.getByRole("spinbutton", { name: /Tenant concurrency/ }),
    daily: scope.getByRole("spinbutton", { name: /Daily creation limit/ }),
    enabled: scope.getByRole("switch", { name: /Guest mode enabled/ }),
    lifetime: scope.getByRole("spinbutton", { name: /Guest session lifetime/ }),
    powDifficulty: scope.getByRole("spinbutton", { name: /Proof-of-work difficulty/ }),
  };
}

async function mountGuestMode(api: Partial<AdminApiShape>) {
  const view = mountModel(makeGuestModeModel, { api });
  view.render(<GuestModeView model={view.model} />);
  await settle();
  return view;
}

it("loads guest mode and saves the edited policy with its revision", async () => {
  const update = vi.fn((settings: GuestModeSettings) =>
    ok({ ...loaded, ...settings, revision: settings.revision + 1 })
  );
  const view = await mountGuestMode({
    getGuestMode: Effect.suspend(vi.fn(() => ok(loaded))),
    updateGuestMode: update,
  });
  const user = userEvent.setup({ delay: null });

  const tenant = screen.getByRole("region", { name: "Guest tenant" });
  expect(within(tenant).getByText("tenant_guest_a")).toBeVisible();
  expect(within(tenant).getByText("12 of 500")).toBeVisible();
  const policy = screen.getByRole("region", { name: "Guest mode policy" });
  const form = policyForm(policy);
  expect(form.enabled).not.toBeChecked();
  expect(form.daily).toHaveValue(500);
  expect(form.concurrency).toHaveValue(8);
  expect(form.lifetime).toHaveValue(7);
  expect(form.powDifficulty).toHaveValue(14);

  await user.click(
    within(policy).getByRole("button", { name: "Open Free Router models" })
  );
  await settle();
  expect(view.links.select).toHaveBeenCalledWith("free-models");
  expect(
    screen.queryByRole("region", { name: "Unsaved changes" })
  ).not.toBeInTheDocument();

  await user.click(form.enabled);
  await user.clear(form.concurrency);
  await user.type(form.concurrency, "600");
  expect(within(policy).getByText("Enter a whole number from 1 to 512.")).toBeVisible();
  expect(saveButton()).toBeDisabled();
  await user.clear(form.concurrency);
  await user.type(form.concurrency, "16");
  await user.clear(form.lifetime);
  await user.type(form.lifetime, "2");
  await user.clear(form.powDifficulty);
  await user.type(form.powDifficulty, "25");
  expect(within(policy).getByText("Enter a whole number from 8 to 24.")).toBeVisible();
  expect(saveButton()).toBeDisabled();
  await user.clear(form.powDifficulty);
  await user.type(form.powDifficulty, "16");
  expect(screen.getByRole("region", { name: "Unsaved changes" })).toHaveTextContent(
    "4 unsaved changes"
  );
  await user.click(saveButton());
  await settle();
  const dialog = screen.getByRole("dialog", { name: "Save guest mode?" });
  expect(dialog).toHaveTextContent("Guest session lifetime7 days→2 days");
  await review(user, "Save guest mode?", "Open trial", "guest mode");

  expect(
    screen.getByText("Saved. New guest sessions use these settings.")
  ).toBeVisible();
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
  expect(
    screen.queryByRole("region", { name: "Unsaved changes" })
  ).not.toBeInTheDocument();
});

function saveButton() {
  return screen.getByRole("button", { name: "Save guest mode…" });
}

it("discards edits back to the saved policy", async () => {
  await mountGuestMode({ getGuestMode: Effect.suspend(vi.fn(() => ok(loaded))) });
  const user = userEvent.setup({ delay: null });
  const form = policyForm(screen.getByRole("region", { name: "Guest mode policy" }));
  await user.clear(form.daily);
  await user.type(form.daily, "900");
  await user.click(screen.getByRole("button", { name: "Discard" }));
  await settle();
  expect(form.daily).toHaveValue(500);
  expect(
    screen.queryByRole("region", { name: "Unsaved changes" })
  ).not.toBeInTheDocument();
});

it("reloads the latest policy when the saved revision is stale", async () => {
  const latest = { ...loaded, daily_creation_limit: 50, revision: 4 };
  const getGuestMode = vi
    .fn()
    .mockReturnValueOnce(ok(loaded))
    .mockReturnValueOnce(ok(latest));
  const update = vi.fn(() => refuse(409, "guest_policy_conflict"));
  await mountGuestMode({
    getGuestMode: Effect.suspend(getGuestMode),
    updateGuestMode: update,
  });
  const user = userEvent.setup({ delay: null });

  const policy = screen.getByRole("region", { name: "Guest mode policy" });
  const form = policyForm(policy);
  await user.clear(form.daily);
  await user.type(form.daily, "1000");
  await user.click(saveButton());
  await settle();
  await review(user, "Save guest mode?", "Raise cap", "guest mode");

  expect(screen.getByText(/Guest mode changed after this page loaded/)).toBeVisible();
  expect(screen.getByRole("spinbutton", { name: /Daily creation/ })).toHaveValue(50);
  expect(getGuestMode).toHaveBeenCalledTimes(2);
  expect(update).toHaveBeenCalledTimes(1);
});

it("blocks enabling guest mode until a guest tenant exists", async () => {
  await mountGuestMode({
    getGuestMode: Effect.suspend(vi.fn(() => ok({ ...loaded, salix_tenant_id: null }))),
  });
  const user = userEvent.setup({ delay: null });

  const policy = screen.getByRole("region", { name: "Guest mode policy" });
  const form = policyForm(policy);
  await user.click(form.enabled);
  expect(within(policy).getByRole("alert")).toHaveTextContent(
    "Create a guest tenant before you enable guest mode."
  );
  expect(saveButton()).toBeDisabled();
});

it("creates a new guest tenant after an explained confirmation", async () => {
  const create = vi.fn((revision: number) =>
    ok({ ...loaded, salix_tenant_id: "tenant_guest_b", revision: revision + 1 })
  );
  await mountGuestMode({
    getGuestMode: Effect.suspend(vi.fn(() => ok(loaded))),
    createGuestTenant: create,
  });
  const user = userEvent.setup({ delay: null });

  const tenant = screen.getByRole("region", { name: "Guest tenant" });
  const scope = within(tenant);
  await user.click(scope.getByRole("button", { name: "Create new guest tenant" }));
  await settle();
  const dialog = screen.getByRole("dialog", { name: "Create new guest tenant?" });
  expect(dialog).toHaveTextContent(
    "New guests go to the new tenant. Existing guest workspaces stay"
  );
  await review(user, "Create new guest tenant?", "Rotate", "guest mode");

  expect(scope.getByText("tenant_guest_b")).toBeVisible();
  expect(create).toHaveBeenCalledWith(
    3,
    expect.objectContaining({
      confirmation: "create-guest-tenant:comma",
      reason: "Rotate",
    })
  );
});
