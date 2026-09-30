import path from "node:path";
import ts from "typescript";

export function collectNativeCapabilityEntries(
  sourceText,
  sourceFileName = "capability-leaves.ts"
) {
  const sourceFile = ts.createSourceFile(
    sourceFileName,
    sourceText,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS
  );
  const commandLeaves = new Map();
  const eventLeaves = new Map();
  const stateLeaves = new Map();
  const inputSchemaKinds = collectInputSchemaKinds(sourceFile);
  let commandRegistryNames = null;
  let eventRegistryNames = null;
  let stateRegistryNames = null;

  for (const statement of sourceFile.statements) {
    if (!ts.isVariableStatement(statement) || !isExported(statement)) {
      continue;
    }

    for (const declaration of statement.declarationList.declarations) {
      if (!ts.isIdentifier(declaration.name) || !declaration.initializer) {
        continue;
      }

      const call = declaration.initializer;
      if (!ts.isCallExpression(call) || !ts.isIdentifier(call.expression)) {
        continue;
      }

      const object = call.arguments[0];
      if (!object || !ts.isObjectLiteralExpression(object)) {
        continue;
      }

      const exportName = declaration.name.text;
      if (call.expression.text === "defineNativeCapability") {
        const bridge = readRequiredObject(object, "bridge", exportName);
        const handler = readRequiredObject(object, "handler", exportName);
        const sessionAdmission = readRequiredNativeSessionAdmission(object, exportName);
        const sessionAdmissionRationale =
          readOptionalString(object, "sessionAdmissionRationale") ?? undefined;

        if (sessionAdmission === "local_only" && !sessionAdmissionRationale?.trim()) {
          throw new Error(
            `${exportName} uses local_only sessionAdmission and must declare a non-empty sessionAdmissionRationale.`
          );
        }

        if (
          sessionAdmission !== "local_only" &&
          sessionAdmissionRationale !== undefined
        ) {
          throw new Error(
            `${exportName} may declare sessionAdmissionRationale only with local_only sessionAdmission.`
          );
        }

        commandLeaves.set(exportName, {
          bridge: {
            method: readRequiredString(bridge, "method", exportName),
            namespace: readRequiredString(bridge, "namespace", exportName),
          },
          channel: readRequiredString(object, "channel", exportName),
          exportName,
          generatedKey: stripSuffix(exportName, "Capability"),
          handler: {
            exportName: readRequiredString(handler, "exportName", exportName),
            member: readRequiredString(handler, "member", exportName),
            module: readRequiredString(handler, "module", exportName),
            provider: readRequiredString(handler, "provider", exportName),
          },
          id: readRequiredString(object, "id", exportName),
          inputKind: readCommandInputKind(object, exportName, inputSchemaKinds),
          preloadTransform: readOptionalString(object, "preloadTransform") ?? undefined,
          payloadClass: readOptionalString(object, "payloadClass") ?? "control",
          permission: readRequiredString(object, "permission", exportName),
          sessionAdmission,
          ...(sessionAdmissionRationale ? { sessionAdmissionRationale } : {}),
          transport: readOptionalString(object, "transport") ?? "ipc-rpc",
        });
      }

      if (call.expression.text === "defineNativeEvent") {
        const permission = readOptionalString(object, "permission");
        const bridge = readOptionalObject(object, "bridge");
        eventLeaves.set(exportName, {
          ...(bridge
            ? {
                bridge: {
                  method: readRequiredString(bridge, "method", exportName),
                  namespace: readRequiredString(bridge, "namespace", exportName),
                },
              }
            : {}),
          channel: readRequiredString(object, "channel", exportName),
          exportName,
          generatedKey: stripSuffix(exportName, "Event"),
          id: readRequiredString(object, "id", exportName),
          ...(permission ? { permission } : {}),
          target: readRequiredNativeEventTarget(object, "target", exportName),
        });
      }

      if (call.expression.text === "defineNativeState") {
        const bridge = readRequiredObject(object, "bridge", exportName);
        stateLeaves.set(exportName, {
          bridge: {
            method: readRequiredString(bridge, "method", exportName),
            namespace: readRequiredString(bridge, "namespace", exportName),
          },
          exportName,
          generatedKey: stripSuffix(exportName, "Leaf"),
          getLeaf: readRequiredIdentifier(object, "get", exportName),
          id: readRequiredString(object, "id", exportName),
          subscribeLeaf: readRequiredIdentifier(object, "subscribe", exportName),
        });
      }
    }

    for (const declaration of statement.declarationList.declarations) {
      if (!ts.isIdentifier(declaration.name) || !declaration.initializer) {
        continue;
      }

      if (declaration.name.text === "nativeCapabilityRegistry") {
        commandRegistryNames = readIdentifierArray(
          declaration.initializer,
          "nativeCapabilityRegistry"
        );
      }

      if (declaration.name.text === "nativeEventRegistry") {
        eventRegistryNames = readIdentifierArray(
          declaration.initializer,
          "nativeEventRegistry"
        );
      }

      if (declaration.name.text === "nativeStateRegistry") {
        stateRegistryNames = readIdentifierArray(
          declaration.initializer,
          "nativeStateRegistry"
        );
      }
    }
  }

  const commands = resolveControlledRegistry({
    entries: commandLeaves,
    registryName: "nativeCapabilityRegistry",
    registryNames: commandRegistryNames,
  });
  const events = resolveControlledRegistry({
    entries: eventLeaves,
    registryName: "nativeEventRegistry",
    registryNames: eventRegistryNames,
  });
  const states = resolveControlledRegistry({
    entries: stateLeaves,
    registryName: "nativeStateRegistry",
    registryNames: stateRegistryNames,
  });
  assertStateReferences({ commands, events, states });
  assertUniqueValues({
    entries: commands,
    label: "native capability id",
    property: "id",
  });
  assertUniqueValues({
    entries: commands,
    label: "native capability channel",
    property: "channel",
  });

  return { commands, events, states };
}

