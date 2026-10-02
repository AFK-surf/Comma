import {
  appPreferencesPatchSchema,
  appPreferencesSchema,
  createGeneratedNativeBridgeMock,
  createGeneratedNativeWebBridge,
  createNativePeerAsyncCall,
  browserSidebarOpenInputSchema,
  browserSidebarStateSchema,
  browserSidebarUpdateInputSchema,
  defineNativeCapability,
  generatedNativeCapabilityContracts,
  generatedNativeCapabilityIndex,
  generatedNativeCapabilityManifest,
  generatedNativeMainBindingsById,
  generatedNativeEventIndex,
  generatedNativeEventManifest,
  generatedNativePreloadEventBindings,
  generatedNativePreloadBindings,
  generatedNativeStateBindings,
  generatedNativeStateIndex,
  generatedNativeStateManifest,
  generatedNativeWebFallbacks,
  getNativeBridge,
  fileDownloadMaxBytes,
  fileDownloadMaxFileNameBytes,
  filesSaveDownloadInputSchema,
  filesOpenDownloadInputSchema,
  filesListOpenApplicationsResultSchema,
  maxBrowserSidebarSessionsPerOwner,
  nativeCapabilityRegistry,
  nativeEventRegistry,
  nativeStateRegistry,
  nativeInfoContract,
  localFilesPickInputSchema,
  localFilesPickResultSchema,
  localFilesPreviewInputSchema,
  localFilesPreviewResultSchema,
  nativePeerPortChannel,
  peersConnectContract,
  recommendationMediaLoadInputSchema,
  recommendationMediaLoadResultSchema,
  surfacesStateContract,
  shellOpenExternalInputSchema,
  sideChatOpenTestWindowInputSchema,
  synchronicityReadInputSchema,
  synchronicityReadMaxBytes,
  synchronicityWriteInputSchema,
  synchronicityWriteMaxBase64Characters,
  defaultSideChatDebugSettings,
  deriveSideChatDebugGeometry,
  sideChatDebugSettingsPatchSchema,
  sideChatDebugSettingsSchema,
  unavailableComputerUseBridge,
  unavailableConnectorBridge,
  unavailableNotchBridge,
  unavailableUpdateBridge,
  validateNativeCapabilityFixtures,
  webNativeBridge,
  type CommaNativeBridge,
  type GeneratedNativeBridge,
  type NativePeerMessagePort,
  type NativeStateBridge,
} from "@comma/native-bridge";
import {
  chatAttachmentUploadMaxBytes,
  chatAttachmentDownloadMaxBytes,
  chatAttachmentDownloadMaxFileNameBytes,
  chatImagePreviewMaxBytes,
} from "@comma/chat-contract";
import { z } from "zod";
import { afterEach, describe, expect, it, vi } from "vitest";

afterEach(() => {
  Reflect.deleteProperty(globalThis, "commaNative");
});

const TEST_SESSION_PRODUCT_LEASE = {
  audience: "https://api.comma.example",
  authorityInstanceId: "authority-1",
  generation: 2,
  sessionId: "session-1",
} as const;

describe("app preference schemas", () => {
  it("keeps omitted patch fields absent and rejects an empty patch", () => {
    expect(appPreferencesPatchSchema.parse({ notificationSound: false })).toEqual({
      notificationSound: false,
    });
    expect(appPreferencesPatchSchema.parse({ notifyRouterMessages: true })).toEqual({
      notifyRouterMessages: true,
    });
    expect(appPreferencesPatchSchema.parse({ showInDock: false })).toEqual({
      showInDock: false,
    });
    expect(appPreferencesPatchSchema.safeParse({}).success).toBe(false);
  });

  it("defaults notification preferences only for a complete legacy snapshot", () => {
    expect(
      appPreferencesSchema.parse({
        launchAtLogin: false,
        showInDock: true,
        showInMenuBar: true,
      })
    ).toMatchObject({
      notificationSound: true,
      notifyRouterMessages: true,
      systemNotifications: true,
    });
  });

  it("keeps the OS notification readback out of patches", () => {
    expect(
      appPreferencesPatchSchema.safeParse({ systemNotificationsStatus: "denied" })
        .success
    ).toBe(false);
    expect(appPreferencesPatchSchema.parse({ systemNotifications: false })).toEqual({
      systemNotifications: false,
    });
  });
});

describe("Side Chat test-window source contract", () => {
  it("accepts finite positive screen-DIP geometry and rejects fabricated zero sizes", () => {
    expect(
      sideChatOpenTestWindowInputSchema.parse({
        sourceFrame: { height: 30, width: 30, x: -118.5, y: 84.25 },
      })
    ).toEqual({
      sourceFrame: { height: 30, width: 30, x: -118.5, y: 84.25 },
    });
    expect(
      sideChatOpenTestWindowInputSchema.safeParse({
        sourceFrame: { height: 30, width: 0, x: 0, y: 0 },
      }).success
    ).toBe(false);
  });
});

describe("local file native boundary", () => {
  it("accepts bounded draft capacity and rejects renderer-supplied paths", () => {
    expect(
      localFilesPickInputSchema.safeParse({
        maxFiles: 50,
        maxTotalSize: 1024 * 1024 * 1024,
        session: TEST_SESSION_PRODUCT_LEASE,
        workspaceId: "workspace-1",
        path: "/private/user/file.txt",
      }).success
    ).toBe(false);
    expect(
      localFilesPickInputSchema.parse({
        maxFiles: 50,
        maxTotalSize: 1024 * 1024 * 1024,
        session: TEST_SESSION_PRODUCT_LEASE,
        workspaceId: "workspace-1",
      })
    ).toEqual({
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      session: TEST_SESSION_PRODUCT_LEASE,
      workspaceId: "workspace-1",
    });
  });

  it("preserves the bounded ownerless Connector remediation class", () => {
    expect(
      localFilesPickResultSchema.parse({
        cancelled: false,
        errors: [
          {
            errorClass: "connector_reconfiguration_required",
            message: "Reconnect the Connector with a newly issued token.",
            retryable: true,
          },
        ],
        files: [],
      })
    ).toEqual({
      cancelled: false,
      errors: [
        {
          errorClass: "connector_reconfiguration_required",
          message: "Reconnect the Connector with a newly issued token.",
          retryable: true,
        },
      ],
      files: [],
    });
  });

  it("accepts only opaque refs and bounded PNG previews", () => {
    const localFileRef = `lfi1_${"a".repeat(43)}`;
    expect(
      localFilesPreviewInputSchema.safeParse({
        localFileRef,
        path: "/private/user/photo.jpg",
        session: TEST_SESSION_PRODUCT_LEASE,
      }).success
    ).toBe(false);
    expect(
      localFilesPreviewInputSchema.parse({
        localFileRef,
        session: TEST_SESSION_PRODUCT_LEASE,
      })
    ).toEqual({ localFileRef, session: TEST_SESSION_PRODUCT_LEASE });
    const pngImage = new Uint8Array([137, 80, 78, 71]);
    expect(
      localFilesPreviewResultSchema.parse({
        pngImage,
        status: "ready",
      })
    ).toEqual({ pngImage, status: "ready" });
    expect(
      localFilesPreviewResultSchema.safeParse({
        pngImage: "not binary preview bytes",
        status: "ready",
      }).success
    ).toBe(false);
    expect(
      localFilesPreviewResultSchema.safeParse({
        pngImage: new Uint8Array(chatImagePreviewMaxBytes + 1),
        status: "ready",
      }).success
    ).toBe(false);
  });
});

