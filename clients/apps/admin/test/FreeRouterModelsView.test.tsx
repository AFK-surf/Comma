import { Effect } from "effect";
import { screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import type { FreeRouterPolicy } from "../src/adminApi";
import { makeFreeRouterModelsModel } from "../src/FreeRouterModelsModel";
import { FreeRouterModelsView } from "../src/FreeRouterModelsView";
import { mountModel, ok, review, settle } from "./support";

it("adds, reviews, saves, and removes free Router models", async () => {
  const update = vi.fn((policy: FreeRouterPolicy) =>
    ok({
      ...policy,
      revision: policy.revision + 1,
    })
  );
  const view = mountModel(makeFreeRouterModelsModel, {
    api: {
      getFreeRouterModels: Effect.suspend(vi.fn(() => ok({ models: [], revision: 3 }))),
      updateFreeRouterModels: update,
    },
  });
  const user = userEvent.setup({ delay: null });
  view.render(<FreeRouterModelsView model={view.model} />);
  await settle();
  expect(screen.getByText("No models are free under this policy.")).toBeInTheDocument();
  await user.type(screen.getByRole("textbox", { name: "Provider" }), "OpenAI");
  await user.click(screen.getByRole("textbox", { name: "Model SKU" }));
  await user.paste("gpt-5.6-luna");
  await user.click(screen.getByRole("button", { name: "Add model" }));
  await settle();
  expect(update).not.toHaveBeenCalled();
  const saveBar = screen.getByRole("region", { name: "Unsaved changes" });
  await user.click(
    within(saveBar).getByRole("button", { name: "Save free Router models…" })
  );
  await settle();
  expect(
    screen.getByRole("dialog", { name: "Save free Router models?" })
  ).toHaveTextContent("openai/gpt-5.6-lunaCharged→Free");
  await review(user, "Save free Router models?", "Offer free routing", "free models");
  expect(screen.getByText(/Saved. New Router calls/)).toBeInTheDocument();
  expect(update).toHaveBeenCalledWith(
    { revision: 3, models: [{ provider: "openai", sku: "gpt-5.6-luna" }] },
    expect.objectContaining({
      confirmation: "update-free-router-models:comma",
      reason: "Offer free routing",
    })
  );
  expect(
    screen.queryByRole("region", { name: "Unsaved changes" })
  ).not.toBeInTheDocument();

  await user.click(screen.getByRole("button", { name: "Remove gpt-5.6-luna" }));
  await settle();
  await user.click(screen.getByRole("button", { name: "Save free Router models…" }));
  await settle();
  await review(user, "Save free Router models?", "End free routing", "free models");
  expect(screen.getByText("No models are free under this policy.")).toBeInTheDocument();
  expect(update).toHaveBeenLastCalledWith(
    { revision: 4, models: [] },
    expect.objectContaining({ reason: "End free routing" })
  );
});
