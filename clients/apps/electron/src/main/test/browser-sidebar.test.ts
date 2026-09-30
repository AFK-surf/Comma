import {
  browserInspectionComposerConsolePrefix,
  type BrowserSidebarOpenTabRequest,
  type BrowserSidebarState,
  type SurfaceList,
} from "@comma/native-bridge";
import { describe, expect, it, vi } from "vitest";
import {
  BROWSER_SIDEBAR_PARTITION,
  BROWSER_SIDEBAR_WEB_PREFERENCES,
  CLIENT_BROWSER_OPEN_TIMEOUT_MS,
  CLIENT_CDP_TIMEOUT_MS,
  NativeBrowserSidebarService,
  browserFacingUserAgent,
  installBrowserSidebarSecurity,
  type BrowserSidebarViewLike,
} from "../modules/browser-sidebar";
import { maxBrowserSidebarSessionsPerOwner } from "@comma/native-bridge";
import { NativeSurfaceService } from "../modules/surfaces";

describe("NativeBrowserSidebarService", () => {
  it("owns a sandboxed, permission-denied view and publishes its surface lifecycle", async () => {
    const harness = await createHarness();

    const state = await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/start",
    });

    expect(state).toMatchObject({
      active: true,
      available: true,
      surface: {
        bounds: { height: 720, width: 420, x: 860, y: 0 },
        lifecycle: "ready",
        owner: { id: "win_main", kind: "window" },
        partition: BROWSER_SIDEBAR_PARTITION,
        role: "browser-sidebar",
        windowId: "win_main",
      },
      url: "https://example.com/start",
      visible: true,
    });
    expect(harness.owner.contentView.addChildView).toHaveBeenCalledWith(
      harness.views[0]
    );
    expect(harness.views[0]?.webContents.loadURL).toHaveBeenCalledWith(
      "https://example.com/start"
    );
    expect(
      harness.published.flatMap((snapshot) =>
        snapshot.views.map((surface) => surface.lifecycle)
      )
    ).toEqual(["creating", "ready"]);

    const view = harness.views[0]!;
    const checkPermission =
      view.webContents.session.setPermissionCheckHandler.mock.calls[0]?.[0];
    expect(checkPermission?.()).toBe(false);
    const permissionCallback = vi.fn();
    view.webContents.session.setPermissionRequestHandler.mock.calls[0]?.[0]?.(
      view.webContents,
      "geolocation",
      permissionCallback
    );
    expect(permissionCallback).toHaveBeenCalledWith(false);

    const blockedNavigation = view.emitNavigation(
      "will-frame-navigate",
      "file:///etc/passwd"
    );
    const allowedNavigation = view.emitNavigation(
      "will-redirect",
      "https://example.com/next"
    );
    expect(blockedNavigation.preventDefault).toHaveBeenCalledOnce();
    expect(allowedNavigation.preventDefault).not.toHaveBeenCalled();

    expect(BROWSER_SIDEBAR_WEB_PREFERENCES).toEqual({
      contextIsolation: true,
      nodeIntegration: false,
      partition: BROWSER_SIDEBAR_PARTITION,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
    });
    expect(BROWSER_SIDEBAR_WEB_PREFERENCES).not.toHaveProperty("preload");
  });

  it("attaches and removes the clipping root while retaining logical browser bounds", async () => {
    const nativeRoot = createTestView();
    const harness = await createHarness({ nativeRoot });
    const bounds = { x: 200, y: 100, width: 420, height: 500 };
    const state = await harness.service.open({
      sessionId: "host-a",
      bounds,
      url: "https://example.com",
    });
    expect(harness.owner.contentView.addChildView).toHaveBeenCalledWith(nativeRoot);
    expect(harness.views[0]!.setBounds).toHaveBeenCalledWith(bounds);
    expect(state.surface?.bounds).toEqual(bounds);
    await harness.service.dispose();
    expect(harness.owner.contentView.removeChildView).toHaveBeenCalledWith(nativeRoot);
    expect(harness.views[0]!.webContents.close).toHaveBeenCalledOnce();
  });

  it("updates navigation in place and reattaches the same session without losing history", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/one",
    });
    const first = harness.views[0]!;

    await expect(
      harness.service.update({
        sessionId: "host-a",
        bounds: { height: 680, width: 480, x: 800, y: 20 },
        url: "https://example.org/two",
        visible: false,
      })
    ).resolves.toMatchObject({
      active: true,
      surface: {
        bounds: { height: 680, width: 480, x: 800, y: 20 },
        lifecycle: "ready",
      },
      url: "https://example.org/two",
      visible: false,
    });
    expect(harness.createView).toHaveBeenCalledOnce();
    expect(first.setBounds).toHaveBeenLastCalledWith({
      height: 680,
      width: 480,
      x: 800,
      y: 20,
    });
    expect(first.webContents.loadURL).toHaveBeenLastCalledWith(
      "https://example.org/two"
    );

    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 700, width: 440, x: 840, y: 0 },
      url: "https://example.net/replacement",
    });

    expect(harness.createView).toHaveBeenCalledOnce();
    expect(harness.owner.contentView.removeChildView).not.toHaveBeenCalled();
    expect(first.webContents.close).not.toHaveBeenCalled();
    expect(first.webContents.getURL()).toBe("https://example.org/two");
    expect(harness.owner.children).toEqual([first]);
    await expect(harness.surfaces.state()).resolves.toMatchObject({
      views: [
        {
          lifecycle: "ready",
          windowId: "win_main",
        },
      ],
    });
  });

  it("captures PNG bytes only for the current visible browser session", async () => {
    const harness = await createHarness();

    await expect(harness.service.capture({ sessionId: "missing" })).resolves.toEqual({
      status: "unavailable",
    });

    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/start",
    });
    const pngImage = new Uint8Array([137, 80, 78, 71]);
    harness.views[0]!.webContents.capturePage.mockResolvedValueOnce({
      toPNG: () => pngImage,
    });

    await expect(harness.service.capture({ sessionId: "host-a" })).resolves.toEqual({
      pngImage,
      status: "ready",
    });

    await harness.service.update({ sessionId: "host-a", visible: false });
    await expect(harness.service.capture({ sessionId: "host-a" })).resolves.toEqual({
      status: "unavailable",
    });
    expect(harness.views[0]!.webContents.capturePage).toHaveBeenCalledOnce();
  });

  it("returns unavailable when native page capture rejects", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/start",
    });
    harness.views[0]!.webContents.capturePage.mockRejectedValueOnce(
      new Error("capture failed")
    );

    await expect(harness.service.capture({ sessionId: "host-a" })).resolves.toEqual({
      status: "unavailable",
    });
  });

  it("opens a renderer tab by stable tab id and settles from that exact native view", async () => {
    let requested:
      | { ownerWindowId: string; request: BrowserSidebarOpenTabRequest }
      | undefined;
    const harness = await createHarness({
      onClientOpenTabRequested: (ownerWindowId, request) => {
        requested = { ownerWindowId, request };
        return true;
      },
    });

    const opening = harness.service.openClientTab({
      url: "https://example.com/from-client",
    });
    expect(requested).toMatchObject({
      ownerWindowId: "win_main",
      request: { url: "https://example.com/from-client" },
    });
    const tabId = requested!.request.tabId;

    await harness.service.open({
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      sessionId: "renderer-session",
      tabId,
      url: requested!.request.url,
    });

    await expect(opening).resolves.toMatchObject({
      tabId,
      url: "https://example.com/from-client",
    });
  });

  it("waits for the exact tab's first navigation before settling a client open", async () => {
    const firstNavigation = deferred<unknown>();
    let requested: BrowserSidebarOpenTabRequest | undefined;
    const harness = await createHarness({
      loadNavigation: () => firstNavigation.promise,
      onClientOpenTabRequested: (_ownerWindowId, request) => {
        requested = request;
        return true;
      },
    });

    let settled = false;
    const opening = harness.service
      .openClientTab({ url: "https://example.com/slow" })
      .then((target) => {
        settled = true;
        return target;
      });
    await harness.service.open({
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      sessionId: "renderer-session",
      tabId: requested!.tabId,
      url: requested!.url,
    });
    await Promise.resolve();
    expect(settled).toBe(false);

    firstNavigation.resolve(undefined);
    await expect(opening).resolves.toMatchObject({
      tabId: requested!.tabId,
      url: "https://example.com/slow",
    });
  });

  it("bounds an unacknowledged renderer tab request without polling", async () => {
    const harness = await createHarness({
      onClientOpenTabRequested: () => true,
    });
    vi.useFakeTimers();
    try {
      const opening = harness.service.openClientTab({
        url: "https://example.com/no-renderer-ack",
      });
      const rejection = expect(opening).rejects.toThrow(/timed out/i);
      await vi.advanceTimersByTimeAsync(CLIENT_BROWSER_OPEN_TIMEOUT_MS);
      await rejection;
    } finally {
      vi.useRealTimers();
    }
  });

  it("lists and controls exact tabs while screenshots use the tab's own view", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      tabId: "tab-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://linear.app/",
    });
    const view = harness.views[0]!;

    expect(harness.service.listClientTargets()).toEqual([
      {
        tabId: "tab-a",
        title: "Page title",
        url: "https://linear.app/",
        visible: true,
      },
    ]);

    view.webContents.debugger.sendCommand.mockResolvedValueOnce({
      result: { value: "Linear" },
    });
    await expect(
      harness.service.sendClientCdpCommand({
        method: "Runtime.evaluate",
        params: { expression: "document.title" },
        tabId: "tab-a",
      })
    ).resolves.toEqual({ result: { value: "Linear" } });
    expect(view.webContents.debugger.attach).toHaveBeenCalledWith("1.3");
    expect(view.webContents.debugger.detach).toHaveBeenCalledOnce();

    await expect(
      harness.service.sendClientCdpCommand({
        method: "Target.getTargets",
        params: {},
        tabId: "tab-a",
      })
    ).rejects.toThrow(/domain/i);

    const pngImage = Buffer.from([137, 80, 78, 71]);
    view.webContents.debugger.sendCommand.mockResolvedValueOnce({
      data: pngImage.toString("base64"),
    });
    await expect(
      harness.service.captureClientScreenshot({ tabId: "tab-a" })
    ).resolves.toEqual({
      pngImage,
      target: {
        tabId: "tab-a",
        title: "Page title",
        url: "https://linear.app/",
        visible: true,
      },
    });
    expect(view.webContents.debugger.sendCommand).toHaveBeenLastCalledWith(
      "Page.captureScreenshot",
      {
        captureBeyondViewport: false,
        format: "png",
        fromSurface: true,
      }
    );
    expect(view.webContents.debugger.detach).toHaveBeenCalledTimes(2);

    view.webContents.debugger.sendCommand.mockRejectedValueOnce(
      new Error("CDP failed")
    );
    await expect(
      harness.service.sendClientCdpCommand({
        method: "Runtime.evaluate",
        params: {},
        tabId: "tab-a",
      })
    ).rejects.toThrow("CDP failed");
    expect(view.webContents.debugger.detach).toHaveBeenCalledTimes(3);
  });

  it("captures any retained tab by tab id, including a hidden tab", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      tabId: "tab-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/a",
    });
    await harness.service.open({
      sessionId: "host-b",
      tabId: "tab-b",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/b",
    });
    expect(harness.views[0]!.getVisible()).toBe(false);
    const pngImage = Buffer.from([1, 2, 3, 4]);
    harness.views[0]!.webContents.debugger.sendCommand.mockResolvedValueOnce({
      data: pngImage.toString("base64"),
    });

    await expect(
      harness.service.captureClientScreenshot({ tabId: "tab-a" })
    ).resolves.toMatchObject({
      pngImage,
      target: { tabId: "tab-a", visible: false },
    });
    expect(harness.views[0]!.webContents.debugger.sendCommand).toHaveBeenCalledWith(
      "Page.captureScreenshot",
      {
        captureBeyondViewport: false,
        format: "png",
        fromSurface: true,
      }
    );
    expect(harness.views[1]!.webContents.debugger.sendCommand).not.toHaveBeenCalled();
  });

  it("rejects screenshots above five MiB", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      tabId: "tab-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://linear.app/",
    });
    const view = harness.views[0]!;
    view.webContents.debugger.sendCommand.mockResolvedValueOnce({
      data: Buffer.alloc(5 * 1024 * 1024 + 1).toString("base64"),
    });

    await expect(
      harness.service.captureClientScreenshot({ tabId: "tab-a" })
    ).rejects.toThrow(/decoded limit/i);
  });

  it("allows screenshots above the generic CDP result cap but below five MiB", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      tabId: "tab-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://linear.app/",
    });
    const pngImage = Buffer.alloc(400 * 1024, 7);
    harness.views[0]!.webContents.debugger.sendCommand.mockResolvedValueOnce({
      data: pngImage.toString("base64"),
    });

    await expect(
      harness.service.captureClientScreenshot({ tabId: "tab-a" })
    ).resolves.toMatchObject({
      pngImage,
      target: { tabId: "tab-a" },
    });
  });

  it("does not let detach failure mask a primary CDP failure", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://linear.app/",
    });
    const view = harness.views[0]!;
    view.webContents.debugger.sendCommand.mockRejectedValueOnce(
      new Error("primary CDP failure")
    );
    view.webContents.debugger.detach.mockImplementationOnce(() => {
      throw new Error("detach failure");
    });

    await expect(
      harness.service.sendClientCdpCommand({
        method: "Runtime.evaluate",
        params: {},
        tabId: "host-a",
      })
    ).rejects.toThrow("primary CDP failure");
  });

  it("bounds CDP commands by a wall timeout and always detaches", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://linear.app/",
    });
    const view = harness.views[0]!;
    view.webContents.debugger.sendCommand.mockReturnValueOnce(
      new Promise(() => undefined)
    );

    vi.useFakeTimers();
    try {
      const request = harness.service.sendClientCdpCommand({
        method: "Runtime.evaluate",
        params: { expression: "new Promise(() => {})" },
        tabId: "host-a",
      });
      const rejection = expect(request).rejects.toThrow(/timed out/i);
      await vi.advanceTimersByTimeAsync(CLIENT_CDP_TIMEOUT_MS);
      await rejection;
      expect(view.webContents.debugger.detach).toHaveBeenCalledOnce();
    } finally {
      vi.useRealTimers();
    }
  });

  it("returns bounded inspected element context and can cancel selection", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/start",
    });
    const executeJavaScript = harness.views[0]!.webContents.executeJavaScript;
    executeJavaScript.mockResolvedValueOnce({
      element: {
        attributes: { "aria-label": "Save", role: "button" },
        outerHTML: '<button aria-label="Save">Save</button>',
        rect: { height: 32, width: 80, x: 20, y: 40 },
        selector: "main > button",
        tagName: "button",
        text: "Save",
      },
      inspectionId: "inspection-1",
      page: { title: "Example", url: "https://example.com/start" },
      status: "selected",
      userMessage: "What does this do?",
    });

    await expect(
      harness.service.inspect({ action: "start", sessionId: "host-a" })
    ).resolves.toMatchObject({
      inspectionId: "inspection-1",
      status: "selected",
    });
    expect(executeJavaScript.mock.calls.at(-1)?.[0]).toContain(
      "comma-browser-sidebar-element-inspector"
    );

    const pendingSelection = deferred<unknown>();
    executeJavaScript.mockReturnValueOnce(pendingSelection.promise);
    const inspection = harness.service.inspect({
      action: "start",
      sessionId: "host-a",
    });
    await vi.waitFor(() =>
      expect(executeJavaScript.mock.calls.at(-1)?.[0]).toContain(
        "comma-browser-sidebar-element-inspector"
      )
    );
    await expect(
      harness.service.inspect({ action: "cancel", sessionId: "host-a" })
    ).resolves.toEqual({ status: "cancelled" });
    expect(executeJavaScript.mock.calls.at(-1)?.[0]).toContain(".cancel()");
    pendingSelection.resolve({ status: "cancelled" });
    await expect(inspection).resolves.toEqual({ status: "cancelled" });
  });

  it("places the shared composer beside the selected element and returns its prompt", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 40 },
      url: "https://example.com/start",
    });
    await vi.waitFor(() => expect(harness.composerViews).toHaveLength(1));
    const composer = harness.composerViews[0]!;
    expect(composer.webContents.loadURL).toHaveBeenCalledWith(
      "assets://./#/browser-inspection-composer"
    );
    expect(composer.webContents.setWindowOpenHandler).toHaveBeenCalledOnce();
    composer.emitStateChange("console-message", {
      message: `${browserInspectionComposerConsolePrefix}${JSON.stringify({ height: 88, type: "layout" })}`,
    });
    harness.views[0]!.webContents.executeJavaScript.mockResolvedValueOnce({
      element: {
        attributes: { role: "button" },
        outerHTML: "<button>Save</button>",
        rect: { height: 32, width: 80, x: 20, y: 40 },
        selector: "main > button",
        tagName: "button",
        text: "Save",
      },
      inspectionId: "inspection-overlay",
      page: { title: "Example", url: "https://example.com/start" },
      status: "selected",
    });

    const result = harness.service.inspect({ action: "start", sessionId: "host-a" });
    const escapedNavigation = composer.emitNavigation(
      "will-navigate",
      "https://example.com/escape"
    );
    expect(escapedNavigation.preventDefault).toHaveBeenCalledOnce();
    await vi.waitFor(() => expect(composer.webContents.focus).toHaveBeenCalledOnce());
    expect(composer.setBounds).toHaveBeenLastCalledWith({
      height: 88,
      width: 396,
      x: 872,
      y: 124,
    });
    composer.emitStateChange("console-message", {
      message: `${browserInspectionComposerConsolePrefix}${JSON.stringify({ message: "Explain this", type: "submit" })}`,
    });

    await expect(result).resolves.toMatchObject({
      inspectionId: "inspection-overlay",
      status: "selected",
      userMessage: "Explain this",
    });
    expect(harness.owner.children).toEqual([harness.views[0], composer]);
    expect(composer.setVisible).toHaveBeenLastCalledWith(false);
    expect(composer.webContents.close).not.toHaveBeenCalled();

    harness.views[0]!.webContents.executeJavaScript.mockResolvedValueOnce({
      element: {
        attributes: {},
        outerHTML: "<a>Learn more</a>",
        rect: { height: 24, width: 90, x: 40, y: 120 },
        selector: "main > a",
        tagName: "a",
        text: "Learn more",
      },
      inspectionId: "inspection-overlay-reused",
      page: { title: "Example", url: "https://example.com/start" },
      status: "selected",
    });
    const reusedResult = harness.service.inspect({
      action: "start",
      sessionId: "host-a",
    });
    await vi.waitFor(() => expect(composer.webContents.focus).toHaveBeenCalledTimes(2));
    expect(harness.composerViews).toHaveLength(1);
    composer.emitStateChange("console-message", {
      message: `${browserInspectionComposerConsolePrefix}${JSON.stringify({ message: "Why this link?", type: "submit" })}`,
    });
    await expect(reusedResult).resolves.toMatchObject({
      inspectionId: "inspection-overlay-reused",
      status: "selected",
      userMessage: "Why this link?",
    });
    expect(composer.webContents.loadURL).toHaveBeenCalledOnce();
  });

  it("restores an active composer after its renderer reloads", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 40 },
      url: "https://example.com/start",
    });
    await vi.waitFor(() => expect(harness.composerViews).toHaveLength(1));
    const composer = harness.composerViews[0]!;
    composer.emitStateChange("console-message", {
      message: `${browserInspectionComposerConsolePrefix}${JSON.stringify({ height: 76, type: "layout" })}`,
    });
    harness.views[0]!.webContents.executeJavaScript.mockResolvedValueOnce({
      element: {
        attributes: {},
        outerHTML: "<textarea>Draft</textarea>",
        rect: { height: 80, width: 240, x: 20, y: 40 },
        selector: "textarea",
        tagName: "textarea",
        text: "Draft",
      },
      inspectionId: "inspection-reloaded",
      page: { title: "Example", url: "https://example.com/start" },
      status: "selected",
    });

    const result = harness.service.inspect({ action: "start", sessionId: "host-a" });
    await vi.waitFor(() => expect(composer.webContents.focus).toHaveBeenCalledOnce());

    composer.emitStateChange("did-start-loading");
    composer.emitStateChange("console-message", {
      message: `${browserInspectionComposerConsolePrefix}${JSON.stringify({ height: 88, type: "layout" })}`,
    });

    await vi.waitFor(() => expect(composer.webContents.focus).toHaveBeenCalledTimes(2));
    expect(composer.setVisible).toHaveBeenLastCalledWith(true);
    expect(composer.webContents.executeJavaScript).toHaveBeenLastCalledWith(
      expect.stringContaining("resetDraft: false")
    );

    composer.emitStateChange("console-message", {
      message: `${browserInspectionComposerConsolePrefix}${JSON.stringify({ message: "Recovered prompt", type: "submit" })}`,
    });
    await expect(result).resolves.toMatchObject({
      inspectionId: "inspection-reloaded",
      status: "selected",
      userMessage: "Recovered prompt",
    });
  });

  it("settles inspection when the isolated composer renderer is destroyed", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 40 },
      url: "https://example.com/start",
    });
    harness.views[0]!.webContents.executeJavaScript.mockResolvedValueOnce({
      element: {
        attributes: {},
        outerHTML: "<button>Save</button>",
        rect: { height: 32, width: 80, x: 20, y: 40 },
        selector: "button",
        tagName: "button",
        text: "Save",
      },
      inspectionId: "inspection-destroyed",
      page: { url: "https://example.com/start" },
      status: "selected",
    });

    const result = harness.service.inspect({ action: "start", sessionId: "host-a" });
    await vi.waitFor(() => expect(harness.composerViews).toHaveLength(1));
    const composer = harness.composerViews[0]!;
    composer.emitStateChange("console-message", {
      message: `${browserInspectionComposerConsolePrefix}${JSON.stringify({ height: 76, type: "layout" })}`,
    });
    await vi.waitFor(() => expect(composer.webContents.focus).toHaveBeenCalledOnce());
    composer.webContents.close({ waitForBeforeUnload: false });

    await expect(result).resolves.toEqual({
      reason: "The element composer closed before the prompt was sent.",
      status: "unavailable",
    });
    expect(harness.owner.children).toEqual([harness.views[0]]);
  });

  it("returns from a dismissed selection to selection mode until bare Escape exits", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 40 },
      url: "https://example.com/start",
    });
    await vi.waitFor(() => expect(harness.composerViews).toHaveLength(1));
    const composer = harness.composerViews[0]!;
    composer.emitStateChange("console-message", {
      message: `${browserInspectionComposerConsolePrefix}${JSON.stringify({ height: 76, type: "layout" })}`,
    });

    const bareSelection = deferred<unknown>();
    const pageContents = harness.views[0]!.webContents;
    pageContents.executeJavaScript
      .mockResolvedValueOnce({
        element: {
          attributes: {},
          outerHTML: "<button>Save</button>",
          rect: { height: 32, width: 80, x: 20, y: 40 },
          selector: "button",
          tagName: "button",
          text: "Save",
        },
        inspectionId: "inspection-dismissed",
        page: { url: "https://example.com/start" },
        status: "selected",
      })
      .mockReturnValueOnce(bareSelection.promise);

    const result = harness.service.inspect({ action: "start", sessionId: "host-a" });
    await vi.waitFor(() => expect(composer.webContents.focus).toHaveBeenCalledOnce());
    composer.emitStateChange("console-message", {
      message: `${browserInspectionComposerConsolePrefix}${JSON.stringify({ type: "cancel" })}`,
    });

    await vi.waitFor(() => expect(pageContents.focus).toHaveBeenCalledTimes(2));
    expect(bareSelection.settled()).toBe(false);
    expect(composer.setVisible).toHaveBeenLastCalledWith(false);

    bareSelection.resolve({ status: "cancelled" });
    await expect(result).resolves.toEqual({ status: "cancelled" });
    expect(harness.composerViews).toHaveLength(1);
  });

  it("atomically distinguishes fresh link intent from a retained-history restore", async () => {
    const harness = await createHarness();
    const bounds = { height: 720, width: 420, x: 860, y: 0 };
    await harness.service.open({
      bounds,
      navigationRevision: 1,
      sessionId: "host-a",
      url: "https://example.com/old",
    });
    const view = harness.views[0]!;
    await harness.service.update({
      sessionId: "host-a",
      url: "https://example.com/history",
    });

    await harness.service.open({
      bounds,
      navigationRevision: 1,
      sessionId: "host-a",
      url: "https://example.com/old",
    });
    expect(view.webContents.getURL()).toBe("https://example.com/history");
    expect(view.webContents.loadURL).toHaveBeenCalledTimes(2);

    await harness.service.open({
      bounds,
      navigationRevision: 2,
      sessionId: "host-a",
      url: "https://example.com/new",
    });
    expect(view.webContents.getURL()).toBe("https://example.com/new");
    expect(view.webContents.loadURL).toHaveBeenLastCalledWith(
      "https://example.com/new"
    );
    expect(view.webContents.loadURL).toHaveBeenCalledTimes(3);
  });

  it("resumes a first navigation interrupted by a same-revision viewport remount", async () => {
    const firstNavigation = deferred<unknown>();
    const resumedNavigation = deferred<unknown>();
    const loadNavigation = vi
      .fn<(url: string) => Promise<unknown>>()
      .mockReturnValueOnce(firstNavigation.promise)
      .mockReturnValueOnce(resumedNavigation.promise);
    const harness = await createHarness({ loadNavigation });
    const bounds = { height: 720, width: 420, x: 860, y: 0 };
    const input = {
      bounds,
      navigationRevision: 1,
      sessionId: "host-a",
      url: "https://example.com/first",
    };

    await harness.service.open(input);
    await harness.service.update({ sessionId: "host-a", visible: false });
    await harness.service.open(input);

    expect(harness.createView).toHaveBeenCalledOnce();
    expect(loadNavigation).toHaveBeenCalledTimes(2);
    expect(loadNavigation).toHaveBeenNthCalledWith(2, "https://example.com/first");

    firstNavigation.resolve(undefined);
    resumedNavigation.resolve(undefined);
    await Promise.resolve();
    await Promise.resolve();
  });

  it("removes native views when the owner renderer reloads or exits", async () => {
    const harness = await createHarness();
    const bounds = { height: 720, width: 420, x: 860, y: 0 };
    await harness.service.open({
      bounds,
      sessionId: "host-a",
      url: "https://example.com/a",
    });
    await harness.service.open({
      bounds,
      sessionId: "host-b",
      url: "https://example.com/b",
    });

    harness.owner.emitDidStartNavigation({ isInPlace: true, isMainFrame: true });
    expect(harness.owner.children).toHaveLength(2);

    harness.owner.emitDidStartNavigation({ isInPlace: false, isMainFrame: true });
    await vi.waitFor(() => expect(harness.owner.children).toEqual([]));
    expect(harness.views[0]?.webContents.close).toHaveBeenCalledOnce();
    expect(harness.views[1]?.webContents.close).toHaveBeenCalledOnce();

    await harness.service.open({
      bounds,
      sessionId: "host-c",
      url: "https://example.com/c",
    });
    harness.owner.emitRenderProcessGone();
    await vi.waitFor(() => expect(harness.owner.children).toEqual([]));
    expect(harness.views[2]?.webContents.close).toHaveBeenCalledOnce();
  });

  it("drives browser history, reload, stop, and publishes navigation state", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/one",
    });
    const view = harness.views[0]!;
    await harness.service.update({
      sessionId: "host-a",
      url: "https://example.com/two",
    });

    await expect(
      harness.service.navigate({ sessionId: "host-a", action: "back" })
    ).resolves.toMatchObject({
      canGoBack: false,
      canGoForward: true,
      url: "https://example.com/one",
    });
    await harness.service.navigate({ sessionId: "host-a", action: "forward" });
    expect(view.webContents.getURL()).toBe("https://example.com/two");

    await harness.service.navigate({ sessionId: "host-a", action: "reload" });
    await harness.service.navigate({ sessionId: "host-a", action: "stop" });
    expect(view.webContents.reload).toHaveBeenCalledOnce();
    expect(view.webContents.stop).toHaveBeenCalledOnce();

    view.emitStateChange("did-start-loading");
    await vi.waitFor(() =>
      expect(harness.sidebarStates.at(-1)).toMatchObject({
        active: true,
        canGoBack: true,
        title: "Page title",
        url: "https://example.com/two",
      })
    );

    view.emitNavigation("will-navigate", "https://example.com/two");
    view.emitStateChange(
      "did-fail-load",
      {},
      -105,
      "Name not resolved",
      "https://example.com/two",
      true
    );
    await vi.waitFor(() =>
      expect(harness.sidebarStates.at(-1)).toMatchObject({
        reason: "Name not resolved",
      })
    );
  });

  it("lets stop, hide, close, owner disposal, and service disposal preempt a pending load", async () => {
    const pendingNavigation = deferred<unknown>();
    const harness = await createHarness({
      loadNavigation: () => pendingNavigation.promise,
    });
    const bounds = { height: 720, width: 420, x: 860, y: 0 };

    await harness.service.open({
      bounds,
      sessionId: "host-a",
      url: "https://example.com/hang",
    });
    await expect(
      harness.service.navigate({ action: "stop", sessionId: "host-a" })
    ).resolves.toMatchObject({ active: true });
    await expect(
      harness.service.update({ sessionId: "host-a", visible: false })
    ).resolves.toMatchObject({ active: true, visible: false });
    await expect(harness.service.close({ sessionId: "host-a" })).resolves.toMatchObject(
      { active: false }
    );

    await harness.service.open({
      bounds,
      sessionId: "host-b",
      url: "https://example.com/hang",
    });
    await expect(harness.service.disposeOwner("win_main")).resolves.toMatchObject({
      active: false,
    });

    await harness.service.open({
      bounds,
      sessionId: "host-c",
      url: "https://example.com/hang",
    });
    await expect(harness.service.dispose()).resolves.toBeUndefined();
    expect(
      harness.views.every(
        (view) =>
          view.webContents.stop.mock.calls.length > 0 &&
          view.webContents.close.mock.calls.length > 0
      )
    ).toBe(true);
  });

  it("does not inject inspection cancellation while an idle page is closing", async () => {
    const harness = await createHarness();
    await harness.service.open({
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      sessionId: "idle-inspection-host",
      url: "https://example.com/hang",
    });
    const executeJavaScript = harness.views[0]!.webContents.executeJavaScript;
    await vi.waitFor(() => expect(harness.composerViews).toHaveLength(1));
    executeJavaScript.mockClear();

    await expect(harness.service.reset()).resolves.toBeUndefined();

    expect(executeJavaScript).not.toHaveBeenCalled();
    expect(harness.owner.children).toEqual([]);
  });

  it("serializes a reopen behind an in-flight close so one owner never holds two views", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/one",
    });
    const destroyingStarted = deferred<void>();
    const releaseDestroying = deferred<void>();
    const updateView = harness.surfaces.updateView.bind(harness.surfaces);
    vi.spyOn(harness.surfaces, "updateView").mockImplementation(
      async (viewId, expectedView, patch) => {
        if (patch.lifecycle === "destroying") {
          destroyingStarted.resolve();
          await releaseDestroying.promise;
        }
        return updateView(viewId, expectedView, patch);
      }
    );

    const closing = harness.service.close({ sessionId: "host-a" });
    await destroyingStarted.promise;
    const reopening = harness.service.open({
      sessionId: "host-a",
      bounds: { height: 700, width: 440, x: 840, y: 0 },
      url: "https://example.org/two",
    });
    await Promise.resolve();

    expect(harness.createView).toHaveBeenCalledOnce();
    expect(harness.owner.children).toEqual([harness.views[0]]);

    releaseDestroying.resolve();
    await closing;
    await reopening;
    expect(harness.createView).toHaveBeenCalledTimes(2);
    expect(harness.owner.children).toEqual([harness.views[1]]);
  });

  it("isolates history and visibility for multiple chat-host sessions", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com/one",
    });
    await harness.service.update({
      sessionId: "host-a",
      url: "https://example.org/two",
    });
    await harness.service.open({
      sessionId: "host-b",
      bounds: { height: 680, width: 460, x: 820, y: 10 },
      url: "https://example.net/one",
    });
    await harness.service.update({
      sessionId: "host-b",
      url: "https://example.net/two",
    });
    expect(harness.views[0]?.getVisible()).toBe(false);
    expect(harness.views[1]?.getVisible()).toBe(true);

    await expect(
      harness.service.open({
        sessionId: "host-a",
        bounds: { height: 720, width: 420, x: 860, y: 0 },
        url: "https://example.com/one",
      })
    ).resolves.toMatchObject({
      canGoBack: true,
      url: "https://example.org/two",
    });
    await harness.service.navigate({ action: "back", sessionId: "host-a" });
    expect(harness.views[0]?.webContents.getURL()).toBe("https://example.com/one");

    await expect(
      harness.service.open({
        sessionId: "host-b",
        bounds: { height: 680, width: 460, x: 820, y: 10 },
        url: "https://example.net/one",
      })
    ).resolves.toMatchObject({
      canGoBack: true,
      url: "https://example.net/two",
    });
    await harness.service.navigate({ action: "back", sessionId: "host-b" });
    expect(harness.views[1]?.webContents.getURL()).toBe("https://example.net/one");
    expect(harness.createView).toHaveBeenCalledTimes(2);
  });

  it("bounds native sessions with a main-owned LRU and recreates evicted hosts", async () => {
    const harness = await createHarness();
    const bounds = { height: 720, width: 420, x: 860, y: 0 };

    for (let index = 0; index <= maxBrowserSidebarSessionsPerOwner; index += 1) {
      await harness.service.open({
        bounds,
        sessionId: `host-${index}`,
        url: `https://example.com/${index}`,
      });
    }

    expect(harness.owner.children).toHaveLength(maxBrowserSidebarSessionsPerOwner);
    expect(harness.views[0]?.webContents.close).toHaveBeenCalledOnce();
    await expect(harness.surfaces.state()).resolves.toMatchObject({
      views: expect.arrayContaining([
        expect.objectContaining({
          role: "browser-sidebar",
        }),
      ]),
    });
    expect((await harness.surfaces.state()).views).toHaveLength(
      maxBrowserSidebarSessionsPerOwner
    );

    await harness.service.open({
      bounds,
      sessionId: "host-0",
      url: "https://example.org/revisited",
    });

    expect(harness.createView).toHaveBeenCalledTimes(
      maxBrowserSidebarSessionsPerOwner + 2
    );
    expect(harness.views.at(-1)?.webContents.loadURL).toHaveBeenCalledWith(
      "https://example.org/revisited"
    );
    expect((await harness.surfaces.state()).views).toHaveLength(
      maxBrowserSidebarSessionsPerOwner
    );
  });

  it("closes the exact renderer victim before admission and preserves another host's history", async () => {
    const harness = await createHarness();
    const bounds = { height: 720, width: 420, x: 860, y: 0 };

    await harness.service.open({
      bounds,
      sessionId: "protected-host-active",
      url: "https://example.com/protected-one",
    });
    const protectedView = harness.views[0]!;
    await harness.service.update({
      sessionId: "protected-host-active",
      url: "https://example.com/protected-two",
    });
    await expect(
      harness.service.navigate({
        action: "back",
        sessionId: "protected-host-active",
      })
    ).resolves.toMatchObject({
      canGoForward: true,
      url: "https://example.com/protected-one",
    });

    await harness.service.open({
      bounds,
      sessionId: "renderer-selected-victim",
      url: "https://example.com/victim",
    });
    const victimView = harness.views[1]!;
    for (let index = 0; index < maxBrowserSidebarSessionsPerOwner - 2; index += 1) {
      await harness.service.open({
        bounds,
        sessionId: `capacity-host-${index}`,
        url: `https://example.com/capacity-${index}`,
      });
    }
    expect(harness.owner.children).toHaveLength(maxBrowserSidebarSessionsPerOwner);

    const destroyingStarted = deferred<void>();
    const releaseDestroying = deferred<void>();
    const updateView = harness.surfaces.updateView.bind(harness.surfaces);
    vi.spyOn(harness.surfaces, "updateView").mockImplementation(
      async (viewId, expectedView, patch) => {
        if (
          viewId.includes(encodeURIComponent("renderer-selected-victim")) &&
          patch.lifecycle === "destroying"
        ) {
          destroyingStarted.resolve();
          await releaseDestroying.promise;
        }
        return updateView(viewId, expectedView, patch);
      }
    );

    const admitting = harness.service.open({
      bounds,
      closeBeforeOpenSessionIds: ["renderer-selected-victim"],
      sessionId: "newly-admitted-page",
      url: "https://example.com/admitted",
    });
    await Promise.race([
      destroyingStarted.promise,
      admitting.then(() => {
        throw new Error("The replacement was admitted before its victim closed.");
      }),
    ]);

    expect(harness.createView).toHaveBeenCalledTimes(maxBrowserSidebarSessionsPerOwner);
    expect(protectedView.webContents.close).not.toHaveBeenCalled();
    expect(victimView.webContents.close).not.toHaveBeenCalled();

    releaseDestroying.resolve();
    await expect(admitting).resolves.toMatchObject({
      active: true,
      sessionId: "newly-admitted-page",
      url: "https://example.com/admitted",
    });

    expect(victimView.webContents.close).toHaveBeenCalledOnce();
    expect(protectedView.webContents.close).not.toHaveBeenCalled();
    expect(harness.createView).toHaveBeenCalledTimes(
      maxBrowserSidebarSessionsPerOwner + 1
    );
    expect(harness.owner.children).toHaveLength(maxBrowserSidebarSessionsPerOwner);
    await expect(
      harness.service.navigate({
        action: "forward",
        sessionId: "protected-host-active",
      })
    ).resolves.toMatchObject({
      canGoBack: true,
      url: "https://example.com/protected-two",
    });
    expect(harness.views[0]).toBe(protectedView);
    expect(protectedView.webContents.getURL()).toBe(
      "https://example.com/protected-two"
    );
  });

  it("drains every exact victim before admission when an earlier teardown report fails", async () => {
    const harness = await createHarness();
    const bounds = { height: 720, width: 420, x: 860, y: 0 };

    await harness.service.open({
      bounds,
      sessionId: "victim-a",
      url: "https://example.com/a",
    });
    await harness.service.open({
      bounds,
      sessionId: "victim-b",
      url: "https://example.com/b",
    });
    const [victimA, victimB] = harness.views;
    const updateView = harness.surfaces.updateView.bind(harness.surfaces);
    let rejectedFirstDestroyingReport = false;
    vi.spyOn(harness.surfaces, "updateView").mockImplementation(
      async (viewId, expectedView, patch) => {
        if (
          !rejectedFirstDestroyingReport &&
          viewId.includes(encodeURIComponent("victim-a")) &&
          patch.lifecycle === "destroying"
        ) {
          rejectedFirstDestroyingReport = true;
          throw new Error("surface destroying report failed");
        }
        return updateView(viewId, expectedView, patch);
      }
    );

    await expect(
      harness.service.open({
        bounds,
        closeBeforeOpenSessionIds: ["victim-a", "victim-b"],
        sessionId: "replacement",
        url: "https://example.com/replacement",
      })
    ).resolves.toMatchObject({
      active: true,
      sessionId: "replacement",
      url: "https://example.com/replacement",
    });

    expect(rejectedFirstDestroyingReport).toBe(true);
    expect(victimA?.webContents.close).toHaveBeenCalledOnce();
    expect(victimB?.webContents.close).toHaveBeenCalledOnce();
    expect(harness.owner.children).toEqual([harness.views[2]]);
    expect((await harness.surfaces.state()).views).toHaveLength(1);
  });

  it("stops at a physically live exact head and admits only after a later full retry", async () => {
    const harness = await createHarness();
    const bounds = { height: 720, width: 420, x: 860, y: 0 };
    await harness.service.open({
      bounds,
      sessionId: "live-victim",
      url: "https://example.com/live-victim",
    });
    await harness.service.open({
      bounds,
      sessionId: "drained-victim",
      url: "https://example.com/drained-victim",
    });
    const [liveVictim, drainedVictim] = harness.views;
    liveVictim?.webContents.close.mockImplementationOnce(() => {
      throw new Error("close failed before destroying WebContents");
    });

    await expect(
      harness.service.open({
        bounds,
        closeBeforeOpenSessionIds: ["live-victim", "drained-victim"],
        sessionId: "retry-replacement",
        url: "https://example.com/retry-replacement",
      })
    ).resolves.toMatchObject({
      active: false,
      reasonCode: "capacity",
      sessionId: "retry-replacement",
    });

    expect(harness.createView).toHaveBeenCalledTimes(2);
    expect(liveVictim?.webContents.isDestroyed()).toBe(false);
    expect(liveVictim?.webContents.close).toHaveBeenCalledOnce();
    expect(drainedVictim?.webContents.close).not.toHaveBeenCalled();
    expect(drainedVictim?.webContents.isDestroyed()).toBe(false);
    await expect(
      harness.service.update({ bounds, sessionId: "live-victim" })
    ).resolves.toMatchObject({ active: true, sessionId: "live-victim" });
    await expect(
      harness.service.update({ bounds, sessionId: "drained-victim" })
    ).resolves.toMatchObject({ active: true, sessionId: "drained-victim" });

    await expect(
      harness.service.open({
        bounds,
        closeBeforeOpenSessionIds: ["live-victim", "drained-victim"],
        sessionId: "retry-replacement",
        url: "https://example.com/retry-replacement",
      })
    ).resolves.toMatchObject({
      active: true,
      sessionId: "retry-replacement",
      url: "https://example.com/retry-replacement",
    });

    expect(liveVictim?.webContents.close).toHaveBeenCalledTimes(2);
    expect(liveVictim?.webContents.isDestroyed()).toBe(true);
    expect(drainedVictim?.webContents.close).toHaveBeenCalledOnce();
    expect(drainedVictim?.webContents.isDestroyed()).toBe(true);
    expect(harness.createView).toHaveBeenCalledTimes(3);
    expect(harness.owner.children).toEqual([harness.views[2]]);
    expect((await harness.surfaces.state()).views).toHaveLength(1);
  });

  it("closes through the captured WebContents handle when the view getter disappears", async () => {
    const harness = await createHarness({
      dropWebContentsFromViewOnDestroy: true,
    });
    const sessionId = "unstable-view-web-contents-getter";
    await harness.service.open({
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      sessionId,
      url: "https://example.com/unstable-view-web-contents-getter",
    });
    const view = harness.views[0]!;
    const webContents = view.webContents;

    await expect(harness.service.close({ sessionId })).resolves.toMatchObject({
      active: false,
      sessionId,
    });

    expect(webContents.close).toHaveBeenCalledOnce();
    expect(webContents.isDestroyed()).toBe(true);
    expect(view.webContents).toBeUndefined();
    expect((await harness.surfaces.state()).views).toEqual([]);
  });

  it("publishes inactive after an explicit close releases capacity but teardown reporting fails", async () => {
    const harness = await createHarness();
    const sessionId = "close-report-failure";
    await harness.service.open({
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      sessionId,
      url: "https://example.com/close-report-failure",
    });
    const updateView = harness.surfaces.updateView.bind(harness.surfaces);
    vi.spyOn(harness.surfaces, "updateView").mockImplementation(
      async (viewId, expectedView, patch) => {
        if (patch.lifecycle === "destroying") {
          throw new Error("destroying state publication failed");
        }
        return updateView(viewId, expectedView, patch);
      }
    );

    await expect(harness.service.close({ sessionId })).rejects.toThrow(
      "destroying state publication failed"
    );

    expect(harness.views[0]?.webContents.close).toHaveBeenCalledOnce();
    expect(harness.sidebarStates.at(-1)).toEqual({
      active: false,
      available: true,
      sessionId,
    });
  });

  it("publishes inactive when external destruction cleanup reporting fails", async () => {
    const harness = await createHarness();
    const sessionId = "external-destroy-report-failure";
    await harness.service.open({
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      sessionId,
      url: "https://example.com/external-destroy-report-failure",
    });
    vi.spyOn(harness.surfaces, "unregisterView").mockRejectedValueOnce(
      new Error("surface unregister failed")
    );

    harness.views[0]?.webContents.close({ waitForBeforeUnload: false });

    await vi.waitFor(() =>
      expect(harness.sidebarStates.at(-1)).toEqual({
        active: false,
        available: true,
        sessionId,
      })
    );
    await expect(
      harness.service.update({
        bounds: { height: 700, width: 400, x: 880, y: 10 },
        sessionId,
      })
    ).resolves.toMatchObject({ active: false, sessionId });
  });

  it("returns a retryable capacity state for an empty renderer fence without evicting an unrelated session", async () => {
    const harness = await createHarness();
    const bounds = { height: 720, width: 420, x: 860, y: 0 };

    for (let index = 0; index < maxBrowserSidebarSessionsPerOwner; index += 1) {
      await harness.service.open({
        bounds,
        sessionId: `retained-session-${index}`,
        url: `https://example.com/retained-${index}`,
      });
    }
    const oldestRetainedView = harness.views[0]!;

    await expect(
      harness.service.open({
        bounds,
        closeBeforeOpenSessionIds: [],
        sessionId: "fenced-admission-without-room",
        url: "https://example.com/not-admitted",
      })
    ).resolves.toEqual({
      active: false,
      available: true,
      reason: "Waiting for an older browser sidebar session to finish closing.",
      reasonCode: "capacity",
      sessionId: "fenced-admission-without-room",
    });

    expect(harness.createView).toHaveBeenCalledTimes(maxBrowserSidebarSessionsPerOwner);
    expect(harness.owner.children).toHaveLength(maxBrowserSidebarSessionsPerOwner);
    expect(oldestRetainedView.webContents.close).not.toHaveBeenCalled();
    expect(harness.sidebarStates.at(-1)).toMatchObject({
      active: false,
      reasonCode: "capacity",
      sessionId: "fenced-admission-without-room",
    });
  });

  it("returns the retryable capacity result when capacity event delivery fails", async () => {
    const harness = await createHarness({
      onBrowserSidebarStateChanged: (state) => {
        if (state.reasonCode === "capacity") {
          throw new Error("capacity event delivery failed");
        }
      },
    });
    const bounds = { height: 720, width: 420, x: 860, y: 0 };
    for (let index = 0; index < maxBrowserSidebarSessionsPerOwner; index += 1) {
      await harness.service.open({
        bounds,
        sessionId: `event-failure-retained-${index}`,
        url: `https://example.com/event-failure-${index}`,
      });
    }

    await expect(
      harness.service.open({
        bounds,
        closeBeforeOpenSessionIds: [],
        sessionId: "event-failure-capacity-blocked",
        url: "https://example.com/event-failure-blocked",
      })
    ).resolves.toMatchObject({
      active: false,
      available: true,
      reasonCode: "capacity",
      sessionId: "event-failure-capacity-blocked",
    });
    expect(harness.createView).toHaveBeenCalledTimes(maxBrowserSidebarSessionsPerOwner);
  });

  it("ignores superseded and cancelled navigation settlements", async () => {
    const hangingNavigation = deferred<unknown>();
    const loadNavigation = vi.fn((url: string) =>
      url.endsWith("/hang") ? hangingNavigation.promise : Promise.resolve()
    );
    const harness = await createHarness({ loadNavigation });
    const bounds = { height: 720, width: 420, x: 860, y: 0 };

    await harness.service.open({
      bounds,
      sessionId: "host-a",
      url: "https://example.com/hang",
    });
    const recovered = await harness.service.update({
      sessionId: "host-a",
      url: "https://example.com/recovered",
    });
    expect(recovered).toMatchObject({
      url: "https://example.com/recovered",
    });
    expect(recovered).not.toHaveProperty("reason");

    const stateCountBeforeLateFailure = harness.sidebarStates.length;
    harness.views[0]?.emitStateChange(
      "did-fail-load",
      {},
      -105,
      "Late failure from the superseded page",
      "https://example.com/hang",
      true
    );
    await vi.waitFor(() =>
      expect(harness.sidebarStates.length).toBeGreaterThan(stateCountBeforeLateFailure)
    );
    expect(harness.sidebarStates.at(-1)).toMatchObject({
      url: "https://example.com/recovered",
    });
    expect(harness.sidebarStates.at(-1)).not.toHaveProperty("reason");

    hangingNavigation.reject(new Error("ERR_ABORTED"));
    await Promise.resolve();
    await Promise.resolve();
    const reopened = await harness.service.update({
      sessionId: "host-a",
      visible: true,
    });
    expect(reopened).toMatchObject({
      url: "https://example.com/recovered",
    });
    expect(reopened).not.toHaveProperty("reason");

    const stoppedNavigation = deferred<unknown>();
    const stoppedHarness = await createHarness({
      loadNavigation: () => stoppedNavigation.promise,
    });
    await stoppedHarness.service.open({
      bounds,
      sessionId: "host-b",
      url: "https://example.com/hang",
    });
    await stoppedHarness.service.navigate({
      action: "stop",
      sessionId: "host-b",
    });
    const stateCountBeforeStoppedFailure = stoppedHarness.sidebarStates.length;
    stoppedHarness.views[0]?.emitStateChange(
      "did-fail-load",
      {},
      -105,
      "Late failure after stop",
      "https://example.com/hang",
      true
    );
    await vi.waitFor(() =>
      expect(stoppedHarness.sidebarStates.length).toBeGreaterThan(
        stateCountBeforeStoppedFailure
      )
    );
    expect(stoppedHarness.sidebarStates.at(-1)).not.toHaveProperty("reason");
    stoppedNavigation.reject(new Error("ERR_ABORTED"));
    await Promise.resolve();
    await Promise.resolve();
    const hidden = await stoppedHarness.service.update({
      sessionId: "host-b",
      visible: false,
    });
    expect(hidden).toMatchObject({
      visible: false,
    });
    expect(hidden).not.toHaveProperty("reason");

    const currentCancellation = deferred<unknown>();
    const currentHarness = await createHarness({
      loadNavigation: () => currentCancellation.promise,
    });
    await currentHarness.service.open({
      bounds,
      sessionId: "host-c",
      url: "https://example.com/recovered",
    });
    currentCancellation.reject(new Error("(-3) loading recovered page"));
    await Promise.resolve();
    await Promise.resolve();
    const current = await currentHarness.service.update({
      bounds,
      sessionId: "host-c",
    });
    expect(current).toMatchObject({
      url: "https://example.com/recovered",
    });
    expect(current).not.toHaveProperty("reason");
  });

  it("keeps redirects in the current generation and ignores subframe redirect targets", async () => {
    const bounds = { height: 720, width: 420, x: 860, y: 0 };
    const mainRedirectNavigation = deferred<unknown>();
    const mainRedirectHarness = await createHarness({
      loadNavigation: () => mainRedirectNavigation.promise,
    });
    await mainRedirectHarness.service.open({
      bounds,
      sessionId: "main-redirect",
      url: "https://example.com/redirect-start",
    });
    mainRedirectHarness.views[0]?.emitNavigation(
      "will-redirect",
      "https://example.com/redirect-target",
      { isMainFrame: true }
    );
    mainRedirectNavigation.reject(new Error("main redirect navigation failed"));
    await vi.waitFor(() =>
      expect(mainRedirectHarness.sidebarStates.at(-1)).toMatchObject({
        reason: "main redirect navigation failed",
      })
    );

    const subframeRedirectNavigation = deferred<unknown>();
    const subframeRedirectHarness = await createHarness({
      loadNavigation: () => subframeRedirectNavigation.promise,
    });
    await subframeRedirectHarness.service.open({
      bounds,
      sessionId: "subframe-redirect",
      url: "https://example.com/main-frame",
    });
    subframeRedirectHarness.views[0]?.emitNavigation(
      "will-redirect",
      "https://example.com/iframe-target",
      { isMainFrame: false }
    );
    subframeRedirectNavigation.reject(new Error("current main navigation failed"));
    await vi.waitFor(() =>
      expect(subframeRedirectHarness.sidebarStates.at(-1)).toMatchObject({
        reason: "current main navigation failed",
      })
    );
  });

  it("rejects unsafe direct calls before allocating a view", async () => {
    const harness = await createHarness();

    await expect(
      harness.service.open({
        sessionId: "host-a",
        bounds: { height: 720, width: 420, x: 860, y: 0 },
        url: "javascript:alert(1)",
      })
    ).rejects.toThrow();
    await expect(
      harness.service.open({
        sessionId: "host-a",
        bounds: { height: 0, width: 420, x: 860, y: 0 },
        url: "https://example.com",
      })
    ).rejects.toThrow();

    expect(harness.createView).not.toHaveBeenCalled();
    expect(harness.owner.children).toEqual([]);
  });

  it("keeps an initial navigation failure active so a later URL can recover", async () => {
    const loadNavigation = vi
      .fn<(url: string) => Promise<unknown>>()
      .mockRejectedValueOnce(new Error("navigation failed"))
      .mockResolvedValue(undefined);
    const harness = await createHarness({
      loadNavigation,
    });

    await expect(
      harness.service.open({
        sessionId: "host-a",
        bounds: { height: 720, width: 420, x: 860, y: 0 },
        url: "https://unavailable.example",
      })
    ).resolves.toMatchObject({
      active: true,
      reason: "navigation failed",
    });

    const view = harness.views[0]!;
    await expect(
      harness.service.update({
        sessionId: "host-a",
        url: "https://example.com/recovered",
      })
    ).resolves.toMatchObject({
      active: true,
      url: "https://example.com/recovered",
    });
    expect(view.webContents.close).not.toHaveBeenCalled();
    expect(harness.owner.children).toEqual([view]);
    expect(loadNavigation).toHaveBeenCalledTimes(2);
  });

  it("closes explicitly, disposes owner views on window unregister, and removes surfaces", async () => {
    const harness = await createHarness();
    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      url: "https://example.com",
    });
    const first = harness.views[0]!;

    await expect(harness.service.close({ sessionId: "host-a" })).resolves.toEqual({
      active: false,
      available: true,
      sessionId: "host-a",
    });
    expect(first.webContents.close).toHaveBeenCalledWith({
      waitForBeforeUnload: false,
    });
    await expect(harness.surfaces.state()).resolves.toMatchObject({ views: [] });
    expect(
      harness.published.flatMap((snapshot) =>
        snapshot.views.map((surface) => surface.lifecycle)
      )
    ).toEqual(["creating", "ready", "destroying", "destroyed"]);

    await harness.service.open({
      sessionId: "host-a",
      bounds: { height: 640, width: 400, x: 880, y: 20 },
      url: "https://example.org",
    });
    const second = harness.views[1]!;
    harness.unregisterOwner?.("win_main");
    await vi.waitFor(() => {
      expect(second.webContents.close).toHaveBeenCalledWith({
        waitForBeforeUnload: false,
      });
    });
    await expect(harness.surfaces.state()).resolves.toMatchObject({ views: [] });

    await harness.service.dispose();
    await expect(
      harness.service.open({
        sessionId: "host-a",
        bounds: { height: 640, width: 400, x: 880, y: 20 },
        url: "https://example.net",
      })
    ).rejects.toThrow("Browser sidebar service is disposed");
    expect(harness.releaseOwnerListener).toHaveBeenCalledOnce();
  });
});

