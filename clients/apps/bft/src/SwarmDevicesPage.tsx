import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { Dropdown } from "@comma/ui/components/dropdown";
import { InputField } from "@comma/ui/components/input";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
} from "@comma/ui/components/menu";
import { MoreHorizontalIcon } from "@comma/ui/components/icons";
import { Fragment, useCallback, useRef, useState, type ReactNode } from "react";
import type {
  BftAndroidDevice,
  BftCloudVm,
  BftComputeEnvironment,
  BftComputeInstallCommand,
  BftSwarmDevice,
  BftSwarmDevices,
} from "./api";
import { DialogError, writeErrorMessage } from "./dialogs";
import { InstallCommand, installErrorMessage } from "./AddRunnerDialog";
import { HardwareSetupDialog } from "./HardwareSetupDialog";
import { showFlash } from "./flash";
import { formatBytes, formatRelative, humanize } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { useApi, useResource, type Resource } from "./resource";
import { spaLinkClick } from "./router";
import { FormSection, SettingsPage, useConfirm, useWrite } from "./settingsForm";
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
 * Compute Host it uses), the connectors registered to the swarm, Compute
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
  const last = useRef<BftSwarmDevices | undefined>(undefined);
  if (first.state === "ready") last.current = first.data;
  const data = first.state === "ready" ? first.data : last.current;
  const resource: Resource<BftSwarmDevices> = data ? { state: "ready", data } : first;
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

  return (
    <>
      <SettingsPage
        description={data ? t.description(data.project.name) : undefined}
        onRetry={onRetry}
        resource={resource}
        title={t.title}
        wide
      >
        {(page) => (
          <>
            {page.cloud_vm ? (
              <CloudVmSection
                data={page.cloud_vm}
                notify={notify}
                org={org}
                project={project}
              />
            ) : null}
            <DevicesSection
              data={page}
              fail={fail}
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
    </>
  );
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
 * The swarm's Cloud VM and its separate VMM Station Host.
 * An admin controls the Host authorization.
 */
function CloudVmSection({
  org,
  project,
  data,
  notify,
}: {
  org: string;
  project: string;
  data: BftCloudVm;
  notify: (notice: string) => void;
}) {
  const api = useApi();
  const confirm = useConfirm();
  const [choosing, setChoosing] = useState(false);
  const { vm, runner } = data;
  const runnerName = runner?.name ?? t.otherHost;
  const status = !data.enabled && !vm ? null : (vm?.status ?? null);

  return (
    <FormSection description={t.cloudVmNote} title={t.cloudVmTitle}>
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
  const manage = data.project.role === "admin";
  const [settingUp, setSettingUp] = useState(false);
  const [addingComputer, setAddingComputer] = useState(false);
  // The list is a server-side copy the registry refreshes in turn; read the
  // registry for this swarm first so a board just set up shows at once.
  const refresh = () => api.refreshDevices(org, project).then(onRetry, fail);

  return (
    <FormSection
      action={
        <>
          <Button
            className="bft-panel-link"
            hierarchy="tertiary-gray"
            isDisabled={loading}
            onPress={refresh}
            size="xs"
          >
            {t.refresh}
          </Button>
          {manage ? (
            <>
              <Button
                hierarchy="secondary-gray"
                onPress={() => setSettingUp(true)}
                size="sm"
              >
                {t.addHardware}
              </Button>
              <Button
                hierarchy="primary"
                onPress={() => setAddingComputer(true)}
                size="sm"
              >
                {t.addComputer}
              </Button>
            </>
          ) : null}
        </>
      }
      description={t.listNote}
      title={t.listTitle}
    >
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
                        sub={
                          device.hardware
                            ? `${t.hardwareGateway} · ${
                                device.allows_operations
                                  ? t.operationsAllowed
                                  : t.readOnly
                              }`
                            : undefined
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
                            ...(device.hardware
                              ? [
                                  {
                                    id: "operations",
                                    label: device.allows_operations
                                      ? t.blockOperations
                                      : t.allowOperations,
                                    onAction: () =>
                                      api
                                        .setDeviceOperations(
                                          org,
                                          project,
                                          device.id,
                                          !device.allows_operations
                                        )
                                        .then(({ notice }) => notify(notice), fail),
                                  },
                                ]
                              : []),
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
      {settingUp ? (
        <HardwareSetupDialog
          onClose={() => {
            setSettingUp(false);
            void refresh();
          }}
          org={org}
          project={project}
        />
      ) : null}
      {addingComputer ? (
        <AddComputerDialog
          onClose={() => {
            setAddingComputer(false);
            void refresh();
          }}
          org={org}
          project={project}
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

/** The one-time command that installs the station on a computer of this swarm. */
function AddComputerDialog({
  org,
  project,
  onClose,
}: {
  org: string;
  project: string;
  onClose: () => void;
}) {
  const api = useApi();
  const [name, setName] = useState("");
  const [issued, setIssued] = useState<BftComputeInstallCommand>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const generate = () => {
    setBusy(true);
    setError(undefined);
    void api.createStationInstallCommand(org, project, name.trim()).then(
      (answer) => {
        setIssued(answer);
        setBusy(false);
      },
      (caught: unknown) => {
        setError(writeErrorMessage(caught));
        setBusy(false);
      }
    );
  };
  return (
    <Dialog
      isOpen
      isDismissable={!busy}
      className="bft-dialog-wide"
      title={t.addComputer}
      description={t.addComputerBody}
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
      actions={[
        {
          label: messages.runners.done,
          hierarchy: "secondary-gray",
          onPress: onClose,
          disabled: busy,
        },
      ]}
    >
      {issued ? (
        <InstallCommand issued={issued} />
      ) : (
        <>
          <InputField
            className="w-full"
            disabled={busy}
            fieldSize="sm"
            label={t.computerName}
            onChange={(event) => setName(event.target.value)}
            value={name}
            wrapperClassName="bft-form-field"
          />
          <Button
            hierarchy="primary"
            isDisabled={busy || name.trim() === ""}
            onPress={generate}
          >
            {t.generateComputerCommand}
          </Button>
        </>
      )}
      {error ? <DialogError message={error} /> : null}
    </Dialog>
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
  const [installOpen, setInstallOpen] = useState(false);
  const intent = (environment: BftComputeEnvironment, next: "drain" | "revoke") => {
    api
      .setEnvironmentIntent(org, project, environment.id, next, environment.revision)
      .then(
        ({ notice }) => notify(notice),
        (error: unknown) => fail(error)
      );
  };

  return (
    <FormSection
      description={t.computeNote}
      title={t.computeTitle}
      action={
        manage && !data.cloud_vm?.runner ? (
          <Button
            hierarchy="secondary-gray"
            size="sm"
            onPress={() => setInstallOpen(true)}
          >
            {t.installHost}
          </Button>
        ) : undefined
      }
    >
      {installOpen ? (
        <ComputeHostInstallDialog
          key={`${org}:${project}`}
          org={org}
          project={project}
          onClose={() => {
            setInstallOpen(false);
            onRetry();
          }}
        />
      ) : null}
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

function ComputeHostInstallDialog({
  org,
  project,
  onClose,
}: {
  org: string;
  project: string;
  onClose: () => void;
}) {
  const api = useApi();
  const requestId = useRef<string | undefined>(undefined);
  const [issued, setIssued] = useState<BftComputeInstallCommand>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const generate = () => {
    requestId.current ??= crypto.randomUUID();
    setBusy(true);
    setError(undefined);
    void api.createComputeInstallCommand(org, project, requestId.current).then(
      (answer) => {
        setIssued(answer);
        setBusy(false);
      },
      (caught: unknown) => {
        setError(installErrorMessage(caught));
        setBusy(false);
      }
    );
  };
  return (
    <Dialog
      isOpen
      isDismissable={!busy}
      className="bft-dialog-wide"
      title={t.installHost}
      description={t.installHostBody}
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
      actions={[
        {
          label: messages.runners.done,
          hierarchy: "secondary-gray",
          onPress: onClose,
          disabled: busy,
        },
      ]}
    >
      {issued ? (
        <InstallCommand issued={issued} />
      ) : (
        <Button hierarchy="primary" isDisabled={busy} onPress={generate}>
          {t.generateHostCommand}
        </Button>
      )}
      {error ? <DialogError message={error} /> : null}
    </Dialog>
  );
}
