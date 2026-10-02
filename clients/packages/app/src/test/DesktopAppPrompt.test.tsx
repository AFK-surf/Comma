import { act, render, screen } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { describe, expect, it } from "vitest";
import {
  DesktopAppPromptHost,
  requestDesktopApp,
} from "../components/DesktopAppPrompt";

describe("desktop app prompt", () => {
  it("never opens in the desktop app", () => {
    installNativeBridgeMock({ platform: "electron" });
    render(<DesktopAppPromptHost />);

    act(() => requestDesktopApp("voice"));

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("names the feature in a browser", async () => {
    installNativeBridgeMock({ platform: "web" });
    render(<DesktopAppPromptHost />);

    act(() => requestDesktopApp("voice"));

    expect(
      await screen.findByRole("dialog", { name: "Get Comma for Mac" })
    ).toHaveTextContent("Voice input needs the Comma app for Mac.");
  });
});
