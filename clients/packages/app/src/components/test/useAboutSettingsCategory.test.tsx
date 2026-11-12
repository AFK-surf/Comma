import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import type { NativeInfo } from "@comma/native-bridge";
import type { ReactNode } from "react";
import { afterEach, expect, it, vi } from "vitest";
import { useApplicationMenu } from "../application-menu/useApplicationMenu";
import { NativeInfoContext } from "../nativeInfoContext";
import { useAboutSettingsCategory } from "../useAboutSettingsCategory";

const desktop: NativeInfo = {
  appVersion: "1.2.3",
  os: "windows",
  platform: "electron",
};

function wrapper(info: NativeInfo) {
  return ({ children }: { children: ReactNode }) => (
    <NativeInfoContext.Provider value={info}>{children}</NativeInfoContext.Provider>
  );
}

// Settings with the desktop app's update owner (AutomaticUpdates) mounted beside it.
function renderAbout(run: () => unknown, info: NativeInfo = desktop) {
  installNativeBridgeMock({
    platform: info.platform,
    applicationMenu: { update: async () => {}, onCommand: () => () => {} },
  });
  return renderHook(
    ({ enabled }) => {
      useApplicationMenu([{ id: "check-updates", enabled, run }]);
      return useAboutSettingsCategory();
    },
    { initialProps: { enabled: true }, wrapper: wrapper(info) }
  );
}

const versionRow = (category: ReturnType<typeof useAboutSettingsCategory>) =>
  category?.sections[0]?.items[0];

afterEach(() => {
  window.history.replaceState(null, "", "#/");
});

it("shows the version and checks for updates with the application menu's command", async () => {
  const run = vi.fn();
  const hook = renderAbout(run);

  await waitFor(() =>
    expect(versionRow(hook.result.current)?.control).toMatchObject({ disabled: false })
  );
  expect(hook.result.current).toMatchObject({ id: "about", icon: "about" });
  expect(versionRow(hook.result.current)).toMatchObject({
    description: "1.2.3",
    title: "Version",
  });
  expect(run).not.toHaveBeenCalled();

  const control = versionRow(hook.result.current)?.control;
  await act(async () => {
    if (control?.type === "button") control.onPress?.();
  });
  expect(run).toHaveBeenCalledOnce();

  // While a check runs, the button waits for it.
  hook.rerender({ enabled: false });
  await waitFor(() =>
    expect(versionRow(hook.result.current)?.control).toMatchObject({ disabled: true })
  );
});

it("checks once for the status item's link and forgets it", async () => {
  window.history.replaceState(null, "", "#/settings?category=about&check=updates");
  const run = vi.fn();
  const hook = renderAbout(run);

  await waitFor(() => expect(run).toHaveBeenCalledOnce());
  expect(window.location.hash).toBe("#/settings?category=about");

  // The check running and ending does not start another.
  hook.rerender({ enabled: false });
  hook.rerender({ enabled: true });
  await act(async () => {});
  expect(run).toHaveBeenCalledOnce();

  // The next link checks again.
  await act(async () => {
    window.location.hash = "#/settings?category=about&check=updates";
  });
  await waitFor(() => expect(run).toHaveBeenCalledTimes(2));
});

it("is the desktop app's alone", () => {
  const hook = renderAbout(vi.fn(), {
    appVersion: "unknown",
    os: "macos",
    platform: "web",
  });
  expect(hook.result.current).toBeNull();
});