export function renderNativeCapabilityArtifacts({ commands, events, states = [] }) {
  const importedNames = [...commands, ...events, ...states]
    .map((entry) => entry.exportName)
    .toSorted((left, right) => left.localeCompare(right));
  const commandContractEntries = commands
    .map((entry) => `  ${entry.generatedKey}: ${entry.exportName}.contract,`)
    .join("\n");
  const webFallbackEntries = commands
    .map((entry) => `  ${entry.generatedKey}: ${entry.exportName}.webFallback,`)
    .join("\n");
  const preloadBindingEntries = renderPreloadBindings(commands);
  const preloadEventBindingEntries = renderPreloadEventBindings(events);
  const stateBindingEntries = renderStateBindings(states);
  const mainBindingEntries = commands
    .map(
      (entry) => `  "${entry.id}": {
    contract: ${entry.exportName}.contract,
    id: ${entry.exportName}.id,
    method: "${entry.handler.member}",
    provider: "${entry.handler.provider}",
${renderSessionAdmissionMetadata(entry, "    ")}
  },`
    )
    .join("\n");
  const commandManifestEntries = commands
    .map(
      (entry) => `  {
    bridge: ${entry.exportName}.bridge,
    channel: ${entry.exportName}.channel,
    id: ${entry.exportName}.id,
    payloadClass: ${entry.exportName}.payloadClass,
    permission: ${entry.exportName}.permission,
${renderSessionAdmissionMetadata(entry, "    ")}
    transport: ${entry.exportName}.transport,
  },`
    )
    .join("\n");
  const eventManifestEntries = events
    .map(
      (entry) => `  {
    channel: ${entry.exportName}.channel,
    id: ${entry.exportName}.id,
    permission: ${entry.exportName}.permission,
    target: ${entry.exportName}.target,
  },`
    )
    .join("\n");
  const stateManifestEntries = states
    .map(
      (entry) => `  {
    bridge: ${entry.exportName}.bridge,
    get: {
      channel: ${entry.exportName}.get.channel,
      id: ${entry.exportName}.get.id,
      permission: ${entry.exportName}.get.permission,
      sessionAdmission: ${entry.exportName}.get.sessionAdmission,
      sessionAdmissionRationale: ${entry.exportName}.get.sessionAdmissionRationale,
    },
    id: ${entry.exportName}.id,
    subscribe: {
      channel: ${entry.exportName}.subscribe.channel,
      id: ${entry.exportName}.subscribe.id,
      permission: ${entry.exportName}.subscribe.permission,
      target: ${entry.exportName}.subscribe.target,
    },
  },`
    )
    .join("\n");
  const commandIndexEntries = commands
    .map(
      (entry) => `  "${entry.id}": {
    artifacts: {
      contract: "${entry.generatedKey}Contract",
      handlerType: 'NativeCapabilityHandlerTypeMap["${entry.id}"]',
      leaf: "${entry.exportName}",
      mainBinding: 'generatedNativeMainBindingsById["${entry.id}"]',
      mock: "${entry.exportName}.mock",
      preloadBinding: "generatedNativePreloadBindings.${entry.bridge.namespace}.${entry.bridge.method}",
      webFallback: "generatedNativeWebFallbacks.${entry.generatedKey}",
    },
    bridge: ${entry.exportName}.bridge,
    channel: ${entry.exportName}.channel,
    handler: ${entry.exportName}.handler,
    id: ${entry.exportName}.id,
    payloadClass: ${entry.exportName}.payloadClass,
    permission: ${entry.exportName}.permission,
${renderSessionAdmissionMetadata(entry, "    ")}
    transport: ${entry.exportName}.transport,
  },`
    )
    .join("\n");
  const eventIndexEntries = events
    .map(
      (entry) => `  "${entry.id}": {
    artifacts: {
      leaf: "${entry.exportName}",
      mock: "${entry.exportName}.mock",
    },
    channel: ${entry.exportName}.channel,
    id: ${entry.exportName}.id,
    permission: ${entry.exportName}.permission,
    target: ${entry.exportName}.target,
  },`
    )
    .join("\n");
  const stateIndexEntries = states
    .map(
      (entry) => `  "${entry.id}": {
    artifacts: {
      get: "generatedNativeStateBindings.${entry.bridge.namespace}.${entry.bridge.method}.get",
      leaf: "${entry.exportName}",
      mock: "${entry.exportName}.mock",
      subscribe: "generatedNativeStateBindings.${entry.bridge.namespace}.${entry.bridge.method}.subscribe",
      webFallback: "${entry.exportName}.webFallback",
    },
    bridge: ${entry.exportName}.bridge,
    get: {
      channel: ${entry.exportName}.get.channel,
      id: ${entry.exportName}.get.id,
      permission: ${entry.exportName}.get.permission,
      sessionAdmission: ${entry.exportName}.get.sessionAdmission,
      sessionAdmissionRationale: ${entry.exportName}.get.sessionAdmissionRationale,
    },
    id: ${entry.exportName}.id,
    subscribe: {
      channel: ${entry.exportName}.subscribe.channel,
      id: ${entry.exportName}.subscribe.id,
      permission: ${entry.exportName}.subscribe.permission,
      target: ${entry.exportName}.subscribe.target,
    },
  },`
    )
    .join("\n");
  const aliases = commands
    .map((entry) => renderContractAlias(entry.generatedKey))
    .join("\n");
  const commandTypeMapEntries = commands
    .map((entry) => `  "${entry.id}": typeof ${entry.exportName};`)
    .join("\n");
  const eventTypeMapEntries = events
    .map((entry) => `  "${entry.id}": typeof ${entry.exportName};`)
    .join("\n");
  const stateTypeMapEntries = states
    .map((entry) => `  "${entry.id}": typeof ${entry.exportName};`)
    .join("\n");
  const generatedBridgeTypeEntries = renderGeneratedBridgeTypeEntries({
    commands,
    events,
    states,
  });
  const generatedPreloadBridgeEntries = renderGeneratedPreloadBridgeEntries({
    commands,
    events,
    states,
  });
  const generatedWebBridgeEntries = renderGeneratedWebBridgeEntries({
    commands,
    events,
    states,
  });
  const generatedMockBridgeEntries = renderGeneratedMockBridgeEntries({
    commands,
    events,
    states,
  });
  const generatedMergeEntries = renderGeneratedBridgeMergeEntries({
    commands,
    events,
    states,
  });
  return `// Generated by clients/scripts/generate-native-capability-artifacts.mjs.
// Do not edit by hand.

import {
${importedNames.map((name) => `  ${name},`).join("\n")}
} from "../capability-leaves";
import type { z } from "zod";
import type {
  NativeCommandContract,
  NativeEventLeaf,
  NativeStateBridge,
  NativeStateLeaf,
} from "../capability-leaves";

export const generatedNativeCapabilityContracts = {
${commandContractEntries}
} as const;

export const generatedNativeWebFallbacks = {
${webFallbackEntries}
} as const;

export const generatedNativePreloadBindings = {
${preloadBindingEntries}
} as const;

export const generatedNativePreloadEventBindings = {
${preloadEventBindingEntries}
} as const;

export const generatedNativeStateBindings = {
${stateBindingEntries}
} as const;

export const generatedNativeMainBindingsById = {
${mainBindingEntries}
} as const;

export const generatedNativeMainBindings = Object.values(
  generatedNativeMainBindingsById
);

export const generatedNativeCapabilityManifest = [
${commandManifestEntries}
] as const;

export const generatedNativeEventManifest = [
${eventManifestEntries}
] as const;

export const generatedNativeStateManifest = [
${stateManifestEntries}
] as const;

export const generatedNativeCapabilityIndex = {
${commandIndexEntries}
} as const;

export const generatedNativeEventIndex = {
${eventIndexEntries}
} as const;

export const generatedNativeStateIndex = {
${stateIndexEntries}
} as const;

${aliases}

export type NativeCapabilityTypeMap = {
${commandTypeMapEntries}
};

export type NativeEventTypeMap = {
${eventTypeMapEntries}
};

export type NativeStateTypeMap = {
${stateTypeMapEntries}
};

// Infer command parameters independently through the contract. Darwin tsgo
// collapses required inputs to void when both leaf generics are inferred at once.
export type GeneratedNativeCommandInput<Leaf> =
  Leaf extends { preloadInput: z.ZodType<infer BridgeInput> }
    ? BridgeInput
    : Leaf extends { contract: NativeCommandContract<infer Input, unknown> }
      ? Input
      : never;

export type GeneratedNativeCommandTransportInput<Leaf> =
  Leaf extends { contract: NativeCommandContract<infer Input, unknown> }
    ? Input
    : never;

export type GeneratedNativeCommandOutput<Leaf> =
  Leaf extends { contract: NativeCommandContract<unknown, infer Output> }
    ? Output
    : never;

export type GeneratedNativeCommandBridgeMethod<Leaf> =
  [GeneratedNativeCommandInput<Leaf>] extends [void]
    ? () => Promise<GeneratedNativeCommandOutput<Leaf>>
    : undefined extends GeneratedNativeCommandInput<Leaf>
      ? (input?: GeneratedNativeCommandInput<Leaf>) =>
          Promise<GeneratedNativeCommandOutput<Leaf>>
      : (input: GeneratedNativeCommandInput<Leaf>) =>
          Promise<GeneratedNativeCommandOutput<Leaf>>;

export type GeneratedNativeEventBridgeMethod<Leaf> =
  Leaf extends NativeEventLeaf<infer Payload>
    ? (listener: (payload: Payload) => void) => () => void
    : never;

export type GeneratedNativeStateGetInput<Leaf> =
  Leaf extends NativeStateLeaf<unknown, infer GetInput> ? GetInput : never;

export type GeneratedNativeStateSnapshot<Leaf> =
  Leaf extends NativeStateLeaf<infer Snapshot, unknown> ? Snapshot : never;

export type GeneratedNativeStateBridgeMethod<Leaf> =
  Leaf extends NativeStateLeaf<infer Snapshot, infer GetInput>
    ? NativeStateBridge<Snapshot, GetInput>
    : never;

export type GeneratedNativeBridge = {
${generatedBridgeTypeEntries}
};

export type GeneratedNativeBridgeOverrides = {
  [Namespace in keyof GeneratedNativeBridge]?: Partial<GeneratedNativeBridge[Namespace]>;
};

export interface GeneratedNativePreloadBridgeHelpers {
  prepareChatAttachments<Input, Output>(
    contract: NativeCommandContract<Input, Output>,
    input: unknown
  ): Promise<Output>;
  invoke<Input, Output>(
    contract: NativeCommandContract<Input, Output>,
    input: Input
  ): Promise<Output>;
  state<GetInput, Snapshot>(binding: {
    get: NativeCommandContract<GetInput, Snapshot>;
    subscribe: NativeEventLeaf<Snapshot>;
  }): NativeStateBridge<Snapshot, GetInput>;
  subscribe<Payload>(
    event: NativeEventLeaf<Payload>,
    listener: (payload: Payload) => void
  ): () => void;
  importLocalFile<Output>(
    contract: NativeCommandContract<
      { path: string; sourcePath: string; space: string },
      Output
    >,
    input: { path: string; source: unknown; space: string }
  ): Promise<Output>;
}

export interface GeneratedNativeBridgeMockHelpers {
  command<Args extends unknown[], Output>(
    implementation: (...args: Args) => Promise<Output>
  ): (...args: Args) => Promise<Output>;
  event<Payload>(
    implementation: (listener: (payload: Payload) => void) => () => void
  ): (listener: (payload: Payload) => void) => () => void;
  state<GetInput, Snapshot>(
    getSnapshot: (input: GetInput) => Snapshot
  ): NativeStateBridge<Snapshot, GetInput>;
}

export function createGeneratedNativePreloadBridge(
  helpers: GeneratedNativePreloadBridgeHelpers
): GeneratedNativeBridge {
  return {
${generatedPreloadBridgeEntries}
  };
}

export function createGeneratedNativeWebBridge(): GeneratedNativeBridge {
  return {
${generatedWebBridgeEntries}
  };
}

export function createGeneratedNativeBridgeMock(
  helpers: GeneratedNativeBridgeMockHelpers
): GeneratedNativeBridge {
  return {
${generatedMockBridgeEntries}
  };
}

export function mergeGeneratedNativeBridgeOverrides(
  bridge: GeneratedNativeBridge,
  overrides: GeneratedNativeBridgeOverrides = {}
): GeneratedNativeBridge {
  return {
${generatedMergeEntries}
  };
}

function createGeneratedWebStateBridge<Snapshot, GetInput>(
  getSnapshot: (input: GetInput) => Snapshot
): NativeStateBridge<Snapshot, GetInput> {
  const get = async (input: GetInput) => getSnapshot(input);
  const bridge = Object.assign(get, {
    get,
    subscribe(listener: (snapshot: Snapshot) => void, replayInput: GetInput) {
      void get(replayInput).then(listener);
      return () => {};
    },
  });

  return bridge as NativeStateBridge<Snapshot, GetInput>;
}
`;
}

