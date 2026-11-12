import type { ListedScreen } from "@comma/core-client";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useOptionalCommaClientSettings } from "../../commaClientSettings";
import {
  ScreenComputerMenu,
  ScreenModelChooser,
  type ChosenScreen,
} from "../ScreenMenus";

// The screen menu while a tab shows an iOS Simulator of this Mac ("mini"): the Mac's iOS models in its place, each
// once, and its other running screens; another Mac ("mbp") keeps its display.

const device = (
  id: string,
  name: string,
  title: string,
  more: Partial<ListedScreen> = {}
): ListedScreen => ({
  id: id as ListedScreen["id"],
  instance: `${id}/boot`,
  name,
  title,
  width: 1206,
  height: 2622,
  peek: true,
  capabilities: { input: "touch", buttons: [], panels: [] },
  ...more,
});
const shown = device("simulator:A", "iPhone 17 Pro", "iPhone 17 Pro · iOS 27.1");
const air = device("simulator:B", "iPhone Air", "iPhone Air · iOS 27.1");
const pixel = device("android:emulator-5554", "Pixel_9", "Pixel_9 · Android 16");
const booted17 = device("simulator:N", "iPhone 17", "iPhone 17 · iOS 27.1");

let listed: ListedScreen[];
const calls: { name: string; params: Record<string, unknown> }[] = [];
const call = vi.fn(async (name: string, params: Record<string, unknown>) => {
  calls.push({ name, params });
  if (name === "devices.startScreenDevice") {
    // (it is listed as it is up)
    listed = [...listed, booted17];
    return { id: booted17.id };
  }
  if (name === "devices.listScreens")
    return params.device === "mini"
      ? {
          screens: listed,
          avds: ["Pixel_Fold"],
          simulators: [
            // The one model on two runtimes, twice on the newest: one row, the newest.
            { udid: "N", title: "iPhone 17 · iOS 27.1" },
            { udid: "N2", title: "iPhone 17 · iOS 27.1" },
            { udid: "O", title: "iPhone 17 · iOS 26.2" },
            // The current model's other device: no row of its own.
            { udid: "P", title: "iPhone 17 Pro · iOS 26.2" },
            // Only on an older runtime: behind More….
            { udid: "Q", title: "iPhone 15 · iOS 17.0" },
          ],
        }
      : { screens: [], avds: [], simulators: [] };
  return null;
});
vi.mock("@comma/core-client", async (original) => ({
  ...(await original<typeof import("@comma/core-client")>()),
  useCall: () => call,
  useTopic: (topic: unknown) => ({
    value: topic
      ? {
          devices: [
            {
              device_id: "mini",
              name: "Pengs-Mac-Mini-2",
              alias: "Default workspace Station",
              station_id: "station-mini",
              status: "connected",
              screen_view: true,
            },
            {
              device_id: "mbp",
              name: "MacBook-Pro-373",
              alias: "Default workspace Station",
              station_id: "station-mbp",
              status: "connected",
              screen_view: true,
            },
          ],
        }
      : undefined,
  }),
}));
vi.mock("../../commaClientSettings", () => ({
  useOptionalCommaClientSettings: vi.fn(),
}));

beforeEach(() => {
  listed = [shown, air, pixel];
  calls.length = 0;
  localStorage.clear();
  vi.mocked(useOptionalCommaClientSettings).mockReturnValue({
    computerMesh: "on",
  } as never);
  installNativeBridgeMock({
    platform: "electron",
    connectorRuntime: {
      state: createNativeStateBridgeMock(() => ({
        revision: 1,
        scopes: [{ workspaceId: "wsp", available: true, scope: "", deviceId: "mini" }],
      })),
    },
  });
});
afterEach(cleanup);

const openMenu = async (onChoose: (chosen: ChosenScreen) => void = () => undefined) => {
  render(
    <ScreenComputerMenu
      current="mini"
      currentScreen={shown.instance}
      line="Live"
      onChoose={onChoose}
      title="iPhone 17 Pro"
      workspace="wsp"
    />
  );
  await userEvent.click(screen.getByTestId("remote-screen-computers"));
  const menu = await screen.findByRole("menu");
  await waitFor(() => expect(within(menu).getByText("iPhone Air")).toBeTruthy());
  return menu;
};
/** The rows of the section headed `heading`, by their names. */
const rows = (menu: HTMLElement, heading: string) => {
  const section = [...menu.querySelectorAll("section")].find(
    (one) => one.querySelector("header")?.textContent === heading
  )!;
  return [...section.querySelectorAll<HTMLElement>('[role="menuitem"]')].map(
    (item) =>
      item.getAttribute("aria-label") ??
      item.querySelector('[data-slot="menu-item-label"]')?.textContent
  );
};

