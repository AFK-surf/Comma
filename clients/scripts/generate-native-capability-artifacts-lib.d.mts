export interface NativeCapabilityGeneratorCommand {
  bridge: {
    method: string;
    namespace: string;
  };
  channel: string;
  exportName: string;
  generatedKey: string;
  handler: {
    exportName: string;
    member: string;
    module: string;
    provider: string;
  };
  id: string;
  inputKind?: "required" | "optional" | "void";
  payloadClass: string;
  permission: string;
  sessionAdmission: "lifecycle" | "required" | "local_only";
  sessionAdmissionRationale?: string;
  transport: string;
}

export interface NativeCapabilityGeneratorEvent {
  bridge?: {
    method: string;
    namespace: string;
  };
  channel: string;
  exportName: string;
  generatedKey: string;
  id: string;
  target:
    | { type: "all" }
    | { type: "role"; role: string }
    | { type: "view"; viewId: string }
    | { type: "window"; windowId: string };
}

export interface NativeCapabilityGeneratorState {
  bridge: {
    method: string;
    namespace: string;
  };
  exportName: string;
  generatedKey: string;
  getLeaf: string;
  id: string;
  subscribeLeaf: string;
}

export interface NativeCapabilityGeneratorEntries {
  commands: NativeCapabilityGeneratorCommand[];
  events: NativeCapabilityGeneratorEvent[];
  states?: NativeCapabilityGeneratorState[];
}

export function collectNativeCapabilityEntries(
  sourceText: string,
  sourceFileName?: string
): NativeCapabilityGeneratorEntries;

export function renderNativeCapabilityArtifacts(
  entries: NativeCapabilityGeneratorEntries
): string;

export function renderNativeCapabilityMainArtifacts(
  entries: NativeCapabilityGeneratorEntries,
  options?: {
    handlerModuleSpecifier?: (moduleSpecifier: string) => string;
  }
): string;

export function createRelativeImportSpecifierResolver(options: {
  outputFile: string;
  sourceFile: string;
}): (moduleSpecifier: string) => string;
