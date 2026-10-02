import {
  Button,
  Dialog,
  Dropdown,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  MoreHorizontalIcon,
  Toggle,
} from "@comma/ui";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import type {
  BftAndroidDevice,
  BftComputeEnvironment,
  BftRuntimeAuthRequests,
  BftRuntimeAuthTarget,
  BftSwarmDevice,
  BftSwarmDevices,
} from "./api";
import { DialogError, writeErrorMessage } from "./dialogs";
import { showFlash } from "./flash";
import { formatBytes, formatRelative, humanize } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { useApi, useResource, type Resource } from "./resource";
import { navigate, spaLinkClick } from "./router";
import { RuntimeAuthDialog } from "./RuntimeAuthDialog";
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
  draining: "warn",
  provisioning: "warn",
  disconnected: "error",
  offline: "error",
  failed: "error",
  error: "error",
  revoked: "error",
};

function State({ value }: { value: string | null }) {
  if (!value) return <span className="bft-muted">—</span>;
  return (
    <span className="bft-status" data-tone={tones[value] ?? "neutral"}>
      <span className="bft-truncate">{t.states[value] ?? humanize(value)}</span>
    </span>
  );
}

/** The device address a Router-request management link names. */
export function deviceLink(search: string) {
  const params = new URLSearchParams(search);
  return {
    target: params.get("runtime_auth_target"),
    request: params.get("runtime_auth_request"),
  };
}

const deviceName = (device: BftSwarmDevice) => device.name ?? t.unnamed;

interface OpenAuth {
  target: Pick<BftRuntimeAuthTarget, "id" | "provider" | "target" | "managed">;
  requestId: string | null;
}

