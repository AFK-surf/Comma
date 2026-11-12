import "@comma/ui/styles.css";

import { SettingsSectionView } from "@comma/ui/components/settings-panel";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { page } from "vitest/browser";

// A row's action and its dropdown stand side by side: in real Chromium they
// must be one control size at each font size the reader can choose.

let root: Root | undefined;
afterEach(() => {
  root?.unmount();
  root = undefined;
  document.documentElement.style.fontSize = "";
});

describe("a settings row's action", () => {
  it("matches the row's dropdown in height, radius, border and text", async () => {
    const onPress = vi.fn();
    const host = document.createElement("div");
    host.style.width = "720px";
    document.body.append(host);
    root = createRoot(host);
    root.render(
      <SettingsSectionView
        section={{
          id: "mesh",
          title: "Computers over the mesh",
          items: [
            {
              id: "mesh.mode",
              title: "Reach my computers",
              description: "Restart Comma to apply.",
              action: { label: "Restart", onPress },
              control: {
                type: "dropdown",
                value: "on",
                items: [
                  { id: "off", label: "Off" },
                  { id: "on", label: "On" },
                ],
              },
            },
          ],
        }}
      />
    );
    const restart = page.getByRole("button", { name: "Restart" });
    await expect.element(restart).toBeInTheDocument();
    const action = restart.element() as HTMLElement;
    const select = Array.from(
      host.querySelectorAll<HTMLElement>('[data-slot="settings-control"] button')
    ).find((button) => button !== action)!;
    expect(select).toHaveTextContent("On");

    // Small, default and large, as Settings › Appearance sets the root size.
    for (const rootFontSize of [14.4, 16, 17.6]) {
      // Reading a box lays the page out again at this size.
      document.documentElement.style.fontSize = `${rootFontSize}px`;
      const a = getComputedStyle(action);
      const s = getComputedStyle(select);
      const actionBox = action.getBoundingClientRect();
      const selectBox = select.getBoundingClientRect();
      expect(actionBox.height).toBeCloseTo(selectBox.height, 1);
      expect(actionBox.top + actionBox.height / 2).toBeCloseTo(
        selectBox.top + selectBox.height / 2,
        1
      );
      expect(a.borderTopLeftRadius).toBe(s.borderTopLeftRadius);
      expect(a.borderTopWidth).toBe(s.borderTopWidth);
      expect(a.borderTopColor).toBe(s.borderTopColor);
      expect(a.fontSize).toBe(s.fontSize);
    }

    await restart.click();
    expect(onPress).toHaveBeenCalledOnce();
  });
});