function renderContractAlias(generatedKey) {
  const oneLine = `export const ${generatedKey}Contract = generatedNativeCapabilityContracts.${generatedKey};`;

  if (oneLine.length <= 88) {
    return oneLine;
  }

  return `export const ${generatedKey}Contract =
  generatedNativeCapabilityContracts.${generatedKey};`;
}

function renderSessionAdmissionMetadata(entry, indentation) {
  return [
    `${indentation}sessionAdmission: ${entry.exportName}.sessionAdmission,`,
    ...(entry.sessionAdmissionRationale
      ? [
          `${indentation}sessionAdmissionRationale: ${entry.exportName}.sessionAdmissionRationale,`,
        ]
      : []),
  ].join("\n");
}

function renderGeneratedBridgeTypeEntries({ commands, events, states }) {
  return renderGeneratedBridgeNamespaces({
    commands,
    events,
    states,
    renderCommand: (entry) =>
      `${entry.bridge.method}: GeneratedNativeCommandBridgeMethod<typeof ${entry.exportName}>;`,
    renderEvent: (entry) =>
      `${entry.bridge.method}: GeneratedNativeEventBridgeMethod<typeof ${entry.exportName}>;`,
    renderState: (entry) =>
      `${entry.bridge.method}: GeneratedNativeStateBridgeMethod<typeof ${entry.exportName}>;`,
    terminator: "",
  });
}

