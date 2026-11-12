import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { afterEach, expect, it, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { ScreenStreamAction, ScreenQualityMenu } from "../ScreenStreamChrome";
import { ScreenStatsPanel } from "../ScreenStatsPanel";

afterEach(cleanup);

it("names a toolbar icon on hover and keyboard focus without activating it", async () => {
  const pressed = vi.fn();
  render(<ScreenStreamAction icon={<span />} label="Ask Comma" onClick={pressed} />);
  setInteractionModality("pointer");
  const button = page.getByRole("button", { name: "Ask Comma" });
  await userEvent.hover(button);
  await expect.element(page.getByRole("tooltip")).toHaveTextContent("Ask Comma");
  await userEvent.unhover(button);
  await userEvent.keyboard("{Tab}");
  await expect.element(page.getByRole("tooltip")).toHaveTextContent("Ask Comma");
  expect(pressed).not.toHaveBeenCalled();
  await userEvent.keyboard("{Enter}");
  expect(pressed).toHaveBeenCalledOnce();
});

it("names the quality and connection controls while preserving their menus", async () => {
  render(
    createScriptedCore({ values: () => undefined }).wrap(
      <>
        <ScreenQualityMenu quality={undefined} onChoose={() => undefined} />
        <ScreenStatsPanel read={() => ({})} way={undefined} />
      </>
    )
  );
  await userEvent.keyboard("{Tab}");
  await expect.element(page.getByRole("tooltip")).toHaveTextContent("Quality: Auto");
  await userEvent.keyboard("{Enter}");
  await expect.element(page.getByRole("menu", { name: "Quality" })).toBeVisible();
  await userEvent.keyboard("{Escape}{Tab}");
  await expect.element(page.getByRole("tooltip")).toHaveTextContent("Connection");
  await userEvent.keyboard("{Enter}");
  await expect.element(page.getByRole("dialog", { name: "Connection" })).toBeVisible();
});
