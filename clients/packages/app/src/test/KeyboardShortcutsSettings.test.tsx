import { flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { WebSettings } from "./settingsHarness";

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
});

afterEach(() => {
  localStorage.clear();
});

it("offers the Drive shortcut in the web client", async () => {
  const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
  render(<WebSettings />);
  await flush();
  await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
  await flush();
  // The web reads the Workspace's Drive, so its shortcut is offered with the rest.
  expect(
    document.querySelector('[data-setting-id="keyboard.go-inbox"]')
  ).not.toBeNull();
  expect(
    document.querySelector('[data-setting-id="keyboard.go-drive"]')
  ).not.toBeNull();
});