function renderGeneratedPreloadBridgeEntries({ commands, events, states }) {
  return renderGeneratedBridgeNamespaces({
    commands,
    events,
    states,
    renderCommand: (entry) => {
      const inputType = `GeneratedNativeCommandInput<typeof ${entry.exportName}>`;
      const invocation =
        entry.preloadTransform === "file-path-from-file"
          ? `helpers.importLocalFile(${entry.exportName}.contract`
          : entry.preloadTransform === "chat-attachment-files"
            ? `helpers.prepareChatAttachments(${entry.exportName}.contract`
            : `helpers.invoke(${entry.exportName}.contract`;

      if (isVoidCommand(entry)) {
        return `${entry.bridge.method}: () => ${invocation}, undefined)`;
      }

      if (isOptionalCommand(entry)) {
        return `${entry.bridge.method}: (input?: ${inputType}) => ${invocation}, input)`;
      }

      return `${entry.bridge.method}: (input: ${inputType}) => ${invocation}, input)`;
    },
    renderEvent: (entry) =>
      `${entry.bridge.method}: (listener) => helpers.subscribe(${entry.exportName}, listener)`,
    renderState: (entry) =>
      `${entry.bridge.method}: helpers.state({
      get: ${entry.getLeaf}.contract,
      subscribe: ${entry.subscribeLeaf},
    })`,
    terminator: ",",
  });
}

