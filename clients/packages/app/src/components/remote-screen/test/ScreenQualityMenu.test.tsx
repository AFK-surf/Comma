import { cleanup, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ScreenQualityMenu } from "../ScreenStreamChrome";
import { useScreenQuality } from "../screenQuality";

// The core's `screenQuality` topic and `devices.chooseScreenQuality`, as the menu's hook reads and calls them.
let kept: string | null = null;
const calls: [string, unknown][] = [];
vi.mock("@comma/core-client", async (original) => ({
  ...(await original<typeof import("@comma/core-client")>()),
  useCall: () => (name: string, params: unknown) => {
    calls.push([name, params]);
    return Promise.resolve(null);
  },
  useTopic: () => ({ value: { quality: kept } }),
}));
afterEach(() => {
  cleanup();
  calls.length = 0;
  kept = null;
});

function Toolbar() {
  const [quality, choose] = useScreenQuality();
  return <ScreenQualityMenu onChoose={choose} quality={quality} />;
}

const open = async () => {
  render(<Toolbar />);
  await userEvent.click(screen.getByTestId("remote-screen-quality"));
  return screen.findByRole("menu");
};

describe("the viewer's 画质 menu", () => {
  it("shows the kept choice, offers the four with what each asks, and checks the one chosen", async () => {
    kept = "hd";
    expect(screen.queryByRole("menu")).toBeNull();
    const menu = await open();
    expect(screen.getByTestId("remote-screen-quality")).toHaveAccessibleName(
      "Quality: HD"
    );
    const rows = within(menu).getAllByRole("menuitemradio");
    expect(rows.map((row) => row.textContent)).toEqual([
      "AutoAdjusts to the link",
      "Smooth720p",
      "HD1080p",
      "OriginalHighest resolution",
    ]);
    expect(rows.map((row) => row.getAttribute("aria-checked"))).toEqual([
      "false",
      "false",
      "true",
      "false",
    ]);
  });

  it("keeps a new choice with the core, 自动 as none, and asks nothing for the one already chosen", async () => {
    let menu = await open();
    await userEvent.click(
      within(menu).getByRole("menuitemradio", { name: /Original/ })
    );
    expect(calls).toEqual([["devices.chooseScreenQuality", { quality: "original" }]]);
    cleanup();
    kept = "original";
    menu = await open();
    await userEvent.click(
      within(menu).getByRole("menuitemradio", { name: /Original/ })
    );
    expect(calls).toHaveLength(1);
    await userEvent.click(screen.getByTestId("remote-screen-quality"));
    menu = await screen.findByRole("menu");
    await userEvent.click(within(menu).getByRole("menuitemradio", { name: /Auto/ }));
    expect(calls.at(-1)).toEqual(["devices.chooseScreenQuality", { quality: null }]);
  });
});