async function createHarness({
  nativeRoot,
  dropWebContentsFromViewOnDestroy,
  loadNavigation,
  onClientOpenTabRequested,
  onBrowserSidebarStateChanged,
}: {
  nativeRoot?: BrowserSidebarViewLike | undefined;
  dropWebContentsFromViewOnDestroy?: boolean | undefined;
  loadNavigation?: ((url: string) => Promise<unknown>) | undefined;
  onClientOpenTabRequested?:
    | ((ownerWindowId: string, request: BrowserSidebarOpenTabRequest) => boolean)
    | undefined;
  onBrowserSidebarStateChanged?:
    | ((state: BrowserSidebarState) => Promise<void> | void)
    | undefined;
} = {}) {
  const published: SurfaceList[] = [];
  const sidebarStates: BrowserSidebarState[] = [];
  const surfaces = new NativeSurfaceService({
    getNativeInfo: () => ({
      appVersion: "0.0.1",
      os: "macos",
      platform: "electron",
    }),
    getNotchStatus: () => ({ available: false }),
    onStateChanged: (snapshot) => {
      published.push(snapshot);
    },
  });
  const owner = createOwnerWindow();
  await surfaces.registerWindow({
    id: "win_main",
    role: "main-window",
    route: "/",
    window: owner,
  });
  published.length = 0;

  const views: TestBrowserSidebarView[] = [];
  const composerViews: TestBrowserSidebarView[] = [];
  const createView = vi.fn(() => {
    const view = createTestView(loadNavigation, {
      dropWebContentsFromViewOnDestroy,
    });
    if (nativeRoot) Object.assign(view, { nativeView: nativeRoot });
    views.push(view);
    return view;
  });
  const createComposerView = vi.fn(() => {
    const view = createTestView();
    composerViews.push(view);
    return view;
  });
  let unregisterOwner: ((windowId: string) => void) | undefined;
  const releaseOwnerListener = vi.fn();
  const service = new NativeBrowserSidebarService({
    createView,
    createComposerView,
    composerUrl: "assets://./#/browser-inspection-composer",
    getCallerWindowId: () => "win_main",
    onClientOpenTabRequested,
    onStateChanged: async (_windowId, state) => {
      sidebarStates.push(state);
      await onBrowserSidebarStateChanged?.(state);
    },
    onOwnerWindowUnregistered: (listener) => {
      unregisterOwner = listener;
      return releaseOwnerListener;
    },
    resolveOwnerWindow: (windowId) => (windowId === "win_main" ? owner : undefined),
    surfaces,
  });

  return {
    createView,
    composerViews,
    owner,
    published,
    releaseOwnerListener,
    service,
    sidebarStates,
    surfaces,
    unregisterOwner,
    views,
  };
}

