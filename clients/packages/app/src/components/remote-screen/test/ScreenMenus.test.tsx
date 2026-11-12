import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useOptionalCommaClientSettings } from "../../commaClientSettings";
import { ScreenComputerMenu } from "../ScreenMenus";

// Two computers whose stations carry the same default alias, as the owner's Mac mini and MacBook Pro did; both serve
// their display (`screen_view`).
let devices: Record<string, unknown>[] = [];
const macs = [
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
    name: "MacBook-Pro-2",
    alias: "Default workspace Station",
    station_id: "station-mbp",
    status: "connected",
    screen_view: true,
  },
];
vi.mock("@comma/core-client", async (original) => ({
  ...(await original<typeof import("@comma/core-client")>()),
  useCall: () => () => new Promise(() => undefined),
  useTopic: (topic: unknown) => ({ value: topic ? { devices } : undefined }),
}));
vi.mock("../../commaClientSettings", () => ({
  useOptionalCommaClientSettings: vi.fn(),
}));
const setting = vi.mocked(useOptionalCommaClientSettings);

beforeEach(() => {
  devices = macs;
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

const openMenu = async () => {
  render(
    <ScreenComputerMenu
      current="mini"
      line="Live"
      onChoose={() => undefined}
      title="Display"
      workspace="wsp"
    />
  );
  await userEvent.click(screen.getByTestId("remote-screen-computers"));
  return screen.findByRole("menu");
};

describe("the screen menu's computers", () => {
  it("heads each computer's screens with its own name, and marks this computer", async () => {
    setting.mockReturnValue({ computerMesh: "on" } as never);
    const menu = await openMenu();
    await waitFor(() =>
      expect(
        Array.from(menu.querySelectorAll("header"), (header) => header.textContent)
      ).toEqual(["Pengs-Mac-Mini-2 · This computer", "MacBook-Pro-2"])
    );
    expect(screen.queryByText("Default workspace Station")).toBeNull();
  });

  it("lists no computer with Settings › Debug's mesh off: none could be reached", async () => {
    setting.mockReturnValue({ computerMesh: "off" } as never);
    const menu = await openMenu();
    expect(menu.querySelectorAll("[role=menuitem]")).toHaveLength(0);
  });

  it("offers a computer's display only where its station says it serves one", async () => {
    // A Windows PC that serves its display, a Linux box that does not, a Mac whose station is from before
    // `screen_view` (a current server says false; when an older server says nothing, the core infers it, `screenSaid`).
    devices = [
      {
        device_id: "pc",
        name: "PC",
        station_id: "s1",
        status: "connected",
        screen_view: true,
      },
      {
        device_id: "linux",
        name: "Linux box",
        station_id: "s2",
        status: "connected",
        screen_view: false,
      },
      {
        device_id: "old",
        name: "Old Mac",
        station_id: "s3",
        status: "connected",
        screen_view: false,
      },
    ];
    setting.mockReturnValue({ computerMesh: "on" } as never);
    const menu = await openMenu();
    await waitFor(() =>
      expect(
        Array.from(menu.querySelectorAll("header"), (h) => h.textContent)
      ).toHaveLength(3)
    );
    expect(screen.getAllByRole("menuitem", { name: "Display" })).toHaveLength(1);
  });
});
