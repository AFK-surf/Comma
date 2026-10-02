import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import {
  appPreferencesSchema,
  type AppPreferences,
  type ComputerUsePermissionFlowResult,
  type SystemNotificationsStatus,
} from "@comma/native-bridge";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { act, render, renderHook, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LivePermissionsPanel } from "../PermissionsPanel";
import { usePermissionsStep, usePermissionsStepAvailable } from "../usePermissionsStep";

/** The Mac as Main reports it: the helper's readback and the preferences snapshot. */
function installMac({
  notifications = "denied",
}: { notifications?: SystemNotificationsStatus } = {}) {
  const mac = {
    permissions: { accessibility: false, screenRecording: false },
    notifications,
    revision: 1,
  };
  const snapshot = () =>
    appPreferencesSchema.parse({
      launchAtLogin: false,
      revision: mac.revision,
      showInDock: true,
      showInMenuBar: true,
      systemNotificationsStatus: mac.notifications,
    });
  // Main publishes a readback change to every subscribed window.
  const listeners = new Set<(preferences: AppPreferences) => void>();
  const state = createNativeStateBridgeMock(snapshot);
  state.subscribe = vi.fn((listener: (preferences: AppPreferences) => void) => {
    listeners.add(listener);
    void state.get().then(listener);
    return () => listeners.delete(listener);
  });
  const getPermissions = vi.fn(
    async (): Promise<ComputerUsePermissionFlowResult> => ({
      ok: true,
      permissions: { ...mac.permissions },
    })
  );
  const openPermissionFlow = vi.fn(
    async (): Promise<ComputerUsePermissionFlowResult> => ({ ok: true })
  );
  const openNotificationSettings = vi.fn(async () => ({ opened: true }));
  // The user allows Comma in macOS's own prompt; Main reads the answer back
  // and publishes it before resolving.
  const requestNotificationAuthorization = vi.fn(
    async (): Promise<SystemNotificationsStatus> => {
      mac.notifications = "available";
      mac.revision += 1;
      for (const listener of listeners) listener(snapshot());
      return mac.notifications;
    }
  );
  installNativeBridgeMock({
    appPreferences: {
      openNotificationSettings,
      requestNotificationAuthorization,
      state,
    },
    computerUse: { getPermissions, openPermissionFlow },
    os: "macos",
    platform: "electron",
  });
  return {
    getPermissions,
    mac,
    openNotificationSettings,
    openPermissionFlow,
    requestNotificationAuthorization,
  };
}

const renderPanel = (onAdvance = vi.fn()) => {
  render(
    <CommaI18nProvider locale="en">
      <LivePermissionsPanel assistantName="Atlas" onAdvance={onAdvance} />
    </CommaI18nProvider>
  );
  return { onAdvance };
};

const allow = (permission: string) =>
  screen.getByRole("button", { name: `Allow ${permission}` });

// States that trade places stay in the DOM; only the one on show is exposed.
const shown = { ignore: '[aria-hidden="true"], [aria-hidden="true"] *' };