function createOwnerWindow() {
  const children: BrowserSidebarViewLike[] = [];
  const lifecycleListeners = new Map<
    "did-start-navigation" | "render-process-gone",
    Set<(...args: unknown[]) => void>
  >();
  return {
    children,
    close: vi.fn(),
    contentView: {
      addChildView: vi.fn((view: BrowserSidebarViewLike) => {
        children.push(view);
      }),
      removeChildView: vi.fn((view: BrowserSidebarViewLike) => {
        const index = children.indexOf(view);
        if (index >= 0) {
          children.splice(index, 1);
        }
      }),
    },
    focus: vi.fn(),
    getBounds: () => ({ height: 768, width: 1_280, x: 0, y: 0 }),
    isDestroyed: () => false,
    isFocused: () => true,
    isFullScreen: () => false,
    isMaximized: () => false,
    isMinimized: () => false,
    isVisible: () => true,
    emitDidStartNavigation: ({
      isInPlace,
      isMainFrame,
    }: {
      isInPlace: boolean;
      isMainFrame: boolean;
    }) => {
      for (const listener of lifecycleListeners.get("did-start-navigation") ?? []) {
        listener({}, "app://comma/", isInPlace, isMainFrame);
      }
    },
    emitRenderProcessGone: () => {
      for (const listener of lifecycleListeners.get("render-process-gone") ?? []) {
        listener();
      }
    },
    webContents: {
      on: vi.fn(
        (
          event: "did-start-navigation" | "render-process-gone",
          listener: (...args: unknown[]) => void
        ) => {
          let listeners = lifecycleListeners.get(event);
          if (!listeners) {
            listeners = new Set();
            lifecycleListeners.set(event, listeners);
          }
          listeners.add(listener);
        }
      ),
      removeListener: vi.fn(
        (
          event: "did-start-navigation" | "render-process-gone",
          listener: (...args: unknown[]) => void
        ) => {
          lifecycleListeners.get(event)?.delete(listener);
        }
      ),
    },
  };
}

