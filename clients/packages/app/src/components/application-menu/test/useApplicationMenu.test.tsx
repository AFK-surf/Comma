import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import type { ApplicationMenuCommand } from "@comma/native-bridge";
import { expect, it, vi } from "vitest";
import { useHoldOnboardingOpen } from "../../onboarding/onboardingPresence";
import {
  runApplicationMenuCommand,
  useApplicationMenu,
  useEnabledApplicationMenuCommands,
} from "../useApplicationMenu";

it("withdraws unmounted actions and dispatches the latest handler only while enabled", async () => {
  let invoke: ((id: ApplicationMenuCommand) => void) | undefined;
  const update = vi.fn(async () => {});
  installNativeBridgeMock({
    platform: "electron",
    applicationMenu: {
      update,
      onCommand: (listener) => {
        invoke = listener;
        return () => {
          invoke = undefined;
        };
      },
    },
  });
  const first = vi.fn();
  const latest = vi.fn();
  const hook = renderHook(
    ({ enabled, run }) => useApplicationMenu([{ id: "drive-download", enabled, run }]),
    { initialProps: { enabled: true, run: first } }
  );
  hook.rerender({ enabled: true, run: latest });
  await act(async () => {
    invoke?.("drive-download");
  });
  expect(latest).toHaveBeenCalledTimes(1);
  expect(first).not.toHaveBeenCalled();
  hook.rerender({ enabled: false, run: latest });
  await act(async () => {
    invoke?.("drive-download");
  });
  expect(latest).toHaveBeenCalledTimes(1);
  hook.unmount();
  await waitFor(() =>
    expect(update).toHaveBeenLastCalledWith({ locale: "en", items: [] })
  );
});

it("lets the active recorder own Stop when another surface has a disabled Stop", async () => {
  let invoke: ((id: ApplicationMenuCommand) => void) | undefined;
  const update = vi.fn(async () => {});
  installNativeBridgeMock({
    platform: "electron",
    applicationMenu: {
      update,
      onCommand: (listener) => {
        invoke = listener;
        return () => {};
      },
    },
  });
  const meetingStop = vi.fn();
  const composerStop = vi.fn();
  const meeting = renderHook(() =>
    useApplicationMenu([{ id: "record-stop", enabled: true, run: meetingStop }])
  );
  const composer = renderHook(() =>
    useApplicationMenu([{ id: "record-stop", enabled: false, run: composerStop }])
  );
  await waitFor(() =>
    expect(update).toHaveBeenLastCalledWith({
      locale: "en",
      items: [{ id: "record-stop", enabled: true }],
    })
  );
  await act(async () => {
    invoke?.("record-stop");
  });
  expect(meetingStop).toHaveBeenCalledTimes(1);
  expect(composerStop).not.toHaveBeenCalled();
  meeting.unmount();
  await act(async () => {
    invoke?.("record-stop");
  });
  expect(composerStop).not.toHaveBeenCalled();
  composer.unmount();
});

it("publishes one settled command set when a surface changes presentation", async () => {
  const update = vi.fn(async () => {});
  installNativeBridgeMock({
    platform: "electron",
    applicationMenu: { update, onCommand: () => () => {} },
  });
  const hook = renderHook(
    ({ enabled }) =>
      useApplicationMenu([
        { id: "go-search", enabled, accelerator: "Command+K", run: () => {} },
      ]),
    { initialProps: { enabled: true } }
  );
  await waitFor(() => expect(update).toHaveBeenCalledOnce());
  update.mockClear();
  hook.rerender({ enabled: false });
  await waitFor(() => expect(update).toHaveBeenCalledOnce());
  expect(update).toHaveBeenCalledWith({
    locale: "en",
    items: [{ id: "go-search", enabled: false, accelerator: "Command+K" }],
  });
  hook.unmount();
  await waitFor(() =>
    expect(update).toHaveBeenLastCalledWith({ locale: "en", items: [] })
  );
});

it("holds every command unavailable while the onboarding covers the window", async () => {
  let invoke: ((id: ApplicationMenuCommand) => void) | undefined;
  const update = vi.fn(async () => {});
  installNativeBridgeMock({
    platform: "electron",
    applicationMenu: {
      update,
      onCommand: (listener) => {
        invoke = listener;
        return () => {
          invoke = undefined;
        };
      },
    },
  });
  const openSearch = vi.fn();
  const menu = renderHook(() =>
    useApplicationMenu([
      { id: "go-search", enabled: true, accelerator: "Super+K", run: openSearch },
    ])
  );
  await waitFor(() => expect(update).toHaveBeenCalledOnce());

  const onboarding = renderHook(() => useHoldOnboardingOpen());
  await waitFor(() =>
    expect(update).toHaveBeenLastCalledWith({
      locale: "en",
      items: [{ id: "go-search", enabled: false, accelerator: "Super+K" }],
    })
  );
  await act(async () => {
    invoke?.("go-search");
  });
  expect(openSearch).not.toHaveBeenCalled();

  onboarding.unmount();
  await waitFor(() =>
    expect(update).toHaveBeenLastCalledWith({
      locale: "en",
      items: [{ id: "go-search", enabled: true, accelerator: "Super+K" }],
    })
  );
  await act(async () => {
    invoke?.("go-search");
  });
  expect(openSearch).toHaveBeenCalledOnce();
  menu.unmount();
});

it("offers the command palette the commands enabled now and runs the enabled owner's", async () => {
  installNativeBridgeMock({
    platform: "electron",
    applicationMenu: { update: vi.fn(async () => {}), onCommand: () => () => {} },
  });
  const check = vi.fn();
  const download = vi.fn();
  const owner = renderHook(
    ({ downloadable }) =>
      useApplicationMenu([
        { id: "check-updates", enabled: true, run: check },
        { id: "drive-download", enabled: downloadable, run: download },
      ]),
    { initialProps: { downloadable: false } }
  );
  const enabled = renderHook(() => useEnabledApplicationMenuCommands());
  await waitFor(() => expect(enabled.result.current).toEqual(["check-updates"]));
  owner.rerender({ downloadable: true });
  await waitFor(() =>
    expect(enabled.result.current).toEqual(["check-updates", "drive-download"])
  );
  await act(async () => {
    runApplicationMenuCommand("check-updates");
  });
  expect(check).toHaveBeenCalledTimes(1);
  owner.unmount();
  await waitFor(() => expect(enabled.result.current).toEqual([]));
  enabled.unmount();
});
