import { runInNewContext } from "node:vm";
import ts from "typescript";
import { describe, expect, it, vi } from "vitest";
import {
  collectNativeCapabilityEntries,
  renderNativeCapabilityArtifacts,
  renderNativeCapabilityMainArtifacts,
} from "../generate-native-capability-artifacts-lib.mjs";

describe("native capability artifact generator", () => {
  it("collects command and event leaves from the controlled registry source", () => {
    const entries = collectNativeCapabilityEntries(`
      export const nativeInfoCapability = defineNativeCapability({
        bridge: { method: "info", namespace: "native" },
        channel: "comma:native:info",
        id: "native.info",
        handler: {
          exportName: "NativeInfoProvider",
          member: "info",
          module: "../../../apps/electron/src/main/modules/native/index",
          provider: "nativeInfo",
        },
        input: z.void(),
        mock: {},
        output: nativeInfoSchema,
        permission: "native.info.read",
        sessionAdmission: "local_only",
        sessionAdmissionRationale: "Reads local application metadata only.",
        webFallback: {},
      });

      export const surfacesChangedEvent = defineNativeEvent({
        channel: "comma:surfaces:changed",
        id: "surfaces.changed",
        mock: {},
        payload: surfaceListSchema,
        target: { type: "all" },
      });

      export const surfacesStateCapability = defineNativeCapability({
        bridge: { method: "state", namespace: "surfaces" },
        channel: "comma:surfaces:state",
        id: "surfaces.state",
        handler: {
          exportName: "SurfaceListProvider",
          member: "state",
          module: "../../../apps/electron/src/main/modules/native/index",
          provider: "surfaces",
        },
        input: z.void(),
        mock: {},
        output: surfaceListSchema,
        permission: "surfaces.state.read",
        sessionAdmission: "required",
        webFallback: {},
      });

      export const surfacesStateLeaf = defineNativeState({
        bridge: { method: "state", namespace: "surfaces" },
        get: surfacesStateCapability,
        id: "surfaces.state",
        subscribe: surfacesChangedEvent,
      });

      export const nativeCapabilityRegistry = [
        nativeInfoCapability,
        surfacesStateCapability,
      ] as const;
      export const nativeEventRegistry = [surfacesChangedEvent] as const;
      export const nativeStateRegistry = [surfacesStateLeaf] as const;
    `);

    expect(entries.commands).toEqual([
      {
        bridge: { method: "info", namespace: "native" },
        channel: "comma:native:info",
        exportName: "nativeInfoCapability",
        generatedKey: "nativeInfo",
        handler: {
          exportName: "NativeInfoProvider",
          member: "info",
          module: "../../../apps/electron/src/main/modules/native/index",
          provider: "nativeInfo",
        },
        id: "native.info",
        inputKind: "void",
        permission: "native.info.read",
        sessionAdmission: "local_only",
        sessionAdmissionRationale: "Reads local application metadata only.",
        payloadClass: "control",
        transport: "ipc-rpc",
      },
      {
        bridge: { method: "state", namespace: "surfaces" },
        channel: "comma:surfaces:state",
        exportName: "surfacesStateCapability",
        generatedKey: "surfacesState",
        handler: {
          exportName: "SurfaceListProvider",
          member: "state",
          module: "../../../apps/electron/src/main/modules/native/index",
          provider: "surfaces",
        },
        id: "surfaces.state",
        inputKind: "void",
        permission: "surfaces.state.read",
        sessionAdmission: "required",
        payloadClass: "control",
        transport: "ipc-rpc",
      },
    ]);
    expect(entries.events).toEqual([
      {
        channel: "comma:surfaces:changed",
        exportName: "surfacesChangedEvent",
        generatedKey: "surfacesChanged",
        id: "surfaces.changed",
        target: { type: "all" },
      },
    ]);
    expect(entries.states).toEqual([
      {
        bridge: { method: "state", namespace: "surfaces" },
        exportName: "surfacesStateLeaf",
        generatedKey: "surfacesState",
        getLeaf: "surfacesStateCapability",
        id: "surfaces.state",
        subscribeLeaf: "surfacesChangedEvent",
      },
    ]);
  });

  it("orders command leaves by the controlled native capability registry", () => {
    const entries = collectNativeCapabilityEntries(`
      export const firstCapability = defineNativeCapability({
        bridge: { method: "first", namespace: "native" },
        channel: "comma:test:first",
        handler: {
          exportName: "FirstProvider",
          member: "first",
          module: "../../../apps/electron/src/main/modules/native/index",
          provider: "first",
        },
        id: "test.first",
        input: z.void(),
        mock: {},
        output: testSchema,
        permission: "test.first",
        sessionAdmission: "required",
        webFallback: {},
      });

      export const secondCapability = defineNativeCapability({
        bridge: { method: "second", namespace: "native" },
        channel: "comma:test:second",
        handler: {
          exportName: "SecondProvider",
          member: "second",
          module: "../../../apps/electron/src/main/modules/native/index",
          provider: "second",
        },
        id: "test.second",
        input: z.void(),
        mock: {},
        output: testSchema,
        permission: "test.second",
        sessionAdmission: "required",
        webFallback: {},
      });

      export const nativeCapabilityRegistry = [
        secondCapability,
        firstCapability,
      ] as const;
      export const nativeEventRegistry = [] as const;
    `);

    expect(entries.commands.map((entry) => entry.id)).toEqual([
      "test.second",
      "test.first",
    ]);
  });

  it("rejects command leaves that are not listed in the controlled registry", () => {
    expect(() =>
      collectNativeCapabilityEntries(`
        export const registeredCapability = defineNativeCapability({
          bridge: { method: "registered", namespace: "native" },
          channel: "comma:test:registered",
          handler: {
            exportName: "RegisteredProvider",
            member: "registered",
            module: "../../../apps/electron/src/main/modules/native/index",
            provider: "registered",
          },
          id: "test.registered",
          input: z.void(),
          mock: {},
          output: testSchema,
          permission: "test.registered",
          sessionAdmission: "required",
          webFallback: {},
        });

        export const orphanCapability = defineNativeCapability({
          bridge: { method: "orphan", namespace: "native" },
          channel: "comma:test:orphan",
          handler: {
            exportName: "OrphanProvider",
            member: "orphan",
            module: "../../../apps/electron/src/main/modules/native/index",
            provider: "orphan",
          },
          id: "test.orphan",
          input: z.void(),
          mock: {},
          output: testSchema,
          permission: "test.orphan",
          sessionAdmission: "required",
          webFallback: {},
        });

        export const nativeCapabilityRegistry = [registeredCapability] as const;
        export const nativeEventRegistry = [] as const;
      `)
    ).toThrow(/orphanCapability.*nativeCapabilityRegistry/);
  });

  it("rejects registry entries that do not point at capability leaves", () => {
    expect(() =>
      collectNativeCapabilityEntries(`
        export const nativeCapabilityRegistry = [missingCapability] as const;
        export const nativeEventRegistry = [] as const;
      `)
    ).toThrow(/nativeCapabilityRegistry.*missingCapability/);
  });

  it.each(
    [
      {
        name: "rejects duplicate command ids across registered leaves",
        channels: ["comma:test:first", "comma:test:second"],
        ids: ["test.duplicate", "test.duplicate"],
        error: /duplicate native capability id.*test\.duplicate/,
      },
      {
        name: "rejects duplicate command channels across registered leaves",
        channels: ["comma:test:duplicate", "comma:test:duplicate"],
        ids: ["test.first", "test.second"],
        error: /duplicate native capability channel.*comma:test:duplicate/,
      },
    ].map((row) => [row.name, row] as [string, typeof row])
  )("%s", (_name, { channels, ids, error }) => {
    expect(() =>
      collectNativeCapabilityEntries(`
        export const firstCapability = defineNativeCapability({
          bridge: { method: "first", namespace: "native" },
          channel: "${channels[0]}",
          handler: {
            exportName: "FirstProvider",
            member: "first",
            module: "../../../apps/electron/src/main/modules/native/index",
            provider: "first",
          },
          id: "${ids[0]}",
          input: z.void(),
          mock: {},
          output: testSchema,
          permission: "test.first",
          sessionAdmission: "required",
          webFallback: {},
        });

        export const secondCapability = defineNativeCapability({
          bridge: { method: "second", namespace: "native" },
          channel: "${channels[1]}",
          handler: {
            exportName: "SecondProvider",
            member: "second",
            module: "../../../apps/electron/src/main/modules/native/index",
            provider: "second",
          },
          id: "${ids[1]}",
          input: z.void(),
          mock: {},
          output: testSchema,
          permission: "test.second",
          sessionAdmission: "required",
          webFallback: {},
        });

        export const nativeCapabilityRegistry = [
          firstCapability,
          secondCapability,
        ] as const;
        export const nativeEventRegistry = [] as const;
      `)
    ).toThrow(error);
  });

  it("rejects event leaves that are not listed in the controlled registry", () => {
    expect(() =>
      collectNativeCapabilityEntries(`
        export const registeredEvent = defineNativeEvent({
          channel: "comma:test:registered",
          id: "test.registered",
          mock: {},
          payload: testSchema,
          target: { type: "all" },
        });

        export const orphanEvent = defineNativeEvent({
          channel: "comma:test:orphan",
          id: "test.orphan",
          mock: {},
          payload: testSchema,
          target: { type: "all" },
        });

        export const nativeCapabilityRegistry = [] as const;
        export const nativeEventRegistry = [registeredEvent] as const;
      `)
    ).toThrow(/orphanEvent.*nativeEventRegistry/);
  });

  it("rejects command leaves without permission metadata", () => {
    expect(() =>
      collectNativeCapabilityEntries(`
        export const missingPermissionCapability = defineNativeCapability({
          bridge: { method: "bad", namespace: "native" },
          channel: "comma:test:bad",
          handler: {
            exportName: "BadProvider",
            member: "bad",
            module: "./bad",
            provider: "bad",
          },
          id: "test.bad",
          input: z.void(),
          mock: {},
          output: testSchema,
          sessionAdmission: "required",
          webFallback: {},
        });
      `)
    ).toThrow(/missingPermissionCapability.*permission/);
  });

  it("requires exhaustive session admission metadata and local-only rationale", () => {
    expect(() =>
      collectNativeCapabilityEntries(`
        export const missingAdmissionCapability = defineNativeCapability({
          bridge: { method: "bad", namespace: "native" },
          channel: "comma:test:bad",
          handler: {
            exportName: "BadProvider",
            member: "bad",
            module: "./bad",
            provider: "bad",
          },
          id: "test.bad",
          input: z.void(),
          mock: {},
          output: testSchema,
          permission: "test.bad",
          webFallback: {},
        });
      `)
    ).toThrow(/missingAdmissionCapability.*sessionAdmission/);

    expect(() =>
      collectNativeCapabilityEntries(`
        export const invalidAdmissionCapability = defineNativeCapability({
          bridge: { method: "bad", namespace: "native" },
          channel: "comma:test:bad",
          handler: {
            exportName: "BadProvider",
            member: "bad",
            module: "./bad",
            provider: "bad",
          },
          id: "test.bad",
          input: z.void(),
          mock: {},
          output: testSchema,
          permission: "test.bad",
          sessionAdmission: "sometimes",
          webFallback: {},
        });
      `)
    ).toThrow(/unsupported sessionAdmission sometimes/);

    expect(() =>
      collectNativeCapabilityEntries(`
        export const localOnlyCapability = defineNativeCapability({
          bridge: { method: "local", namespace: "native" },
          channel: "comma:test:local",
          handler: {
            exportName: "LocalProvider",
            member: "local",
            module: "./local",
            provider: "local",
          },
          id: "test.local",
          input: z.void(),
          mock: {},
          output: testSchema,
          permission: "test.local",
          sessionAdmission: "local_only",
          webFallback: {},
        });
      `)
    ).toThrow(/local_only.*sessionAdmissionRationale/);
  });

  it("rejects command leaves without handler metadata", () => {
    expect(() =>
      collectNativeCapabilityEntries(`
        export const missingHandlerCapability = defineNativeCapability({
          bridge: { method: "bad", namespace: "native" },
          channel: "comma:test:bad",
          id: "test.bad",
          input: z.void(),
          mock: {},
          output: testSchema,
          permission: "test.bad",
          sessionAdmission: "required",
          webFallback: {},
        });
      `)
    ).toThrow(/missingHandlerCapability.*handler/);
  });

  it("renders generated renderer bridge assembly helpers from leaf metadata", async () => {
    const output = renderNativeCapabilityArtifacts({
      commands: [
        {
          bridge: { method: "info", namespace: "native" },
          channel: "comma:native:info",
          exportName: "nativeInfoCapability",
          generatedKey: "nativeInfo",
          handler: {
            exportName: "NativeInfoProvider",
            member: "info",
            module: "../../../apps/electron/src/main/modules/native/index",
            provider: "nativeInfo",
          },
          id: "native.info",
          inputKind: "void",
          payloadClass: "control",
          permission: "native.info.read",
          sessionAdmission: "required",
          transport: "ipc-rpc",
        },
        {
          bridge: { method: "open", namespace: "dialog" },
          channel: "comma:dialog:open",
          exportName: "dialogOpenCapability",
          generatedKey: "dialogOpen",
          handler: {
            exportName: "DialogProvider",
            member: "open",
            module: "../../../apps/electron/src/main/modules/native/index",
            provider: "dialog",
          },
          id: "dialog.open",
          inputKind: "optional",
          payloadClass: "control",
          permission: "dialog.open",
          sessionAdmission: "required",
          transport: "ipc-rpc",
        },
      ],
      events: [
        {
          bridge: { method: "onEvent", namespace: "notch" },
          channel: "comma:notch:event",
          exportName: "notchHostEvent",
          generatedKey: "notchHost",
          id: "notch.event",
          target: { type: "all" },
        },
      ],
      states: [],
    });

    const leaves = {
      nativeInfoCapability: {
        id: "native.info",
        contract: { id: "native.info" },
        mock: "mock-info",
        webFallback: "web-info",
      },
      dialogOpenCapability: {
        id: "dialog.open",
        contract: { id: "dialog.open" },
        mock: "mock-dialog",
        webFallback: "web-dialog",
      },
      notchHostEvent: { id: "notch.event" },
    };
    const generated = executeGenerated<{
      createGeneratedNativePreloadBridge: (helpers: unknown) => Bridge;
      createGeneratedNativeWebBridge: () => Bridge;
      createGeneratedNativeBridgeMock: (helpers: unknown) => Bridge;
      mergeGeneratedNativeBridgeOverrides: (
        bridge: Bridge,
        overrides: unknown
      ) => Bridge;
      generatedNativeMainBindings: unknown[];
      generatedNativeMainBindingsById: Record<string, unknown>;
    }>(output, { "../capability-leaves": leaves });
    const invoke = vi.fn(async (_contract: unknown, input: unknown) => input);
    const unsubscribe = vi.fn();
    const subscribe = vi.fn(() => unsubscribe);
    const bridge = generated.createGeneratedNativePreloadBridge({ invoke, subscribe });
    const request = { title: "Pick a file" };
    await bridge.dialog.open(request);
    expect(invoke).toHaveBeenLastCalledWith(
      leaves.dialogOpenCapability.contract,
      request
    );
    await bridge.native.info();
    expect(invoke).toHaveBeenLastCalledWith(
      leaves.nativeInfoCapability.contract,
      undefined
    );
    const listener = vi.fn();
    expect(bridge.notch.onEvent(listener)).toBe(unsubscribe);
    expect(subscribe).toHaveBeenCalledWith(leaves.notchHostEvent, listener);
    const web = generated.createGeneratedNativeWebBridge();
    await expect(web.native.info()).resolves.toBe("web-info");
    await expect(web.dialog.open(request)).resolves.toBe("web-dialog");
    const mock = generated.createGeneratedNativeBridgeMock({
      command: (handler: unknown) => handler,
      event: (handler: unknown) => handler,
    });
    await expect(mock.native.info()).resolves.toBe("mock-info");
    const override = vi.fn(async () => "override");
    const merged = generated.mergeGeneratedNativeBridgeOverrides(web, {
      native: { info: override },
    });
    await expect(merged.native.info()).resolves.toBe("override");
    await expect(merged.dialog.open(request)).resolves.toBe("web-dialog");
    expect(generated.generatedNativeMainBindings).toEqual(
      Object.values(generated.generatedNativeMainBindingsById)
    );
    expect(generated.generatedNativeMainBindings).toHaveLength(2);
  });
  it("renders state artifacts as get plus subscribe bindings", async () => {
    const output = renderNativeCapabilityArtifacts({
      commands: [
        {
          bridge: { method: "state", namespace: "surfaces" },
          channel: "comma:surfaces:state",
          exportName: "surfacesStateCapability",
          generatedKey: "surfacesState",
          handler: {
            exportName: "SurfaceListProvider",
            member: "state",
            module: "../../../apps/electron/src/main/modules/native/index",
            provider: "surfaces",
          },
          id: "surfaces.state",
          permission: "surfaces.state.read",
          sessionAdmission: "required",
          payloadClass: "control",
          transport: "ipc-rpc",
        },
      ],
      events: [
        {
          channel: "comma:surfaces:changed",
          exportName: "surfacesChangedEvent",
          generatedKey: "surfacesChanged",
          id: "surfaces.changed",
          target: { type: "all" },
        },
      ],
      states: [
        {
          bridge: { method: "state", namespace: "surfaces" },
          exportName: "surfacesStateLeaf",
          generatedKey: "surfacesState",
          getLeaf: "surfacesStateCapability",
          id: "surfaces.state",
          subscribeLeaf: "surfacesChangedEvent",
        },
      ],
    });

    const get = { id: "surfaces.state" };
    const event = { id: "surfaces.changed" };
    const generated = executeGenerated<{
      createGeneratedNativePreloadBridge: (helpers: unknown) => {
        surfaces: { state: unknown };
      };
      createGeneratedNativeWebBridge: () => {
        surfaces: {
          state: {
            get: () => Promise<unknown>;
            subscribe: (listener: (value: unknown) => void) => () => void;
          };
        };
      };
    }>(output, {
      "../capability-leaves": {
        surfacesStateCapability: { contract: get },
        surfacesChangedEvent: event,
        surfacesStateLeaf: { get, subscribe: event, webFallback: { visible: false } },
      },
    });
    const ownedState = { get: vi.fn(), subscribe: vi.fn() };
    const state = vi.fn(() => ownedState);
    expect(generated.createGeneratedNativePreloadBridge({ state }).surfaces.state).toBe(
      ownedState
    );
    expect(state).toHaveBeenCalledWith({ get, subscribe: event });
    const web = generated.createGeneratedNativeWebBridge().surfaces.state;
    await expect(web.get()).resolves.toEqual({ visible: false });
    const listener = vi.fn();
    const unsubscribe = web.subscribe(listener);
    await Promise.resolve();
    expect(listener).toHaveBeenCalledWith({ visible: false });
    unsubscribe();
  });
  it("forwards IPC input through generated main wrappers for non-void capabilities", async () => {
    const output = renderNativeCapabilityMainArtifacts(
      {
        commands: [
          {
            bridge: { method: "configure", namespace: "connector" },
            channel: "comma:connector:configure",
            exportName: "connectorConfigureCapability",
            generatedKey: "connectorConfigure",
            handler: {
              exportName: "ConnectorConfigureProvider",
              member: "configure",
              module: "../../../apps/electron/src/main/modules/native/index",
              provider: "connector",
            },
            id: "connector.configure",
            payloadClass: "control",
            permission: "connector.configure.write",
            sessionAdmission: "required",
            transport: "ipc-rpc",
          },
        ],
        events: [],
      },
      { handlerModuleSpecifier: () => "../modules/native/index" }
    );

    const contract = { id: "connector.configure" };
    const generated = executeGenerated<{
      registerGeneratedNativeMainBindings: (options: unknown) => void;
    }>(output, {
      "@comma/native-bridge": {
        generatedNativeMainBindings: [{ id: contract.id, contract }],
      },
    });
    const handlers = new Map<unknown, (input: unknown) => Promise<unknown>>();
    const configure = vi.fn(async (input: unknown) => ({ saved: input }));
    let admitted = true;
    const run = vi.fn(async ({ handler }: { handler: () => unknown }) => {
      if (!admitted) throw new Error("session rejected");
      return handler();
    });
    generated.registerGeneratedNativeMainBindings({
      gateway: {
        register: (key: unknown, handler: (input: unknown) => Promise<unknown>) =>
          handlers.set(key, handler),
      },
      providers: { connector: { configure } },
      sessionAdmissionGuard: { run },
    });
    const input = { workspace: "workspace-one" };
    await expect(handlers.get(contract)!(input)).resolves.toEqual({ saved: input });
    expect(configure).toHaveBeenCalledWith(input);
    expect(run).toHaveBeenCalledWith({
      contract,
      input,
      handler: expect.any(Function),
    });
    admitted = false;
    await expect(handlers.get(contract)!(input)).rejects.toThrow("session rejected");
    expect(configure).toHaveBeenCalledTimes(1);
  });
});

interface Bridge {
  native: { info: () => Promise<unknown> };
  dialog: { open: (input?: unknown) => Promise<unknown> };
  notch: { onEvent: (listener: () => void) => () => void };
}

function executeGenerated<T>(source: string, imports: Record<string, unknown>): T {
  const exports = {};
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    reportDiagnostics: true,
  });
  runInNewContext(outputText, {
    exports,
    require: (name: string) => {
      if (!(name in imports)) throw new Error(`Unexpected runtime import: ${name}`);
      return imports[name];
    },
  });
  return exports as T;
}