type NavigationEventName = "will-frame-navigate" | "will-navigate" | "will-redirect";

interface TestNavigationEvent {
  isMainFrame?: boolean | undefined;
  preventDefault: ReturnType<typeof vi.fn>;
  url: string;
}

type TestBrowserSidebarView = ReturnType<typeof createTestView>;

let nextWebContentsId = 1;
function createTestView(
  loadNavigation?: (url: string) => Promise<unknown>,
  {
    dropWebContentsFromViewOnDestroy = false,
  }: { dropWebContentsFromViewOnDestroy?: boolean | undefined } = {}
) {
  let bounds = { height: 1, width: 1, x: 0, y: 0 };
  let currentUrl = "";
  let destroyed = false;
  let visible = false;
  const history: string[] = [];
  let historyIndex = -1;
  let webContentsAvailable = true;
  const navigationListeners = new Map<
    NavigationEventName,
    Array<(event: TestNavigationEvent) => void>
  >();
  const destroyedListeners: Array<() => void> = [];
  const stateListeners = new Map<string, Array<(...args: unknown[]) => void>>();
  let debuggerAttached = false;
  const webContents = {
    id: nextWebContentsId++,
    capturePage: vi.fn(async () => ({
      toPNG: () => new Uint8Array([137, 80, 78, 71]),
    })),
    close: vi.fn((_options: { waitForBeforeUnload: boolean }) => {
      destroyed = true;
      for (const listener of destroyedListeners) listener();
      if (dropWebContentsFromViewOnDestroy) {
        webContentsAvailable = false;
      }
    }),
    getOSProcessId: () => 4242,
    executeJavaScript: vi.fn<(source: string) => Promise<unknown>>(async (_source) => ({
      status: "cancelled",
    })),
    debugger: {
      attach: vi.fn(() => {
        debuggerAttached = true;
      }),
      detach: vi.fn(() => {
        debuggerAttached = false;
      }),
      isAttached: vi.fn(() => debuggerAttached),
      sendCommand: vi.fn(async () => ({})),
    },
    focus: vi.fn(),
    getTitle: vi.fn(() => "Page title"),
    getURL: vi.fn(() => currentUrl),
    isLoading: vi.fn(() => false),
    isDestroyed: vi.fn(() => destroyed),
    loadURL: vi.fn(async (url: string) => {
      currentUrl = url;
      history.splice(historyIndex + 1);
      history.push(url);
      historyIndex = history.length - 1;
      await loadNavigation?.(url);
    }),
    navigationHistory: {
      canGoBack: vi.fn(() => historyIndex > 0),
      canGoForward: vi.fn(() => historyIndex >= 0 && historyIndex < history.length - 1),
      goBack: vi.fn(() => {
        if (historyIndex > 0) {
          historyIndex -= 1;
          currentUrl = history[historyIndex] ?? currentUrl;
        }
      }),
      goForward: vi.fn(() => {
        if (historyIndex < history.length - 1) {
          historyIndex += 1;
          currentUrl = history[historyIndex] ?? currentUrl;
        }
      }),
    },
    on: vi.fn((event: string, listener: (...args: unknown[]) => void) => {
      if (event === "destroyed") {
        destroyedListeners.push(listener as () => void);
      } else if (
        event === "will-frame-navigate" ||
        event === "will-navigate" ||
        event === "will-redirect"
      ) {
        const listeners = navigationListeners.get(event) ?? [];
        listeners.push(listener as (event: TestNavigationEvent) => void);
        navigationListeners.set(event, listeners);
      } else {
        const listeners = stateListeners.get(event) ?? [];
        listeners.push(listener as (...args: unknown[]) => void);
        stateListeners.set(event, listeners);
      }
    }),
    reload: vi.fn(),
    session: {
      setPermissionCheckHandler: vi.fn(),
      setPermissionRequestHandler: vi.fn(),
    },
    setWindowOpenHandler: vi.fn(),
    stop: vi.fn(),
  };
  const view = {
    emitNavigation(
      eventName: NavigationEventName,
      url: string,
      { isMainFrame = true }: { isMainFrame?: boolean } = {}
    ) {
      const event = { isMainFrame, preventDefault: vi.fn(), url };
      for (const listener of navigationListeners.get(eventName) ?? []) {
        listener(event);
      }
      return event;
    },
    emitStateChange(eventName: string, ...args: unknown[]) {
      for (const listener of stateListeners.get(eventName) ?? []) listener(...args);
    },
    getBounds: vi.fn(() => bounds),
    getVisible: vi.fn(() => visible),
    setBounds: vi.fn((nextBounds: typeof bounds) => {
      bounds = nextBounds;
    }),
    setVisible: vi.fn((nextVisible: boolean) => {
      visible = nextVisible;
    }),
    get webContents() {
      return webContentsAvailable ? webContents : (undefined as never);
    },
  };
  return view as typeof view & BrowserSidebarViewLike;
}

