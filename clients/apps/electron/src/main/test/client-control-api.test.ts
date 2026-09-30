import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  appPreferencesSchema,
  commaClientSettingsSchema,
  defaultCommaClientSettings,
  type AppPreferences,
  type AppPreferencesPatch,
} from "@comma/native-bridge";
import {
  ClientControlApiServer,
  createCommaClientControlRegistry,
} from "../modules/client-control";
import { AirDropService } from "../modules/airdrop";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { force: true, recursive: true }))
  );
});

describe("Comma Main client-control API", () => {
  it("routes an AirDrop send and returns actionable errors through the authenticated API", async () => {
    const harness = await createHarness();
    const operationId = randomUUID();
    const input = {
      requestId: operationId,
      peerId: "phone-id",
      paths: ["/tmp/report.pdf"],
    };
    const sender = {
      status: () => ({ available: true }),
      find: vi.fn(() => ({ operationId, kind: "find", status: "running" })),
      send: vi.fn((_input: typeof input) => ({
        operationId,
        kind: "send",
        status: "running",
      })),
      operation: vi.fn((_id: string) => ({
        operationId,
        kind: "send",
        status: "succeeded",
      })),
      cancel: vi.fn((_id: string) => ({
        operationId,
        kind: "send",
        status: "cancelled",
      })),
    };
    const server = await ClientControlApiServer.open({
      registry: createCommaClientControlRegistry({
        ...harness,
        airdrop: new AirDropService({ dataDir: harness.artifactRoot }),
        airdropSender: sender,
      }),
      token: "airdrop-control-token",
    });
    const call = async (api: string, args: unknown) => {
      const response = await fetch(`${server.endpoint}/v1/invoke`, {
        method: "POST",
        headers: {
          authorization: "Bearer airdrop-control-token",
          "content-type": "application/json",
        },
        body: JSON.stringify({ module: "airdrop", api, input: args }),
      });
      expect(response.status).toBe(200);
      return response.json();
    };
    try {
      expect(await call("find", {})).toMatchObject({ operationId, status: "running" });
      expect(await call("send", input)).toMatchObject({
        operationId,
        status: "running",
      });
      expect(sender.send).toHaveBeenCalledWith(input);
      // Several files, Drive and Mac paths alike, go to the recipient together.
      const vfsInput = {
        requestId: randomUUID(),
        peerId: "phone-id",
        paths: ["/drive/file.png", "/tmp/report.pdf"],
      };
      expect(await call("send", vfsInput)).toMatchObject({ status: "running" });
      expect(sender.send).toHaveBeenCalledWith(vfsInput);
      expect(await call("operation", { operationId })).toMatchObject({
        status: "succeeded",
      });
      expect(sender.operation).toHaveBeenCalledWith(operationId);
      expect(await call("cancel", { operationId })).toMatchObject({
        status: "cancelled",
      });
      sender.send.mockImplementationOnce(() => {
        throw new Error("Run AirDrop find again.");
      });
      expect(await call("send", input)).toEqual({
        status: "failed",
        error: "Run AirDrop find again.",
      });
    } finally {
      await server.close();
    }
  });

  it("routes remote device access through the local owner", async () => {
    const harness = await createHarness();
    const deviceAccess = vi.fn(async (_workspaceId: string, allow: boolean) => ({
      allows_operations: allow,
    }));
    const registry = createCommaClientControlRegistry({ ...harness, deviceAccess });
    const server = await ClientControlApiServer.open({
      registry,
      token: "device-owner-token",
    });
    try {
      const response = await fetch(`${server.endpoint}/v1/invoke`, {
        method: "POST",
        headers: {
          authorization: "Bearer device-owner-token",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          module: "devices",
          api: "set-access",
          input: { workspaceId: "wsp_owned", allow_operations: true },
        }),
      });
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ allows_operations: true });
      expect(deviceAccess).toHaveBeenCalledWith("wsp_owned", true);
    } finally {
      await server.close();
    }
  });

  it("discovers declarations and rejects absent or incorrect bearer credentials", async () => {
    const harness = await createHarness();
    const server = await ClientControlApiServer.open({
      registry: harness.registry,
      token: "control-token-1",
    });

    try {
      await expect(fetch(`${server.endpoint}/v1/modules`)).resolves.toMatchObject({
        status: 401,
      });
      await expect(
        fetch(`${server.endpoint}/v1/modules`, {
          headers: { authorization: "Bearer wrong-token" },
        })
      ).resolves.toMatchObject({ status: 401 });

      const modules = await request(server.endpoint, "control-token-1", "/v1/modules");
      expect(modules).toEqual({
        modules: [
          expect.objectContaining({ id: "global-settings" }),
          expect.objectContaining({ id: "client-settings" }),
          expect.objectContaining({ id: "in-app-browser" }),
        ],
      });

      const clientSettings = await request(
        server.endpoint,
        "control-token-1",
        "/v1/modules/client-settings"
      );
      expect(clientSettings).toMatchObject({
        apis: [
          expect.objectContaining({ id: "get" }),
          expect.objectContaining({
            id: "update",
            inputSchema: expect.objectContaining({
              properties: expect.objectContaining({
                appearance: expect.any(Object),
                appShortcutOverrides: expect.any(Object),
                localePreference: expect.any(Object),
                sideChatAppearance: expect.any(Object),
                sideChatShortcut: expect.any(Object),
              }),
            }),
          }),
        ],
        id: "client-settings",
      });

      const browser = await request(
        server.endpoint,
        "control-token-1",
        "/v1/modules/in-app-browser"
      );
      expect(browser).toMatchObject({
        apis: [
          expect.objectContaining({ id: "open-tab", usage: expect.any(String) }),
          expect.objectContaining({ id: "list-targets", usage: expect.any(String) }),
          expect.objectContaining({ id: "send-cdp-command" }),
          expect.objectContaining({ id: "capture-screenshot" }),
        ],
        id: "in-app-browser",
      });
    } finally {
      await server.close();
    }
  });

  it("validates invocation inputs and routes settings mutations through Main ownership", async () => {
    const harness = await createHarness();

    await expect(
      harness.registry.invoke({
        api: "update",
        input: { showInDock: false },
        module: "global-settings",
      })
    ).resolves.toEqual({
      airDropName: null,
      launchAtLogin: false,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: true,
      showInNotch: true,
      systemNotifications: true,
    });
    expect(harness.appPreferences.update).toHaveBeenCalledWith({ showInDock: false });

    await expect(
      harness.registry.invoke({
        api: "update",
        input: { rendererSecret: "no" },
        module: "global-settings",
      })
    ).rejects.toThrow(/invalid/i);

    await expect(
      harness.registry.invoke({
        api: "update",
        input: {
          appearance: { reducedMotion: true, theme: "dark" },
          localePreference: "zh-CN",
        },
        module: "client-settings",
      })
    ).resolves.toMatchObject({
      appearance: { reducedMotion: true, theme: "dark" },
      localePreference: "zh-CN",
    });
    expect(harness.appPreferences.update).toHaveBeenLastCalledWith({
      clientSettings: {
        appearance: { reducedMotion: true, theme: "dark" },
        localePreference: "zh-CN",
      },
    });
  });

  it("opens and controls exact browser tabs and creates readable screenshot artifacts", async () => {
    const harness = await createHarness();

    await expect(
      harness.registry.invoke({
        api: "open-tab",
        input: { url: "https://example.com/new" },
        module: "in-app-browser",
      })
    ).resolves.toEqual({
      target: expect.objectContaining({
        tabId: "tab-opened",
        url: "https://example.com/new",
      }),
    });
    expect(harness.browser.openClientTab).toHaveBeenCalledWith({
      url: "https://example.com/new",
    });

    await expect(
      harness.registry.invoke({
        api: "list-targets",
        input: {},
        module: "in-app-browser",
      })
    ).resolves.toEqual({
      targets: [
        {
          tabId: "tab-1",
          title: "Linear",
          url: "https://linear.app/",
          visible: true,
        },
      ],
    });

    await expect(
      harness.registry.invoke({
        api: "send-cdp-command",
        input: {
          method: "Runtime.evaluate",
          params: { expression: "document.title", returnByValue: true },
          tabId: "tab-1",
        },
        module: "in-app-browser",
      })
    ).resolves.toEqual({ result: { result: { value: "Linear" } } });
    expect(harness.browser.sendClientCdpCommand).toHaveBeenCalledWith({
      method: "Runtime.evaluate",
      params: { expression: "document.title", returnByValue: true },
      tabId: "tab-1",
    });

    const captured = (await harness.registry.invoke({
      api: "capture-screenshot",
      input: { tabId: "tab-1" },
      module: "in-app-browser",
    })) as {
      mimeType: string;
      path: string;
      size: number;
      target: { tabId: string };
    };
    expect(captured).toMatchObject({
      mimeType: "image/png",
      size: 8,
      target: { tabId: "tab-1" },
    });
    expect(captured.path.startsWith(harness.artifactRoot)).toBe(true);
    expect(await readFile(captured.path)).toEqual(
      Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])
    );
  });

  it("caps screenshots at five MiB and uses collision-free temporary artifacts", async () => {
    const harness = await createHarness();
    harness.browser.captureClientScreenshot.mockResolvedValue({
      pngImage: Buffer.alloc(5 * 1024 * 1024 + 1),
      target: browserTarget(),
    });

    await expect(
      harness.registry.invoke({
        api: "capture-screenshot",
        input: { tabId: "tab-1" },
        module: "in-app-browser",
      })
    ).rejects.toThrow(/artifact limit/i);
    expect(await readdir(harness.artifactRoot)).toEqual([]);

    harness.browser.captureClientScreenshot.mockResolvedValue({
      pngImage: Buffer.from([137, 80, 78, 71]),
      target: browserTarget(),
    });
    const captures = await Promise.all(
      Array.from({ length: 9 }, () =>
        harness.registry.invoke({
          api: "capture-screenshot",
          input: { tabId: "tab-1" },
          module: "in-app-browser",
        })
      )
    );
    expect(
      new Set(captures.map((capture) => (capture as { path: string }).path)).size
    ).toBe(9);
    const artifacts = await readdir(harness.artifactRoot);
    expect(artifacts).toHaveLength(8);
    expect(artifacts.some((path) => path.endsWith(".tmp"))).toBe(false);
  });

  it("rejects oversized bodies before invoking Main handlers", async () => {
    const harness = await createHarness();
    const server = await ClientControlApiServer.open({
      registry: harness.registry,
      token: "control-token-2",
    });

    try {
      const response = await fetch(`${server.endpoint}/v1/invoke`, {
        body: JSON.stringify({
          api: "update",
          input: { value: "x".repeat(70_000) },
          module: "global-settings",
        }),
        headers: {
          authorization: "Bearer control-token-2",
          "content-type": "application/json",
        },
        method: "POST",
      });
      expect(response.status).toBe(413);
      expect(harness.appPreferences.update).not.toHaveBeenCalled();
    } finally {
      await server.close();
    }
  });
});