describe("the screen menu while a simulator shows", () => {
  it("offers this Mac's iOS models once each, those that run and then those that would boot, without unrelated screens or computers", async () => {
    const menu = await openMenu();
    expect(
      [...menu.querySelectorAll("header")].map((header) => header.textContent)
    ).toEqual(["Booted", "Available (will boot)"]);
    // No display of this computer's own, and nothing to "Start".
    expect(rows(menu, "Booted")).toEqual(["iPhone 17 Pro", "iPhone Air"]);
    // Newest first; the one only on an older runtime comes last.
    expect(rows(menu, "Available (will boot)")).toEqual(["iPhone 17", "iPhone 15"]);
    expect(within(menu).queryByText(/^Start /)).toBeNull();
    // The one the tab shows has the check, and no other.
    expect(
      within(menu).getByRole("menuitem", { name: "iPhone 17 Pro" }).querySelector("svg")
    ).not.toBeNull();
    expect(
      within(menu).getByRole("menuitem", { name: "iPhone Air" }).querySelector("svg")
    ).toBeNull();
    expect(within(menu).queryByText("Display")).toBeNull();
    expect(within(menu).queryByText("MacBook-Pro-373")).toBeNull();
  });

  it("says under each model what it runs", async () => {
    const menu = await openMenu();
    const under = (name: string) =>
      within(menu)
        .getByRole("menuitem", { name })
        .querySelector('[data-slot="menu-item-under"]')?.textContent;
    expect(under("iPhone 17 Pro")).toBe("iOS 27.1");
    expect(under("iPhone Air")).toBe("iOS 27.1");
    expect(under("iPhone 17")).toBe("iOS 27.1");
    expect(under("iPhone 15")).toBe("iOS 17.0");
    expect(within(menu).queryByText("Pixel_9")).toBeNull();
  });

  it("shows a model that is running at once", async () => {
    const chosen = vi.fn();
    const menu = await openMenu(chosen);
    await userEvent.click(within(menu).getByRole("menuitem", { name: "iPhone Air" }));
    expect(chosen).toHaveBeenCalledWith({ device: "mini", screen: air });
    expect(calls.some(({ name }) => name === "devices.startScreenDevice")).toBe(false);
  });

  it("boots a model that is not running, on its newest runtime, then shows it", async () => {
    const chosen = vi.fn();
    const menu = await openMenu(chosen);
    await userEvent.click(within(menu).getByRole("menuitem", { name: "iPhone 17" }));
    await waitFor(() =>
      expect(chosen).toHaveBeenCalledWith({ device: "mini", screen: booted17 })
    );
    expect(
      calls
        .filter(({ name }) => name === "devices.startScreenDevice")
        .map(({ params }) => params)
    ).toEqual([{ workspace: "wsp", device: "mini", simulator: "N" }]);
    cleanup();
    // The one chosen last comes first next time, of those that would boot.
    listed = [shown, air, pixel];
    const again = await openMenu();
    expect(rows(again, "Booted")).toEqual(["iPhone 17 Pro", "iPhone Air"]);
    expect(rows(again, "Available (will boot)")[0]).toBe("iPhone 17");
  });
});

describe("the models to start, in a tab where none runs", () => {
  it("lists each platform's models once, and boots the one chosen, then shows it", async () => {
    listed = [];
    const chosen = vi.fn();
    render(
      <ScreenModelChooser active device="mini" onChoose={chosen} workspace="wsp" />
    );
    const menu = await screen.findByRole("menu", { name: "Simulators" });
    await waitFor(() => expect(within(menu).getByText("iPhone 17")).toBeTruthy());
    expect(
      [...menu.querySelectorAll("header")].map((header) => header.textContent)
    ).toEqual(["iOS Simulators", "Android Emulators"]);
    expect(
      within(menu)
        .getAllByRole("menuitem")
        .map((item) => item.querySelector('[data-slot="menu-item-label"]')?.textContent)
      // (iPhone 17 Pro and iPhone 15 are only on older runtimes)
    ).toEqual(["iPhone 17", "More…", "Pixel_Fold"]);
    await userEvent.click(within(menu).getByRole("menuitem", { name: "iPhone 17" }));
    await waitFor(() =>
      expect(chosen).toHaveBeenCalledWith({ device: "mini", screen: booted17 })
    );
    expect(
      calls
        .filter(({ name }) => name === "devices.startScreenDevice")
        .map(({ params }) => params)
    ).toEqual([{ workspace: "wsp", device: "mini", simulator: "N" }]);
  });
});
