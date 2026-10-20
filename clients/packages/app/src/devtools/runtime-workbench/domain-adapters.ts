import {
  generatedNativeCapabilityManifest,
  getNativeBridge,
  type NativeTransportStatus,
  type SurfaceList,
} from "@comma/native-bridge";
import type { WorkbenchControlDescriptor } from "./control-descriptors";

export type WorkbenchTabId = "runtime" | "session" | "notch" | "windows" | "transport";

export interface WorkbenchSnapshot {
  nativeInfo?: unknown;
  session?: unknown;
  surfaces?: SurfaceList | undefined;
  transport?: NativeTransportStatus | undefined;
}

export interface WorkbenchTabModel {
  id: WorkbenchTabId;
  label: string;
  status: "ready" | "partial" | "planned" | "fail";
  proves: string;
  flows: readonly WorkbenchFlowModel[];
  controls: readonly WorkbenchControlDescriptor[];
}

export type WorkbenchFlowStatus = "ready" | "partial" | "disabled" | "fail";

export interface WorkbenchFlowModel {
  id: string;
  label: string;
  status: WorkbenchFlowStatus;
  evidenceLabel: string;
  traceIdSource: string;
  steps: readonly WorkbenchFlowStepModel[];
}

export interface WorkbenchFlowStepModel {
  id: string;
  label: string;
  source: string;
  target: string;
  observes: string;
  status: WorkbenchFlowStatus;
  traceIdSource: string;
}

export async function loadRuntimeSnapshot(): Promise<WorkbenchSnapshot> {
  const bridge = getNativeBridge();
  const [nativeInfo, surfaces, session, transport] = await Promise.all([
    bridge.native.info(),
    // Electron's contextBridge preserves the callable state snapshot function,
    // while properties attached to that function are not guaranteed to cross
    // the isolated-world boundary. Use the state leaf's callable snapshot form
    // here, matching the session consumer below.
    bridge.surfaces.state(),
    bridge.session.state(),
    bridge.transport.status(),
  ]);

  return {
    nativeInfo,
    session,
    surfaces,
    transport,
  };
}

export function buildWorkbenchTabs(snapshot: WorkbenchSnapshot): WorkbenchTabModel[] {
  return [
    runtimeTab(snapshot),
    sessionTab(snapshot),
    notchTab(),
    windowsTab(snapshot.surfaces),
    transportTab(snapshot),
  ] satisfies WorkbenchTabModel[];
}

function runtimeTab(snapshot: WorkbenchSnapshot) {
  return {
    controls: [
      {
        evidenceLabel: "native.info",
        id: "runtime-native-info",
        kind: "json",
        label: "native.info",
        status: "ready",
        value: snapshot.nativeInfo ?? {},
      },
      {
        evidenceLabel: "capability.manifest",
        id: "runtime-capabilities",
        kind: "monitor",
        label: "Capabilities",
        status: "ready",
        value: generatedNativeCapabilityManifest.length,
      },
    ],
    id: "runtime",
    label: "Runtime",
    proves: "The workbench is running against the real public native bridge.",
    flows: [
      {
        evidenceLabel: "native.info",
        id: "runtime-capability-rpc",
        label: "Runtime Capability RPC",
        status: snapshot.nativeInfo ? "ready" : "disabled",
        steps: [
          flowStep({
            id: "native-info-rpc",
            label: "native.info",
            observes: snapshot.nativeInfo ? "native bridge resolved" : "waiting",
            source: "renderer",
            status: snapshot.nativeInfo ? "ready" : "disabled",
            target: "NativeInfoService",
            traceIdSource: "NativeObservationEvent.trace.id for native.info",
          }),
        ],
        traceIdSource: "NativeObservationEvent.trace.id for native.info",
      },
    ],
    status: "ready",
  } satisfies WorkbenchTabModel;
}