describe("synchronicity read boundary", () => {
  it("requires an explicit bounded byte window", () => {
    expect(
      synchronicityReadInputSchema.parse({
        length: synchronicityReadMaxBytes,
        offset: 0,
        path: "notes/today.md",
        space: "comma-drive",
      })
    ).toMatchObject({ length: synchronicityReadMaxBytes, offset: 0 });
    expect(
      synchronicityReadInputSchema.safeParse({
        length: synchronicityReadMaxBytes + 1,
        offset: 0,
        path: "notes/today.md",
        space: "comma-drive",
      }).success
    ).toBe(false);
    expect(
      synchronicityReadInputSchema.safeParse({
        length: 1,
        offset: -1,
        path: "notes/today.md",
        space: "comma-drive",
      }).success
    ).toBe(false);
  });

  it("bounds the remaining renderer-to-Main base64 upload", () => {
    expect(
      synchronicityWriteInputSchema.safeParse({
        content: "A".repeat(synchronicityWriteMaxBase64Characters + 1),
        path: "too-large.bin",
        space: "comma-drive",
      }).success
    ).toBe(false);
  });
});

describe("saved-download native boundary", () => {
  it("admits opaque application choices but no executable paths", () => {
    const input = { downloadRef: `dnl1_${"A".repeat(43)}` };
    expect(filesOpenDownloadInputSchema.safeParse(input).success).toBe(true);
    expect(
      filesOpenDownloadInputSchema.safeParse({
        ...input,
        applicationId: `fap1_${"B".repeat(43)}`,
      }).success
    ).toBe(true);
    expect(
      filesOpenDownloadInputSchema.safeParse({
        ...input,
        applicationId: "/Applications/Reader.app",
      }).success
    ).toBe(false);
    expect(
      filesOpenDownloadInputSchema.safeParse({
        ...input,
        applicationPath: "/Applications/Reader.app",
      }).success
    ).toBe(false);
    expect(
      filesListOpenApplicationsResultSchema.safeParse({
        status: "available",
        applications: [
          {
            id: `fap1_${"B".repeat(43)}`,
            name: "Reader",
            isDefault: true,
            iconDataUrl: "file:///Users/private/icon.png",
          },
        ],
      }).success
    ).toBe(false);
  });

  it("uses the chat attachment byte ceiling and includes empty files", () => {
    expect(fileDownloadMaxBytes).toBe(chatAttachmentUploadMaxBytes);
    expect(fileDownloadMaxBytes).toBe(chatAttachmentDownloadMaxBytes);
    expect(fileDownloadMaxFileNameBytes).toBe(chatAttachmentDownloadMaxFileNameBytes);
    expect(
      filesSaveDownloadInputSchema.safeParse({
        content: new Uint8Array(),
        fileName: "empty.txt",
      }).success
    ).toBe(true);
    expect(
      filesSaveDownloadInputSchema.safeParse({
        content: new Uint8Array(chatAttachmentUploadMaxBytes),
        fileName: "at-limit.bin",
      }).success
    ).toBe(true);
    expect(
      filesSaveDownloadInputSchema.safeParse({
        content: new Uint8Array(chatAttachmentUploadMaxBytes + 1),
        fileName: "over-limit.bin",
      }).success
    ).toBe(false);
  });

  it("lets Main normalize a long Unicode name inside the bounded envelope", () => {
    const exactName = `${"界".repeat(340)}aaaa`;

    expect(new TextEncoder().encode(exactName)).toHaveLength(
      fileDownloadMaxFileNameBytes
    );
    expect(
      filesSaveDownloadInputSchema.safeParse({
        content: new Uint8Array([1]),
        fileName: `${"报告".repeat(150)}.pdf`,
      }).success
    ).toBe(true);
    expect(
      filesSaveDownloadInputSchema.safeParse({
        content: new Uint8Array([1]),
        fileName: exactName,
      }).success
    ).toBe(true);
    expect(
      filesSaveDownloadInputSchema.safeParse({
        content: new Uint8Array([1]),
        fileName: `${exactName}b`,
      }).success
    ).toBe(false);
  });
});

describe("recommendation media capability leaf", () => {
  it("admits only credential-free HTTPS and bounded PNG output", () => {
    expect(
      recommendationMediaLoadInputSchema.parse({
        url: "https://media.example/release.png",
      })
    ).toEqual({ url: "https://media.example/release.png" });
    expect(
      recommendationMediaLoadInputSchema.safeParse({
        url: "http://media.example/release.png",
      }).success
    ).toBe(false);
    expect(
      recommendationMediaLoadInputSchema.safeParse({
        url: "https://user:secret@media.example/release.png",
      }).success
    ).toBe(false);

    const pngImage = new Uint8Array([137, 80, 78, 71]);
    expect(
      recommendationMediaLoadResultSchema.parse({ pngImage, status: "ready" })
    ).toEqual({ pngImage, status: "ready" });
    expect(
      recommendationMediaLoadResultSchema.safeParse({
        pngImage: new Uint8Array(1024 * 1024 + 1),
        status: "ready",
      }).success
    ).toBe(false);
  });
});

