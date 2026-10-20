import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { Dropdown } from "@comma/ui/components/dropdown";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
} from "@comma/ui/components/menu";
import { MoreHorizontalIcon } from "@comma/ui/components/icons";
import { Toggle } from "@comma/ui/components/toggle";
import {
  Fragment,
  useCallback,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type {
  BftAndroidDevice,
  BftCloudVm,
  BftComputeEnvironment,
  BftSwarmDevice,
  BftSwarmDevices,
} from "./api";
import { DialogError, writeErrorMessage } from "./dialogs";
import { showFlash } from "./flash";
import { formatBytes, formatRelative, humanize } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { useApi, useResource, type Resource } from "./resource";
import { spaLinkClick } from "./router";
import {
  FormSection,
  SettingsPage,
  TextField,
  useConfirm,
  useWrite,
} from "./settingsForm";
import { Skeleton } from "./states";

const t = messages.swarmDevices;

type Tone = "ok" | "warn" | "error" | "neutral";

const tones: Record<string, Tone> = {
  connected: "ok",
  online: "ok",
  ready: "ok",
  enabled: "ok",
  available: "ok",
  running: "ok",
  pending: "warn",
  starting: "warn",
  creating: "warn",
  archiving: "warn",
  waking: "warn",
  processing: "warn",
  action_required: "error",
  draining: "warn",
  provisioning: "warn",
  disconnected: "error",
  offline: "error",
  failed: "error",
  error: "error",
  revoked: "error",
};

function State({
  value,
  labels = t.states,
}: {
  value: string | null;
  labels?: Record<string, string>;
}) {
  if (!value) return <span className="bft-muted">—</span>;
  return (
    <span className="bft-status" data-tone={tones[value] ?? "neutral"}>
      <span className="bft-truncate">{labels[value] ?? humanize(value)}</span>
    </span>
  );
}

const deviceName = (device: BftSwarmDevice) => device.name ?? t.unnamed;

/**
 * An Agent Swarm's devices: its Cloud VM (where it runs, its status and the
 * org Runner it uses), the connectors registered to the swarm, Compute
 * environments and Android setup. While a device request is being
 * provisioned the page polls a cheap status and reads itself again once it
 * is done.
 */
export function SwarmDevicesPage({
  org,
  project,
  first,
  onRetry,
}: {
  org: string;
  project: string;
  first: Resource<BftSwarmDevices>;
  onRetry: () => void;
}) {
  const api = useApi();
  const last = useRef<BftSwarmDevices | undefined>(undefined);
  if (first.state === "ready") last.current = first.data;
  const data = first.state === "ready" ? first.data : last.current;
  const resource: Resource<BftSwarmDevices> = data ? { state: "ready", data } : first;
  const [adding, setAdding] = useState(false);
  const devicesPath = projectHref(org, project, "/devices");
  const notify = useCallback(
    (notice: string) => {
      showFlash({ kind: "info", text: notice }, devicesPath);
      onRetry();
    },
    [devicesPath, onRetry]
  );
  // A refused write is said above the page, which is read again.
  const fail = useCallback(
    (error: unknown) => {
      const text = writeErrorMessage(error);
      if (text) showFlash({ kind: "error", text }, devicesPath);
      onRetry();
    },
    [devicesPath, onRetry]
  );

  // Each page read that still shows a request in flight starts the poll over.
  useWhileActive(
    data?.provisioning === true ? data : null,
    (signal) =>
      api.deviceProvisioning(org, project, signal).then((status) => status.active),
    onRetry
  );

  const manage = data?.project.role === "admin";

  return (
    <>
      <SettingsPage
        actions={
          manage ? (
            <button
              className="bft-btn bft-btn-primary"
              onClick={() => setAdding(true)}
              type="button"
            >
              {t.addDevice}
            </button>
          ) : undefined
        }
        description={data ? t.description(data.project.name) : undefined}
        onRetry={onRetry}
        resource={resource}
        title={t.title}
        wide
      >
        {(page) => (
          <>
            <CloudVmSection
              data={page.cloud_vm}
              fail={fail}
              loading={first.state === "loading"}
              notify={notify}
              org={org}
              project={project}
            />
            <DevicesSection
              data={page}
              loading={first.state === "loading"}
              notify={notify}
              onRetry={onRetry}
              org={org}
              project={project}
            />
            <div className="bft-settings-grid">
              <ComputeSection
                data={page}
                fail={fail}
                notify={notify}
                onRetry={onRetry}
                org={org}
                project={project}
              />
              <AndroidSection data={page} />
            </div>
          </>
        )}
      </SettingsPage>
      {adding ? (
        <AddDeviceDialog
          onClose={() => setAdding(false)}
          onCreated={(notice) => {
            setAdding(false);
            notify(notice);
          }}
          org={org}
          project={project}
        />
      ) : null}
    </>
  );
}

/**
 * Calls `check` every 2 s while `active` is set and the page is visible; one
 * call at a time, and a reply that arrives after a stop is dropped. When
 * `check` answers false the poll stops and `onDone` runs once.
 */
function useWhileActive(
  active: object | null,
  check: (signal: AbortSignal) => Promise<boolean>,
  onDone: () => void,
  intervalMs = 2000
) {
  const latest = useRef({ check, onDone });
  latest.current = { check, onDone };
  useEffect(() => {
    if (active === null) return undefined;
    let stopped = false;
    let timer: number | undefined;
    let inflight: AbortController | null = null;
    const schedule = () => {
      if (!stopped && !document.hidden && timer === undefined && !inflight)
        timer = window.setTimeout(tick, intervalMs);
    };
    const tick = () => {
      timer = undefined;
      if (stopped || document.hidden || inflight) return;
      const controller = new AbortController();
      inflight = controller;
      latest.current.check(controller.signal).then(
        (still) => {
          if (stopped || controller.signal.aborted) return;
          inflight = null;
          if (still) schedule();
          else {
            stopped = true;
            latest.current.onDone();
          }
        },
        () => {
          if (stopped || controller.signal.aborted) return;
          inflight = null;
          schedule();
        }
      );
    };
    const onVisibility = () => {
      if (document.hidden) {
        window.clearTimeout(timer);
        timer = undefined;
        inflight?.abort();
        inflight = null;
      } else if (timer === undefined && !inflight) tick();
    };
    document.addEventListener("visibilitychange", onVisibility);
    schedule();
    return () => {
      stopped = true;
      window.clearTimeout(timer);
      inflight?.abort();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [active, intervalMs]);
}

function Cell({ main, sub }: { main: ReactNode; sub?: ReactNode }) {
  return (
    <>
      <span className="bft-cell-main">{main}</span>
      {sub ? <span className="bft-cell-sub">{sub}</span> : null}
    </>
  );
}

const relative = (iso: string | null) => (iso && formatRelative(iso)) || "—";

export interface RowAction {
  id: string;
  label: string;
  destructive?: boolean;
  onAction: () => void;
}

/** A row's writes behind one "more" button; destructive ones come last. */
export function RowMenu({ name, items }: { name: string; items: RowAction[] }) {
  const plain = items.filter((item) => !item.destructive);
  const destructive = items.filter((item) => item.destructive);
  return (
    <MenuTrigger>
      <Button
        aria-label={t.actionsFor(name)}
        hierarchy="tertiary-gray"
        iconLeading={<MoreHorizontalIcon />}
        iconOnly
        size="xs"
      />
      <MenuPopover className="bft-menu-popover" placement="bottom end">
        <Menu aria-label={t.actionsFor(name)}>
          {plain.map((item) => (
            <MenuItem id={item.id} key={item.id} onAction={item.onAction}>
              {item.label}
            </MenuItem>
          ))}
          {plain.length > 0 && destructive.length > 0 ? <MenuSeparator /> : null}
          {destructive.map((item) => (
            <MenuItem
              id={item.id}
              key={item.id}
              onAction={item.onAction}
              tone="destructive"
            >
              {item.label}
            </MenuItem>
          ))}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

const locationText = (location: BftCloudVm["next_location"]) => {
  switch (location?.kind) {
    case "cloudflare":
      return t.cloudflare;
    case "runner":
      return location.name ? t.runnerNamed(location.name) : t.otherHost;
    case "conflict":
      return t.placementConflict;
    default:
      return "—";
  }
};

/**
 * The swarm's Cloud VM: where it runs and its status, or, before it exists,
 * where a new one goes. An admin turns it on or off and chooses the org
 * Runner a new VM is created on; the choice does not move an existing VM.
 */
function CloudVmSection({
  org,
  project,
  data,
  loading,
  notify,
  fail,
}: {
  org: string;
  project: string;
  data: BftCloudVm;
  loading: boolean;
  notify: (notice: string) => void;
  fail: (error: unknown) => void;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const [saving, setSaving] = useState(false);
  const [choosing, setChoosing] = useState(false);
  const { vm, runner } = data;
  const toggle = (enabled: boolean) => {
    setSaving(true);
    api.setCloudComputer(org, project, enabled).then(
      ({ notice }) => {
        setSaving(false);
        notify(notice);
      },
      (error: unknown) => {
        setSaving(false);
        fail(error);
      }
    );
  };
  const runnerName = runner?.name ?? t.otherHost;
  const status = !data.enabled && !vm ? null : (vm?.status ?? null);

  return (
    <FormSection
      action={
        data.manageable ? (
          <Toggle
            aria-label={t.cloudVmToggle}
            checked={data.enabled}
            disabled={saving || loading}
            onChange={(event) => toggle(event.target.checked)}
            size="sm"
          />
        ) : undefined
      }
      description={t.cloudVmNote}
      title={t.cloudVmTitle}
    >
      <dl className="bft-kv">
        <div>
          <dt>{t.cloudVmStatus}</dt>
          <dd>
            {status ? (
              <State value={status} />
            ) : (
              <span className="bft-muted">
                {data.enabled ? t.cloudVmNotCreated : t.cloudVmOff}
              </span>
            )}
          </dd>
        </div>
        {vm ? (
          <div>
            <dt>{t.cloudVmRunsOn}</dt>
            <dd>
              {vm.status === "unavailable"
                ? t.cloudVmUnavailable
                : locationText(vm.location)}
            </dd>
          </div>
        ) : (
          <div>
            <dt>{t.cloudVmNextRunsOn}</dt>
            <dd>{locationText(data.next_location)}</dd>
          </div>
        )}
        <div>
          <dt>{t.cloudVmRunner}</dt>
          <dd>
            {runner ? (
              <>
                {runnerName} · <State labels={t.runnerStates} value={runner.status} />
              </>
            ) : (
              <span className="bft-muted">{t.noRunner}</span>
            )}
          </dd>
        </div>
      </dl>
      {data.runner_choosable || data.runner_removable ? (
        <div className="bft-quiet-row bft-quiet-row-flush">
          <p className="bft-quiet bft-quiet-inline">{t.runnerChoiceNote}</p>
          {data.runner_choosable ? (
            <button
              className="bft-btn bft-btn-sm"
              onClick={() => setChoosing(true)}
              type="button"
            >
              {t.chooseRunner}
            </button>
          ) : (
            <button
              className="bft-btn bft-btn-sm"
              onClick={() =>
                confirm.ask({
                  title: t.removeRunner,
                  description: t.removeRunnerBody(runnerName),
                  confirmLabel: t.removeRunner,
                  action: () =>
                    api
                      .removeCloudVmRunner(org, project)
                      .then(({ notice }) => notify(notice)),
                })
              }
              type="button"
            >
              {t.removeRunner}
            </button>
          )}
        </div>
      ) : (
        <p className="bft-quiet bft-quiet-inline">{t.runnerChoiceNote}</p>
      )}
      {choosing ? (
        <ChooseRunnerDialog
          onChosen={(notice) => {
            setChoosing(false);
            notify(notice);
          }}
          onClose={() => setChoosing(false)}
          org={org}
          project={project}
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

/** Choose one online org Runner for the swarm's Cloud VM. */
function ChooseRunnerDialog({
  org,
  project,
  onClose,
  onChosen,
}: {
  org: string;
  project: string;
  onClose: () => void;
  onChosen: (notice: string) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [runners, retry] = useResource(`device-runners:${org}:${project}`, (signal) =>
    api.deviceRunners(org, project, signal)
  );
  // One id per dialog: a retried choice repeats the same request.
  const [requestId] = useState(() => crypto.randomUUID());
  const [runner, setRunner] = useState<string>();
  const choices = runners.state === "ready" ? runners.data.runners : [];
  const none = runners.state === "ready" && choices.length === 0;
  const chosen = runner ?? choices[0]?.id ?? "";
  const close = () => {
    if (!write.busy) onClose();
  };
  const submit = () =>
    write.run(
      () =>
        api.chooseCloudVmRunner(org, project, {
          runner_id: chosen,
          request_id: requestId,
        }),
      ({ notice }) => onChosen(notice)
    );

  return (
    <Dialog
      actions={[
        {
          label: messages.common.cancel,
          hierarchy: "secondary-gray",
          onPress: close,
          disabled: write.busy,
        },
        none || runners.state === "error"
          ? { label: t.checkRunners, hierarchy: "primary", onPress: retry }
          : {
              label: write.busy ? messages.settings.saving : t.chooseRunnerSubmit,
              hierarchy: "primary",
              onPress: submit,
              disabled: write.busy || choices.length === 0,
            },
      ]}
      description={none ? t.noRunnersBody : t.chooseRunnerBody}
      isDismissable={!write.busy}
      isOpen
      onOpenChange={(open) => {
        if (!open) close();
      }}
      title={none ? t.noRunnersTitle : t.chooseRunnerTitle}
    >
      <div className="bft-form">
        {runners.state === "loading" ? (
          <output className="bft-rows-skeleton bft-rows-skeleton-flush">
            <Skeleton height={32} />
            <span className="bft-sr-only">{t.runnersLoading}</span>
          </output>
        ) : runners.state === "error" ? (
          <p className="bft-dialog-error" role="alert">
            {t.runnersUnavailable}
          </p>
        ) : none ? (
          <a
            className="bft-link"
            href={runners.data.runners_href}
            onClick={spaLinkClick}
          >
            {t.openRunners}
          </a>
        ) : (
          <Dropdown
            className="bft-form-field"
            disabled={write.busy}
            items={choices.map((choice) => ({ id: choice.id, label: choice.label }))}
            label={t.runnerLabel}
            onChange={setRunner}
            size="sm"
            value={chosen}
          />
        )}
        <DialogError message={write.error} />
      </div>
    </Dialog>
  );
}

/** Why a device cannot take tasks, and how its user upgrades it. */
function StationNotice({
  notice,
}: {
  notice: NonNullable<BftSwarmDevice["station_notice"]>;
}) {
  return (
    <div className="bft-notice" role="note">
      <strong>{t.stationNotice[notice.reason] ?? t.stationNoticeFallback}</strong>
      <p>{notice.message}</p>
    </div>
  );
}

function DevicesSection({
  org,
  project,
  data,
  loading,
  notify,
  onRetry,
}: {
  org: string;
  project: string;
  data: BftSwarmDevices;
  loading: boolean;
  notify: (notice: string) => void;
  onRetry: () => void;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const manage = data.project.role === "admin";

  return (
    <FormSection
      action={
        <Button
          className="bft-panel-link"
          hierarchy="tertiary-gray"
          isDisabled={loading}
          onPress={onRetry}
          size="xs"
        >
          {t.refresh}
        </Button>
      }
      description={t.listNote}
      title={t.listTitle}
    >
      {data.provisioning ? (
        <output className="bft-quiet bft-quiet-inline">{t.provisioning}</output>
      ) : null}
      {data.devices.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.noDevices}</p>
      ) : (
        <div className="bft-devices-table">
          <table className="bft-table bft-devices">
            <thead>
              <tr>
                <th scope="col">{t.columnName}</th>
                <th className="bft-col-status" scope="col">
                  {t.columnStatus}
                </th>
                <th className="bft-col-runtimes" scope="col">
                  {t.columnRuntimes}
                </th>
                <th className="bft-col-host" scope="col">
                  {t.columnHost}
                </th>
                <th className="bft-col-cpu" scope="col">
                  {t.columnCpu}
                </th>
                <th className="bft-col-seen" scope="col">
                  {t.columnLastSeen}
                </th>
                <th className="bft-col-menu" scope="col">
                  <span className="bft-sr-only">{t.columnActions}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {data.devices.map((device) => (
                <Fragment key={device.id}>
                  <tr data-notice={device.station_notice ? "" : undefined}>
                    <td>
                      <Cell
                        main={
                          <span title={deviceName(device)}>{deviceName(device)}</span>
                        }
                      />
                    </td>
                    <td className="bft-col-status">
                      <State value={device.status} />
                    </td>
                    <td className="bft-col-runtimes">
                      {device.runtimes.length === 0 ? (
                        <span className="bft-muted">{t.noRuntime}</span>
                      ) : (
                        device.runtimes.map((runtime) => (
                          <span className="bft-cell-main" key={runtime.id}>
                            {runtime.provider}
                            {runtime.version ? (
                              <span className="bft-muted"> {runtime.version}</span>
                            ) : null}
                          </span>
                        ))
                      )}
                    </td>
                    <td className="bft-col-host">
                      <Cell main={device.host ?? "—"} sub={device.os} />
                    </td>
                    <td className="bft-col-cpu">
                      <Cell
                        main={
                          <span title={device.cpu_model ?? undefined}>
                            {device.cpu_model ?? "—"}
                          </span>
                        }
                        sub={
                          [
                            device.cpu_count ? t.cores(device.cpu_count) : null,
                            device.memory_bytes
                              ? formatBytes(device.memory_bytes)
                              : null,
                          ]
                            .filter(Boolean)
                            .join(" · ") || null
                        }
                      />
                    </td>
                    <td className="bft-col-seen">
                      <Cell
                        main={
                          <span title={device.last_seen_at ?? undefined}>
                            {relative(device.last_seen_at)}
                          </span>
                        }
                        sub={
                          device.info_updated_at
                            ? t.infoUpdated(relative(device.info_updated_at))
                            : null
                        }
                      />
                    </td>
                    <td className="bft-col-menu">
                      {manage ? (
                        <RowMenu
                          items={[
                            ...(device.disconnectable
                              ? [
                                  {
                                    id: "disconnect",
                                    label: t.disconnect,
                                    onAction: () =>
                                      confirm.ask({
                                        title: t.disconnectTitle,
                                        description: t.disconnectBody(
                                          deviceName(device)
                                        ),
                                        confirmLabel: t.disconnect,
                                        action: () =>
                                          api
                                            .disconnectDevice(org, project, device.id)
                                            .then(({ notice }) => notify(notice)),
                                      }),
                                  },
                                ]
                              : []),
                            {
                              id: "delete",
                              label: t.delete,
                              destructive: true,
                              onAction: () =>
                                confirm.ask({
                                  title: t.deleteTitle,
                                  description: t.deleteBody(deviceName(device)),
                                  confirmLabel: t.delete,
                                  action: () =>
                                    api
                                      .deleteDevice(org, project, device.id)
                                      .then(({ notice }) => notify(notice)),
                                }),
                            },
                          ]}
                          name={deviceName(device)}
                        />
                      ) : null}
                    </td>
                  </tr>
                  {device.station_notice ? (
                    <tr className="bft-device-notice-row">
                      <td colSpan={7}>
                        <StationNotice notice={device.station_notice} />
                      </td>
                    </tr>
                  ) : null}
                </Fragment>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {confirm.dialog}
    </FormSection>
  );
}

function ComputeSection({
  org,
  project,
  data,
  notify,
  fail,
  onRetry,
}: {
  org: string;
  project: string;
  data: BftSwarmDevices;
  notify: (notice: string) => void;
  fail: (error: unknown) => void;
  onRetry: () => void;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const manage = data.project.role === "admin";
  const { compute } = data;
  const intent = (environment: BftComputeEnvironment, next: "drain" | "revoke") => {
    api
      .setEnvironmentIntent(org, project, environment.id, next, environment.revision)
      .then(
        ({ notice }) => notify(notice),
        (error: unknown) => fail(error)
      );
  };

  return (
    <FormSection description={t.computeNote} title={t.computeTitle}>
      {compute.status === "unavailable" ? (
        <div className="bft-quiet-row bft-quiet-row-flush">
          <p className="bft-quiet bft-quiet-inline">{t.computeUnavailable}</p>
          <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
            {messages.states.retry}
          </button>
        </div>
      ) : compute.environments.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.computeEmpty}</p>
      ) : (
        <table className="bft-table">
          <thead>
            <tr>
              <th scope="col">{t.columnEnvironment}</th>
              <th className="bft-col-state" scope="col">
                {t.columnIntent}
              </th>
              <th className="bft-col-state" scope="col">
                {t.columnReadiness}
              </th>
              {manage ? (
                <th className="bft-col-menu" scope="col">
                  <span className="bft-sr-only">{t.columnActions}</span>
                </th>
              ) : null}
            </tr>
          </thead>
          <tbody>
            {compute.environments.map((environment) => (
              <tr key={environment.id}>
                <td className="bft-mono" title={environment.id}>
                  {environment.id}
                </td>
                <td className="bft-col-state">
                  <State value={environment.desired_state} />
                </td>
                <td className="bft-col-state">
                  <State value={environment.observed_state} />
                </td>
                {manage ? (
                  <td className="bft-col-menu">
                    {environment.desired_state !== "revoked" ? (
                      <RowMenu
                        items={[
                          ...(environment.desired_state === "ready"
                            ? [
                                {
                                  id: "shell",
                                  label: t.createShell,
                                  onAction: () =>
                                    confirm.ask({
                                      title: t.createShell,
                                      description: t.shellBody,
                                      confirmLabel: t.createShell,
                                      action: () =>
                                        api
                                          .createShellWorkload(
                                            org,
                                            project,
                                            environment.id
                                          )
                                          .then(({ notice }) => notify(notice)),
                                    }),
                                },
                                {
                                  id: "drain",
                                  label: t.drain,
                                  onAction: () => intent(environment, "drain"),
                                },
                              ]
                            : []),
                          {
                            id: "revoke",
                            label: t.revoke,
                            destructive: true,
                            onAction: () => intent(environment, "revoke"),
                          },
                        ]}
                        name={environment.id}
                      />
                    ) : null}
                  </td>
                ) : null}
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {compute.workloads.length > 0 ? (
        <table aria-label={t.workloadsTitle} className="bft-table">
          <thead>
            <tr>
              <th scope="col">{t.columnWorkload}</th>
              <th className="bft-col-state" scope="col">
                {t.columnKind}
              </th>
              <th className="bft-col-state" scope="col">
                {t.columnStatus}
              </th>
            </tr>
          </thead>
          <tbody>
            {compute.workloads.map((workload) => (
              <tr key={workload.id}>
                <td className="bft-mono" title={workload.id}>
                  {workload.id}
                </td>
                <td className="bft-col-state">{workload.kind}</td>
                <td className="bft-col-state">
                  <State value={workload.observed_state} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

function AndroidSection({ data }: { data: BftSwarmDevices }) {
  const { android } = data;
  const devices = data.devices.filter(
    (device): device is BftSwarmDevice & { android: BftAndroidDevice } =>
      !!device.android
  );

  return (
    <FormSection
      action={
        <span
          className="bft-status"
          data-tone={
            android.setup === "connected"
              ? "ok"
              : android.setup === "needs_attention"
                ? "warn"
                : "neutral"
          }
        >
          {t.androidSetups[android.setup]}
        </span>
      }
      description={t.androidNote}
      title={t.androidTitle}
    >
      {android.status === "unavailable" ? (
        <p className="bft-quiet bft-quiet-inline">{t.androidUnavailable}</p>
      ) : !android.entitled ? (
        <p className="bft-dialog-note">{t.androidNotEntitled}</p>
      ) : (
        <>
          <p className="bft-dialog-note">
            {t.allowedProfiles(android.profiles.join(", "))} · {t.oneLease}
          </p>
          <p className="bft-dialog-note">
            {android.registered ? t.androidRegistered : t.androidAskAdmin}
          </p>
        </>
      )}
      {devices.length > 0 ? (
        <ul className="bft-list bft-android-list">
          {devices.map((device) => (
            <AndroidDevice device={device} key={device.id} />
          ))}
        </ul>
      ) : null}
    </FormSection>
  );
}

function AndroidDevice({
  device,
}: {
  device: BftSwarmDevice & { android: BftAndroidDevice };
}) {
  const facts = device.android;
  const lines = [
    t.configuredProfiles(facts.profiles.join(", ")),
    t.defaultProfile(facts.default_profile ?? t.unknownProfile),
    facts.active_profile ? t.currentProfile(facts.active_profile) : null,
    facts.target_profile ? t.targetProfile(facts.target_profile) : null,
    facts.phase ? t.phase(t.androidPhases[facts.phase] ?? t.statusUnavailable) : null,
    t.androidState(
      (facts.state && t.androidStates[facts.state]) ?? t.statusUnavailable
    ),
    facts.available_slots !== null && facts.capacity !== null
      ? t.slots(facts.available_slots, facts.capacity)
      : null,
  ].filter((line): line is string => line !== null);

  return (
    <li className="bft-android-device">
      <span className="bft-cell-main">{deviceName(device)}</span>
      {lines.map((line) => (
        <span className="bft-cell-sub" key={line}>
          {line}
        </span>
      ))}
    </li>
  );
}

/**
 * Add a device on an online runner. The runner list is read when the dialog
 * opens and again on "Check for runners"; one dialog serves every state.
 */
function AddDeviceDialog({
  org,
  project,
  onClose,
  onCreated,
}: {
  org: string;
  project: string;
  onClose: () => void;
  onCreated: (notice: string) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [runners, retry] = useResource(`device-runners:${org}:${project}`, (signal) =>
    api.deviceRunners(org, project, signal)
  );
  const [name, setName] = useState("");
  const [alias, setAlias] = useState("");
  const [runner, setRunner] = useState<string>();
  const choices = runners.state === "ready" ? runners.data.runners : [];
  const none = runners.state === "ready" && choices.length === 0;
  const chosen = runner ?? choices[0]?.id ?? "";
  const close = () => {
    if (!write.busy) onClose();
  };
  const submit = () =>
    write.run(
      () =>
        api.createDevice(org, project, {
          name: name.trim(),
          alias: alias.trim(),
          runner_id: chosen,
        }),
      ({ notice }) => onCreated(notice)
    );

  return (
    <Dialog
      actions={[
        {
          label: messages.common.cancel,
          hierarchy: "secondary-gray",
          onPress: close,
          disabled: write.busy,
        },
        none || runners.state === "error"
          ? { label: t.checkRunners, hierarchy: "primary", onPress: retry }
          : {
              label: write.busy ? messages.settings.saving : t.createOnRunner,
              hierarchy: "primary",
              onPress: submit,
              disabled: write.busy || choices.length === 0,
            },
      ]}
      description={none ? t.noRunnersBody : t.addBody}
      isDismissable={!write.busy}
      isOpen
      onOpenChange={(open) => {
        if (!open) close();
      }}
      title={none ? t.noRunnersTitle : t.addDevice}
    >
      <div className="bft-form">
        {runners.state === "loading" ? (
          <output className="bft-rows-skeleton bft-rows-skeleton-flush">
            <Skeleton height={32} />
            <span className="bft-sr-only">{t.runnersLoading}</span>
          </output>
        ) : runners.state === "error" ? (
          <p className="bft-dialog-error" role="alert">
            {t.runnersUnavailable}
          </p>
        ) : none ? (
          <a
            className="bft-link"
            href={runners.data.runners_href}
            onClick={spaLinkClick}
          >
            {t.openRunners}
          </a>
        ) : (
          <>
            <TextField
              disabled={write.busy}
              error={write.fields.name}
              label={t.nameLabel}
              onChange={setName}
              placeholder={t.namePlaceholder}
              value={name}
            />
            <TextField
              disabled={write.busy}
              error={write.fields.alias ?? write.fields.env_alias}
              label={t.aliasLabel}
              onChange={setAlias}
              placeholder={t.aliasPlaceholder}
              value={alias}
            />
            <Dropdown
              className="bft-form-field"
              disabled={write.busy}
              items={choices.map((choice) => ({ id: choice.id, label: choice.label }))}
              label={t.runnerLabel}
              onChange={setRunner}
              size="sm"
              value={chosen}
            />
          </>
        )}
        <DialogError message={write.error} />
      </div>
    </Dialog>
  );
}
