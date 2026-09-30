import { useCallback, useEffect, useMemo, useState } from "react";
import type { NativeInfo, NativeTransportStatus } from "@comma/native-bridge";
import type { WorkbenchControlDescriptor } from "./control-descriptors";
import {
  appendEvidence,
  type WorkbenchEvidenceEntry,
  type WorkbenchEvidenceType,
} from "./evidence-store";
import {
  buildWorkbenchTabs,
  loadRuntimeSnapshot,
  type WorkbenchFlowModel,
  type WorkbenchFlowStatus,
  type WorkbenchSnapshot,
  type WorkbenchTabId,
} from "./domain-adapters";
import { TweakpaneControlPane } from "./TweakpaneControlPane";
import { SideChatBackdropPanel } from "./SideChatBackdropPanel";
import "./runtime-workbench.css";

type WorkbenchTabStatus = "ready" | "partial" | "planned" | "fail";

const STATUS_LABEL: Record<WorkbenchTabStatus, string> = {
  ready: "LIVE",
  partial: "PARTIAL",
  planned: "PLANNED",
  fail: "FAIL",
};

// One tone vocabulary (pass/partial/planned/fail) shared by every workbench
// dot & badge via data-tone; disabled flows fold into the neutral gray. The
// colors live once in runtime-workbench.css, keyed off data-tone.
const STATUS_TONE: Record<WorkbenchTabStatus | WorkbenchFlowStatus, string> = {
  ready: "pass",
  partial: "partial",
  planned: "planned",
  disabled: "planned",
  fail: "fail",
};

const STATUS_HELP: Record<WorkbenchTabStatus, string> = {
  ready: "LIVE — 已接入真实 runtime，现在可点、可拿真实结果",
  partial: "PARTIAL — 一部分已接入真实能力，其余 Phase B 控件标 needs-capability",
  planned: "PLANNED — 只有设计方向，尚无 runtime，控件 disabled，不做假数据",
  fail: "FAIL — 预期链路失败",
};

const FLOW_STATUS_LABEL: Record<WorkbenchFlowStatus, string> = {
  ready: "LIVE",
  partial: "PARTIAL",
  disabled: "OFF",
  fail: "FAIL",
};

const EVIDENCE_TABS: readonly WorkbenchEvidenceType[] = [
  "result",
  "event",
  "transport",
  "security",
  "activity",
];

const EVIDENCE_LABEL: Record<WorkbenchEvidenceType, string> = {
  result: "Result",
  event: "Events",
  transport: "Transport",
  security: "Security",
  activity: "Activity",
};

interface CommEdge {
  from: string;
  to: string;
  channel: string;
  transport: string;
  transportTag: "ipc" | "px";
}

// Derive the comm matrix from the REAL registered NativeEventBus channels
// (snapshot.transport.events.channels) rather than a hand-maintained list — the
// bus is the source of truth, so a channel can't read as planned once it's
// actually wired, and newly registered channels show up automatically. Every
// NativeEventBus event flows main -> renderer; registration is all the bus
// reports, so no per-channel active/planned health is fabricated.
function deriveCommEdges(transport: NativeTransportStatus | undefined): CommEdge[] {
  const channels = transport?.events.channels ?? [];
  return channels
    .toSorted((a, b) => a.localeCompare(b))
    .map((channel) => ({
      channel,
      from: "main",
      to: "renderer",
      transport: "IPC·bus",
      transportTag: "ipc",
    }));
}