describe("browser sidebar capability leaves", () => {
  it("accepts bounded http(s) requests and rejects unsafe URLs or geometry", () => {
    expect(
      browserSidebarOpenInputSchema.parse({
        bounds: { height: 720, width: 420, x: 860, y: 0 },
        navigationRevision: 3,
        sessionId: "workspace-1:conversation-1",
        url: "https://example.com/path",
      })
    ).toEqual({
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      navigationRevision: 3,
      sessionId: "workspace-1:conversation-1",
      url: "https://example.com/path",
    });
    expect(
      browserSidebarOpenInputSchema.safeParse({
        bounds: { height: 720, width: 420, x: 860, y: 0 },
        navigationRevision: -1,
        sessionId: "workspace-1:conversation-1",
        url: "https://example.com/path",
      }).success
    ).toBe(false);
    expect(
      browserSidebarOpenInputSchema.safeParse({
        bounds: { height: 720, width: 420, x: 860, y: 0 },
        sessionId: "workspace-1:conversation-1",
        url: "file:///etc/passwd",
      }).success
    ).toBe(false);
    expect(
      browserSidebarOpenInputSchema.safeParse({
        bounds: { height: 720, width: 0, x: 860, y: 0 },
        sessionId: "workspace-1:conversation-1",
        url: "https://example.com",
      }).success
    ).toBe(false);
    expect(
      browserSidebarOpenInputSchema.safeParse({
        bounds: { height: 16_385, width: 420, x: 0, y: 0 },
        sessionId: "workspace-1:conversation-1",
        url: "https://example.com",
      }).success
    ).toBe(false);
    expect(browserSidebarUpdateInputSchema.safeParse({}).success).toBe(false);
  });

  it("bounds exact close-before-open victims and rejects ambiguous fences", () => {
    const input = {
      bounds: { height: 720, width: 420, x: 860, y: 0 },
      closeBeforeOpenSessionIds: ["renderer-victim-a", "renderer-victim-b"],
      sessionId: "newly-admitted-page",
      url: "https://example.com/path",
    };

    expect(browserSidebarOpenInputSchema.parse(input)).toEqual(input);
    expect(
      browserSidebarOpenInputSchema.parse({
        ...input,
        closeBeforeOpenSessionIds: [],
      }).closeBeforeOpenSessionIds
    ).toEqual([]);
    expect(
      browserSidebarOpenInputSchema.safeParse({
        ...input,
        closeBeforeOpenSessionIds: ["renderer-victim-a", "renderer-victim-a"],
      }).success
    ).toBe(false);
    expect(
      browserSidebarOpenInputSchema.safeParse({
        ...input,
        closeBeforeOpenSessionIds: [input.sessionId],
      }).success
    ).toBe(false);
    expect(
      browserSidebarOpenInputSchema.safeParse({
        ...input,
        closeBeforeOpenSessionIds: Array.from(
          { length: maxBrowserSidebarSessionsPerOwner + 1 },
          (_, index) => `renderer-victim-${index}`
        ),
      }).success
    ).toBe(false);
  });

  it("accepts an explicit retryable browser-sidebar capacity state", () => {
    expect(
      browserSidebarStateSchema.parse({
        active: false,
        available: true,
        reason: "Waiting for an older browser sidebar session to finish closing.",
        reasonCode: "capacity",
        sessionId: "newly-admitted-page",
      })
    ).toMatchObject({
      active: false,
      available: true,
      reasonCode: "capacity",
      sessionId: "newly-admitted-page",
    });
  });

  it("publishes an honest unavailable web fallback instead of an iframe surrogate", async () => {
    await expect(
      webNativeBridge.browserSidebar.open({
        bounds: { height: 720, width: 420, x: 860, y: 0 },
        sessionId: "workspace-1:conversation-1",
        url: "https://example.com",
      })
    ).resolves.toEqual({
      active: false,
      available: false,
      reason: "Browser sidebar is unavailable in this runtime.",
    });
  });
});

describe("getNativeBridge", () => {
  it("returns the web fallback when no native bridge is installed", () => {
    expect(getNativeBridge()).toBe(webNativeBridge);
  });

  it("returns the installed native bridge when one exists", () => {
    const nativeBridge: CommaNativeBridge = {
      ...webNativeBridge,
      platform: "electron",
      os: "macos",
      self: { role: "main-window", windowId: "win_main" },
      notch: unavailableNotchBridge,
      connector: unavailableConnectorBridge,
      computerUse: unavailableComputerUseBridge,
      updates: unavailableUpdateBridge,
    };
    globalThis.commaNative = nativeBridge;

    expect(getNativeBridge()).toBe(nativeBridge);
  });
});

describe("peer channel bridge", () => {
  it("declares peers.connect as the message-port handshake leaf", () => {
    expect(nativePeerPortChannel).toBe("comma:peers:port");
    expect(peersConnectContract.channel).toBe("comma:peers:connect");
    expect(
      peersConnectContract.input.safeParse({ target: { windowId: "win_peer" } }).success
    ).toBe(true);
    expect(
      peersConnectContract.input.safeParse({ target: { role: "main-window" } }).success
    ).toBe(true);
    expect(peersConnectContract.output.safeParse({ channelId: "peer_1" }).success).toBe(
      true
    );
    expect(generatedNativeCapabilityIndex["peers.connect"]).toMatchObject({
      channel: "comma:peers:connect",
      payloadClass: "control",
      permission: "peers.connect",
      transport: "message-port",
    });
  });

  it("wraps a MessagePort as an AsyncCall peer connection", async () => {
    interface LeftApi {
      seen(input: { message: string }): void;
    }
    interface RightApi {
      ping(input: { message: string }): Promise<{ reply: string }>;
    }

    const [leftPort, rightPort] = createLinkedPeerPorts();
    const seen = vi.fn();
    const rightConnection = createNativePeerAsyncCall<LeftApi, RightApi>({
      channelId: "peer_1",
      localApi: {
        async ping(input) {
          return { reply: `pong:${input.message}` };
        },
      },
      port: rightPort,
    });
    const leftConnection = createNativePeerAsyncCall<RightApi, LeftApi>({
      channelId: "peer_1",
      localApi: {
        seen,
      },
      port: leftPort,
    });

    await expect(leftConnection.remote.ping({ message: "hello" })).resolves.toEqual({
      reply: "pong:hello",
    });
    await rightConnection.notify.seen({ message: "fire-and-forget" });
    await vi.waitFor(() => {
      expect(seen).toHaveBeenCalledWith({ message: "fire-and-forget" });
    });
  });
});

