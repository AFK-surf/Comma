import { Button, Checkbox, Dropdown, SearchIcon } from "@comma/ui";
import { useEffect, useState } from "react";
import {
  workloadProviders,
  type BftAgentTarget,
  type BftAgentWorkload,
  type BftWorkloadProvider,
} from "./api";
import { formatRelative } from "./format";
import { messages } from "./messages";
import { stateLabel } from "./ProjectOverviewPage";
import { useApi, useResource } from "./resource";
import { Skeleton } from "./states";

const t = messages.swarmAgents;

/** Where an external agent runs, as the New agent and Rebind forms edit it. */
export interface TargetDraft {
  location: "connected" | "compute";
  deviceId: string;
  runtimeId: string;
  provider: BftWorkloadProvider;
  query: string;
  showUnavailable: boolean;
  workloadId: string;
  /** The selected Workload's fence, from the page that listed it. */
  fence: Record<string, unknown> | null;
}

export const emptyTarget: TargetDraft = {
  location: "connected",
  deviceId: "",
  runtimeId: "",
  provider: "codex",
  query: "",
  showUnavailable: false,
  workloadId: "",
  fence: null,
};

/** The write's target; the server names whatever is missing. */
export const toTarget = (draft: TargetDraft): BftAgentTarget =>
  draft.location === "compute"
    ? {
        kind: "compute_workload",
        workload_id: draft.workloadId,
        selection_fence: draft.fence,
      }
    : {
        kind: "connected_runtime",
        device_id: draft.deviceId,
        device_runtime_id: draft.runtimeId,
      };

interface PickerProps {
  org: string;
  project: string;
  draft: TargetDraft;
  onChange: (change: Partial<TargetDraft>) => void;
  disabled: boolean;
}

/** A Connected Device runtime or a Compute Workload for an external agent. */
export function AgentTargetPicker(props: PickerProps) {
  const { draft, onChange, disabled } = props;
  return (
    <>
      <Dropdown
        className="bft-form-field"
        disabled={disabled}
        items={(["connected", "compute"] as const).map((location) => ({
          id: location,
          label: t.locations[location],
        }))}
        label={t.locationLabel}
        onChange={(location) =>
          onChange({ location: location as TargetDraft["location"] })
        }
        size="sm"
        value={draft.location}
      />
      {draft.location === "connected" ? (
        <ConnectedTarget {...props} />
      ) : (
        <ComputeTarget {...props} />
      )}
    </>
  );
}

function ConnectedTarget({ org, project, draft, onChange, disabled }: PickerProps) {
  const api = useApi();
  const [targets, retry] = useResource(`agent-targets:${org}:${project}`, (signal) =>
    api.agentTargets(org, project, signal)
  );
  if (targets.state === "loading") return <Skeleton height={32} />;
  if (targets.state === "error") {
    return (
      <div className="bft-quiet-row bft-quiet-row-flush" role="alert">
        <p className="bft-quiet bft-quiet-inline">{t.devicesUnavailable}</p>
        <button className="bft-btn bft-btn-sm" onClick={retry} type="button">
          {messages.states.retry}
        </button>
      </div>
    );
  }
  const devices = targets.data.devices;
  // A device or runtime that is gone no longer counts as chosen.
  const device = devices.find((item) => item.id === draft.deviceId);
  const runtime = device?.runtimes.find((item) => item.id === draft.runtimeId);
  return (
    <>
      {devices.length === 0 ? <p className="bft-dialog-note">{t.noDevices}</p> : null}
      <Dropdown
        className="bft-form-field"
        disabled={disabled || devices.length === 0}
        items={devices.map((item) => ({ id: item.id, label: item.label }))}
        label={t.deviceLabel}
        onChange={(deviceId) => onChange({ deviceId, runtimeId: "" })}
        placeholder={t.devicePlaceholder}
        size="sm"
        // Controlled throughout; an empty value shows the placeholder.
        value={device?.id ?? ""}
      />
      <Dropdown
        className="bft-form-field"
        disabled={disabled || !device || device.runtimes.length === 0}
        items={(device?.runtimes ?? []).map((item) => ({
          id: item.id,
          label: item.label,
        }))}
        label={t.runtimeLabel}
        onChange={(runtimeId) => onChange({ runtimeId })}
        placeholder={t.runtimePlaceholder}
        size="sm"
        value={runtime?.id ?? ""}
      />
      {runtime ? (
        <div className="bft-readiness" data-testid="runtime-readiness">
          <p className="bft-readiness-line">
            <span className="bft-status" data-tone={runtime.ready ? "ok" : "warn"}>
              {stateLabel(runtime.status)}
            </span>
            {runtime.version ? <span>{runtime.version}</span> : null}
            {runtime.checked_at && formatRelative(runtime.checked_at) ? (
              <span title={runtime.checked_at}>
                {t.checked(formatRelative(runtime.checked_at) ?? "")}
              </span>
            ) : null}
          </p>
          {runtime.issue ? (
            <p className="bft-setting-row-sub">{runtime.issue}</p>
          ) : null}
          {runtime.ready ? null : (
            <p className="bft-dialog-note">{t.runtimeNotReady}</p>
          )}
        </div>
      ) : null}
    </>
  );
}