export function RuntimeWorkbenchRoute() {
  const [activeTabId, setActiveTabId] = useState<WorkbenchTabId>(readEntryTab);
  const [snapshot, setSnapshot] = useState<WorkbenchSnapshot>({});
  const [evidence, setEvidence] = useState<readonly WorkbenchEvidenceEntry[]>([]);
  const [evidenceTab, setEvidenceTab] = useState<WorkbenchEvidenceType>("result");
  const tabs = useMemo(() => buildWorkbenchTabs(snapshot), [snapshot]);
  const activeTab =
    tabs.find((tab) => tab.id === activeTabId) ?? getFirstWorkbenchTab(tabs);

  useEffect(() => {
    const followEntry = () => setActiveTabId(readEntryTab());
    window.addEventListener("hashchange", followEntry);
    return () => window.removeEventListener("hashchange", followEntry);
  }, []);

  const selectTab = (tabId: WorkbenchTabId) => {
    setActiveTabId(tabId);
    const [path, query] = window.location.hash.split("?");
    const params = new URLSearchParams(query);
    params.set("tab", tabId);
    // Keep the native menu's target distinct after a manual tab switch, so an
    // existing workbench receives a hashchange when it opens Side Chat again.
    window.history.replaceState(
      window.history.state,
      "",
      `${path || "#/dev/workbench"}?${params}`
    );
  };

  useEffect(() => {
    let active = true;

    void loadRuntimeSnapshot().then((nextSnapshot) => {
      if (!active) {
        return;
      }

      setSnapshot(nextSnapshot);
      setEvidence((entries) =>
        appendEvidence(entries, {
          channel: "comma:surfaces:state",
          input: undefined,
          label: "Runtime snapshot",
          output: nextSnapshot.surfaces ?? {},
          status: "success",
          type: "result",
        })
      );
    });

    return () => {
      active = false;
    };
  }, []);

  const nativeInfo = snapshot.nativeInfo as NativeInfo | undefined;
  const windows = snapshot.surfaces?.windows ?? [];
  const views = snapshot.surfaces?.views ?? [];
  const gatewayReady = Boolean(nativeInfo);
  const showMatrix = activeTab.id === "windows" || activeTab.id === "transport";
  const commEdges = useMemo(
    () => deriveCommEdges(snapshot.transport),
    [snapshot.transport]
  );
  const visibleEvidence = evidence.filter((entry) => entry.type === evidenceTab);

  const counts = tabs.reduce(
    (accumulator, tab) => {
      accumulator[tab.status] += 1;
      return accumulator;
    },
    { fail: 0, partial: 0, planned: 0, ready: 0 } as Record<WorkbenchTabStatus, number>
  );

  const recordControlEvidence = useCallback((entry: ControlEvidenceEntry) => {
    setEvidence((entries) =>
      appendEvidence(entries, {
        channel: entry.channel,
        error: entry.error,
        input: entry.input,
        label: entry.label,
        output: entry.output,
        status: entry.status,
        type: "result",
      })
    );
    setEvidenceTab("result");
  }, []);

  // Wrap each control's action so invoking it records the real result/error
  // envelope into the evidence store. Domain adapters only need to return the
  // capability result; the route owns the evidence plumbing (its lane).
  const controls = useMemo(
    () => wrapControlsWithEvidence(activeTab.controls, recordControlEvidence),
    [activeTab.controls, recordControlEvidence]
  );

  return (
    <section className="comma-runtime-workbench" aria-label="Runtime Workbench">
      <header className="comma-runtime-workbench__title">
        <h1>Runtime Workbench</h1>
        <span className="sub">· dev-workbench window</span>
        <span className="dev">DEV ONLY · excluded from prod</span>
      </header>

      <div className="comma-runtime-workbench__rbar">
        <Chip
          dot
          k="runtime"
          ok={nativeInfo?.platform === "electron"}
          v={nativeInfo?.platform ?? "…"}
        />
        <Chip dot k="prod-guard" ok v="on" />
        <Chip k="app" v={nativeInfo?.appVersion ?? "…"} />
        <Chip k="os" v={nativeInfo?.os ?? "…"} />
        <Chip k="windows" v={String(windows.length)} />
        <Chip k="views" v={String(views.length)} />
        <Chip dot k="gateway" ok={gatewayReady} v={gatewayReady ? "healthy" : "…"} />
      </div>

      <div className="comma-runtime-workbench__tabs" role="tablist">
        {tabs.map((tab) => (
          <button
            aria-selected={tab.id === activeTabId}
            data-status={tab.status}
            key={tab.id}
            onClick={() => selectTab(tab.id)}
            role="tab"
            title={STATUS_HELP[tab.status]}
            type="button"
          >
            <span
              aria-hidden="true"
              className="wb-dot"
              data-tone={STATUS_TONE[tab.status]}
            />
            {tab.label}
            <span className="st">{STATUS_LABEL[tab.status]}</span>
          </button>
        ))}
      </div>

      <div className="comma-runtime-workbench__accept">
        <span className="proves-label">What this proves</span>
        <span
          className="wb-badge"
          data-tone={STATUS_TONE[activeTab.status]}
          title={STATUS_HELP[activeTab.status]}
        >
          {STATUS_LABEL[activeTab.status]}
        </span>
        <p className="prove">{activeTab.proves}</p>
      </div>

      <main
        className={`comma-runtime-workbench__body${activeTab.id === "side-chat" ? " comma-runtime-workbench__body--side-chat" : ""}`}
      >
        {activeTab.id === "side-chat" ? (
          <SideChatBackdropPanel platform={nativeInfo?.platform} os={nativeInfo?.os} />
        ) : (
          <>
            <section className="comma-runtime-workbench__control">
              <ObservedFlows flows={activeTab.flows} />

              <SurfaceSummary windows={windows} />

              <TweakpaneControlPane controls={controls} />

              <p className="note">
                参数面板 = <b>Tweakpane · Comma compact light theme</b>（只有右侧
                evidence wells 保持 dark）。ready 控件读真实 capability；尚未接入的
                mutation 控件标 <code>needs-capability</code> 且不可交互（Phase B）。
              </p>
            </section>

            <aside className="comma-runtime-workbench__obs" aria-label="Observation">
              {showMatrix ? <CommMatrix edges={commEdges} /> : null}

              <p className="comma-runtime-workbench__olabel">
                Evidence
                <span className="code">input · channel · result / error envelope</span>
              </p>
              <div className="comma-runtime-workbench__ev-tabs" role="tablist">
                {EVIDENCE_TABS.map((type) => {
                  const count = evidence.filter((entry) => entry.type === type).length;
                  return (
                    <button
                      aria-selected={type === evidenceTab}
                      key={type}
                      onClick={() => setEvidenceTab(type)}
                      role="tab"
                      type="button"
                    >
                      {EVIDENCE_LABEL[type]}
                      {count > 0 ? <span className="n"> {count}</span> : null}
                    </button>
                  );
                })}
              </div>

              {visibleEvidence.length === 0 ? (
                <p className="ev-empty">
                  还没有 {EVIDENCE_LABEL[evidenceTab]} evidence ——
                  触发一个控件后这里会记录 input / channel / result envelope。
                </p>
              ) : (
                visibleEvidence.map((entry) => (
                  <EvidenceWell entry={entry} key={entry.id} />
                ))
              )}
            </aside>
          </>
        )}
      </main>

      <footer className="comma-runtime-workbench__foot">
        <span>
          ● LIVE {counts.ready} = real runtime · ◐ PARTIAL {counts.partial} = partly
          wired
        </span>
        <span>
          entry <code>dev window → #/dev/workbench</code> · bare render, no
          sidebar/login
        </span>
      </footer>
    </section>
  );
}

