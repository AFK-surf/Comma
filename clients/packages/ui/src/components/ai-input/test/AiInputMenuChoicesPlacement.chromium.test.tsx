import "@comma/ui/styles.css";

import { cleanup, render } from "@comma/test-utils/render";
import { useState } from "react";
import { afterEach, expect, it } from "vitest";
import { page, userEvent } from "vitest/browser";
import {
  AiInput,
  createAiInputRichValue,
  type AiInputMenuBrowse,
  type AiInputMenuItem,
  type AiInputRichValue,
} from "..";

afterEach(async () => {
  cleanup();
  await page.viewport(1280, 720);
});

const level = (label: string, items: AiInputMenuItem[]): AiInputMenuBrowse => ({
  compact: true,
  label,
  title: label,
  searchPlaceholder: label,
  emptyLabel: "Empty",
  noResultsLabel: "No results",
  groups: [{ id: `${label}/rows`, items }],
});
const vendor: AiInputMenuItem = {
  id: "vendor",
  label: "Vendor",
  browseGroupId: "vendor",
  browse: level("Vendor", [
    {
      id: "model",
      label: "Model",
      browse: level("Efforts", [
        { id: "low", label: "low" },
        { id: "high", label: "high" },
      ]),
    },
  ]),
};

/** A chat column narrower than the window, with another pane beside it. */
function Column() {
  const [value, setValue] = useState<AiInputRichValue>(() =>
    createAiInputRichValue([])
  );
  return (
    <div style={{ display: "flex", height: "100vh" }}>
      <div
        data-testid="column"
        style={{
          display: "flex",
          flexDirection: "column",
          justifyContent: "flex-end",
          overflow: "hidden",
          padding: 16,
          width: 560,
        }}
      >
        <AiInput
          menuRegistrations={[
            {
              id: "mentions",
              trigger: "@",
              label: "Mentions",
              groups: [{ id: "models", items: [vendor] }],
            },
          ]}
          richValue={value}
          onRichValueChange={setValue}
        />
      </div>
      <div style={{ flex: 1 }} />
    </div>
  );
}

it("keeps a row's choices inside a column that is narrower than the window", async () => {
  await page.viewport(1200, 600);
  const { container } = render(<Column />);
  await userEvent.click(page.getByRole("textbox"));
  await userEvent.keyboard("@{Enter}{ArrowRight}");
  const choice = page.getByRole("option", { name: "high", exact: true });
  await expect.element(choice).toBeVisible();

  const column = container
    .querySelector<HTMLElement>('[data-testid="column"]')!
    .getBoundingClientRect();
  const choices = choice
    .element()
    .closest(".comma-ai-input-menu")!
    .getBoundingClientRect();
  expect(choices.left).toBeGreaterThanOrEqual(column.left);
  expect(choices.right).toBeLessThanOrEqual(column.right);
  // With no room beside the panel they cover it, and leave the composer clear.
  expect(choices.bottom).toBeLessThanOrEqual(
    page.getByRole("textbox").element().getBoundingClientRect().top
  );

  await userEvent.click(choice);
  await expect.element(page.getByRole("textbox")).toHaveTextContent("high");
});
