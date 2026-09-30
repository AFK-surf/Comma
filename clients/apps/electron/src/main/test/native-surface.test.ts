import type { NativeInfo, NotchStatus, SurfaceList } from "@comma/native-bridge";
import { describe, expect, it, vi } from "vitest";
import { NativeSurfaceService, NativeWindowCommandService } from "../modules/surfaces";

describe("NativeSurfaceService", () => {
  it("does not expose the old list alias on the Main service", () => {
    const service = new NativeSurfaceService({
      getNativeInfo: () => nativeInfo,
      getNotchStatus: async () => notchStatus,
    });

    expect("list" in service).toBe(false);
  });

  it("returns the registered main window with platform and notch facts", async () => {
    const service = new NativeSurfaceService({
      getNativeInfo: () => nativeInfo,
      getNotchStatus: async () => notchStatus,
    });

    service.registerWindow({
      id: "win_main",
      role: "main-window",
      route: "/",
      window: createWindowLike({
        focused: true,
        visible: true,
        state: "normal",
      }),
    });

    await expect(service.state()).resolves.toEqual({
      notch: notchStatus,
      panels: [],
      platform: nativeInfo,
      views: [],
      windows: [
        {
          bounds: { height: 768, width: 1024, x: 12, y: 24 },
          focused: true,
          id: "win_main",
          lifecycle: "ready",
          owner: { id: "app", kind: "app" },
          role: "main-window",
          route: "/",
          state: "normal",
          surfaceId: "win_main",
          visible: true,
        },
      ],
    });
  });

  it("publishes owner-coupled surfaces.state snapshots when windows register and unregister", async () => {
    const published: SurfaceList[] = [];
    const service = new NativeSurfaceService({
      getNativeInfo: () => nativeInfo,
      getNotchStatus: async () => notchStatus,
      onStateChanged: (state) => {
        published.push(state);
      },
    });

    await service.registerWindow({
      id: "win_main",
      role: "main-window",
      route: "/",
      window: createWindowLike({
        focused: true,
        visible: true,
        state: "normal",
      }),
    });
    await service.unregisterWindow("win_main");

    expect(published).toHaveLength(2);
    expect(published[0]?.windows).toEqual([
      expect.objectContaining({
        lifecycle: "ready",
        owner: { id: "app", kind: "app" },
        role: "main-window",
        surfaceId: "win_main",
      }),
    ]);
    expect(published[1]?.windows).toEqual([]);
  });

  it("does not let a late close from an old window generation unregister its replacement", async () => {
    const service = new NativeSurfaceService({
      getNativeInfo: () => nativeInfo,
      getNotchStatus: async () => notchStatus,
    });
    const oldWindow = createWindowLike({
      focused: false,
      visible: true,
      state: "normal",
    });
    const replacementWindow = createWindowLike({
      focused: true,
      visible: true,
      state: "maximized",
    });

    await service.registerWindow({
      id: "win_reused",
      role: "main-window",
      route: "/old",
      window: oldWindow,
    });
    await service.registerWindow({
      id: "win_reused",
      role: "main-window",
      route: "/replacement",
      window: replacementWindow,
    });
    await service.unregisterWindow("win_reused", oldWindow);

    await expect(service.state()).resolves.toMatchObject({
      windows: [
        {
          id: "win_reused",
          route: "/replacement",
          state: "maximized",
        },
      ],
    });
  });

  it("rolls back the exact generation when publishing registration fails", async () => {
    const service = new NativeSurfaceService({
      getNativeInfo: () => nativeInfo,
      getNotchStatus: async () => notchStatus,
      onStateChanged: async () => {
        throw new Error("state publish failed");
      },
    });

    await expect(
      service.registerWindow({
        id: "win_failed",
        role: "main-window",
        route: "/failed",
        window: createWindowLike({
          focused: false,
          visible: false,
          state: "normal",
        }),
      })
    ).rejects.toThrow("state publish failed");
    await expect(service.state()).resolves.toMatchObject({ windows: [] });
  });

  it("marks maximized and fullscreen states from the window", async () => {
    const service = new NativeSurfaceService({
      getNativeInfo: () => nativeInfo,
      getNotchStatus: async () => notchStatus,
    });

    service.registerWindow({
      id: "win_fullscreen",
      role: "main-window",
      route: "/inbox",
      window: createWindowLike({
        focused: false,
        visible: true,
        state: "fullscreen",
      }),
    });

    await expect(service.state()).resolves.toMatchObject({
      windows: [
        {
          id: "win_fullscreen",
          route: "/inbox",
          state: "fullscreen",
        },
      ],
    });
  });

  it("lists the development workbench beside the main window", async () => {
    const service = new NativeSurfaceService({
      getNativeInfo: () => nativeInfo,
      getNotchStatus: async () => notchStatus,
    });

    service.registerWindow({
      id: "win_main",
      role: "main-window",
      route: "/",
      window: createWindowLike({
        focused: true,
        visible: true,
        state: "normal",
      }),
    });
    service.registerWindow({
      id: "dev_workbench",
      role: "dev-workbench",
      route: "/dev/workbench",
      window: createWindowLike({
        focused: false,
        visible: true,
        state: "normal",
      }),
    });

    await expect(service.state()).resolves.toMatchObject({
      windows: [
        { id: "win_main", role: "main-window", route: "/" },
        { id: "dev_workbench", role: "dev-workbench", route: "/dev/workbench" },
      ],
    });
  });

  it("creates product windows through the window command provider", async () => {
    const service = new NativeSurfaceService({
      getNativeInfo: () => nativeInfo,
      getNotchStatus: async () => notchStatus,
    });
    const window = createWindowLike({
      focused: true,
      state: "normal",
      visible: true,
    });
    const openWindow = vi.fn(async ({ route, role, windowId }) => {
      await service.registerWindow({
        id: windowId,
        role,
        route,
        window,
      });
    });
    const commands = new NativeWindowCommandService({
      nextWindowId: () => "win_dynamic_1",
      openWindow,
      surfaces: service,
    });

    await expect(commands.create({ route: "/inbox" })).resolves.toMatchObject({
      windows: [
        {
          id: "win_dynamic_1",
          role: "main-window",
          route: "/inbox",
        },
      ],
    });
    expect(openWindow).toHaveBeenCalledWith({
      role: "main-window",
      route: "/inbox",
      windowId: "win_dynamic_1",
    });
  });

  it("focuses and closes registered windows by id", async () => {
    const published: SurfaceList[] = [];
    const activateApplication = vi.fn();
    const window = createWindowLike({
      focused: true,
      state: "minimized",
      visible: false,
    });
    const service = new NativeSurfaceService({
      getNativeInfo: () => nativeInfo,
      getNotchStatus: async () => notchStatus,
      onStateChanged: (state) => {
        published.push(state);
      },
    });
    const commands = new NativeWindowCommandService({
      activateApplication,
      nextWindowId: () => "unused",
      openWindow: vi.fn(async () => undefined),
      surfaces: service,
    });

    await service.registerWindow({
      id: "win_main",
      role: "main-window",
      route: "/",
      window,
    });
    await expect(commands.focus({ windowId: "win_main" })).resolves.toMatchObject({
      windows: [{ id: "win_main" }],
    });
    await expect(commands.close({ windowId: "win_main" })).resolves.toMatchObject({
      windows: [],
    });
    await service.unregisterWindow("win_main");

    expect(window.focus).toHaveBeenCalledOnce();
    expect(window.show).toHaveBeenCalledOnce();
    expect(window.restore).toHaveBeenCalledOnce();
    expect(activateApplication).toHaveBeenCalledOnce();
    expect(window.close).toHaveBeenCalledOnce();
    expect(published).toHaveLength(2);
    expect(published[1]?.windows).toEqual([]);
  });
});

const nativeInfo: NativeInfo = {
  appVersion: "0.0.1",
  os: "macos",
  platform: "electron",
};

const notchStatus: NotchStatus = {
  available: true,
  running: false,
};

function createWindowLike({
  focused,
  state,
  visible,
}: {
  focused: boolean;
  state: "normal" | "maximized" | "fullscreen" | "minimized";
  visible: boolean;
}) {
  return {
    close: vi.fn(),
    focus: vi.fn(),
    getBounds: () => ({ height: 768, width: 1024, x: 12, y: 24 }),
    isFocused: () => focused,
    isFullScreen: () => state === "fullscreen",
    isMaximized: () => state === "maximized",
    isMinimized: () => state === "minimized",
    isVisible: () => visible,
    restore: vi.fn(),
    show: vi.fn(),
  };
}