function readEntryTab(): WorkbenchTabId {
  const tab = new URLSearchParams(window.location.hash.split("?")[1]).get("tab");
  return buildWorkbenchTabs({}).find((entry) => entry.id === tab)?.id ?? "runtime";
}

function Chip({
  dot,
  k,
  ok,
  v,
}: {
  dot?: boolean;
  k: string;
  ok?: boolean;
  v: string;
}) {
  return (
    <span className={ok ? "chip ok" : "chip"}>
      {dot ? <span aria-hidden="true" className={ok ? "sdot g" : "sdot"} /> : null}
      <span className="k">{k}</span>
      <span className="v">{v}</span>
    </span>
  );
}

function getFirstWorkbenchTab(tabs: ReturnType<typeof buildWorkbenchTabs>) {
  const [tab] = tabs;

  if (!tab) {
    throw new Error("Runtime Workbench requires at least one tab.");
  }

  return tab;
}

function SurfaceSummary({
  windows,
}: {
  windows: NonNullable<WorkbenchSnapshot["surfaces"]>["windows"];
}) {
  if (windows.length === 0) {
    return null;
  }

  return (
    <section aria-label="Surfaces" className="comma-runtime-workbench__surfaces">
      {windows.map((window) => (
        <dl key={window.id}>
          <dt>id</dt>
          <dd>{window.id}</dd>
          <dt>role</dt>
          <dd>{window.role}</dd>
          <dt>bounds</dt>
          <dd>
            {window.bounds.width}×{window.bounds.height}
          </dd>
        </dl>
      ))}
    </section>
  );
}

function ObservedFlows({ flows }: { flows: readonly WorkbenchFlowModel[] }) {
  if (flows.length === 0) {
    return null;
  }

  return (
    <section aria-label="Observed flows" className="comma-runtime-workbench__flows">
      <p className="comma-runtime-workbench__olabel">
        Observed Flow
        <span className="code">重点观察 · source → target · traceId</span>
      </p>
      {flows.map((flow) => (
        <div className="flow-card" key={flow.id}>
          <div className="flow-head">
            <span
              aria-hidden="true"
              className="wb-dot"
              data-tone={STATUS_TONE[flow.status]}
            />
            <span className="flow-label">{flow.label}</span>
            <span className="wb-badge" data-tone={STATUS_TONE[flow.status]}>
              {FLOW_STATUS_LABEL[flow.status]}
            </span>
          </div>
          <ol className="flow-steps">
            {flow.steps.map((step) => (
              <li className="flow-step" key={step.id}>
                <span
                  aria-hidden="true"
                  className="wb-dot"
                  data-tone={STATUS_TONE[step.status]}
                />
                <span className="flow-hop">
                  <span className="flow-node">{step.source}</span>
                  <span className="flow-arrow">→</span>
                  <span className="flow-node">{step.target}</span>
                </span>
                <span className="flow-step-label">{step.label}</span>
                <span className="flow-observes">{step.observes}</span>
              </li>
            ))}
          </ol>
          <p className="flow-trace">
            trace <span className="code">{flow.traceIdSource}</span>
          </p>
        </div>
      ))}
    </section>
  );
}

