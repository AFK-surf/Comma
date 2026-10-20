import { Effect } from "effect";
import { screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import { makeBillingModel } from "../src/BillingModel";
import { BillingView } from "../src/BillingView";
import { mountModel, ok, review, settle } from "./support";

it("renders a recovered create as redacted completion without copy affordances", async () => {
  const view = mountModel(makeBillingModel(undefined), {
    api: {
      createRedeemCode: vi.fn(() =>
        ok({
          kind: "recovered_redacted" as const,
          record: {
            id: "code_recovered",
            display_prefix: "COMMA-RECO",
            package_code: "comma_monthly",
            package_version: "v1",
            code_type: "one_time_package",
            status: "active",
          },
        })
      ),
      listPackageVersions: Effect.suspend(
        vi.fn(() =>
          ok([
            {
              id: "package_v1",
              package_code: "comma_monthly",
              package_name: "Comma Monthly",
              version: "v1",
              surface: "comma",
              kind: "one_time",
              grant_credits: 100,
              grant_period: "current_period",
              status: "active",
            },
          ])
        )
      ),
      listRedeemCodes: vi.fn(() => ok([])),
    },
  });
  view.render(<BillingView model={view.model} />);
  await settle();
  const user = userEvent.setup({ delay: null });

  await user.click(screen.getByRole("button", { name: "New code" }));
  await settle();
  const drawer = screen.getByRole("dialog", { name: "New redeem code" });
  await user.click(within(drawer).getByRole("button", { name: "Review command" }));
  await settle();
  await review(user, "Create this redeem code?", "Recover an earlier create command");

  const recovered = screen.getByRole("dialog", {
    name: "Code already created",
  });
  expect(recovered).toHaveTextContent("The plaintext is intentionally unavailable");
  expect(within(recovered).queryByRole("button", { name: "Copy code" })).toBeNull();
  expect(within(recovered).queryByText("Shown once")).toBeNull();
});

it("reports a reconciled apply as an earlier success instead of a new redemption", async () => {
  const code = {
    id: "code_applied",
    display_prefix: "COMMA-APPL",
    package_code: "comma_monthly",
    package_version: "v1",
    code_type: "one_time_package",
    surface: "comma",
    status: "active",
  };
  const view = mountModel(
    makeBillingModel({
      billingAccountId: "billing_workspace_1",
      productOwnerId: "workspace_1",
      productOwnerType: "workspace",
      workspaceName: "Workspace One",
    }),
    {
      api: {
        applyRedeemCode: vi.fn(() =>
          ok({
            idempotent: true,
            redemption: {
              id: "redemption_existing",
              redeem_code_id: code.id,
              billing_account_id: "billing_workspace_1",
            },
          })
        ),
        listPackageVersions: Effect.suspend(vi.fn(() => ok([]))),
        listRedeemCodes: vi.fn(() => ok([code])),
        listRedemptions: vi.fn(() => ok([])),
      },
    }
  );
  view.render(<BillingView model={view.model} />);
  await settle();
  const user = userEvent.setup({ delay: null });

  const drawer = screen.getByRole("dialog", { name: "Apply redeem code" });
  await user.click(within(drawer).getByRole("button", { name: "Review command" }));
  await settle();
  await review(user, "Apply this redeem code?", "Recover the earlier apply command");

  expect(
    screen.getByText("COMMA-APPL was already applied during an earlier attempt.")
  ).toBeInTheDocument();
});

it("applies a code to the account the operator finds by email, without typing its ids", async () => {
  const code = {
    id: "code_active",
    display_prefix: "COMMA-ACTV",
    package_code: "comma_monthly",
    package_version: "v1",
    code_type: "one_time_package",
    surface: "comma",
    status: "active",
  };
  const workspace = {
    id: "wsp_ada",
    name: "Ada's Workspace",
    status: "ready" as const,
    tenant_id: "tnt_ada",
    group_id: "grp_ada",
    billing_account_id: "billing_ada",
    created_at: 1_784_880_000,
    updated_at: 1_784_880_500,
  };
  const billing = {
    account_id: "billing_ada",
    current_credits: 0,
    active_grants: [],
    has_more: false,
  };
  const applyRedeemCode = vi.fn(() =>
    ok({
      idempotent: false,
      redemption: {
        id: "redemption_new",
        redeem_code_id: code.id,
        billing_account_id: "billing_ada",
      },
    })
  );
  const getUserWorkspaceBilling = vi
    .fn()
    .mockReturnValueOnce(ok({ workspace: null, billing: null }))
    .mockReturnValueOnce(
      ok({ workspace, billing: { ...billing, account_status: "active" as const } })
    );
  const view = mountModel(makeBillingModel(undefined), {
    api: {
      applyRedeemCode,
      getUserWorkspaceBilling,
      listPackageVersions: Effect.suspend(vi.fn(() => ok([]))),
      listRedeemCodes: vi.fn(() => ok([code])),
      listRedemptions: vi.fn(() => ok([])),
      lookup: vi.fn(() =>
        ok({
          data: [
            {
              match: "email" as const,
              user: { id: "usr_ada", email: "ada@example.com", name: "Ada" },
              workspace: null,
            },
          ],
        })
      ),
    },
  });
  view.render(<BillingView model={view.model} />);
  await settle();
  const user = userEvent.setup({ delay: null });

  await user.click(screen.getByRole("button", { name: "Apply code" }));
  await settle();
  const drawer = screen.getByRole("dialog", { name: "Apply redeem code" });
  expect(
    within(drawer).queryByRole("textbox", { name: /Billing account ID/ })
  ).toBeNull();
  expect(within(drawer).getByRole("button", { name: "Review command" })).toBeDisabled();

  await user.click(within(drawer).getByRole("textbox", { name: "Account" }));
  await user.paste("ada@");
  await view.advance("250 millis");
  await user.click(within(drawer).getByRole("button", { name: /ada@example\.com/ }));
  await settle();
  expect(within(drawer).getByRole("alert")).toHaveTextContent(
    "ada@example.com has no Workspace yet"
  );

  await user.click(within(drawer).getByRole("button", { name: /ada@example\.com/ }));
  await settle();
  expect(within(drawer).getByText("billing_ada")).toBeInTheDocument();
  expect(within(drawer).getByText("wsp_ada")).toBeInTheDocument();
  await user.click(within(drawer).getByRole("button", { name: "Review command" }));
  await settle();
  await review(user, "Apply this redeem code?", "Monthly plan for Ada");

  expect(applyRedeemCode).toHaveBeenCalledWith(
    expect.objectContaining({
      billingAccountId: "billing_ada",
      codeId: "code_active",
      confirmation: "apply-redeem-code:billing_ada",
      productOwnerId: "wsp_ada",
      productOwnerType: "workspace",
    })
  );
});