describe("onboarding permissions", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
  });

  it("opens the Computer Use helper for computer grants and System Settings for refused notifications", async () => {
    const user = userEvent.setup();
    const {
      openNotificationSettings,
      openPermissionFlow,
      requestNotificationAuthorization,
    } = installMac({ notifications: "denied" });
    renderPanel();
    await waitFor(() => expect(allow("Screen Recording")).toBeVisible());

    await user.click(allow("Screen Recording"));
    expect(openPermissionFlow).toHaveBeenCalledOnce();
    // The row waits for macOS: its Allow says so and does nothing more meanwhile.
    expect(allow("Screen Recording")).toHaveAttribute("aria-disabled", "true");
    expect(screen.getByText("Waiting…", shown)).toBeInTheDocument();

    // Once macOS has refused, only System Settings can allow Comma again.
    await user.click(screen.getByRole("button", { name: "Open Settings" }));
    expect(openNotificationSettings).toHaveBeenCalledOnce();
    expect(requestNotificationAuthorization).not.toHaveBeenCalled();
    // Accessibility shares the helper's flow, and stays at full contrast.
    await user.click(allow("Accessibility"));
    expect(openPermissionFlow).toHaveBeenCalledTimes(2);
  });

  it("lets macOS ask about notifications itself while it has not asked about Comma yet", async () => {
    const user = userEvent.setup();
    const { openNotificationSettings, requestNotificationAuthorization } = installMac({
      notifications: "undetermined",
    });
    const { onAdvance } = renderPanel();
    // Not asked yet is not a grant: the row offers one.
    await user.click(
      await screen.findByRole("button", { name: "Allow Notifications" })
    );

    expect(requestNotificationAuthorization).toHaveBeenCalledOnce();
    expect(openNotificationSettings).not.toHaveBeenCalled();
    // The answer Main publishes lands without the window losing focus.
    expect(await screen.findByText("Allowed", shown)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Allow Notifications" })).toBeNull();

    // One grant allowed: the others can still be skipped, and Comma cannot
    // work on the Mac without the Computer Use grants, which it names as
    // still missing.
    await user.click(screen.getByRole("button", { name: "Skip for now" }));
    expect(onAdvance).toHaveBeenCalledExactlyOnceWith({
      allowed: 1,
      computerUse: false,
      missing: ["accessibility", "screenRecording"],
      total: 3,
    });
  });

  it("waits from Allow until the read after the user comes back, then shows macOS's answer", async () => {
    const user = userEvent.setup();
    const { getPermissions, mac } = installMac();
    renderPanel();
    await waitFor(() => expect(allow("Accessibility")).toBeVisible());
    expect(getPermissions).toHaveBeenCalledOnce();

    await user.click(allow("Accessibility"));
    expect(screen.getByText("Waiting…", shown)).toBeInTheDocument();

    // Back from the helper without allowing it: the row offers Allow again.
    act(() => {
      window.dispatchEvent(new Event("focus"));
    });
    await waitFor(() => expect(screen.queryByText("Waiting…", shown)).toBeNull());
    expect(allow("Accessibility")).not.toHaveAttribute("aria-disabled");
    expect(getPermissions).toHaveBeenCalledTimes(2);

    // Allowed in System Settings: each row shows it once macOS reports it.
    mac.permissions = { accessibility: true, screenRecording: true };
    mac.notifications = "available";
    mac.revision = 2;
    act(() => {
      window.dispatchEvent(new Event("focus"));
    });
    await waitFor(() => expect(screen.getAllByText("Allowed", shown)).toHaveLength(3));
    expect(screen.queryByRole("button", { name: /^Allow / })).toBeNull();

    mac.permissions = { accessibility: true, screenRecording: false };
    act(() => {
      document.dispatchEvent(new Event("visibilitychange"));
    });
    expect(
      await screen.findByRole("button", { name: "Allow Screen Recording" })
    ).toBeVisible();
    expect(getPermissions).toHaveBeenCalledTimes(4);
  });

  it("stops waiting and says so when macOS's window could not be opened", async () => {
    const user = userEvent.setup();
    const { openPermissionFlow } = installMac();
    // A missing or crashed Computer Use helper reports failure in its result.
    openPermissionFlow.mockResolvedValueOnce({
      ok: false,
      error: "ComputerUse helper is missing.",
    });
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    renderPanel();
    await waitFor(() => expect(allow("Accessibility")).toBeVisible());

    await user.click(allow("Accessibility"));
    // Nothing opened, so nothing will bring the user back: the row does not wait.
    expect(
      await screen.findByText("Couldn't open the permission window. Try again.", shown)
    ).toBeInTheDocument();
    expect(screen.queryByText("Waiting…", shown)).toBeNull();
    expect(allow("Accessibility")).not.toHaveAttribute("aria-disabled");

    // Allow again tries again.
    await user.click(allow("Accessibility"));
    expect(openPermissionFlow).toHaveBeenCalledTimes(2);
    expect(
      screen.queryByText("Couldn't open the permission window. Try again.", shown)
    ).toBeNull();
  });

  it("keeps a grant macOS reported when a later read fails", async () => {
    const { getPermissions, mac } = installMac();
    mac.permissions = { accessibility: true, screenRecording: false };
    renderPanel();
    expect(await screen.findByText("Allowed", shown)).toBeInTheDocument();

    // The user comes back while the helper cannot answer.
    getPermissions.mockResolvedValueOnce({ ok: false, error: "Helper busy" });
    act(() => window.dispatchEvent(new Event("focus")));
    await waitFor(() => expect(getPermissions).toHaveBeenCalledTimes(2));
    expect(screen.getByText("Allowed", shown)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Allow Accessibility" })).toBeNull();
  });

  it("says when the Computer Use grants cannot be read at all", async () => {
    const { getPermissions } = installMac();
    getPermissions.mockResolvedValue({ ok: false, error: "Helper missing" });
    renderPanel();
    expect(
      await screen.findAllByText(
        "Couldn’t read this permission. You can turn it on later in System Settings.",
        shown
      )
    ).toHaveLength(2);
  });

  it("does not exist outside the macOS app", async () => {
    const openPermissionFlow = vi.fn();
    const openNotificationSettings = vi.fn();
    installNativeBridgeMock({
      appPreferences: { openNotificationSettings },
      computerUse: { openPermissionFlow },
    });
    expect(renderHook(() => usePermissionsStepAvailable()).result.current).toBe(false);
    const { result } = renderHook(() => usePermissionsStep());
    expect(result.current.available).toBe(false);

    await act(() => result.current.grant("accessibility"));
    await act(() => result.current.grant("notifications"));
    expect(openPermissionFlow).not.toHaveBeenCalled();
    expect(openNotificationSettings).not.toHaveBeenCalled();
  });
});
