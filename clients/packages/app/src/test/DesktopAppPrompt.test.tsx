import { act, render, screen } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { describe, expect, it } from "vitest";
import {
  DesktopAppPromptHost,
  commaDesktopDownloadUrl,
  requestDesktopApp,
} from "../components/DesktopAppPrompt";

const macUserAgent =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const windowsUserAgent =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

describe("desktop app prompt", () => {
  it("never opens in the desktop app", () => {
    installNativeBridgeMock({ platform: "electron" });
    render(<DesktopAppPromptHost />);

    act(() => requestDesktopApp("voice"));

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("names the desktop app, and the Mac app only for features the Mac app alone has", () => {
    installNativeBridgeMock({ platform: "web" });
    render(<DesktopAppPromptHost />);

    act(() => requestDesktopApp("voice"));
    expect(
      screen.getByRole("dialog", { name: "Get the Comma desktop app" })
    ).toHaveTextContent("Voice input needs the Comma desktop app.");

    act(() => requestDesktopApp("computer-use"));
    expect(
      screen.getByRole("dialog", { name: "Get the Comma desktop app" })
    ).toHaveTextContent("Computer use needs the Comma app for Mac.");
  });

  it("starts the macOS download only for a Mac reader", () => {
    expect(commaDesktopDownloadUrl(macUserAgent)).toBe(
      "https://comma.surf/download?start=mac"
    );
    expect(commaDesktopDownloadUrl(windowsUserAgent)).toBe(
      "https://comma.surf/download"
    );
  });
});