function renderGeneratedWebBridgeEntries({ commands, events, states }) {
  return renderGeneratedBridgeNamespaces({
    commands,
    events,
    states,
    renderCommand: (entry) => {
      const inputType = `GeneratedNativeCommandInput<typeof ${entry.exportName}>`;

      if (isVoidCommand(entry)) {
        return `${entry.bridge.method}: async () => ${entry.exportName}.webFallback`;
      }

      if (isOptionalCommand(entry)) {
        return `${entry.bridge.method}: async (_input?: ${inputType}) => ${entry.exportName}.webFallback`;
      }

      return `${entry.bridge.method}: async (_input: ${inputType}) => ${entry.exportName}.webFallback`;
    },
    renderEvent: (entry) => `${entry.bridge.method}: () => () => {}`,
    renderState: (entry) =>
      `${entry.bridge.method}: createGeneratedWebStateBridge<
      GeneratedNativeStateSnapshot<typeof ${entry.exportName}>,
      GeneratedNativeStateGetInput<typeof ${entry.exportName}>
    >(
      (_input) => ${entry.exportName}.webFallback
    )`,
    terminator: ",",
  });
}

function renderGeneratedMockBridgeEntries({ commands, events, states }) {
  return renderGeneratedBridgeNamespaces({
    commands,
    events,
    states,
    renderCommand: (entry) => {
      const inputType = `GeneratedNativeCommandInput<typeof ${entry.exportName}>`;

      if (isVoidCommand(entry)) {
        return `${entry.bridge.method}: helpers.command(async () => ${entry.exportName}.mock)`;
      }

      if (isOptionalCommand(entry)) {
        return `${entry.bridge.method}: helpers.command(
      async (_input?: ${inputType}) => ${entry.exportName}.mock
    )`;
      }

      return `${entry.bridge.method}: helpers.command(
      async (_input: ${inputType}) => ${entry.exportName}.mock
    )`;
    },
    renderEvent: (entry) =>
      `${entry.bridge.method}: helpers.event((_listener) => () => {})`,
    renderState: (entry) =>
      `${entry.bridge.method}: helpers.state(
      (_input: GeneratedNativeStateGetInput<typeof ${entry.exportName}>) =>
        ${entry.exportName}.mock
    )`,
    terminator: ",",
  });
}

function renderGeneratedBridgeMergeEntries({ commands, events, states }) {
  return getGeneratedBridgeNamespaces({ commands, events, states })
    .map(
      (namespace) => `    ${namespace}: {
      ...bridge.${namespace},
      ...overrides.${namespace},
    },`
    )
    .join("\n");
}

function renderGeneratedBridgeNamespaces({
  commands,
  events,
  states,
  renderCommand,
  renderEvent,
  renderState,
  terminator,
}) {
  const namespaces = new Map();
  const stateCommandIds = new Set(states.map((state) => state.id));

  for (const command of commands) {
    if (stateCommandIds.has(command.id)) {
      continue;
    }

    addGeneratedBridgeNamespaceEntry({
      namespaces,
      namespace: command.bridge.namespace,
      rendered: renderCommand(command),
    });
  }

  for (const state of states) {
    addGeneratedBridgeNamespaceEntry({
      namespaces,
      namespace: state.bridge.namespace,
      rendered: renderState(state),
    });
  }

  for (const event of events) {
    if (!event.bridge) {
      continue;
    }

    addGeneratedBridgeNamespaceEntry({
      namespaces,
      namespace: event.bridge.namespace,
      rendered: renderEvent(event),
    });
  }

  return [...namespaces.entries()]
    .map(([namespace, entries]) => {
      const renderedEntries = entries
        .map((entry) => `    ${entry}${terminator}`)
        .join("\n");

      return `  ${namespace}: {
${renderedEntries}
  },`;
    })
    .join("\n");
}