describe("native bridge contracts", () => {
  it("classifies every native command for Session admission", () => {
    const lifecycleIds = nativeCapabilityRegistry
      .filter(({ sessionAdmission }) => sessionAdmission === "lifecycle")
      .map(({ id }) => id);
    const requiredIds = nativeCapabilityRegistry
      .filter(({ sessionAdmission }) => sessionAdmission === "required")
      .map(({ id }) => id);

    expect(lifecycleIds).toEqual([
      "session.state",
      "session.requestEmailLogin",
      "session.verifyEmailLogin",
      "session.signInWithGoogle",
      "session.verifyGoogleLink",
      "session.cancelAuthAttempt",
      "session.reconcile",
      "session.signOut",
    ]);
    expect(requiredIds).toEqual([
      "onboarding.presentWindow",
      "subscriptionAuthorization.start",
      "tokenDanceAuthorization.start",
      "tokenDanceAuthorization.status",
      "tokenDanceAuthorization.save",
      "tokenDanceAuthorization.cancel",
      "subscriptionAuthorization.status",
      "subscriptionAuthorization.cancel",
      "localFiles.pick",
      "localFiles.preview",
      "sessionHistory.state",
      "sessionHistory.load",
      "sessionHistory.retain",
      "productInbox.state",
      "productInbox.retain",
      "productInbox.refresh",
      ...nativeCapabilityRegistry
        .filter(({ id }) => id.startsWith("chat."))
        .map(({ id }) => id),
      "audioCapture.selectMicrophone",
      "audioCapture.start",
      "audioCapture.stop",
      "audioCapture.openSaved",
    ]);

    for (const capability of nativeCapabilityRegistry) {
      expect(
        generatedNativeCapabilityManifest.find(({ id }) => id === capability.id)
      ).toMatchObject({
        id: capability.id,
        sessionAdmission: capability.sessionAdmission,
      });
      if (capability.sessionAdmission === "local_only") {
        expect(capability.sessionAdmissionRationale?.trim()).not.toBe("");
      } else {
        expect(capability.sessionAdmissionRationale).toBeUndefined();
      }
    }
  });

  it("publishes a generated capability index that stitches runtime, mocks, and handlers by id", () => {
    expect(generatedNativeCapabilityIndex["native.info"]).toEqual({
      artifacts: {
        contract: "nativeInfoContract",
        handlerType: 'NativeCapabilityHandlerTypeMap["native.info"]',
        leaf: "nativeInfoCapability",
        mainBinding: 'generatedNativeMainBindingsById["native.info"]',
        mock: "nativeInfoCapability.mock",
        preloadBinding: "generatedNativePreloadBindings.native.info",
        webFallback: "generatedNativeWebFallbacks.nativeInfo",
      },
      bridge: { method: "info", namespace: "native" },
      channel: "comma:native:info",
      handler: {
        exportName: "NativeInfoProvider",
        member: "info",
        module: "../../../apps/electron/src/main/modules/native/index",
        provider: "nativeInfo",
      },
      id: "native.info",
      payloadClass: "control",
      permission: "native.info.read",
      sessionAdmission: "local_only",
      sessionAdmissionRationale:
        "Reads application and operating-system metadata without Session state or authenticated transport.",
      transport: "ipc-rpc",
    });
    expect(generatedNativeMainBindingsById["native.info"]).toEqual(
      expect.objectContaining({
        contract: nativeInfoContract,
        method: "info",
        provider: "nativeInfo",
      })
    );
  });

  it("publishes event leaves as first-class generated manifest entries", () => {
    expect(nativeEventRegistry.map((event) => event.id)).toEqual([
      "applicationMenu.command",
      "sitePermissionMenu.changed",
      "appPreferences.state.changed",
      "connectorRuntime.state.changed",
      "browserSidebar.changed",
      "browserSidebar.openTabRequested",
      "surfaces.changed",
      "surfaces.windowFullScreen.changed",
      "onboarding.window.changed",
      "onboarding.handoff",
      "notch.event",
      "session.state.changed",
      "sessionHistory.state.changed",
      "productInbox.state.changed",
      "chat.state.changed",
      "chat.drafts.changed",
      "messageNotifications.event",
      "sideChat.presentation.changed",
      "sideChat.debugSettings.changed",
      "computeNode.state.changed",
      "audioCapture.state.changed",
      "meetingPresence.state.changed",
      "meetingRecorder.state.changed",
      "surfaces.windowResizeSettled",
      "airDrop.state.changed",
      "driveCatalog.state.changed",
    ]);
    expect(generatedNativeEventManifest).toEqual([
      {
        channel: "comma:application-menu:command",
        id: "applicationMenu.command",
        permission: "application-menu.control",
        target: { role: "main-window", type: "role" },
      },
      {
        channel: "comma:site-permission-menu:changed",
        id: "sitePermissionMenu.changed",
        permission: "site-permission-menu.control",
        target: { type: "all" },
      },
      {
        channel: "comma:app-preferences:changed",
        id: "appPreferences.state.changed",
        permission: "app-preferences.read",
        target: { type: "all" },
      },
      {
        channel: "comma:connector-runtime:state-changed",
        id: "connectorRuntime.state.changed",
        permission: "connector-runtime.scope.read",
        target: { type: "all" },
      },
      {
        channel: "comma:browser-sidebar:changed",
        id: "browserSidebar.changed",
        permission: "browser-sidebar.control",
        target: { type: "all" },
      },
      {
        channel: "comma:browser-sidebar:open-tab-requested",
        id: "browserSidebar.openTabRequested",
        permission: "browser-sidebar.control",
        target: { role: "main-window", type: "role" },
      },
      {
        channel: "comma:surfaces:changed",
        id: "surfaces.changed",
        permission: "surfaces.state.read",
        target: { type: "all" },
      },
      {
        channel: "comma:surfaces:window-full-screen-changed",
        id: "surfaces.windowFullScreen.changed",
        permission: "surfaces.state.read",
        target: { type: "all" },
      },
      {
        channel: "comma:onboarding:window-changed",
        id: "onboarding.window.changed",
        permission: "onboarding.window.read",
        target: { type: "all" },
      },
      {
        channel: "comma:onboarding:handoff",
        id: "onboarding.handoff",
        permission: "onboarding.window.read",
        target: { type: "window", windowId: "win_main" },
      },
      {
        channel: "comma:notch:event",
        id: "notch.event",
        permission: "notch.status.read",
        target: { type: "all" },
      },
      {
        channel: "comma:session:state-changed",
        id: "session.state.changed",
        permission: "session.state.read",
        target: { type: "all" },
      },
      {
        channel: "comma:session-history:state-changed",
        id: "sessionHistory.state.changed",
        permission: "session-history.read",
        target: { type: "all" },
      },
      {
        channel: "comma:product-inbox:state-changed",
        id: "productInbox.state.changed",
        permission: "product-inbox.state.read",
        target: { type: "all" },
      },
      {
        channel: "comma:chat:state-changed",
        id: "chat.state.changed",
        permission: "chat.state.read",
        target: { type: "all" },
      },
      {
        channel: "comma:chat:drafts-changed",
        id: "chat.drafts.changed",
        permission: "chat.state.read",
        target: { type: "all" },
      },
      {
        channel: "comma:message-notifications:event",
        id: "messageNotifications.event",
        permission: "chat.state.read",
        target: { type: "window", windowId: "win_main" },
      },
      {
        channel: "comma:side-chat:presentation-changed",
        id: "sideChat.presentation.changed",
        permission: "side-chat.state.read",
        target: { type: "all" },
      },
      {
        channel: "comma:side-chat:debug-settings-changed",
        id: "sideChat.debugSettings.changed",
        permission: "side-chat.debug-settings.read",
        target: { type: "all" },
      },
      {
        channel: "comma:compute-node:state-changed",
        id: "computeNode.state.changed",
        permission: "compute-node.read",
        target: { type: "all" },
      },
      {
        channel: "comma:audio-capture:state-changed",
        id: "audioCapture.state.changed",
        permission: "audio-capture.read",
        target: { type: "all" },
      },
      {
        channel: "comma:meeting-presence:state-changed",
        id: "meetingPresence.state.changed",
        permission: "meeting-presence.read",
        target: { type: "all" },
      },
      {
        channel: "comma:meeting-recorder:state-changed",
        id: "meetingRecorder.state.changed",
        permission: "meeting-recorder.read",
        target: { type: "all" },
      },
      {
        channel: "comma:surfaces:window-resize-settled",
        id: "surfaces.windowResizeSettled",
        permission: "surfaces.state.read",
        target: { type: "all" },
      },
      {
        channel: "comma:airdrop:state-changed",
        id: "airDrop.state.changed",
        permission: "airdrop.read",
        target: { type: "all" },
      },
      {
        channel: "comma:drive-catalog:changed",
        id: "driveCatalog.state.changed",
        permission: "synchronicity.read",
        target: { type: "all" },
      },
    ]);
    expect(generatedNativeEventIndex["surfaces.changed"]).toEqual({
      artifacts: {
        leaf: "surfacesChangedEvent",
        mock: "surfacesChangedEvent.mock",
      },
      channel: "comma:surfaces:changed",
      id: "surfaces.changed",
      permission: "surfaces.state.read",
      target: { type: "all" },
    });
    expect(generatedNativePreloadEventBindings.surfaces.changed).toEqual(
      expect.objectContaining({
        channel: "comma:surfaces:changed",
        id: "surfaces.changed",
      })
    );
    expect(generatedNativePreloadEventBindings.notch.event).toEqual(
      expect.objectContaining({
        channel: "comma:notch:event",
        id: "notch.event",
      })
    );
    expect(generatedNativePreloadEventBindings.session.state).toEqual(
      expect.objectContaining({
        channel: "comma:session:state-changed",
        id: "session.state.changed",
      })
    );
  });

  it("publishes state leaves with generated get and subscribe bindings", () => {
    expect(nativeStateRegistry.map((state) => state.id)).toEqual([
      "sitePermissionMenu.state",
      "appPreferences.state",
      "connectorRuntime.state",
      "surfaces.state",
      "surfaces.windowFullScreen",
      "onboarding.window",
      "session.state",
      "sessionHistory.state",
      "productInbox.state",
      "chat.state",
      "chat.drafts",
      "sideChat.presentation",
      "sideChat.debugSettings",
      "computeNode.state",
      "audioCapture.state",
      "meetingPresence.state",
      "meetingRecorder.state",
      "airDrop.state",
      "driveCatalog.state",
    ]);
    expect(generatedNativeStateManifest).toEqual([
      {
        bridge: { method: "state", namespace: "sitePermissionMenu" },
        get: {
          channel: "comma:site-permission-menu:state",
          id: "sitePermissionMenu.state",
          permission: "site-permission-menu.control",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads the Main-owned website menu only from its current dedicated renderer.",
        },
        id: "sitePermissionMenu.state",
        subscribe: {
          channel: "comma:site-permission-menu:changed",
          id: "sitePermissionMenu.changed",
          permission: "site-permission-menu.control",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "appPreferences" },
        get: {
          channel: "comma:app-preferences:state",
          id: "appPreferences.state",
          permission: "app-preferences.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads local desktop application preferences without Session state or authenticated transport.",
        },
        id: "appPreferences.state",
        subscribe: {
          channel: "comma:app-preferences:changed",
          id: "appPreferences.state.changed",
          permission: "app-preferences.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "connectorRuntime" },
        get: {
          channel: "comma:connector-runtime:state",
          id: "connectorRuntime.state",
          permission: "connector-runtime.scope.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads Main's bounded replay-last projection of locally supervised workspace Connector scopes.",
        },
        id: "connectorRuntime.state",
        subscribe: {
          channel: "comma:connector-runtime:state-changed",
          id: "connectorRuntime.state.changed",
          permission: "connector-runtime.scope.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "surfaces" },
        get: {
          channel: "comma:surfaces:state",
          id: "surfaces.state",
          permission: "surfaces.state.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads local window, view, panel, and Notch topology without Session state.",
        },
        id: "surfaces.state",
        subscribe: {
          channel: "comma:surfaces:changed",
          id: "surfaces.changed",
          permission: "surfaces.state.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "windowFullScreen", namespace: "surfaces" },
        get: {
          channel: "comma:surfaces:window-full-screen",
          id: "surfaces.windowFullScreen",
          permission: "surfaces.state.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads the calling local window's full-screen state without Session state.",
        },
        id: "surfaces.windowFullScreen",
        subscribe: {
          channel: "comma:surfaces:window-full-screen-changed",
          id: "surfaces.windowFullScreen.changed",
          permission: "surfaces.state.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "window", namespace: "onboarding" },
        get: {
          channel: "comma:onboarding:window",
          id: "onboarding.window",
          permission: "onboarding.window.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads whether the local onboarding window is open, without Session state or authenticated transport.",
        },
        id: "onboarding.window",
        subscribe: {
          channel: "comma:onboarding:window-changed",
          id: "onboarding.window.changed",
          permission: "onboarding.window.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "session" },
        get: {
          channel: "comma:session:state",
          id: "session.state",
          permission: "session.state.read",
          sessionAdmission: "lifecycle",
          sessionAdmissionRationale: undefined,
        },
        id: "session.state",
        subscribe: {
          channel: "comma:session:state-changed",
          id: "session.state.changed",
          permission: "session.state.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "sessionHistory" },
        id: "sessionHistory.state",
        get: {
          channel: "comma:session-history:state",
          id: "sessionHistory.state",
          permission: "session-history.read",
          sessionAdmission: "required",
        },
        subscribe: {
          channel: "comma:session-history:state-changed",
          id: "sessionHistory.state.changed",
          permission: "session-history.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "productInbox" },
        get: {
          channel: "comma:product-inbox:state",
          id: "productInbox.state",
          permission: "product-inbox.state.read",
          sessionAdmission: "required",
          sessionAdmissionRationale: undefined,
        },
        id: "productInbox.state",
        subscribe: {
          channel: "comma:product-inbox:state-changed",
          id: "productInbox.state.changed",
          permission: "product-inbox.state.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "chat" },
        get: {
          channel: "comma:chat:state",
          id: "chat.state",
          permission: "chat.state.read",
          sessionAdmission: "required",
          sessionAdmissionRationale: undefined,
        },
        id: "chat.state",
        subscribe: {
          channel: "comma:chat:state-changed",
          id: "chat.state.changed",
          permission: "chat.state.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "drafts", namespace: "chat" },
        get: {
          channel: "comma:chat:drafts",
          id: "chat.drafts",
          permission: "chat.state.read",
          sessionAdmission: "required",
          sessionAdmissionRationale: undefined,
        },
        id: "chat.drafts",
        subscribe: {
          channel: "comma:chat:drafts-changed",
          id: "chat.drafts.changed",
          permission: "chat.state.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "presentation", namespace: "sideChat" },
        get: {
          channel: "comma:side-chat:presentation",
          id: "sideChat.presentation",
          permission: "side-chat.state.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads local Side Chat presentation geometry without Session state or authenticated transport.",
        },
        id: "sideChat.presentation",
        subscribe: {
          channel: "comma:side-chat:presentation-changed",
          id: "sideChat.presentation.changed",
          permission: "side-chat.state.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "debugSettings", namespace: "sideChat" },
        get: {
          channel: "comma:side-chat:debug-settings",
          id: "sideChat.debugSettings",
          permission: "side-chat.debug-settings.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads local Side Chat debug settings without Session state or authenticated transport.",
        },
        id: "sideChat.debugSettings",
        subscribe: {
          channel: "comma:side-chat:debug-settings-changed",
          id: "sideChat.debugSettings.changed",
          permission: "side-chat.debug-settings.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "computeNode" },
        get: {
          channel: "comma:compute-node:state",
          id: "computeNode.state",
          permission: "compute-node.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads Main-owned local compute node lifecycle state without exposing its credential.",
        },
        id: "computeNode.state",
        subscribe: {
          channel: "comma:compute-node:state-changed",
          id: "computeNode.state.changed",
          permission: "compute-node.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "audioCapture" },
        get: {
          channel: "comma:audio-capture:state",
          id: "audioCapture.state",
          permission: "audio-capture.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads Main-owned local capture lifecycle state; no captured audio crosses the bridge.",
        },
        id: "audioCapture.state",
        subscribe: {
          channel: "comma:audio-capture:state-changed",
          id: "audioCapture.state.changed",
          permission: "audio-capture.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "meetingPresence" },
        get: {
          channel: "comma:meeting-presence:state",
          id: "meetingPresence.state",
          permission: "meeting-presence.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads which local apps currently hold the microphone; no Session state or captured audio involved.",
        },
        id: "meetingPresence.state",
        subscribe: {
          channel: "comma:meeting-presence:state-changed",
          id: "meetingPresence.state.changed",
          permission: "meeting-presence.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "meetingRecorder" },
        get: {
          channel: "comma:meeting-recorder:state",
          id: "meetingRecorder.state",
          permission: "meeting-recorder.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Controls only Main's current meeting presentation; Main admits capture and file operations against its current Session authority.",
        },
        id: "meetingRecorder.state",
        subscribe: {
          channel: "comma:meeting-recorder:state-changed",
          id: "meetingRecorder.state.changed",
          permission: "meeting-recorder.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "airDrop" },
        get: {
          channel: "comma:airdrop:state",
          id: "airDrop.state",
          permission: "airdrop.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads only Main's local AirDrop consent presentation; Main admits chat attachment intake against its current Session authority.",
        },
        id: "airDrop.state",
        subscribe: {
          channel: "comma:airdrop:state-changed",
          id: "airDrop.state.changed",
          permission: "airdrop.read",
          target: { type: "all" },
        },
      },
      {
        bridge: { method: "state", namespace: "driveCatalog" },
        get: {
          channel: "comma:drive-catalog:state",
          id: "driveCatalog.state",
          permission: "synchronicity.read",
          sessionAdmission: "local_only",
          sessionAdmissionRationale:
            "Reads the local Drive metadata query owner's refresh state.",
        },
        id: "driveCatalog.state",
        subscribe: {
          channel: "comma:drive-catalog:changed",
          id: "driveCatalog.state.changed",
          permission: "synchronicity.read",
          target: { type: "all" },
        },
      },
    ]);
    expect(generatedNativeStateBindings.surfaces.state).toEqual({
      get: expect.objectContaining({ channel: "comma:surfaces:state" }),
      subscribe: expect.objectContaining({ channel: "comma:surfaces:changed" }),
    });
    expect(generatedNativeStateBindings.session.state).toEqual({
      get: expect.objectContaining({ channel: "comma:session:state" }),
      subscribe: expect.objectContaining({ channel: "comma:session:state-changed" }),
    });
    expect(generatedNativeStateBindings.productInbox.state).toEqual({
      get: expect.objectContaining({ channel: "comma:product-inbox:state" }),
      subscribe: expect.objectContaining({
        channel: "comma:product-inbox:state-changed",
      }),
    });
    expect(generatedNativeStateBindings.sideChat.presentation).toEqual({
      get: expect.objectContaining({ channel: "comma:side-chat:presentation" }),
      subscribe: expect.objectContaining({
        channel: "comma:side-chat:presentation-changed",
        target: { type: "all" },
      }),
    });
    expect(generatedNativeStateBindings.sideChat.debugSettings).toEqual({
      get: expect.objectContaining({ channel: "comma:side-chat:debug-settings" }),
      subscribe: expect.objectContaining({
        channel: "comma:side-chat:debug-settings-changed",
        target: { type: "all" },
      }),
    });
    expect(generatedNativeStateIndex["session.state"]).toEqual({
      artifacts: {
        get: "generatedNativeStateBindings.session.state.get",
        leaf: "sessionStateLeaf",
        mock: "sessionStateLeaf.mock",
        subscribe: "generatedNativeStateBindings.session.state.subscribe",
        webFallback: "sessionStateLeaf.webFallback",
      },
      bridge: { method: "state", namespace: "session" },
      get: {
        channel: "comma:session:state",
        id: "session.state",
        permission: "session.state.read",
        sessionAdmission: "lifecycle",
        sessionAdmissionRationale: undefined,
      },
      id: "session.state",
      subscribe: {
        channel: "comma:session:state-changed",
        id: "session.state.changed",
        permission: "session.state.read",
        target: { type: "all" },
      },
    });
  });

  it("keeps Side Chat debug updates bounded and preserves the content position", () => {
    expect(deriveSideChatDebugGeometry(defaultSideChatDebugSettings)).toEqual({
      contentOriginX: 5,
      contentOriginY: -9,
      horizontalBackdropPadding: 159,
      verticalBackdropPadding: 79,
    });
    expect(
      sideChatDebugSettingsSchema.safeParse(defaultSideChatDebugSettings).success
    ).toBe(true);
    expect(sideChatDebugSettingsPatchSchema.safeParse({ blurRadius: 90 }).success).toBe(
      true
    );
    expect(sideChatDebugSettingsPatchSchema.safeParse({ blurRadius: 91 }).success).toBe(
      false
    );
    expect(sideChatDebugSettingsPatchSchema.safeParse({ tintOpacity: 0 }).success).toBe(
      true
    );
    expect(
      sideChatDebugSettingsPatchSchema.safeParse({ tintOpacity: 1.1 }).success
    ).toBe(false);
    expect(sideChatDebugSettingsPatchSchema.safeParse({}).success).toBe(false);
  });

  it("validates web fallbacks and mocks against their leaf schemas", () => {
    expect(generatedNativeWebFallbacks.nativeInfo).toEqual({
      appVersion: "web",
      os: "unknown",
      platform: "web",
    });
    expect(() =>
      validateNativeCapabilityFixtures(nativeCapabilityRegistry)
    ).not.toThrow();
    expect(() =>
      defineNativeCapability({
        bridge: { method: "bad", namespace: "native" },
        channel: "comma:test:bad",
        handler: {
          exportName: "BadProvider",
          member: "bad",
          module: "../../../apps/electron/src/main/modules/native/index",
          provider: "bad",
        },
        id: "test.bad",
        input: z.void(),
        mock: { ok: true },
        output: z.object({ ok: z.boolean() }),
        permission: "test.bad",
        sessionAdmission: "required",
        webFallback: { ok: "nope" } as unknown as { ok: boolean },
      })
    ).toThrow(/webFallback.*test\.bad/);
  });

  it("keeps native.info as a pure schema contract", () => {
    expect(nativeInfoContract.channel).toBe("comma:native:info");
    expect(nativeInfoContract.permission).toBe("native.info.read");
    expect(nativeInfoContract.input.parse(undefined)).toBeUndefined();
    expect(
      nativeInfoContract.output.parse({
        appVersion: "0.0.1",
        os: "macos",
        platform: "electron",
      })
    ).toEqual({
      appVersion: "0.0.1",
      os: "macos",
      platform: "electron",
    });
  });

  it("keeps surfaces.state as the state-leaf snapshot contract", () => {
    expect(surfacesStateContract.channel).toBe("comma:surfaces:state");
    expect(surfacesStateContract.permission).toBe("surfaces.state.read");
    expect(
      surfacesStateContract.output.parse({
        notch: { available: false },
        panels: [],
        platform: { appVersion: "web", os: "unknown", platform: "web" },
        views: [],
        windows: [],
      })
    ).toEqual({
      notch: { available: false },
      panels: [],
      platform: { appVersion: "web", os: "unknown", platform: "web" },
      views: [],
      windows: [],
    });
  });

  it("keeps lifecycle command inputs exact and bearer-free", () => {
    const contract = generatedNativePreloadBindings.session.requestEmailLogin;
    const input = {
      email: "person@example.com",
      expected: {
        authorityInstanceId: "authority-1",
        expectedSessionId: null,
        generation: 2,
      },
    };

    expect(contract.input.parse(input)).toEqual(input);
    expect(
      contract.input.safeParse({
        ...input,
        token: "comma_sess_secret",
      }).success
    ).toBe(false);
    expect("proxyProbe" in generatedNativePreloadBindings.session).toBe(false);
  });

  it("keeps Session state and local diagnostics free of credential fields", () => {
    const snapshot = {
      authority: {
        authorityInstanceId: "authority-1",
        kind: "electron_main",
      },
      cleanup: { revocation: "idle" },
      contractVersion: 1,
      generation: 2,
      phase: "signed_in",
      principal: {
        email: "dev@example.com",
        userId: "user-1",
      },
      revision: 4,
      session: {
        audience: "https://api.comma.example",
        expiresAtEpochSeconds: 1_900_000_000,
        sessionId: "session-1",
      },
    } as const;

    expect(
      generatedNativeCapabilityContracts.sessionState.output.parse(snapshot)
    ).toEqual(snapshot);
    expect(
      generatedNativeCapabilityContracts.sessionState.output.safeParse({
        ...snapshot,
        token: "comma_sess_secret",
      }).success
    ).toBe(false);

    expect(
      generatedNativeCapabilityContracts.localDataStatus.output.parse({
        available: true,
        database: {
          latestSchemaVersion: 2,
          schemaVersion: 2,
          status: "ready",
        },
        fileStore: {
          diskUsage: 0,
          missingReferences: 0,
          status: "ready",
          storedEntries: 0,
        },
        observability: {
          jsonlEnabled: false,
          location: "disabled",
          redacted: true,
          status: "disabled",
        },
      })
    ).toEqual({
      available: true,
      database: {
        latestSchemaVersion: 2,
        schemaVersion: 2,
        status: "ready",
      },
      fileStore: {
        diskUsage: 0,
        missingReferences: 0,
        status: "ready",
        storedEntries: 0,
      },
      observability: {
        jsonlEnabled: false,
        location: "disabled",
        redacted: true,
        status: "disabled",
      },
    });
  });
});

describe("webNativeBridge golden fallbacks", () => {
  it("exposes a web renderer identity fallback", () => {
    expect(webNativeBridge.self).toEqual({
      role: "unknown",
      windowId: "web",
    });
  });

  it("returns web platform facts through native.info", async () => {
    await expect(webNativeBridge.native.info()).resolves.toEqual({
      appVersion: "web",
      os: "unknown",
      platform: "web",
    });
  });

  it("returns an empty native surface list in the web runtime", async () => {
    await expect(webNativeBridge.surfaces.list()).resolves.toEqual({
      notch: { available: false, reason: "Notch is unavailable in this runtime." },
      panels: [],
      platform: { appVersion: "web", os: "unknown", platform: "web" },
      views: [],
      windows: [],
    });
  });

  it("returns an empty product inbox refresh envelope through the web fallback", async () => {
    await expect(
      webNativeBridge.productInbox.refresh({
        session: TEST_SESSION_PRODUCT_LEASE,
      })
    ).resolves.toEqual({
      session: {
        audience: "https://api.comma.test",
        authorityInstanceId: "mock-electron-main",
        generation: 1,
        sessionId: "mock-session",
      },
      snapshot: {
        items: [],
        source: "unavailable",
      },
    });
  });

  it("keeps native event subscriptions as a no-op in the web runtime", () => {
    const listener = vi.fn();

    const unsubscribe = webNativeBridge.surfaces.onChanged(listener);
    unsubscribe();

    expect(listener).not.toHaveBeenCalled();
  });
});

describe("generated renderer bridge assembly", () => {
  it("keeps the final web bridge reachable for every runtime leaf", async () => {
    const stateIds = new Set(nativeStateRegistry.map((state) => state.id));

    for (const capability of nativeCapabilityRegistry) {
      const mainBinding =
        generatedNativeMainBindingsById[
          capability.id as keyof typeof generatedNativeMainBindingsById
        ];
      expect(mainBinding.contract.channel).toBe(capability.channel);

      const member = getGeneratedBridgeMember(
        webNativeBridge,
        capability.bridge.namespace,
        capability.bridge.method
      );

      if (stateIds.has(capability.id)) {
        const stateBridge = member as NativeStateBridge<unknown>;
        expect(stateBridge.get, `${capability.id} get`).toEqual(expect.any(Function));
        expect(stateBridge.subscribe, `${capability.id} subscribe`).toEqual(
          expect.any(Function)
        );
        continue;
      }

      expect(member, capability.id).toEqual(expect.any(Function));
    }

    for (const event of nativeEventRegistry) {
      if (!event.bridge) {
        continue;
      }

      expect(
        getGeneratedBridgeMember(
          webNativeBridge,
          event.bridge.namespace,
          event.bridge.method
        ),
        event.id
      ).toEqual(expect.any(Function));
    }

    expect(webNativeBridge.surfaces.list).toBe(webNativeBridge.surfaces.state.get);
    await expect(webNativeBridge.surfaces.list()).resolves.toEqual(
      await webNativeBridge.surfaces.state.get()
    );
  });

  it("exposes every generated command, state, and bridge event from the leaf registry", () => {
    const generatedBridge = createGeneratedNativeWebBridge();
    const stateIds = new Set(generatedNativeStateManifest.map((state) => state.id));

    for (const capability of generatedNativeCapabilityManifest) {
      if (stateIds.has(capability.id)) {
        continue;
      }

      expect(
        getGeneratedBridgeMember(
          generatedBridge,
          capability.bridge.namespace,
          capability.bridge.method
        ),
        capability.id
      ).toEqual(expect.any(Function));
    }

    for (const state of generatedNativeStateManifest) {
      const stateBridge = getGeneratedBridgeMember(
        generatedBridge,
        state.bridge.namespace,
        state.bridge.method
      ) as NativeStateBridge<unknown>;

      expect(stateBridge.get, `${state.id} get`).toEqual(expect.any(Function));
      expect(stateBridge.subscribe, `${state.id} subscribe`).toEqual(
        expect.any(Function)
      );
    }

    for (const event of nativeEventRegistry) {
      if (!event.bridge) {
        continue;
      }

      expect(
        getGeneratedBridgeMember(
          generatedBridge,
          event.bridge.namespace,
          event.bridge.method
        ),
        event.id
      ).toEqual(expect.any(Function));
    }
  });

  it("builds generated command mocks from leaf mock fixtures", async () => {
    const mockBridge = createGeneratedNativeBridgeMock({
      command: (implementation) => vi.fn(implementation) as typeof implementation,
      event: (implementation) => vi.fn(implementation) as typeof implementation,
      state: (getSnapshot) => createTestStateBridge(getSnapshot),
    });

    await expect(mockBridge.native.info()).resolves.toEqual(
      generatedNativeCapabilityContracts.nativeInfo.output.parse(
        nativeCapabilityRegistry.find((capability) => capability.id === "native.info")
          ?.mock
      )
    );
    await expect(
      mockBridge.productInbox.refresh({ session: TEST_SESSION_PRODUCT_LEASE })
    ).resolves.toEqual(
      generatedNativeCapabilityContracts.productInboxRefresh.output.parse(
        nativeCapabilityRegistry.find(
          (capability) => capability.id === "productInbox.refresh"
        )?.mock
      )
    );
    await expect(
      mockBridge.productInbox.state.get({
        session: TEST_SESSION_PRODUCT_LEASE,
      })
    ).resolves.toEqual(
      generatedNativeCapabilityContracts.productInboxState.output.parse(
        nativeCapabilityRegistry.find(
          (capability) => capability.id === "productInbox.state"
        )?.mock
      )
    );
    await expect(
      mockBridge.sideChat.setInteractiveProgress({ progress: 0.42 })
    ).resolves.toEqual({ revision: 0 });
    await expect(
      mockBridge.sideChat.finishInteractiveProgress({ shouldOpen: true })
    ).resolves.toEqual({ revision: 0 });
    await expect(
      mockBridge.sideChat.openTestWindow({
        sourceFrame: { height: 30, width: 30, x: 42, y: 84 },
      })
    ).resolves.toEqual({ revision: 0 });
    await expect(mockBridge.sideChat.closeTestWindow()).resolves.toEqual({
      revision: 0,
    });
  });
});

describe("unavailableComputerUseBridge", () => {
  it("returns stable unavailable result", async () => {
    await expect(unavailableComputerUseBridge.openPermissionFlow()).resolves.toEqual({
      ok: false,
      error: "ComputerUse is unavailable in this runtime.",
    });
  });
});

describe("unavailableConnectorBridge", () => {
  it("returns stable unavailable status", async () => {
    await expect(unavailableConnectorBridge.status()).resolves.toEqual({
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Connector is unavailable in this runtime.",
    });
  });
});

describe("unavailableNotchBridge", () => {
  it("returns stable unavailable status and events", async () => {
    await expect(unavailableNotchBridge.status()).resolves.toEqual({
      available: false,
      reason: "Notch is unavailable in this runtime.",
    });
    await expect(unavailableNotchBridge.show()).resolves.toEqual({
      type: "error",
      error: "Notch is unavailable in this runtime.",
    });
  });
});

function getGeneratedBridgeMember(
  bridge: GeneratedNativeBridge,
  namespace: string,
  method: string
) {
  const namespaceBridge = bridge[namespace as keyof GeneratedNativeBridge] as
    | Record<string, unknown>
    | undefined;

  return namespaceBridge?.[method];
}

function createTestStateBridge<Snapshot, GetInput = void>(
  getSnapshot: (input: GetInput) => Snapshot
): NativeStateBridge<Snapshot, GetInput> {
  const get = vi.fn(async (input: GetInput) => getSnapshot(input));
  const subscribe = vi.fn(
    (listener: (snapshot: Snapshot) => void, replayInput: GetInput) => {
      void get(replayInput).then(listener);
      return () => {};
    }
  );
  const bridge = Object.assign(get, {
    get,
    subscribe,
  });

  return bridge as unknown as NativeStateBridge<Snapshot, GetInput>;
}

function createLinkedPeerPorts(): [NativePeerMessagePort, NativePeerMessagePort] {
  const left = new TestPeerPort();
  const right = new TestPeerPort();
  left.peer = right;
  right.peer = left;

  return [left, right];
}

class TestPeerPort implements NativePeerMessagePort {
  peer: TestPeerPort | undefined;
  readonly #listeners = new Set<(event: { data: unknown }) => void>();
  #closed = false;

  addEventListener(type: "message", listener: (event: { data: unknown }) => void) {
    if (type === "message") {
      this.#listeners.add(listener);
    }
  }

  close() {
    this.#closed = true;
  }

  postMessage(message: unknown) {
    if (this.#closed) {
      throw new Error("Port is closed.");
    }

    queueMicrotask(() => {
      this.peer?.emit(message);
    });
  }

  removeEventListener(type: "message", listener: (event: { data: unknown }) => void) {
    if (type === "message") {
      this.#listeners.delete(listener);
    }
  }

  start() {}

  private emit(message: unknown) {
    if (this.#closed) {
      return;
    }

    for (const listener of this.#listeners) {
      listener({ data: message });
    }
  }
}

describe("external application URLs", () => {
  it("admits Messages compose links while rejecting executable and multi-recipient URLs", () => {
    expect(
      shellOpenExternalInputSchema.parse({
        url: "sms:comma%40example.test&body=bridgebot%20connect%20LOCAL-CODE",
      }).url
    ).toContain("sms:");
    for (const url of [
      "javascript:alert(1)",
      "file:///etc/passwd",
      "sms:alice%2Cbob&body=hello",
    ]) {
      expect(shellOpenExternalInputSchema.safeParse({ url }).success).toBe(false);
    }
  });
});
