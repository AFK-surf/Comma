import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useOptionalCommaClientSettings } from "../../commaClientSettings";
import { useScreenListing, useScreenDevicesEnabled } from "../useScreenListing";

const call = vi.fn(() => new Promise(() => undefined));
vi.mock("@comma/core-client", () => ({ useCall: () => call }));
vi.mock("../../commaClientSettings", () => ({
  useOptionalCommaClientSettings: vi.fn(),
}));
const setting = vi.mocked(useOptionalCommaClientSettings);

/** What each place that shows devices does: it follows the list only where the mesh is on. */
function Listing() {
  const enabled = useScreenDevicesEnabled();
  const { screens } = useScreenListing("wsp", "dev", enabled);
  return <span>{`${enabled} ${screens.length}`}</span>;
}

describe("a computer's screen devices", () => {
  beforeEach(() => {
    setting.mockReset();
    call.mockClear();
    installNativeBridgeMock({ platform: "electron" });
  });

  it("are followed in the desktop app by default, with no setting changed, and on the web", () => {
    for (const value of [
      undefined,
      { computerMesh: "on" },
      { computerMesh: "salix" },
    ]) {
      setting.mockReturnValue(value as never);
      render(<Listing />);
    }
    installNativeBridgeMock({ platform: "web" });
    setting.mockReturnValue(undefined);
    render(<Listing />);
    expect(screen.getAllByText("true 0")).toHaveLength(4);
    expect(call).toHaveBeenCalledWith("devices.listScreens", {
      workspace: "wsp",
      device: "dev",
    });
  });

  it("are asked nothing with Settings › Debug's mesh off", () => {
    setting.mockReturnValue({ computerMesh: "off" } as never);
    render(<Listing />);
    expect(screen.getAllByText("false 0")).toHaveLength(1);
    expect(call).not.toHaveBeenCalled();
  });
});