async function createHarness() {
  const artifactRoot = await mkdtemp(join(tmpdir(), "comma-client-control-artifacts-"));
  roots.push(artifactRoot);
  let preferenceState: AppPreferences = {
    airDropName: null,
    launchAtLogin: false,
    notchSideWidth: 156,
    notificationSound: true,
    notifyRouterMessages: true,
    revision: 0,
    showInAirDrop: true,
    showInDock: true,
    showInMenuBar: true,
    showInNotch: true,
    systemNotifications: true,
  };
  const appPreferences = {
    state: vi.fn(() => preferenceState),
    update: vi.fn(async (patch: AppPreferencesPatch) => {
      const { clientSettings: clientSettingsPatch, ...topLevelPatch } = patch;
      const currentClientSettings =
        preferenceState.clientSettings ?? structuredClone(defaultCommaClientSettings);
      const nextClientSettings = clientSettingsPatch
        ? commaClientSettingsSchema.parse({
            ...currentClientSettings,
            ...clientSettingsPatch,
            appearance: {
              ...currentClientSettings.appearance,
              ...clientSettingsPatch.appearance,
            },
          })
        : undefined;
      preferenceState = appPreferencesSchema.parse({
        ...preferenceState,
        ...topLevelPatch,
        ...(nextClientSettings ? { clientSettings: nextClientSettings } : {}),
        revision: preferenceState.revision + 1,
      });
      return preferenceState;
    }),
  };
  const browser = {
    captureClientScreenshot: vi.fn(async () => ({
      pngImage: Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
      target: browserTarget(),
    })),
    listClientTargets: vi.fn(() => [browserTarget()]),
    openClientTab: vi.fn(async ({ url }: { url: string }) => ({
      ...browserTarget(),
      tabId: "tab-opened",
      url,
    })),
    sendClientCdpCommand: vi.fn(async () => ({ result: { value: "Linear" } })),
  };
  const registry = createCommaClientControlRegistry({
    appPreferences,
    artifactRoot,
    browser,
  });
  return { appPreferences, artifactRoot, browser, registry };
}

function browserTarget() {
  return {
    tabId: "tab-1",
    title: "Linear",
    url: "https://linear.app/",
    visible: true,
  };
}

async function request(endpoint: string, token: string, path: string) {
  const response = await fetch(`${endpoint}${path}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  expect(response.status).toBe(200);
  return response.json();
}
