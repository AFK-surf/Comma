import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import { FreeRouterModelsPanel } from "../src/FreeRouterModelsPanel";
import type { AdminApi } from "../src/adminApi";

it("loads, adds, confirms, and removes free Router models", async () => {
  const update = vi.fn(async (policy) => ({
    ...policy,
    revision: policy.revision + 1,
  }));
  const api = {
    getFreeRouterModels: vi.fn(async () => ({ models: [], revision: 3 })),
    updateFreeRouterModels: update,
  } as unknown as AdminApi;
  const user = userEvent.setup();
  render(<FreeRouterModelsPanel api={api} onAccessDenied={vi.fn()} />);
  await screen.findByText("No models are free under this policy.");
  await user.type(screen.getByRole("textbox", { name: "Provider" }), "openai");
  await user.type(screen.getByRole("textbox", { name: "Model SKU" }), "gpt-5.6-luna");
  await user.click(screen.getByRole("button", { name: "Add model" }));
  expect(update).not.toHaveBeenCalled();
  await user.type(
    screen.getByRole("textbox", { name: /^Reason/ }),
    "Offer free routing"
  );
  await user.click(screen.getByRole("button", { name: "Save free Router models" }));
  let dialog = screen.getByRole("dialog", { name: "Save free Router models?" });
  await user.type(
    within(dialog).getByRole("textbox"),
    "update-free-router-models:comma"
  );
  await user.click(within(dialog).getByRole("button", { name: "Confirm" }));
  await screen.findByText(/Saved. New Router calls/);
  expect(update).toHaveBeenCalledWith(
    { revision: 3, models: [{ provider: "openai", sku: "gpt-5.6-luna" }] },
    expect.objectContaining({ reason: "Offer free routing" })
  );
  await user.click(screen.getByRole("button", { name: "Remove gpt-5.6-luna" }));
  await user.type(screen.getByRole("textbox", { name: /^Reason/ }), "End free routing");
  await user.click(screen.getByRole("button", { name: "Save free Router models" }));
  dialog = screen.getByRole("dialog", { name: "Save free Router models?" });
  await user.type(
    within(dialog).getByRole("textbox"),
    "update-free-router-models:comma"
  );
  await user.click(within(dialog).getByRole("button", { name: "Confirm" }));
  await screen.findByText("No models are free under this policy.");
  expect(update).toHaveBeenLastCalledWith(
    { revision: 4, models: [] },
    expect.objectContaining({ reason: "End free routing" })
  );
});