/**
 * An Agent Swarm's devices: the fixed cloud computer and the connectors
 * registered to the swarm, their runtime authentication, Compute
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
  const [auth, setAuth] = useState<OpenAuth | null>(null);
  // Every page read, and every closed auth dialog, re-reads the Router requests.
  const [reads, setReads] = useState(0);
  const seen = useRef<BftSwarmDevices | undefined>(undefined);
  useEffect(() => {
    if (data && data !== seen.current) {
      seen.current = data;
      setReads((count) => count + 1);
    }
  }, [data]);
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

  // A management link opens its target once, then leaves the address.
  const linkOpened = useRef(false);
  useEffect(() => {
    if (!data || linkOpened.current) return;
    linkOpened.current = true;
    const link = deviceLink(window.location.search);
    if (!link.target) return;
    const admin = data.project.role === "admin";
    const row = data.runtime_auth.targets.find((item) => item.id === link.target);
    const request =
      data.runtime_auth.request?.target.workload_id === link.target
        ? data.runtime_auth.request.request_id
        : null;
    if (row && (admin || row.managed)) setAuth({ target: row, requestId: request });
    else if (!row && request && admin)
      setAuth({
        target: {
          id: link.target,
          provider: t.providerPending,
          target: { kind: "compute_workload", workload_id: link.target },
          managed: true,
        },
        requestId: request,
      });
  }, [data]);

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
            <DevicesSection
              data={page}
              fail={fail}
              loading={first.state === "loading"}
              notify={notify}
              onRetry={onRetry}
              org={org}
              project={project}
            />
            <AuthSection
              data={page}
              onOpen={setAuth}
              org={org}
              project={project}
              reads={reads}
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
      {auth && data ? (
        <RuntimeAuthDialog
          canManage={data.project.role === "admin"}
          key={auth.target.id}
          onClose={() => {
            setAuth(null);
            setReads((count) => count + 1);
            if (window.location.search) navigate(devicesPath, { replace: true });
          }}
          org={org}
          project={project}
          requestId={auth.requestId}
          target={auth.target}
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

interface RowAction {
  id: string;
  label: string;
  destructive?: boolean;
  onAction: () => void;
}

/** A row's writes behind one "more" button; destructive ones come last. */
function RowMenu({ name, items }: { name: string; items: RowAction[] }) {
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

function DevicesSection({
  org,
  project,
  data,
  loading,
  notify,
  fail,
  onRetry,
}: {
  org: string;
  project: string;
  data: BftSwarmDevices;
  loading: boolean;
  notify: (notice: string) => void;
  fail: (error: unknown) => void;
  onRetry: () => void;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const [saving, setSaving] = useState(false);
  const manage = data.project.role === "admin";
  const toggleCloud = (enabled: boolean) => {
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
            <tr>
              <td>
                <Cell main={t.cloudName} sub={t.cloudNote} />
              </td>
              <td className="bft-col-status">
                <State value={data.cloud.enabled ? "enabled" : "disabled"} />
              </td>
              <td className="bft-col-runtimes">
                <span className="bft-muted">—</span>
              </td>
              <td className="bft-col-host">
                <Cell main={t.cloudHost} sub={t.cloudHostNote} />
              </td>
              <td className="bft-col-cpu">
                <Cell main={t.cloudCapacity} />
              </td>
              <td className="bft-col-seen">
                <span className="bft-muted">—</span>
              </td>
              <td className="bft-col-menu">
                {data.cloud.manageable ? (
                  <Toggle
                    aria-label={t.cloudToggle}
                    checked={data.cloud.enabled}
                    disabled={saving || loading}
                    onChange={(event) => toggleCloud(event.target.checked)}
                    size="sm"
                  />
                ) : null}
              </td>
            </tr>
            {data.devices.map((device) => (
              <tr key={device.id}>
                <td>
                  <Cell
                    main={<span title={deviceName(device)}>{deviceName(device)}</span>}
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
                        device.memory_bytes ? formatBytes(device.memory_bytes) : null,
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
                                    description: t.disconnectBody(deviceName(device)),
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
            ))}
          </tbody>
        </table>
      </div>
      {confirm.dialog}
    </FormSection>
  );
}

function AuthSection({
  org,
  project,
  data,
  onOpen,
  reads,
}: {
  org: string;
  project: string;
  data: BftSwarmDevices;
  onOpen: (auth: OpenAuth) => void;
  reads: number;
}) {
  const manage = data.project.role === "admin";
  const { targets } = data.runtime_auth;
  const openRequest = (workload: string, requestId: string) =>
    onOpen({
      target: targets.find((item) => item.id === workload) ?? {
        id: workload,
        provider: t.providerPending,
        target: { kind: "compute_workload", workload_id: workload },
        managed: true,
      },
      requestId,
    });

  return (
    <FormSection description={t.authNote} title={t.authTitle}>
      <RouterRequests
        manage={manage}
        onOpen={openRequest}
        org={org}
        project={project}
        reads={reads}
      />
      {targets.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.noTargets}</p>
      ) : (
        <table className="bft-table">
          <thead>
            <tr>
              <th scope="col">{t.columnTarget}</th>
              <th className="bft-col-provider" scope="col">
                {t.columnProvider}
              </th>
              <th className="bft-col-status" scope="col">
                {t.columnRuntime}
              </th>
              <th className="bft-col-auth-action" scope="col">
                <span className="bft-sr-only">{t.columnActions}</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {targets.map((target) => (
              <tr key={`${target.target.kind}:${target.id}`}>
                <td className="bft-mono" title={target.id}>
                  {target.id}
                </td>
                <td className="bft-col-provider">{target.provider}</td>
                <td className="bft-col-status">
                  <State value={target.status} />
                </td>
                <td className="bft-col-auth-action">
                  {manage || target.managed ? (
                    <button
                      aria-label={`${manage ? t.manage : t.view} ${target.id}`}
                      className="bft-btn bft-btn-sm"
                      onClick={() => onOpen({ target, requestId: null })}
                      type="button"
                    >
                      {manage ? t.manage : t.view}
                    </button>
                  ) : (
                    <span className="bft-muted">{t.needsAdmin}</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </FormSection>
  );
}

/** Router requests waiting for an admin, one page of 50 at a time. */
function RouterRequests({
  org,
  project,
  manage,
  onOpen,
  reads,
}: {
  org: string;
  project: string;
  manage: boolean;
  onOpen: (workload: string, requestId: string) => void;
  reads: number;
}) {
  const api = useApi();
  const [cursor, setCursor] = useState<string | null>(null);
  const [page] = useResource<BftRuntimeAuthRequests>(
    `runtime-auth-requests:${org}:${project}:${cursor ?? ""}:${reads}`,
    (signal) => api.runtimeAuthRequests(org, project, cursor, signal)
  );
  if (page.state === "loading") return null;
  if (page.state === "error")
    return <p className="bft-quiet bft-quiet-inline">{t.requestsUnavailable}</p>;
  const { runtime_auth_requests: requests, next_cursor: next } = page.data;
  if (requests.length === 0 && !next) return null;

  return (
    <section aria-label={t.requestsTitle} className="bft-auth-requests">
      <p className="bft-field-label">{t.requestsTitle}</p>
      <ul className="bft-list">
        {requests.map((request) => {
          const workload = request.target?.workload_id;
          return (
            <li className="bft-auth-request" key={request.request_id}>
              <span className="bft-mono bft-truncate">
                {[request.action, workload].filter(Boolean).join(" · ")}
              </span>
              {manage && workload ? (
                <button
                  className="bft-btn bft-btn-sm"
                  onClick={() => onOpen(workload, request.request_id)}
                  type="button"
                >
                  {t.handle}
                </button>
              ) : (
                <span className="bft-muted">{t.needsAdmin}</span>
              )}
            </li>
          );
        })}
      </ul>
      {next ? (
        <div>
          <button
            className="bft-btn bft-btn-sm"
            onClick={() => setCursor(next)}
            type="button"
          >
            {t.nextPage}
          </button>
        </div>
      ) : null}
    </section>
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