function deferred<T>() {
  let isSettled = false;
  let reject!: (reason?: unknown) => void;
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((promiseResolve, promiseReject) => {
    reject = (reason) => {
      isSettled = true;
      promiseReject(reason);
    };
    resolve = (value) => {
      isSettled = true;
      promiseResolve(value);
    };
  });
  return { promise, reject, resolve, settled: () => isSettled };
}

describe("installBrowserSidebarSecurity window-open policy", () => {
  it("spends one user gesture per popup and denies unprompted or unsafe windows", () => {
    const page = createSecurityTarget();

    // Sign-in providers open their popup from the page load path too. Without a
    // gesture behind it, that is popup spam, and Electron ships no blocker.
    expect(page.requestWindow("https://accounts.google.com/o/oauth2/auth")).toEqual({
      action: "deny",
    });

    page.input({ type: "mouseDown" });
    expect(page.requestWindow("https://accounts.google.com/o/oauth2/auth")).toEqual({
      action: "allow",
      overrideBrowserWindowOptions: {
        webPreferences: BROWSER_SIDEBAR_WEB_PREFERENCES,
      },
    });
    // One click buys one window: the same gesture cannot spawn a second.
    expect(page.requestWindow("https://accounts.google.com/o/oauth2/auth")).toEqual({
      action: "deny",
    });

    page.input({ key: "Enter", type: "keyDown" });
    expect(page.requestWindow("file:///etc/passwd")).toEqual({ action: "deny" });
    expect(
      page.requestWindow("https://accounts.google.com/o/oauth2/auth")
    ).toMatchObject({ action: "allow" });

    page.input({ type: "mouseDown" });
    page.advance(5_001);
    expect(page.requestWindow("https://accounts.google.com/o/oauth2/auth")).toEqual({
      action: "deny",
    });

    // Pointer travel is not activation, so a hover cannot stand in for a click.
    page.input({ type: "mouseMove" });
    expect(page.requestWindow("https://accounts.google.com/o/oauth2/auth")).toEqual({
      action: "deny",
    });
  });

  it("does not restore popup activation on release, Escape, or shortcut input", () => {
    const page = createSecurityTarget();

    page.input({ type: "mouseDown" });
    expect(
      page.requestWindow("https://accounts.google.com/o/oauth2/auth")
    ).toMatchObject({ action: "allow" });

    // Releasing the same click is not a second user activation.
    page.input({ type: "mouseUp" });
    expect(page.requestWindow("https://accounts.google.com/o/oauth2/auth")).toEqual({
      action: "deny",
    });

    // Escape and browser/application shortcuts are not page-owned activation.
    page.input({ key: "Escape", type: "keyDown" });
    expect(page.requestWindow("https://accounts.google.com/o/oauth2/auth")).toEqual({
      action: "deny",
    });
    page.input({ key: "Enter", type: "keyUp" });
    expect(page.requestWindow("https://accounts.google.com/o/oauth2/auth")).toEqual({
      action: "deny",
    });
    page.input({ control: true, key: "l", type: "keyDown" });
    expect(page.requestWindow("https://accounts.google.com/o/oauth2/auth")).toEqual({
      action: "deny",
    });
  });

  it("hardens the popup it opens with the same guards as the page that opened it", () => {
    const page = createSecurityTarget();
    page.input({ type: "mouseDown" });
    page.requestWindow("https://accounts.google.com/o/oauth2/auth");

    const popup = createSecurityTarget();
    page.createWindow(popup.target);

    expect(popup.target.session.setPermissionCheckHandler).toHaveBeenCalled();
    expect(
      popup.navigate("will-redirect", "comma-connector://callback").preventDefault
    ).toHaveBeenCalled();
    expect(
      popup.navigate("will-navigate", "https://notion.so/callback").preventDefault
    ).not.toHaveBeenCalled();
    // The popup carries the sign-in on, so it gets the same gesture budget.
    expect(popup.requestWindow("https://accounts.google.com/consent")).toEqual({
      action: "deny",
    });
    popup.input({ type: "mouseDown" });
    expect(popup.requestWindow("https://accounts.google.com/consent")).toEqual({
      action: "allow",
      overrideBrowserWindowOptions: {
        webPreferences: BROWSER_SIDEBAR_WEB_PREFERENCES,
      },
    });
  });

  it("stops advertising Electron so providers serve their standard sign-in flow", () => {
    expect(
      browserFacingUserAgent(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
          "(KHTML, like Gecko) Comma/0.0.1 Chrome/148.0.7778.265 Electron/42.4.1 Safari/537.36"
      )
    ).toBe(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Comma/0.0.1 Chrome/148.0.7778.265 Safari/537.36"
    );
  });
});

