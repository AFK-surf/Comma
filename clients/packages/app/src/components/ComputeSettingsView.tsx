import { useEffect, useRef, useState, type ReactNode } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { MoreHorizontalIcon } from "@comma/ui/components/icons";
import {
  DeviceSettingsSection as Section,
  DeviceSettingsRow as Row,
  DeviceSettingsFacts as Facts,
  DeviceSettingsStatus as Status,
  DeviceSettingsSteps as Steps,
  DeviceSettingsResource,
  DeviceSettingsDetail,
  deviceSettingsButtonClassName,
  deviceSettingsMenuClassName,
} from "@comma/ui/components/settings";
import {
  ComputeDiskUsage,
  formatComputeBytes,
} from "@comma/ui/components/compute-disk/ComputeDiskUsage";
import type { useComputeSettingsController } from "./useComputeSettingsController";
import type { ComputeWorkload as CommaComputeWorkload } from "@comma/core/contract";
import { needsDesktopApp, requestDesktopApp } from "./DesktopAppPrompt";

type Controller = ReturnType<typeof useComputeSettingsController>;

const act = (
  label: string,
  onPress: () => void,
  disabled = false,
  hierarchy:
    | "primary"
    | "secondary-gray"
    | "tertiary-gray"
    | "link-gray"
    | "destructive" = "secondary-gray",
  filledDanger = false
) => (
  <Button
    hierarchy={
      hierarchy === "destructive" && !filledDanger ? "secondary-gray" : hierarchy
    }
    className={[
      hierarchy === "link-gray" ? "text-xs" : deviceSettingsButtonClassName,
      hierarchy === "destructive" && !filledDanger ? "compute-danger" : "",
    ].join(" ")}
    isDisabled={disabled}
    onPress={onPress}
    size="sm"
  >
    {label}
  </Button>
);
const workTone = (item: CommaComputeWorkload) =>
  item.phase === "ready" && !item.deletion && item.desired_state !== "draining"
    ? "good"
    : item.phase === "action_required" ||
        item.phase === "waiting_connection" ||
        item.observed_state === "failed"
      ? "warning"
      : "neutral";

const historical = (item: CommaComputeWorkload) =>
  item.phase === "deleted" ||
  item.phase === "cloud_retired" ||
  item.deletion?.phase === "complete";

