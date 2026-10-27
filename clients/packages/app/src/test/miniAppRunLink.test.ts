/** @vitest-environment jsdom */
import { afterEach, expect, it, vi } from "vitest";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { installMiniAppRunLinkClicks } from "../miniAppRunLink";
import {
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../nativePlatformActions";

const { error } = vi.hoisted(() => ({ error: vi.fn() }));
vi.mock("@comma/ui/components/toast", () => ({ toast: { error } }));
afterEach(() => {
  window.location.hash = "";
  document.body.innerHTML = "";
  vi.restoreAllMocks();
  error.mockClear();
});
it("opens clicked run links in the current router before ordinary handlers", () => {
  const cleanup = installMiniAppRunLinkClicks(document);
  const external = vi.fn();
  const anchor = document.createElement("a");
  anchor.href = "https://app-staging.comma.surf/#/apps/other/app/run";
  anchor.target = "_blank";
  anchor.addEventListener("click", external);
  document.body.append(anchor);
  try {
    anchor.click();
    expect(window.location.hash).toBe("#/apps/other/app/run");
    expect(external).not.toHaveBeenCalled();
    anchor.href = "https://example.test/";
    anchor.addEventListener("click", (event) => {
      event.preventDefault();
    });
    anchor.click();
    expect(external).toHaveBeenCalledOnce();
  } finally {
    cleanup();
  }
});
it("routes programmatic web opens and reports malformed addresses", async () => {
  installNativeBridgeMock({ platform: "web" });
  const open = vi.spyOn(window, "open").mockReturnValue(null);
  await openNativePlatformExternalUrl("https://app.comma.surf/#/apps/remote/app/run");
  expect(window.location.hash).toBe("#/apps/remote/app/run");
  expect(open).not.toHaveBeenCalled();
  await openNativePlatformExternalUrl("https://app.comma.surf/#/apps/remote/run");
  expect(error).toHaveBeenCalledOnce();
  expect(open).not.toHaveBeenCalled();
});
it("closes a reserved popup when an asynchronous result is an App", async () => {
  installNativeBridgeMock({ platform: "web" });
  const popup = { close: vi.fn(), location: { href: "about:blank" }, opener: null };
  vi.spyOn(window, "open").mockReturnValue(popup as unknown as Window);
  await openNativePlatformExternalUrlFromUserAction(
    async () => "https://app.comma.surf/#/apps/w/a/run"
  );
  expect(popup.close).toHaveBeenCalledOnce();
  expect(popup.location.href).toBe("about:blank");
  expect(window.location.hash).toBe("#/apps/w/a/run");
});