function createSecurityTarget() {
  let clock = 1_000;
  const listeners = new Map<string, Array<(...args: unknown[]) => void>>();
  const target = {
    on: vi.fn((event: string, listener: (...args: unknown[]) => void) => {
      listeners.set(event, [...(listeners.get(event) ?? []), listener]);
    }),
    session: {
      setPermissionCheckHandler: vi.fn(),
      setPermissionRequestHandler: vi.fn(),
    },
    setWindowOpenHandler: vi.fn(),
  };
  const handle = {
    advance(milliseconds: number) {
      clock += milliseconds;
    },
    createWindow(childWebContents: object) {
      for (const listener of listeners.get("did-create-window") ?? []) {
        listener({ webContents: childWebContents });
      }
    },
    input(input: {
      alt?: boolean;
      control?: boolean;
      key?: string;
      meta?: boolean;
      modifiers?: string[];
      type: string;
    }) {
      for (const listener of listeners.get("input-event") ?? []) {
        listener({}, input);
      }
      const beforeEventName = input.type.startsWith("mouse")
        ? "before-mouse-event"
        : "before-input-event";
      for (const listener of listeners.get(beforeEventName) ?? []) {
        listener({}, input);
      }
    },
    navigate(event: string, url: string) {
      const navigation = { preventDefault: vi.fn(), url };
      for (const listener of listeners.get(event) ?? []) listener(navigation);
      return navigation;
    },
    requestWindow(url: string) {
      const handler = target.setWindowOpenHandler.mock.calls[0]?.[0] as (details: {
        url: string;
      }) => unknown;
      return handler({ url });
    },
    target,
  };
  installBrowserSidebarSecurity(
    target as unknown as Parameters<typeof installBrowserSidebarSecurity>[0],
    { now: () => clock }
  );
  return handle;
}