/** `value` after it has stayed the same for `delay` ms. */
function useSettled<T>(value: T, delay: number) {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    const timer = window.setTimeout(() => setSettled(value), delay);
    return () => window.clearTimeout(timer);
  }, [value, delay]);
  return settled;
}

const sameFence = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

function ComputeTarget({ org, project, draft, onChange, disabled }: PickerProps) {
  const api = useApi();
  const query = useSettled(draft.query.trim(), 300);
  const filter = `${draft.provider}:${draft.showUnavailable}:${query}`;
  // Next page replaces the list; a new filter or Refresh starts over.
  const [page, setPage] = useState({ filter, cursor: null as string | null });
  const cursor = page.filter === filter ? page.cursor : null;
  const [workloads, retry] = useResource(
    `agent-workloads:${org}:${project}:${filter}:${cursor ?? ""}`,
    (signal) =>
      api.agentWorkloads(
        org,
        project,
        {
          provider: draft.provider,
          query,
          includeUnavailable: draft.showUnavailable,
          cursor,
        },
        signal
      )
  );
  const loaded = workloads.state === "ready" ? workloads.data : undefined;
  const items: BftAgentWorkload[] = loaded?.items ?? [];

  // A selection the current page no longer lists is dropped; a listed one
  // keeps the fence this page reports.
  useEffect(() => {
    if (!loaded || !draft.workloadId) return;
    const item = loaded.items.find((candidate) => candidate.id === draft.workloadId);
    if (!item?.selectable) onChange({ workloadId: "", fence: null });
    else if (!sameFence(item.selection_fence, draft.fence))
      onChange({ fence: item.selection_fence });
  }, [loaded, draft.workloadId, draft.fence, onChange]);

  return (
    <>
      <Dropdown
        className="bft-form-field"
        disabled={disabled}
        items={workloadProviders.map((provider) => ({
          id: provider,
          label: t.providers[provider],
        }))}
        label={t.providerLabel}
        onChange={(provider) => onChange({ provider: provider as BftWorkloadProvider })}
        size="sm"
        value={draft.provider}
      />
      <div className="bft-picker-tools">
        <label className="bft-filter">
          <SearchIcon className="bft-filter-icon" />
          <input
            aria-label={t.searchWorkloads}
            disabled={disabled}
            onChange={(event) => onChange({ query: event.target.value })}
            placeholder={t.searchPlaceholder}
            type="search"
            value={draft.query}
          />
        </label>
        <Checkbox
          checked={draft.showUnavailable}
          disabled={disabled}
          label={t.showUnavailable}
          onChange={(event) => onChange({ showUnavailable: event.target.checked })}
          size="sm"
        />
      </div>
      {workloads.state === "loading" ? (
        <output className="bft-quiet bft-quiet-inline">{t.loadingWorkloads}</output>
      ) : workloads.state === "error" || loaded?.status === "unavailable" ? (
        <p className="bft-dialog-error" role="alert">
          {t.workloadsUnavailable}
        </p>
      ) : items.length === 0 ? (
        <p className="bft-dialog-note">{t.noWorkloads}</p>
      ) : (
        <fieldset aria-label={t.workloadsLabel} className="bft-choices">
          {items.map((item) => (
            <label
              className="bft-choice"
              data-disabled={item.selectable ? undefined : true}
              key={item.id}
            >
              <input
                checked={draft.workloadId === item.id}
                disabled={disabled || !item.selectable}
                name="workload"
                onChange={() =>
                  onChange({ workloadId: item.id, fence: item.selection_fence })
                }
                type="radio"
                value={item.id}
              />
              <span className="bft-choice-main">
                <span className="bft-truncate" title={item.label}>
                  {item.label}
                </span>
                <span className="bft-choice-meta">
                  {item.node ? <span className="bft-truncate">{item.node}</span> : null}
                  <span
                    className="bft-status"
                    data-tone={item.tone === "neutral" ? undefined : item.tone}
                  >
                    {item.availability}
                  </span>
                </span>
                {item.issue ? (
                  <span className="bft-setting-row-sub bft-choice-issue">
                    {item.issue}
                  </span>
                ) : null}
              </span>
            </label>
          ))}
        </fieldset>
      )}
      <div className="bft-picker-tools">
        <Button
          disabled={disabled}
          hierarchy="secondary-gray"
          onPress={() => {
            setPage({ filter, cursor: null });
            retry();
          }}
          size="xs"
        >
          {t.refresh}
        </Button>
        {loaded?.next_cursor ? (
          <Button
            disabled={disabled}
            hierarchy="secondary-gray"
            onPress={() => setPage({ filter, cursor: loaded.next_cursor })}
            size="xs"
          >
            {t.nextPage}
          </Button>
        ) : null}
      </div>
    </>
  );
}
