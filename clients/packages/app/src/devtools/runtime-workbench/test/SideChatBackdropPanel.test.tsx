import userEvent from "@testing-library/user-event";
import {
  defaultSideChatDebugSettings,
  type SideChatDebugSettings,
  type SideChatDebugSettingsPatch,
} from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { SideChatBackdropPanel } from "../SideChatBackdropPanel";

function fixture(initial: Partial<SideChatDebugSettings> = {}) {
  let current = { ...defaultSideChatDebugSettings, revision: 3, ...initial };
  let listener: (settings: SideChatDebugSettings) => void = vi.fn();
  const unsubscribe = vi.fn();
  const get = vi.fn(async () => current);
  const subscribe = vi.fn((callback: typeof listener) => {
    listener = callback;
    return unsubscribe;
  });
  const update = vi.fn(async (patch: SideChatDebugSettingsPatch) => {
    current = {
      ...current,
      ...patch,
      revision: current.revision + 1,
    } as SideChatDebugSettings;
    listener(current);
    return current;
  });
  const reset = vi.fn(async () => {
    current = { ...defaultSideChatDebugSettings, revision: current.revision + 1 };
    listener(current);
    return current;
  });
  const copy = vi.fn(async () => ({ ok: true as const }));
  installNativeBridgeMock({
    clipboard: { writeText: copy },
    sideChat: {
      debugSettings: Object.assign(get, { get, subscribe }),
      updateDebugSettings: update,
      resetDebugSettings: reset,
    },
  });
  return {
    get,
    subscribe,
    unsubscribe,
    update,
    reset,
    copy,
    emit: (snapshot: SideChatDebugSettings) => listener(snapshot),
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

describe("Side Chat backdrop controls", () => {
  it("reads native values, changes the live backdrop, copies parameters and resets", async () => {
    const native = fixture({ tintOpacity: 0.12 });
    render(<SideChatBackdropPanel platform="electron" os="macos" />);

    const tint = await screen.findByRole("textbox", { name: "暗色叠加 / Tint %" });
    expect(tint).toHaveValue("12");
    fireEvent.change(tint, { target: { value: "25" } });
    await waitFor(() =>
      expect(native.update).toHaveBeenCalledWith({ tintOpacity: 0.25 })
    );
    await waitFor(() =>
      expect(screen.getByRole("button", { name: /复制参数/ })).toBeEnabled()
    );
    await userEvent.click(screen.getByRole("button", { name: /复制参数/ }));
    expect(native.copy).toHaveBeenCalledWith({
      text: expect.stringContaining('"tintOpacity": 0.25'),
    });
    expect(screen.getByText("参数已复制")).toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: /恢复默认/ }));
    await waitFor(() =>
      expect(tint).toHaveValue(String(defaultSideChatDebugSettings.tintOpacity * 100))
    );
    expect(native.reset).toHaveBeenCalledOnce();
    expect(native.subscribe).toHaveBeenCalledOnce();
  });

  it("keeps the latest slider input while merging changes behind one in-flight mutation", async () => {
    const native = fixture();
    const first = deferred<SideChatDebugSettings>();
    native.update.mockImplementationOnce(() => first.promise);
    render(<SideChatBackdropPanel platform="electron" os="macos" />);
    const blur = await screen.findByRole("textbox", { name: "模糊 / Blur px" });
    const tint = screen.getByRole("textbox", { name: "暗色叠加 / Tint %" });

    fireEvent.change(blur, { target: { value: "30" } });
    fireEvent.change(blur, { target: { value: "40" } });
    fireEvent.change(tint, { target: { value: "16" } });
    fireEvent.change(blur, { target: { value: "45" } });
    expect(native.update).toHaveBeenCalledTimes(1);
    expect(blur).toHaveValue("45");
    expect(screen.getByRole("button", { name: /恢复默认/ })).toBeDisabled();

    await act(async () =>
      first.resolve({ ...defaultSideChatDebugSettings, blurRadius: 30, revision: 4 })
    );
    await waitFor(() => expect(native.update).toHaveBeenCalledTimes(2));
    expect(native.update).toHaveBeenLastCalledWith({
      blurRadius: 45,
      tintOpacity: 0.16,
    });
    expect(blur).toHaveValue("45");
    expect(tint).toHaveValue("16");
  });

  it("reports a failed edit, restores the owner value and allows another edit", async () => {
    const native = fixture();
    native.update.mockRejectedValueOnce(new Error("Backdrop unavailable"));
    render(<SideChatBackdropPanel platform="electron" os="macos" />);
    const blur = await screen.findByRole("textbox", { name: "模糊 / Blur px" });
    fireEvent.change(blur, { target: { value: "32" } });
    expect(await screen.findByRole("alert")).toHaveTextContent("Backdrop unavailable");
    expect(blur).toHaveValue(String(defaultSideChatDebugSettings.blurRadius));
    expect(native.update).toHaveBeenCalledTimes(1);
    fireEvent.change(blur, { target: { value: "36" } });
    await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
    await waitFor(() => expect(blur).toHaveValue("36"));
  });

  it("ignores stale initial reads and removes pending edits and the subscription on unmount", async () => {
    const native = fixture();
    const initial = deferred<SideChatDebugSettings>();
    native.get.mockImplementationOnce(() => initial.promise);
    const first = deferred<SideChatDebugSettings>();
    native.update.mockImplementationOnce(() => first.promise);
    const rendered = render(<SideChatBackdropPanel platform="electron" os="macos" />);
    act(() =>
      native.emit({ ...defaultSideChatDebugSettings, blurRadius: 50, revision: 10 })
    );
    const blur = await screen.findByRole("textbox", { name: "模糊 / Blur px" });
    await act(async () =>
      initial.resolve({ ...defaultSideChatDebugSettings, revision: 1 })
    );
    expect(blur).toHaveValue("50");
    fireEvent.change(blur, { target: { value: "55" } });
    fireEvent.change(blur, { target: { value: "60" } });
    rendered.unmount();
    expect(native.unsubscribe).toHaveBeenCalledOnce();
    await act(async () =>
      first.resolve({ ...defaultSideChatDebugSettings, blurRadius: 55, revision: 11 })
    );
    expect(native.update).toHaveBeenCalledTimes(1);
  });

  it.each([
    ["web", "unknown"],
    ["electron", "windows"],
  ])("does not present fallback values as native controls on %s/%s", (platform, os) => {
    const native = fixture();
    render(<SideChatBackdropPanel platform={platform} os={os} />);
    expect(screen.getByRole("status")).toHaveTextContent(
      "需要 macOS 上的 Comma Dev 桌面应用"
    );
    expect(screen.queryByRole("textbox")).toBeNull();
    expect(native.get).not.toHaveBeenCalled();
    expect(native.subscribe).not.toHaveBeenCalled();
  });
});