function sessionTab(snapshot: WorkbenchSnapshot) {
  return {
    controls: [
      {
        evidenceLabel: "session.state",
        id: "session-state",
        kind: "json",
        label: "session.state",
        status: "ready",
        value: snapshot.session ?? {},
      },
    ],
    id: "session",
    label: "Session",
    proves:
      "Renderer sees only the generated Session projection; raw credentials and product proxy admission remain Main-owned.",
    flows: [
      {
        evidenceLabel: "session.state",
        id: "session-state-flow",
        label: "Session State",
        status: snapshot.session ? "ready" : "disabled",
        steps: [
          flowStep({
            id: "session-state",
            label: "session.state",
            observes: snapshot.session ? "typed state only" : "waiting",
            source: "renderer",
            status: snapshot.session ? "ready" : "disabled",
            target: "SecureSessionStore",
            traceIdSource: "NativeObservationEvent.trace.id for session.state",
          }),
        ],
        traceIdSource: "NativeObservationEvent.trace.id for session.state",
      },
    ],
    status: "ready",
  } satisfies WorkbenchTabModel;
}

function notchTab() {
  return {
    controls: [
      ...(
        ["status", "show", "hide", "open", "close", "toggle", "pulse", "stop"] as const
      ).map((method) => ({
        action: () => getNativeBridge().notch[method](),
        evidenceLabel: `notch.${method}`,
        id: `notch-${method}`,
        kind: "button" as const,
        label: `notch.${method}`,
        status: "ready" as const,
      })),
      {
        // notch.update needs a NotchScenePayload; the workbench has no scene
        // editor, so keep it needs-capability rather than firing an empty
        // command that would look live without doing anything.
        evidenceLabel: "notch.update",
        id: "notch-update",
        kind: "button" as const,
        label: "notch.update",
        status: "needs-capability" as const,
      },
    ],
    id: "notch",
    label: "Native: Notch",
    proves:
      "Notch commands use generated preload, IpcGateway, NotchService, and NativeEventBus.",
    flows: [
      {
        evidenceLabel: "notch.*",
        id: "notch-native-command",
        label: "Notch Native Command",
        status: "ready",
        steps: [
          flowStep({
            id: "notch-command",
            label: "notch.*",
            observes: "status + 7 no-arg actions (update needs a scene payload)",
            source: "renderer",
            status: "ready",
            target: "NotchService -> NotchHost",
            traceIdSource: "NativeObservationEvent.trace.id for notch.*",
          }),
        ],
        traceIdSource: "NativeObservationEvent.trace.id for notch.*",
      },
      {
        evidenceLabel: "notch.event",
        id: "notch-native-event",
        label: "Notch Native Event",
        status: "ready",
        steps: [
          flowStep({
            id: "notch-event",
            label: "notch.event",
            observes: "host events fan out through NativeEventBus",
            source: "NotchHost",
            status: "ready",
            target: "renderer subscribers",
            traceIdSource: "NativeObservationEvent.trace.id for notch.event",
          }),
        ],
        traceIdSource: "NativeObservationEvent.trace.id for notch.event",
      },
    ],
    // notch.update is needs-capability (no scene editor), so by the
    // workbench's own vocabulary the tab is PARTIAL, not fully LIVE.
    status: "partial",
  } satisfies WorkbenchTabModel;
}

function windowsTab(surfaces: SurfaceList | undefined) {
  return {
    controls: [
      {
        evidenceLabel: "surfaces.state",
        id: "surfaces-list",
        kind: "json",
        label: "surfaces.state",
        status: "ready",
        value: surfaces ?? {},
      },
    ],
    id: "windows",
    label: "Windows & Views",
    proves:
      "Current surfaces are observable; mutation and MessagePort controls are explicit Phase B work.",
    flows: [
      {
        evidenceLabel: "surfaces.state",
        id: "surface-observation",
        label: "Surface Observation",
        status: surfaces ? "ready" : "disabled",
        steps: [
          flowStep({
            id: "surface-snapshot",
            label: "surfaces.state",
            observes: `${surfaces?.windows.length ?? 0} windows · ${
              surfaces?.views.length ?? 0
            } views`,
            source: "WebContentsRegistry",
            status: surfaces ? "ready" : "disabled",
            target: "NativeSurfaceService",
            traceIdSource: "NativeObservationEvent.trace.id for surfaces.state",
          }),
        ],
        traceIdSource: "NativeObservationEvent.trace.id for surfaces.state",
      },
    ],
    status: "partial",
  } satisfies WorkbenchTabModel;
}