function CommMatrix({ edges }: { edges: readonly CommEdge[] }) {
  return (
    <section aria-label="Communication matrix">
      <p className="comma-runtime-workbench__olabel">
        Comm Matrix
        <span className="code">who → who · transport · registered channels</span>
      </p>
      {edges.length === 0 ? (
        <p className="note">
          当前没有已注册的 NativeEventBus channel（web 端无 transport 时为空）。
        </p>
      ) : (
        <table className="mx">
          <thead>
            <tr>
              <th>from</th>
              <th>to</th>
              <th>channel</th>
              <th>transport</th>
              <th>status</th>
            </tr>
          </thead>
          <tbody>
            {edges.map((edge) => (
              <tr key={edge.channel}>
                <td>{edge.from}</td>
                <td>{edge.to}</td>
                <td>{edge.channel}</td>
                <td>
                  <span
                    className="wb-tag"
                    data-tone={edge.transportTag === "ipc" ? "pass" : "partial"}
                  >
                    {edge.transport}
                  </span>
                </td>
                <td>
                  <span className="mst">
                    <span className="dt p" />
                    registered
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p className="note">
        矩阵行直接来自 snapshot.transport.events.channels（真实注册的 NativeEventBus
        channel）；registration ≠ 实时流量，heartbeat / msg / drop 实时计数随 Phase B/C
        接入。
      </p>
    </section>
  );
}

function EvidenceWell({ entry }: { entry: WorkbenchEvidenceEntry }) {
  const payload: Record<string, unknown> = {};

  if (entry.input !== undefined) {
    payload.input = entry.input;
  }

  if (entry.output !== undefined) {
    payload.output = entry.output;
  }

  if (entry.error !== undefined) {
    payload.error = entry.error;
  }

  return (
    <div className="well">
      <div className="whead">
        <span className="lbl">{entry.label}</span>
        {entry.channel ? <span className="chan">{entry.channel}</span> : null}
        <span className={entry.status === "error" ? "err" : "ok"}>{entry.status}</span>
      </div>
      <div className="jroot">
        <JsonView value={payload} depth={0} />
      </div>
    </div>
  );
}

interface ControlEvidenceEntry {
  label: string;
  channel: string;
  input?: unknown;
  output?: unknown;
  error?: unknown;
  status: "success" | "error";
}

// Wrap control actions so their real result/error envelope lands in the evidence
// store. Domain adapters just return the capability result; the route owns this
// plumbing. Button descriptors have actions; monitor and JSON descriptors are
// read-only and do not emit action evidence.
export function wrapControlsWithEvidence(
  controls: readonly WorkbenchControlDescriptor[],
  record: (entry: ControlEvidenceEntry) => void
): WorkbenchControlDescriptor[] {
  return controls.map((control): WorkbenchControlDescriptor => {
    if (control.kind === "button" && control.action) {
      const run = control.action;
      return {
        ...control,
        action: async () => {
          try {
            const output = await run();
            record({
              channel: control.evidenceLabel,
              label: control.label,
              output,
              status: "success",
            });
            return output;
          } catch (error) {
            record({
              channel: control.evidenceLabel,
              error: toErrorMessage(error),
              label: control.label,
              status: "error",
            });
            return undefined;
          }
        },
      };
    }

    return control;
  });
}

function toErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

// Compact syntax-highlighted, collapsible object inspector so evidence reads as a
// structured record rather than a raw JSON.stringify blob. Top two levels expand;
// deeper nodes collapse (native <details>, no extra state).
function JsonView({ value, depth }: { value: unknown; depth: number }) {
  if (value === null) {
    return <span className="jn">null</span>;
  }

  if (typeof value === "string") {
    return <span className="js">&quot;{value}&quot;</span>;
  }

  if (typeof value === "number" || typeof value === "boolean") {
    return <span className="jb">{String(value)}</span>;
  }

  if (Array.isArray(value)) {
    if (value.length === 0) {
      return <span className="jm">[]</span>;
    }

    return (
      <details className="jtree" open={depth < 2}>
        <summary>
          <span className="jm">[] {value.length} items</span>
        </summary>
        <div className="jbody">
          {value.map((item, index) => (
            <div className="jrow" key={index}>
              <JsonView depth={depth + 1} value={item} />
            </div>
          ))}
        </div>
      </details>
    );
  }

  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>);

    if (entries.length === 0) {
      return <span className="jm">{"{}"}</span>;
    }

    return (
      <details className="jtree" open={depth < 2}>
        <summary>
          <span className="jm">
            {"{}"} {entries.length} keys
          </span>
        </summary>
        <div className="jbody">
          {entries.map(([key, nested]) => (
            <div className="jrow" key={key}>
              <span className="jk">{key}</span>
              <span className="jsep">: </span>
              <JsonView depth={depth + 1} value={nested} />
            </div>
          ))}
        </div>
      </details>
    );
  }

  return <span className="jm">{String(value)}</span>;
}