function getGeneratedBridgeNamespaces({ commands, events, states }) {
  const namespaces = new Set();
  const stateCommandIds = new Set(states.map((state) => state.id));

  for (const command of commands) {
    if (!stateCommandIds.has(command.id)) {
      namespaces.add(command.bridge.namespace);
    }
  }
  for (const state of states) {
    namespaces.add(state.bridge.namespace);
  }
  for (const event of events) {
    if (event.bridge) {
      namespaces.add(event.bridge.namespace);
    }
  }

  return [...namespaces];
}

function addGeneratedBridgeNamespaceEntry({ namespaces, namespace, rendered }) {
  const entries = namespaces.get(namespace) ?? [];
  entries.push(rendered);
  namespaces.set(namespace, entries);
}

function isVoidCommand(entry) {
  return entry.inputKind === "void";
}

function isOptionalCommand(entry) {
  return entry.inputKind === "optional";
}

export function renderNativeCapabilityMainArtifacts(
  { commands },
  { handlerModuleSpecifier = (moduleSpecifier) => moduleSpecifier } = {}
) {
  const handlerImports = renderHandlerImports(commands, handlerModuleSpecifier);
  const providerMapEntries = renderProviderMapEntries(commands);
  const handlerTypeMapEntries = commands
    .map(
      (entry) =>
        `  "${entry.id}": ${entry.handler.exportName}["${entry.handler.member}"];`
    )
    .join("\n");
  const handlerEntries = commands
    .map(
      (entry) =>
        `    "${entry.id}": async (input) => providers.${entry.handler.provider}.${entry.handler.member}(input),`
    )
    .join("\n");

  return `// Generated by clients/scripts/generate-native-capability-artifacts.mjs.
// Do not edit by hand.

import { generatedNativeMainBindings } from "@comma/native-bridge";
import type { NativeCommandContract } from "@comma/native-bridge";
${handlerImports}

interface NativeGatewayLike {
  register<Input, Output>(
    contract: NativeCommandContract<Input, Output>,
    handler: (input: Input) => Promise<Output> | Output
  ): void;
}

export interface NativeSessionAdmissionGuard {
  run<Input, Output>(args: {
    contract: NativeCommandContract<Input, Output>;
    handler: () => Promise<Output> | Output;
    input: Input;
  }): Promise<Output> | Output;
}

export type NativeCapabilityProviderMap = {
${providerMapEntries}
};

export type NativeCapabilityHandlerTypeMap = {
${handlerTypeMapEntries}
};

type NativeCapabilityHandlerMap = {
  [Id in keyof NativeCapabilityHandlerTypeMap]: (
    input: Parameters<NativeCapabilityHandlerTypeMap[Id]>[0]
  ) => Promise<Awaited<ReturnType<NativeCapabilityHandlerTypeMap[Id]>>>;
};

export function registerGeneratedNativeMainBindings({
  gateway,
  providers,
  sessionAdmissionGuard,
}: {
  gateway: NativeGatewayLike;
  providers: NativeCapabilityProviderMap;
  sessionAdmissionGuard: NativeSessionAdmissionGuard;
}) {
  const handlers: NativeCapabilityHandlerMap = {
${handlerEntries}
  };

  for (const binding of generatedNativeMainBindings) {
    const handler = handlers[binding.id as keyof NativeCapabilityHandlerMap] as (
      input: unknown
    ) => unknown;
    const contract = binding.contract as NativeCommandContract<unknown, unknown>;

    gateway.register(contract, (input) =>
      sessionAdmissionGuard.run({
        contract,
        handler: () => handler(input),
        input,
      })
    );
  }
}
`;
}

function renderProviderMapEntries(commands) {
  const providerTypes = new Map();

  for (const command of commands) {
    const existingType = providerTypes.get(command.handler.provider);
    if (existingType && existingType !== command.handler.exportName) {
      throw new Error(
        `${command.handler.provider} maps to both ${existingType} and ${command.handler.exportName}.`
      );
    }

    providerTypes.set(command.handler.provider, command.handler.exportName);
  }

  return [...providerTypes.entries()]
    .map(([provider, exportName]) => `  ${provider}: ${exportName};`)
    .join("\n");
}

function renderPreloadBindings(commands) {
  const namespaces = new Map();

  for (const command of commands) {
    const namespaceEntries = namespaces.get(command.bridge.namespace) ?? [];
    namespaceEntries.push(command);
    namespaces.set(command.bridge.namespace, namespaceEntries);
  }

  return [...namespaces.entries()]
    .map(([namespace, entries]) => {
      const methods = entries
        .map((entry) => `    ${entry.bridge.method}: ${entry.exportName}.contract,`)
        .join("\n");

      return `  ${namespace}: {
${methods}
  },`;
    })
    .join("\n");
}