function transportTab(snapshot: WorkbenchSnapshot) {
  return {
    controls: [
      {
        evidenceLabel: "transport.status",
        id: "transport-status",
        kind: "json",
        label: "transport.status",
        status: "ready",
        value: snapshot.transport ?? {},
      },
      {
        evidenceLabel: "transport.metadata",
        id: "transport-metadata",
        kind: "json",
        label: "transport metadata",
        status: "ready",
        value: generatedNativeCapabilityManifest,
      },
    ],
    id: "transport",
    label: "Transport",
    proves:
      "Generated IPC RPC metadata, NativeEventBus channels, and the agent-visible observability sink are exposed as the current transport substrate.",
    flows: buildTransportFlows(snapshot.transport),
    status: "partial",
  } satisfies WorkbenchTabModel;
}

function buildTransportFlows(
  transport: NativeTransportStatus | undefined
): readonly WorkbenchFlowModel[] {
  const ipcRpcCount = transport?.capabilities.byTransport["ipc-rpc"] ?? 0;

  return [
    {
      evidenceLabel: "transport.status",
      id: "transport-observability",
      label: "Transport Observability",
      status: transport?.available ? "partial" : "disabled",
      steps: [
        flowStep({
          id: "capability-rpc",
          label: "Capability RPC",
          observes: transport
            ? `${transport.capabilities.total} leaves · ipc-rpc ${ipcRpcCount}`
            : "waiting",
          source: "generated capability manifest",
          status: transport?.available ? "ready" : "disabled",
          target: "IpcGateway",
          traceIdSource: "transport.status.capabilities",
        }),
        flowStep({
          id: "native-event-bus",
          label: "NativeEventBus",
          observes: transport
            ? `${transport.events.total} channels · ${formatEventChannels(
                transport.events.channels
              )}`
            : "waiting",
          source: "NativeEventBus",
          status: transport && transport.events.total > 0 ? "ready" : "disabled",
          target: "renderer subscribers",
          traceIdSource: "transport.status.events",
        }),
        flowStep({
          id: "observability-sink",
          label: "Observability sink",
          observes: transport
            ? `${transport.observability.status} · redacted · ${transport.observability.location}`
            : "waiting",
          source: "IpcGateway / NativeEventBus",
          status: transport?.observability.status === "ready" ? "ready" : "disabled",
          target: "JsonlNativeObservabilitySink",
          traceIdSource: "transport.status.observability",
        }),
        flowStep({
          id: "peer-channel-runtime",
          label: "Peer channel runtime",
          observes: transport
            ? `${transport.messagePort.runtime} · active ${
                transport.messagePort.active ? "yes" : "no"
              }`
            : "waiting",
          source: "MessageChannelMain",
          status:
            transport?.messagePort.runtime === "not-started" ? "partial" : "disabled",
          target: "renderer peer data channel",
          traceIdSource: "transport.status.messagePort",
        }),
      ],
      traceIdSource: "NativeObservationEvent.trace.id for transport.status",
    },
  ];
}

function flowStep(step: WorkbenchFlowStepModel): WorkbenchFlowStepModel {
  return step;
}

function formatEventChannels(channels: readonly string[]) {
  if (channels.length === 0) {
    return "none";
  }

  const visible = channels.slice(0, 3).join(", ");
  return channels.length > 3 ? `${visible}, +${channels.length - 3}` : visible;
}
