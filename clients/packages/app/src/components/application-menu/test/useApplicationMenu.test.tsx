import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import type { ApplicationMenuCommand } from "@comma/native-bridge";
import { expect, it, vi } from "vitest";
import { useApplicationMenu } from "../useApplicationMenu";

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
