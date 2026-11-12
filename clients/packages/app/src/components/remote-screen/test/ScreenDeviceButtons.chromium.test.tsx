import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { afterEach, describe, expect, it, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { ScreenDeviceButtons } from "../ScreenDeviceFrame";
import {
  screenDeviceActions,
  type ScreenDeviceAction,
  type ScreenDevicePose,
} from "../screenDevice";

const core = createScriptedCore({ values: () => undefined });
const poses = ["closed", "open"] as const;
const label = { closed: "Outer screen", open: "Inner screen" } as const;

const buttons = (
  pose: ScreenDevicePose | undefined,
  wide: boolean,
  onAction: (action: ScreenDeviceAction) => void = () => undefined
) =>
  core.wrap(
    <div data-lays={wide ? "wide" : "tall"}>
      <ScreenDeviceButtons
        actions={screenDeviceActions(
          { input: "touch", buttons: [], poses },
          true,
          pose
        )}
        macos
        onAction={onAction}
        pose={pose}
        poses={poses}
      />
    </div>
  );

const selected = () =>
  poses.filter(
    (one) =>
      screen.getByRole("button", { name: label[one] }).getAttribute("aria-pressed") ===
      "true"
  );

afterEach(cleanup);

describe.each([
  ["beside the device", false],
  ["in a row under it", true],
])("a foldable's pose buttons %s", (_where, wide) => {
  it("explains each fold control on hover", async () => {
    render(
      <>
        <div
          data-lays={wide ? "wide" : "tall"}
          style={{ position: "relative", margin: 80, width: 400, height: 240 }}
        >
          {buttons("open", wide)}
        </div>
      </>
    );
    for (const name of ["Outer screen", "Inner screen"]) {
      setInteractionModality("pointer");
      const button = page.getByRole("button", { name, exact: true });
      await userEvent.hover(button);
      await expect.element(page.getByRole("tooltip")).toHaveTextContent(name);
      await userEvent.unhover(button);
    }
  });

  it("shows the screen each state reports", () => {
    const view = render(buttons("closed", wide));
    expect(selected()).toEqual(["closed"]);
    view.rerender(buttons("open", wide));
    expect(selected()).toEqual(["open"]);
    // The next states of the device: its picture turned, the same pose said again.
    view.rerender(buttons("open", wide));
    expect(selected()).toEqual(["open"]);
  });

  it("send a press only for a pose it is not in", async () => {
    const onAction = vi.fn();
    render(buttons("open", wide, onAction));
    await userEvent.click(screen.getByRole("button", { name: "Inner screen" }));
    expect(onAction).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole("button", { name: "Outer screen" }));
    expect(onAction).toHaveBeenCalledWith("fold");
  });

  it("keeps the panel controls as icons in either layout", () => {
    render(buttons("open", wide));
    for (const name of ["Outer screen", "Inner screen"]) {
      expect(screen.getByRole("button", { name }).textContent).toBe("");
    }
  });
});