function renderPreloadEventBindings(events) {
  const namespaces = new Map();

  for (const event of events) {
    const [namespace, method] = event.id.split(".");

    if (!namespace || !method) {
      throw new Error(`${event.exportName} event id must be namespace.method.`);
    }

    const namespaceEntries = namespaces.get(namespace) ?? [];
    namespaceEntries.push({ ...event, method });
    namespaces.set(namespace, namespaceEntries);
  }

  return [...namespaces.entries()]
    .map(([namespace, entries]) => {
      const methods = entries
        .map((entry) => `    ${entry.method}: ${entry.exportName},`)
        .join("\n");

      return `  ${namespace}: {
${methods}
  },`;
    })
    .join("\n");
}

function renderStateBindings(states) {
  const namespaces = new Map();

  for (const state of states) {
    const namespaceEntries = namespaces.get(state.bridge.namespace) ?? [];
    namespaceEntries.push(state);
    namespaces.set(state.bridge.namespace, namespaceEntries);
  }

  return [...namespaces.entries()]
    .map(([namespace, entries]) => {
      const methods = entries
        .map(
          (entry) => `    ${entry.bridge.method}: {
      get: ${entry.getLeaf}.contract,
      subscribe: ${entry.subscribeLeaf},
    },`
        )
        .join("\n");

      return `  ${namespace}: {
${methods}
  },`;
    })
    .join("\n");
}

function renderHandlerImports(commands, handlerModuleSpecifier) {
  const byModule = new Map();

  for (const command of commands) {
    const moduleSpecifier = handlerModuleSpecifier(command.handler.module);
    const names = byModule.get(moduleSpecifier) ?? new Set();
    names.add(command.handler.exportName);
    byModule.set(moduleSpecifier, names);
  }

  return [...byModule.entries()]
    .map(([module, names]) => renderTypeImport([...names].toSorted(), module))
    .join("\n");
}

function renderTypeImport(names, moduleSpecifier) {
  if (names.length === 1) {
    return `import type { ${names[0]} } from "${moduleSpecifier}";`;
  }

  return `import type {
${names.map((name) => `  ${name},`).join("\n")}
} from "${moduleSpecifier}";`;
}

export function createRelativeImportSpecifierResolver({ outputFile, sourceFile }) {
  const outputDirectory = path.dirname(outputFile);
  const sourceDirectory = path.dirname(sourceFile);

  return function resolveImportSpecifier(moduleSpecifier) {
    if (!moduleSpecifier.startsWith(".")) {
      return moduleSpecifier;
    }

    const absoluteModulePath = path.resolve(sourceDirectory, moduleSpecifier);
    let relativeSpecifier = path
      .relative(outputDirectory, absoluteModulePath)
      .split(path.sep)
      .join("/");

    if (!relativeSpecifier.startsWith(".")) {
      relativeSpecifier = `./${relativeSpecifier}`;
    }

    return relativeSpecifier;
  };
}