export interface ComputeHomeContent {
  localNode: ReactNode;
  workloads: ReactNode;
}
export function ComputeSettingsView({
  controller: c,
  renderHome,
}: {
  controller: Controller;
  renderHome?: (content: ComputeHomeContent) => ReactNode;
}) {
  const m = useCommaMessages();
  const { workloads: w, local: l, state: s } = c;
  const h = l.maintenance;
  const [localScope, setLocalScope] = useState<string>();
  const heading = useRef<HTMLHeadingElement>(null);
  const screen = w.mode ?? c.detail ?? "home";
  useEffect(() => {
    heading.current?.focus();
  }, [screen]);
  const go = (detail: Controller["detail"]) => {
    w.close();
    c.setDetail(detail);
  };
  const home = () => go(c.localOnly ? "settings" : undefined);
  const back =
    screen === "owner"
      ? w.backToWorkload
      : screen === "local" || screen === "maintenance"
        ? () => go("settings")
        : screen === "erase"
          ? () => go("local")
          : home;
  const phaseLabel = (phase: string | undefined) =>
    phase === "ready"
      ? m.compute_setup_ready()
      : phase === "failed"
        ? m.compute_ui_step_failed()
        : phase === "preparing" || phase === "connecting"
          ? m.compute_setup_preparing()
          : phase === "unknown"
            ? m.compute_ui_maintenance_unknown()
            : m.compute_ui_setup_wait();
  const live =
    !c.workspaceUnconfirmed &&
    s?.facets.connection === "connected" &&
    s.observationFresh;
  const kindLabel = (kind: string) =>
    kind === "shell"
      ? "Shell"
      : kind === "meeting"
        ? m.settings_meeting()
        : kind === "service"
          ? m.compute_use_service()
          : kind;
  const primaryLabel =
    c.maintenanceActive || s?.status === "processing"
      ? m.compute_ui_view_progress()
      : c.canFinishRemove
        ? m.compute_finish_remove()
        : c.recoveryNeeded
          ? m.compute_ui_authorize()
          : s?.issue === "capability_missing"
            ? m.compute_maintenance_update()
            : s?.issue === "shell_initialization_pending"
              ? m.compute_continue_shell()
              : c.canEnable
                ? s?.desiredEnabled
                  ? m.compute_continue_enable()
                  : m.compute_enable()
                : m.compute_check_status();
  const primary = () =>
    act(
      primaryLabel,
      c.primary,
      c.busy && !c.maintenanceActive && s?.status !== "processing",
      "primary"
    );
  const nodeStatus = live
    ? m.compute_ui_connected()
    : s?.issue === "connection"
      ? m.compute_ui_not_connected()
      : c.recoveryNeeded
        ? m.compute_ui_authorize()
        : c.status;
  const connectionNote =
    c.problem ?? (s?.issue === "connection" ? m.compute_ui_not_current() : c.reason);
  // Node actions follow the workspace's management permission; a reader sees why there is no action.
  const readOnly = !!w.projection && !w.canManage;
  const abandon = () =>
    c.canAbandon &&
    w.canManage &&
    act(m.compute_close_request(), () => c.openConfirm("abandon"), c.busy, "link-gray");
  const workloadStatus = (item: CommaComputeWorkload) =>
    item.phase === "cloud_retired"
      ? m.compute_cloud_retired()
      : item.phase === "deleted" || item.deletion?.phase === "complete"
        ? m.compute_deleted()
        : item.deletion?.error === "original_device_offline"
          ? m.compute_delete_waiting_original_device()
          : item.deletion
            ? m.compute_deleting()
            : w.stateLabel(item);
  const policy = (item?: CommaComputeWorkload) => (
    <Section title={m.compute_shell_policy()}>
      <div className="compute-panel compute-inset">
        <Facts
          rows={[
            [
              m.compute_ui_disk_limit(),
              item?.runtime_policy
                ? item.runtime_policy.resources.writable_quota_bytes === undefined
                  ? m.compute_activity_unknown()
                  : formatComputeBytes(
                      String(item.runtime_policy.resources.writable_quota_bytes)
                    )
                : item
                  ? m.compute_activity_unknown()
                  : "2 GiB",
            ],
            [
              m.compute_ui_pid_limit(),
              item?.runtime_policy
                ? (item.runtime_policy.resources.pid_max ??
                  m.compute_activity_unknown())
                : item
                  ? m.compute_activity_unknown()
                  : "512",
            ],
            [
              m.compute_ui_network(),
              ["none", "deny_all"].includes(item?.runtime_policy?.egress_mode ?? "") ||
              !item
                ? m.compute_ui_no_network()
                : item.runtime_policy?.egress_mode === "allow_all"
                  ? m.compute_network_allowed()
                  : m.compute_activity_unknown(),
            ],
          ]}
        />
      </div>
      <p className="compute-muted compute-note">{m.compute_ui_template_managed()}</p>
    </Section>
  );
  const maintenance = c.startMaintenance;
  const menu = (item: CommaComputeWorkload) => (
    <MenuTrigger>
      <Button
        className={`compute-menu ${deviceSettingsMenuClassName}`}
        hierarchy="tertiary-gray"
        size="xs"
        iconOnly
        iconLeading={<MoreHorizontalIcon />}
        aria-label={`${w.workloadLabel(item)} ${m.compute_more()}`}
      />
      <MenuPopover>
        <Menu>
          <MenuItem id="details" onAction={() => w.openWorkload(item)}>
            {m.compute_details()}
          </MenuItem>
          {(item.uses ?? []).map((use) => (
            <MenuItem
              id={`use-${use.kind}-${use.id}`}
              key={`${use.kind}-${use.id}`}
              onAction={() => {
                w.openWorkload(item);
                w.openUse(use);
              }}
            >
              {use.label ?? m.compute_usage()}
            </MenuItem>
          ))}
          {item.actions?.retry && (
            <MenuItem
              id="retry"
              isDisabled={w.pending}
              onAction={() => void w.retry(item)}
            >
              {m.compute_retry_workload()}
            </MenuItem>
          )}
          {item.actions?.rename && (
            <MenuItem
              id="rename"
              isDisabled={w.pending}
              onAction={() => w.openDialog("rename", item)}
            >
              {m.compute_rename()}
            </MenuItem>
          )}
          {item.actions?.delete && (
            <MenuItem
              id="delete"
              tone="destructive"
              isDisabled={w.pending}
              onAction={() => w.openDialog("delete", item)}
            >
              {w.deleteLabel(item)}
            </MenuItem>
          )}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
  const title =
    screen === "home"
      ? m.settings_compute_node()
      : screen === "settings"
        ? m.compute_local_settings()
        : screen === "local"
          ? m.compute_ui_storage()
          : screen === "erase"
            ? m.compute_clear_all_data()
            : screen === "authorization"
              ? m.compute_ui_authorize()
              : screen === "setup"
                ? m.compute_setup_title()
                : screen === "maintenance"
                  ? m.compute_maintenance_title()
                  : screen === "create"
                    ? m.compute_new_shell()
                    : screen === "owner"
                      ? (w.selectedUse?.label ?? m.compute_usage())
                      : screen === "diagnostics"
                        ? m.compute_diagnostics()
                        : w.current
                          ? w.workloadLabel(w.current)
                          : m.compute_details();
  const disk = l.data?.disk;
  const diskSummary = disk
    ? m.compute_disk_summary({
        used: formatComputeBytes(disk.usedBytes),
        capacity: formatComputeBytes(disk.capacityBytes),
      })
    : m.compute_disk_unavailable();
  const time = l.data?.collectedAt
    ? new Date(l.data.collectedAt).toLocaleString()
    : undefined;
  const storageTime = time
    ? l.fresh
      ? m.compute_disk_read_at({ time })
      : m.compute_disk_old_at({ time })
    : m.compute_disk_unavailable();
  const diagnostics = (
    <details className="compute-diagnostics">
      <summary>{m.compute_diagnostics()}</summary>
      <Facts
        rows={[
          [m.compute_bound_workspace(), c.binding ?? m.compute_no_workspace()],
          [
            m.compute_maintenance_version(),
            h.state?.installedReleaseId ?? m.compute_maintenance_unknown(),
          ],
          [
            m.compute_maintenance_target_version(),
            h.state?.selectedReleaseId ?? m.compute_maintenance_unknown(),
          ],
          [m.compute_last_check(), s?.observedAt ?? m.compute_activity_unknown()],
          [
            m.settings_compute_node_status(),
            s
              ? `${s.facets.connection} · ${s.facets.admission} · ${s.facets.runtimeReadiness} · work: ${s.facets.workActivity};`
              : m.compute_activity_unknown(),
          ],
        ]}
      />
      {c.problemDetail && <p>{c.problemDetail}</p>}
      {c.reasonDetail && <p>{c.reasonDetail}</p>}
      {h.state?.operation?.problem && <p>{h.state.operation.problem}</p>}
      {act(m.compute_check_status(), c.checkWorkspace)}
    </details>
  );
  // In the desktop app on a computer that cannot host one (Windows, an Intel Mac) there is nothing to show of it:
  // a person who never heard of compute environments is not told about one they cannot have.
  const localNode =
    !needsDesktopApp() && (!c.node.available || !c.eligible) ? null : (
      <section
        className="compute-node-summary"
        aria-label={m.compute_capability_title()}
      >
        <div className="compute-section-heading">
          <h2>{m.compute_capability_title()}</h2>
          <Status
            tone={live && !s?.issue ? "good" : s?.issue ? "warning" : "neutral"}
            pending={s?.status === "processing"}
          >
            {c.maintenanceActive ? h.title : nodeStatus}
          </Status>
        </div>
        {!c.node.available || !c.eligible ? (
          <div className="compute-row">
            <p className="compute-muted">{m.compute_ui_desktop_help()}</p>
            {act(m.compute_ui_desktop(), () => requestDesktopApp("compute-node"))}
          </div>
        ) : (
          <>
            <div className="compute-row">
              <div>
                <p className="compute-node-name">
                  {c.workspaceLabel(c.binding ?? c.workspaceId)}
                </p>
                <p className="compute-muted">
                  {c.maintenanceActive
                    ? h.failed
                      ? `${h.title} ${m.compute_ui_repair_note()}`
                      : m.compute_maintenance_shared_scope()
                    : live && !s?.issue
                      ? m.compute_ui_ready_note()
                      : connectionNote}
                </p>
                {s?.issue === "connection" && s.observedAt && (
                  <p className="compute-muted">
                    {m.compute_confirmed_at({
                      time: new Date(s.observedAt).toLocaleString(),
                    })}
                  </p>
                )}
              </div>
              {(c.maintenanceActive || (w.canManage && (!live || s?.issue))) &&
                primary()}
            </div>
            {readOnly && !c.maintenanceActive && (
              <p className="compute-muted">{m.compute_ui_readonly()}</p>
            )}
            <div className="compute-summary-actions">
              <span className="compute-muted">
                {c.maintenanceActive
                  ? m.compute_ui_back_progress()
                  : h.needsInstall && l.data?.disk
                    ? m.compute_ui_retained()
                    : h.title}
              </span>
              {abandon()}
              {act(
                m.compute_local_settings(),
                () => go("settings"),
                false,
                "link-gray"
              )}
            </div>
          </>
        )}
      </section>
    );
  const resource = (item: CommaComputeWorkload) => (
    <DeviceSettingsResource
      key={item.id}
      name={w.workloadLabel(item)}
      description={`${kindLabel(item.kind)} · ${w.location(item)}`}
      onOpen={() => w.openWorkload(item)}
      actions={menu(item)}
      status={
        <Status
          tone={workTone(item)}
          pending={["allocating", "starting"].includes(item.phase ?? "")}
        >
          {workloadStatus(item)}
        </Status>
      }
    />
  );
  const workloads = (
    <Section
      title={m.compute_workspace_workloads()}
      action={
        w.canManage &&
        act(m.compute_new_shell(), w.openCreate, w.pending || !!w.creation)
      }
    >
      <div className="compute-panel">
        {!w.projection ? (
          <div className="compute-empty">
            <p>{w.error || m.compute_loading()}</p>
          </div>
        ) : !w.rows.length ? (
          <div className="compute-empty">
            <p className="compute-row-title">{m.compute_ui_empty()}</p>
            <p className="compute-muted">{m.compute_ui_empty_help()}</p>
          </div>
        ) : (
          <>
            {w.rows.filter((item) => !historical(item)).map(resource)}
            {w.rows.some(historical) && (
              <details className="compute-history">
                <summary>{m.compute_workload_history()}</summary>
                {w.rows.filter(historical).map(resource)}
              </details>
            )}
          </>
        )}
      </div>
      {w.creation && (
        <div className="compute-notice">
          <p>
            {w.pending
              ? m.compute_workloads_creating()
              : w.error || m.compute_creation_unknown()}
          </p>
          <p className="compute-muted">{m.compute_creation_recovery()}</p>
          {act(m.compute_retry_creation(), () => void w.create(), w.pending)}
        </div>
      )}
      {w.error && w.projection && !w.creation && (
        <p role="alert" className="compute-error">
          {w.error}
        </p>
      )}
      <div className="compute-foot compute-list-foot">
        <p className="compute-muted">{m.compute_ui_refresh_note()}</p>
        {act(m.compute_workloads_refresh(), w.refresh)}
      </div>
      <div className="compute-actions">
        {w.hasPreviousPage && act(m.compute_first_page(), w.firstPage)}
        {w.projection?.next_workload_cursor && act(m.compute_next_page(), w.nextPage)}
      </div>
    </Section>
  );
  let body: ReactNode;
  if (screen === "home")
    body = (
      <>
        <div className="compute-panel">{localNode}</div>
        {workloads}
      </>
    );
  else if (screen === "settings")
    body = (
      <>
        {!c.localOnly && (
          <Section title={m.compute_ui_connection()}>
            <div className="compute-panel">
              <Row
                title={c.workspaceLabel(c.binding ?? c.workspaceId)}
                description={nodeStatus}
                action={
                  live
                    ? w.canManage &&
                      act(m.compute_ui_stop(), () => c.openConfirm("drain"), c.busy)
                    : (c.maintenanceActive || w.canManage) && primary()
                }
              >
                {readOnly && <p className="compute-muted">{m.compute_ui_readonly()}</p>}
                {(c.node.error || c.problem) && (
                  <p role="alert" className="compute-error">
                    {c.node.error || c.problem}
                  </p>
                )}
              </Row>
            </div>
          </Section>
        )}
        <Section title={m.compute_ui_components()}>
          <div className="compute-panel">
            <Row
              title={h.title}
              description={
                h.needsInstall
                  ? m.compute_ui_retained()
                  : m.compute_maintenance_shared_scope()
              }
              action={
                h.unfinished
                  ? act(m.compute_ui_view_progress(), () => go("maintenance"))
                  : act(
                      h.needsInstall
                        ? m.compute_maintenance_install()
                        : m.compute_maintenance_update(),
                      () => maintenance(h.needsInstall ? "reinstall" : "update"),
                      h.blocked || (!h.needsInstall && !h.needsUpdate)
                    )
              }
            />
            {!h.needsInstall && !h.unfinished && (
              <Row
                title={m.compute_ui_repair_title()}
                description={m.compute_ui_repair_note()}
                action={act(
                  m.compute_ui_repair(),
                  () => maintenance("reinstall"),
                  h.blocked
                )}
              />
            )}
          </div>
        </Section>
        <Section title={m.compute_ui_data_storage()}>
          <div className="compute-panel">
            <Row
              title={m.compute_ui_storage_data()}
              description={diskSummary}
              action={act(m.compute_ui_manage_storage(), () => go("local"))}
            />
          </div>
        </Section>
        <Section title={m.compute_ui_removal()}>
          <div className="compute-panel">
            {!c.localOnly && w.canManage && c.binding && (
              <Row
                title={m.compute_ui_disconnect_title()}
                description={m.compute_ui_disconnect_note()}
                action={act(
                  m.compute_ui_disconnect(),
                  () => c.openConfirm("remove"),
                  c.busy,
                  "destructive"
                )}
              />
            )}{" "}
            {!h.needsInstall && (
              <Row
                title={m.compute_ui_uninstall_title()}
                description={m.compute_ui_uninstall_note()}
                action={act(
                  m.compute_maintenance_uninstall(),
                  () => maintenance("uninstall"),
                  h.blocked,
                  "destructive"
                )}
              />
            )}
          </div>
        </Section>
        {diagnostics}
      </>
    );
  else if (screen === "local")
    body = (
      <>
        <Section title={m.compute_disk_title()}>
          <div className="compute-panel compute-inset">
            {disk && l.data?.collectedAt ? (
              <ComputeDiskUsage
                usedBytes={disk.usedBytes}
                capacityBytes={disk.capacityBytes}
                collectedAt={l.data.collectedAt}
                environments={
                  l.fresh
                    ? l.data.environments.flatMap((row) =>
                        row.privateDiskBytes !== undefined && row.sampledAt
                          ? [
                              {
                                key: row.key,
                                label: row.label,
                                bytes: row.privateDiskBytes,
                                sampledAt: row.sampledAt,
                              },
                            ]
                          : []
                      )
                    : []
                }
                onSelect={l.select}
                labels={{
                  used: m.compute_disk_used(),
                  otherUsed: m.compute_disk_other(),
                  remaining: m.compute_disk_remaining(),
                  detailUnavailable: m.compute_disk_detail_unavailable(),
                  summary: (used, capacity) =>
                    m.compute_disk_summary({ used, capacity }),
                }}
              />
            ) : (
              <p>{diskSummary}</p>
            )}
            <p className="compute-muted compute-note">{storageTime}</p>
          </div>
        </Section>
        <Section title={m.compute_local_manage()}>
          <div className="compute-panel">
            {(l.data?.environments ?? []).map((row) => (
              <div className="compute-environment" key={row.key}>
                <Row
                  title={m.compute_local_environment({ id: row.label })}
                  description={`${l.fresh ? l.stateLabel(row.state) : m.compute_local_unknown()} · ${row.privateDiskBytes !== undefined ? formatComputeBytes(row.privateDiskBytes) : m.compute_disk_detail_unavailable()}`}
                  action={
                    <MenuTrigger>
                      <Button
                        className={`compute-menu ${deviceSettingsMenuClassName}`}
                        hierarchy="tertiary-gray"
                        size="xs"
                        iconOnly
                        iconLeading={<MoreHorizontalIcon />}
                        aria-label={`${row.label} ${m.compute_more()}`}
                      />
                      <MenuPopover>
                        <Menu>
                          <MenuItem id="scope" onAction={() => setLocalScope(row.key)}>
                            {m.compute_ui_remove_local()}
                          </MenuItem>
                          {row.canReadWorkloads && (
                            <MenuItem
                              id="workloads"
                              onAction={() => {
                                l.select(row.key);
                                void l.readWorkloads(row.key);
                              }}
                            >
                              {m.compute_workloads_title()}
                            </MenuItem>
                          )}
                        </Menu>
                      </MenuPopover>
                    </MenuTrigger>
                  }
                />
                {l.selected === row.key && (
                  <div className="compute-inset">
                    {l.cloudWorkloads?.workloads.map((work) => (
                      <p key={work.label}>
                        {work.label} · {work.state}
                      </p>
                    ))}
                    {l.cloudWorkloads?.nextCursor &&
                      act(
                        m.compute_local_next(),
                        () =>
                          void l.readWorkloads(row.key, l.cloudWorkloads?.nextCursor)
                      )}
                  </div>
                )}
              </div>
            ))}
            {!l.data?.environments.length && (
              <div className="compute-empty">
                <p>{m.compute_local_no_workloads()}</p>
              </div>
            )}
          </div>
          <div className="compute-actions compute-note">
            {l.hasPreviousPage && act(m.compute_local_previous(), l.firstPage)}
            {l.overview?.nextCursor && act(m.compute_local_next(), l.nextPage)}
            {act(m.compute_check_status(), () => void l.refresh())}
          </div>
        </Section>
        {l.disposal && !["completed", "superseded"].includes(l.disposal.outcome) && (
          <div className="compute-notice">
            <p>{m.compute_local_delete_pending()}</p>
            {act(m.compute_check_status(), () => void l.resumeDisposal(), l.mutating)}
          </div>
        )}
        <Section title={m.compute_clear_all_data()}>
          <p className="compute-muted">{m.compute_clear_all_data_warning()}</p>
          <div className="compute-actions compute-note">
            {act(
              m.compute_ui_view_scope(),
              () => go("erase"),
              h.blocked,
              "destructive"
            )}
          </div>
        </Section>
        <details className="compute-diagnostics">
          <summary>{m.compute_ui_statistics()}</summary>
          <p>{m.compute_ui_statistics_note()}</p>
        </details>
        {l.error && <p role="alert">{l.error}</p>}
      </>
    );
  else if (screen === "erase")
    body = (
      <>
        <Section title={m.compute_ui_shared_scope()}>
          <div className="compute-panel compute-inset">
            <Facts
              rows={[
                [m.compute_this_mac(), m.compute_ui_current_device()],
                [m.compute_ui_includes(), m.compute_ui_files_volumes()],
                [m.compute_ui_also_removes(), m.compute_ui_credentials()],
                [m.compute_ui_affects(), m.compute_ui_apps()],
              ]}
            />
          </div>
        </Section>
        <Section title={m.compute_ui_clear_after()}>
          <p className="compute-muted">{m.compute_ui_clear_note()}</p>
        </Section>
        <div className="compute-bottom">
          {act(m.compute_back(), () => go("local"))}
          {act(
            m.compute_ui_confirm_clear(),
            () => maintenance("clear"),
            h.blocked,
            "destructive",
            true
          )}
        </div>
      </>
    );
  else if (screen === "setup" || screen === "authorization")
    body = (
      <>
        {screen === "setup" && (
          <Steps
            steps={[
              {
                label: m.compute_setup_components(),
                phase: s?.setup?.components,
                status: phaseLabel(s?.setup?.components),
              },
              {
                label: m.compute_setup_connection(),
                phase: s?.setup?.connection,
                status: phaseLabel(s?.setup?.connection),
              },
              {
                label: m.compute_setup_shell(),
                phase: s?.setup?.shell,
                status: phaseLabel(s?.setup?.shell),
              },
            ]}
          />
        )}
        {(s?.issue || c.node.error) && (
          <div className="compute-notice">
            <p>
              {c.problem && !s?.recoveryActions?.includes("continue_enable")
                ? c.problem
                : (c.node.error ?? c.problem ?? c.reason)}
            </p>
            <div className="compute-actions">
              {!c.recoveryNeeded && primary()}
              {abandon()}
            </div>
          </div>
        )}
        {c.recoveryNeeded && (
          <Section title={m.compute_recovery_title()}>
            <div className="compute-recovery-content">
              <p className="compute-muted">{m.compute_recovery_explanation()}</p>
              {c.recovery.pending && <output>{m.compute_loading()}</output>}
              {c.recovery.error && <p role="alert">{c.recovery.error}</p>}
              {c.recovery.page?.candidates.map((row) => (
                <div className="compute-panel" key={row.key}>
                  <Row
                    title={
                      row.machine ?? m.compute_recovery_candidate({ id: row.label })
                    }
                    description={[c.workspaceLabel(row.workspaceId), row.endpoint]
                      .filter(Boolean)
                      .join(" · ")}
                    action={act(
                      m.compute_recovery_title(),
                      () => c.recovery.select(row.key),
                      c.recovery.pending
                    )}
                  />
                </div>
              ))}
              {!c.recovery.pending &&
                c.recovery.page &&
                !c.recovery.page.candidates.length && (
                  <output>{m.compute_recovery_none()}</output>
                )}
              <div className="compute-actions">
                {!c.recovery.pending &&
                  !c.recovery.page?.candidates.length &&
                  act(m.compute_ui_authorize(), () => void c.recovery.discover())}
                {c.recovery.page?.nextCursor &&
                  act(
                    m.compute_recovery_next(),
                    () => void c.recovery.discover(c.recovery.page?.nextCursor)
                  )}
              </div>
            </div>
          </Section>
        )}
        <p className="compute-muted compute-note">{m.compute_ui_back_progress()}</p>
        {diagnostics}
      </>
    );
  else if (screen === "maintenance") {
    const operation = h.state?.operation;
    const order = [
      "preparing",
      "stopping",
      operation?.action === "uninstall" ? "removing" : "installing",
      "checking",
      "completed",
    ];
    const index = order.indexOf(operation?.phase ?? "preparing");
    const step = (at: number) =>
      operation?.outcome === "succeeded" || index > at
        ? "ready"
        : operation?.outcome === "failed"
          ? index === at
            ? "failed"
            : "not_started"
          : index === at
            ? "preparing"
            : "not_started";
    body = (
      <>
        <div className="compute-notice">
          <output>{h.title}</output>
          <p className="compute-muted">
            {operation?.dataPolicy === "reset"
              ? m.compute_clear_all_data_warning()
              : m.compute_maintenance_shared_scope()}
          </p>
        </div>
        <Steps
          steps={[
            {
              label: m.compute_maintenance_preparing(),
              phase: step(0),
              status: step(0) === "preparing" ? h.title : phaseLabel(step(0)),
            },
            {
              label: m.compute_ui_stop_shared(),
              phase: step(1),
              status: phaseLabel(step(1)),
            },
            {
              label:
                operation?.action === "uninstall"
                  ? m.compute_maintenance_uninstall()
                  : m.compute_setup_components(),
              phase: step(2),
              status: phaseLabel(step(2)),
            },
            {
              label: m.compute_ui_check_result(),
              phase: step(3),
              status: phaseLabel(step(3)),
            },
          ]}
        />
        {h.error && (
          <p role="alert" className="compute-error">
            {h.error}
          </p>
        )}
        {h.unfinished &&
          act(
            h.readingError
              ? m.compute_check_status()
              : m.compute_maintenance_continue(),
            h.resume,
            h.pending
          )}
        {h.readingError && <p role="alert">{m.compute_maintenance_read_failed()}</p>}
        {!operation && act(m.compute_check_status(), () => void h.refresh())}
        {diagnostics}
      </>
    );
  } else if (screen === "create")
    body = w.canPrepare ? (
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void w.create();
        }}
      >
        <div className="compute-form">
          <InputField
            label={m.compute_name()}
            value={w.name}
            placeholder={m.compute_ui_new_name()}
            maxLength={80}
            onChange={(event) => w.setName(event.target.value)}
            disabled={w.pending || !!w.creation}
          />
        </div>
        <Section title="">
          <div className="compute-panel compute-inset">
            <Facts
              rows={[
                [m.compute_ui_workspace(), w.workspaceName ?? m.compute_no_workspace()],
                [m.compute_location(), m.compute_ui_allocation()],
              ]}
            />
          </div>
        </Section>
        {policy()}
        {w.error && <p role="alert">{w.error}</p>}
        <div className="compute-bottom">
          {act(m.settings_profile_cancel(), home)}
          <Button
            className={deviceSettingsButtonClassName}
            hierarchy="primary"
            size="sm"
            type="submit"
            isDisabled={w.pending || !w.name.trim()}
          >
            {m.compute_confirm_create()}
          </Button>
        </div>
      </form>
    ) : (
      <Section title={m.compute_ui_node_available()}>
        <div className="compute-panel compute-empty">
          <p className="compute-muted">{w.createUnavailable()}</p>
          <div className="compute-actions compute-note">
            {c.node.available
              ? primary()
              : !needsDesktopApp()
                ? null
                : act(
                    m.compute_ui_desktop(),
                    () => requestDesktopApp("compute-node"),
                    false,
                    "primary"
                  )}
            {act(m.compute_workloads_refresh(), w.refresh)}
          </div>
        </div>
      </Section>
    );
  else if (screen === "workload" && w.current) {
    const item = w.current;
    body = (
      <>
        <Section
          title=""
          action={
            item.actions?.retry &&
            act(
              m.compute_retry_workload(),
              () => void w.retry(item),
              w.pending,
              "primary"
            )
          }
        >
          <div className="compute-panel">
            <Row
              title={m.compute_ui_current_status()}
              action={<Status tone={workTone(item)}>{workloadStatus(item)}</Status>}
            />
            <Row title={m.compute_location()} description={w.location(item)}>
              {(item.phase_observed_at || item.updated_at) && (
                <p className="compute-muted">
                  {m.compute_confirmed_at({
                    time: new Date(
                      item.phase_observed_at ?? item.updated_at!
                    ).toLocaleString(),
                  })}
                </p>
              )}
            </Row>
            <div className="compute-foot">
              {act(
                m.compute_check_status(),
                () => w.openWorkload(item),
                w.pending,
                "tertiary-gray"
              )}
              {!item.owner &&
                item.actions?.rename &&
                act(
                  m.compute_rename(),
                  () => w.openDialog("rename", item),
                  w.pending,
                  "tertiary-gray"
                )}
            </div>
          </div>
        </Section>
        {item.phase === "cloud_retired" && (
          <output className="compute-notice">
            {m.compute_cloud_retired_local_data()}
          </output>
        )}
        {item.deletion &&
          !["complete", "cloud_retired"].includes(item.deletion.phase) && (
            <div className="compute-notice">
              <p>
                {item.deletion.error === "original_device_offline"
                  ? m.compute_delete_original_device_help()
                  : m.compute_delete_cleanup_pending()}
              </p>
              {act(m.compute_check_status(), () => w.openWorkload(item))}
            </div>
          )}
        {item.owner || item.uses?.length ? (
          <Section title={m.compute_usage()}>
            <p className="compute-muted">{m.compute_ui_owner_note()}</p>
            <div className="compute-actions compute-note">
              {item.uses?.map((use) => (
                <Button
                  key={`${use.kind}-${use.id}`}
                  className={deviceSettingsButtonClassName}
                  size="sm"
                  onPress={() => w.openUse(use)}
                >
                  {use.label ??
                    (use.kind === "meeting"
                      ? m.settings_meeting()
                      : m.compute_use_service())}
                </Button>
              ))}
            </div>
            {item.uses_truncated && <p>{m.compute_more_uses()}</p>}
          </Section>
        ) : null}
        <details className="compute-diagnostics">
          <summary>{m.compute_shell_policy()}</summary>
          {policy(item)}
          <p className="compute-muted compute-note">{m.compute_ui_not_measured()}</p>
        </details>
        {item.actions?.delete && (
          <Section title={m.compute_ui_delete_section()}>
            <p className="compute-muted">
              {item.kind === "shell"
                ? m.compute_ui_delete_note()
                : m.compute_ui_delete_workload_note()}
            </p>
            <div className="compute-actions compute-note">
              {act(
                w.deleteLabel(item),
                () => w.openDialog("delete", item),
                w.pending,
                "destructive"
              )}
            </div>
          </Section>
        )}
        {w.error && <p role="alert">{w.error}</p>}
        <details className="compute-diagnostics">
          <summary>{m.compute_diagnostics()}</summary>
          <Facts
            rows={[
              [m.compute_identifier(), item.id],
              [
                m.compute_ui_network(),
                item.runtime_policy?.egress_mode ?? m.compute_activity_unknown(),
              ],
              [
                m.compute_last_check(),
                item.phase_observed_at ??
                  item.updated_at ??
                  m.compute_activity_unknown(),
              ],
              [
                m.compute_runtime_image(),
                item.runtime_policy?.image ?? m.compute_activity_unknown(),
              ],
              [
                m.compute_runtime_command(),
                JSON.stringify([
                  ...(item.runtime_policy?.entrypoint ?? []),
                  ...(item.runtime_policy?.command ?? []),
                ]),
              ],
            ]}
          />
        </details>
      </>
    );
  } else if (screen === "owner")
    body = (
      <Section title={m.compute_usage()}>
        <div className="compute-panel">
          <Row
            title={w.selectedUse?.label ?? m.compute_business_owner()}
            description={m.compute_ui_owner_note()}
          />
          <Row
            title={m.compute_workloads_title()}
            description={
              w.current ? w.workloadLabel(w.current) : m.compute_activity_unknown()
            }
          />
        </div>
        <details className="compute-diagnostics">
          <summary>{m.compute_diagnostics()}</summary>
          <Facts
            rows={[
              [m.compute_identifier(), w.selectedUse?.id],
              [m.compute_usage(), w.selectedUse?.kind],
            ]}
          />
        </details>
      </Section>
    );
  else body = diagnostics;
  const selectedLocal = l.data?.environments.find((row) => row.key === localScope);
  if (screen === "home" && renderHome)
    return (
      <div className="compute-home" data-compute-screen="home">
        {renderHome({ localNode, workloads })}
      </div>
    );
  return (
    <DeviceSettingsDetail
      title={title}
      headingRef={heading}
      screen={screen}
      backLabel={m.compute_back()}
      onBack={
        screen !== "home" && !(c.localOnly && screen === "settings") ? back : undefined
      }
      subtitle={`${screen === "workload" && w.current ? `${kindLabel(w.current.kind)} · ` : ""}${screen === "settings" || screen === "local" || screen === "erase" ? m.compute_this_mac() : (w.workspaceName ?? c.workspaceLabel(c.workspaceId))}`}
    >
      {body}
      {selectedLocal && (
        <Dialog
          isOpen
          title={m.compute_ui_remove_local()}
          description={`${selectedLocal.label} · ${selectedLocal.privateDiskBytes !== undefined ? formatComputeBytes(selectedLocal.privateDiskBytes) : m.compute_disk_detail_unavailable()}. ${m.compute_ui_remove_local_note()}`}
          onOpenChange={(open) => {
            if (!open) setLocalScope(undefined);
          }}
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setLocalScope(undefined),
            },
            ...(selectedLocal.canDisposeLocal
              ? [
                  {
                    label: m.compute_force_delete(),
                    hierarchy: "destructive" as const,
                    disabled: !l.fresh || l.mutating || h.unfinished || h.pending,
                    onPress: () => {
                      void l.dispose(selectedLocal.key);
                      setLocalScope(undefined);
                    },
                  },
                ]
              : []),
          ]}
        />
      )}
    </DeviceSettingsDetail>
  );
}
