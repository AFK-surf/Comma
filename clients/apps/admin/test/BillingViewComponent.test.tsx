import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import type { AdminApi } from "../src/adminApi";
import { BillingView } from "../src/BillingView";

it("renders a recovered create as redacted completion without copy affordances", async () => {
  const api = {
    createRedeemCode: vi.fn(async () => ({
      kind: "recovered_redacted" as const,
      record: {
        id: "code_recovered",
        display_prefix: "COMMA-RECO",
        package_code: "comma_monthly",
        package_version: "v1",
        code_type: "one_time_package",
        status: "active",
      },
    })),
    listPackageVersions: vi.fn(async () => [
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
    ]),
    getFreeRouterModels: vi.fn(async () => ({ models: [], revision: 0 })),
    listRedeemCodes: vi.fn(async () => []),
  } as unknown as AdminApi;
  const user = userEvent.setup();

  render(
    <BillingView
      api={api}
      applyTarget={undefined}
      onAccessDenied={vi.fn()}
      onApplyTargetConsumed={vi.fn()}
    />
  );

  await user.click(await screen.findByRole("button", { name: "New code" }));
  const drawer = await screen.findByRole("dialog", { name: "New redeem code" });
  await user.type(
    within(drawer).getByRole("textbox", { name: /^Reason/ }),
    "Recover an earlier create command"
  );
  await user.click(within(drawer).getByRole("button", { name: "Review command" }));

  const confirmation = await screen.findByRole("dialog", {
    name: "Create this redeem code?",
  });
  await user.type(
    within(confirmation).getByRole("textbox", { name: /Confirmation/ }),
    "create-redeem-code:comma_monthly:v1"
  );
  await user.click(within(confirmation).getByRole("button", { name: "Confirm" }));

  const recovered = await screen.findByRole("dialog", {
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
  const api = {
    applyRedeemCode: vi.fn(async () => ({
      idempotent: true,
      redemption: {
        id: "redemption_existing",
        redeem_code_id: code.id,
        billing_account_id: "billing_workspace_1",
      },
    })),
    listPackageVersions: vi.fn(async () => []),
    getFreeRouterModels: vi.fn(async () => ({ models: [], revision: 0 })),
    listRedeemCodes: vi.fn(async () => [code]),
    listRedemptions: vi.fn(async () => []),
  } as unknown as AdminApi;
  const user = userEvent.setup();

  render(
    <BillingView
      api={api}
      applyTarget={{
        billingAccountId: "billing_workspace_1",
        productOwnerId: "workspace_1",
        productOwnerType: "workspace",
        workspaceName: "Workspace One",
      }}
      onAccessDenied={vi.fn()}
      onApplyTargetConsumed={vi.fn()}
    />
  );

  const drawer = await screen.findByRole("dialog", { name: "Apply redeem code" });
  await user.type(
    within(drawer).getByRole("textbox", { name: /^Reason/ }),
    "Recover the earlier apply command"
  );
  await user.click(within(drawer).getByRole("button", { name: "Review command" }));

  const confirmation = await screen.findByRole("dialog", {
    name: "Apply this redeem code?",
  });
  await user.type(
    within(confirmation).getByRole("textbox", { name: /Confirmation/ }),
    "apply-redeem-code:billing_workspace_1"
  );
  await user.click(within(confirmation).getByRole("button", { name: "Confirm" }));

  expect(
    await screen.findByText("COMMA-APPL was already applied during an earlier attempt.")
  ).toBeInTheDocument();
});