function isExported(statement) {
  return Boolean(
    statement.modifiers?.some(
      (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword
    )
  );
}

function readRequiredObject(object, propertyName, exportName) {
  const property = findProperty(object, propertyName);

  if (!property || !ts.isObjectLiteralExpression(property.initializer)) {
    throw new Error(`${exportName} is missing object property ${propertyName}.`);
  }

  return property.initializer;
}

function readRequiredString(object, propertyName, exportName) {
  const property = findProperty(object, propertyName);

  if (!property || !ts.isStringLiteral(property.initializer)) {
    throw new Error(`${exportName} is missing string property ${propertyName}.`);
  }

  return property.initializer.text;
}

function readRequiredNativeSessionAdmission(object, exportName) {
  const value = readRequiredString(object, "sessionAdmission", exportName);

  if (!["lifecycle", "required", "local_only"].includes(value)) {
    throw new Error(
      `${exportName} has unsupported sessionAdmission ${value}; expected lifecycle, required, or local_only.`
    );
  }

  return value;
}

function readRequiredNativeEventTarget(object, propertyName, exportName) {
  const property = findProperty(object, propertyName);

  if (!property || !ts.isObjectLiteralExpression(property.initializer)) {
    throw new Error(`${exportName} is missing event target selector ${propertyName}.`);
  }

  const target = property.initializer;
  const type = readRequiredString(target, "type", exportName);

  if (type === "all") {
    return { type };
  }

  if (type === "role") {
    return { role: readRequiredString(target, "role", exportName), type };
  }

  if (type === "view") {
    return { type, viewId: readRequiredString(target, "viewId", exportName) };
  }

  if (type === "window") {
    return { type, windowId: readRequiredString(target, "windowId", exportName) };
  }

  throw new Error(`${exportName} has unsupported event target type ${type}.`);
}

function readRequiredIdentifier(object, propertyName, exportName) {
  const property = findProperty(object, propertyName);

  if (!property || !ts.isIdentifier(property.initializer)) {
    throw new Error(`${exportName} is missing identifier property ${propertyName}.`);
  }

  return property.initializer.text;
}

function readCommandInputKind(object, exportName, inputSchemaKinds) {
  const property = findProperty(object, "input");

  if (!property) {
    throw new Error(`${exportName} is missing input.`);
  }

  return readInputExpressionKind(property.initializer, inputSchemaKinds);
}

function collectInputSchemaKinds(sourceFile) {
  const inputSchemaKinds = new Map();

  for (const statement of sourceFile.statements) {
    if (!ts.isVariableStatement(statement)) {
      continue;
    }

    for (const declaration of statement.declarationList.declarations) {
      if (!ts.isIdentifier(declaration.name) || !declaration.initializer) {
        continue;
      }

      inputSchemaKinds.set(
        declaration.name.text,
        readInputExpressionKind(declaration.initializer, inputSchemaKinds)
      );
    }
  }

  return inputSchemaKinds;
}

function readInputExpressionKind(expression, inputSchemaKinds) {
  const unwrapped = unwrapExpression(expression);

  if (isZVoidCall(unwrapped)) {
    return "void";
  }

  if (isOptionalCall(unwrapped)) {
    return "optional";
  }

  if (ts.isIdentifier(unwrapped)) {
    return inputSchemaKinds.get(unwrapped.text) ?? "required";
  }

  return "required";
}

function isZVoidCall(expression) {
  return (
    ts.isCallExpression(expression) &&
    ts.isPropertyAccessExpression(expression.expression) &&
    expression.expression.name.text === "void" &&
    ts.isIdentifier(expression.expression.expression) &&
    expression.expression.expression.text === "z"
  );
}

function isOptionalCall(expression) {
  return (
    ts.isCallExpression(expression) &&
    ts.isPropertyAccessExpression(expression.expression) &&
    expression.expression.name.text === "optional"
  );
}

function readOptionalObject(object, propertyName) {
  const property = findProperty(object, propertyName);

  if (!property || !ts.isObjectLiteralExpression(property.initializer)) {
    return null;
  }

  return property.initializer;
}

function readOptionalString(object, propertyName) {
  const property = findProperty(object, propertyName);

  if (!property || !ts.isStringLiteral(property.initializer)) {
    return null;
  }

  return property.initializer.text;
}

function findProperty(object, propertyName) {
  return object.properties.find(
    (property) =>
      ts.isPropertyAssignment(property) &&
      ts.isIdentifier(property.name) &&
      property.name.text === propertyName
  );
}

function readIdentifierArray(initializer, registryName) {
  const expression = unwrapExpression(initializer);

  if (!ts.isArrayLiteralExpression(expression)) {
    throw new Error(`${registryName} must be an array of leaf identifiers.`);
  }

  return expression.elements.map((element) => {
    const unwrappedElement = unwrapExpression(element);

    if (!ts.isIdentifier(unwrappedElement)) {
      throw new Error(`${registryName} must contain only leaf identifiers.`);
    }

    return unwrappedElement.text;
  });
}

function unwrapExpression(expression) {
  let current = expression;

  while (
    ts.isAsExpression(current) ||
    ts.isSatisfiesExpression(current) ||
    ts.isParenthesizedExpression(current)
  ) {
    current = current.expression;
  }

  return current;
}

function resolveControlledRegistry({ entries, registryName, registryNames }) {
  if (entries.size === 0 && registryNames === null) {
    return [];
  }

  if (registryNames === null) {
    throw new Error(`${registryName} is missing.`);
  }

  const registeredNames = new Set(registryNames);
  const unregisteredNames = [...entries.keys()].filter(
    (entryName) => !registeredNames.has(entryName)
  );

  if (unregisteredNames.length > 0) {
    throw new Error(
      `${unregisteredNames.join(", ")} must be listed in ${registryName}.`
    );
  }

  return registryNames.map((entryName) => {
    const entry = entries.get(entryName);

    if (!entry) {
      throw new Error(`${registryName} references unknown leaf ${entryName}.`);
    }

    return entry;
  });
}

function assertUniqueValues({ entries, label, property }) {
  const firstEntryByValue = new Map();

  for (const entry of entries) {
    const value = entry[property];
    const firstEntry = firstEntryByValue.get(value);

    if (firstEntry) {
      throw new Error(
        `duplicate ${label} ${value}: ${firstEntry.exportName} and ${entry.exportName}.`
      );
    }

    firstEntryByValue.set(value, entry);
  }
}

function assertStateReferences({ commands, events, states }) {
  const commandNames = new Set(commands.map((entry) => entry.exportName));
  const eventNames = new Set(events.map((entry) => entry.exportName));

  for (const state of states) {
    if (!commandNames.has(state.getLeaf)) {
      throw new Error(
        `${state.exportName} references unknown get leaf ${state.getLeaf}.`
      );
    }

    if (!eventNames.has(state.subscribeLeaf)) {
      throw new Error(
        `${state.exportName} references unknown subscribe leaf ${state.subscribeLeaf}.`
      );
    }
  }
}

function stripSuffix(value, suffix) {
  return value.endsWith(suffix) ? value.slice(0, -suffix.length) : value;
}
