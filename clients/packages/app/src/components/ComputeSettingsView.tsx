import { Fragment, useEffect, useRef, useState, type ReactNode } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { CubeIcon, MoreHorizontalIcon } from "@comma/ui/components/icons";
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
import { maintenanceFailureReason } from "./computeNodeCard";

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
    : item.deletion
      ? "neutral"
      : item.phase === "action_required" ||
          item.phase === "waiting_connection" ||
          item.observed_state === "failed"
        ? "warning"
        : "neutral";

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
  const kindLabel = (kind: string) =>
    kind === "shell"
      ? "Shell"
      : kind === "meeting"
        ? m.settings_meeting()
        : kind === "service"
          ? m.compute_use_service()
          : kind;
  const card = c.card;
  const cardActions = (actions = card.actions) =>
    actions.map((action, index) => (
      <Fragment key={action.id}>
        {act(
          action.label,
          () => c.run(action.id),
          !c.canRun(action.id),
          index === 0
            ? "primary"
            : action.id === "reinstall_reset"
              ? "destructive"
              : "secondary-gray"
        )}
      </Fragment>
    ));
  const available = card.kind === "available";
  const abandon = () =>
    c.canAbandon &&
    c.canManage &&
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
              ? m.compute_recovery_title()
              : screen === "maintenance"
                ? m.compute_maintenance_title()
                : screen === "create"
                  ? m.compute_new_shell()
                  : screen === "owner"
                    ? (w.selectedUse?.label ?? m.compute_usage())
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
      {s?.setup && (
        <Steps
          steps={[
            {
              label: m.compute_setup_components(),
              phase: s.setup.components,
              status: phaseLabel(s.setup.components),
            },
            {
              label: m.compute_setup_connection(),
              phase: s.setup.connection,
              status: phaseLabel(s.setup.connection),
            },
            {
              label: m.compute_setup_shell(),
              phase: s.setup.shell,
              status: phaseLabel(s.setup.shell),
            },
          ]}
        />
      )}
      {s?.problemDetail && <p>{s.problemDetail}</p>}
      {s?.preparation?.error && <p>{s.preparation.error}</p>}
      {h.state?.operation?.problem && <p>{h.state.operation.problem}</p>}
      {act(m.compute_check_status(), c.checkWorkspace)}
    </details>
  );
  // In the desktop app on a computer that cannot host one (Windows, an Intel Mac) there is nothing to show of it:
  // a person who never heard of compute environments is not told about one they cannot have.
  // On the computer's card the sandbox is one row like an agent's: its name, the card's reason while it is not
  // available (its progress while preparing), and the card's actions. Stopping, disconnecting and its settings are
  // in the computer's menu.
  const unavailable = !c.node.available || !c.eligible;
  const localNode =
    !needsDesktopApp() && unavailable ? null : (
      <section
        className="compute-node-summary"
        aria-label={m.compute_capability_title()}
        data-ready={!unavailable && available}
      >
        <div className="comma-device__agent">
          <span className="comma-device__agent-mark" aria-hidden="true">
            <CubeIcon className="size-4" />
          </span>
          <span className="comma-device__agent-identity">
            <span className="comma-device__agent-name">
              {m.compute_capability_title()}
            </span>
            {unavailable ? (
              <span className="comma-device__agent-status">
                {m.compute_ui_desktop_help()}
              </span>
            ) : card.kind === "preparing" ? (
              <Status pending>{card.reason}</Status>
            ) : card.kind === "attention" ||
              (card.kind === "not_enabled" && card.actions.length === 0) ? (
              <span className="comma-device__agent-status" data-attention="true">
                {card.reason}
              </span>
            ) : null}
            {!unavailable && card.notice && (
              <span className="comma-device__agent-status">{card.notice}</span>
            )}
            {c.node.error && (
              <span
                role="alert"
                className="comma-device__agent-status"
                data-attention="true"
              >
                {c.node.error}
              </span>
            )}
          </span>
          <div className="compute-actions">
            {unavailable ? (
              act(m.compute_ui_desktop(), () => requestDesktopApp("compute-node"))
            ) : (
              <>
                {renderHome && abandon()}
                {cardActions()}
              </>
            )}
          </div>
        </div>
        {/* On a computer's card these are in its menu; on the page alone they follow the row. */}
        {!unavailable && !renderHome && (
          <div className="compute-summary-actions">
            {abandon()}
            {available &&
              c.canManage &&
              act(
                m.compute_ui_stop(),
                () => c.openConfirm("drain"),
                c.busy,
                "link-gray"
              )}
            {c.binding &&
              c.canManage &&
              !card.actions.some((action) => action.id === "remove") &&
              (available || card.kind === "attention") &&
              act(
                m.compute_ui_disconnect(),
                () => c.openConfirm("remove"),
                c.busy,
                "link-gray"
              )}
            {act(m.compute_local_settings(), () => go("settings"), false, "link-gray")}
          </div>
        )}
      </section>
    );
  const resource = (item: CommaComputeWorkload) => (
    <DeviceSettingsResource
      key={item.id}
      name={w.workloadLabel(item)}
      description={`${kindLabel(item.kind)} · ${w.location(item)}`}
      onOpen={() => w.openWorkload(item)}
      actions={
        <>
          {w.needsRetry(item) &&
            act(m.compute_retry(), () => void w.retry(item), w.pending, "link-gray")}
          {menu(item)}
        </>
      }
      statusNote={w.problemReason(item)}
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
          w.rows.map(resource)
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
      {(w.hasPreviousPage || w.projection?.next_workload_cursor) && (
        <div className="compute-actions">
          {w.hasPreviousPage && act(m.compute_first_page(), w.firstPage)}
          {w.projection?.next_workload_cursor && act(m.compute_next_page(), w.nextPage)}
        </div>
      )}
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
                  : h.needsUpdate && !h.needsInstall
                    ? act(
                        m.compute_maintenance_update(),
                        () => maintenance("update"),
                        h.blocked
                      )
                    : undefined
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
        {!h.needsInstall && (
          <Section title={m.compute_ui_removal()}>
            <div className="compute-panel">
              <Row
                title={m.compute_ui_uninstall_title()}
                description={m.compute_ui_uninstall_note()}
                action={act(
                  m.compute_maintenance_uninstall(),
                  () => maintenance("uninstall"),
                  h.uninstallBlocked,
                  "destructive"
                )}
              />
            </div>
          </Section>
        )}
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
                    {l.cloudWorkloads?.workloads.map((work) => {
                      // Main keeps the cloud workload's id; its retry is on the workspace's list.
                      const workload = {
                        problem: work.problem ?? null,
                        location: {
                          provider: "agent_vmm",
                          ...(work.deviceId ? { device_id: work.deviceId } : {}),
                        },
                      };
                      const reason = w.problemReason(workload);
                      return (
                        <div key={work.label}>
                          <p>
                            {work.label} · {work.state} · {w.location(workload)}
                          </p>
                          {reason && <p className="compute-muted">{reason}</p>}
                        </div>
                      );
                    })}
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
  else if (screen === "authorization") {
    const r = c.recovery;
    const candidates = r.page?.candidates ?? [];
    body = (
      <>
        <p className="compute-muted">{m.compute_recovery_explanation()}</p>
        {r.pending && <output>{m.compute_loading()}</output>}
        {r.error && <p role="alert">{r.error}</p>}
        {r.selected ? (
          <Section title="">
            <div className="compute-panel compute-inset">
              <Facts
                rows={[
                  [m.compute_ui_account(), r.account ?? m.compute_ui_account_unknown()],
                  [m.compute_ui_device(), r.selected.machine ?? r.selected.label],
                  [m.compute_ui_workspace(), c.workspaceLabel(r.selected.workspaceId)],
                  [
                    m.compute_ui_service(),
                    r.selected.endpoint ?? m.compute_activity_unknown(),
                  ],
                ]}
              />
            </div>
            <div className="compute-actions compute-note">
              {candidates.length > 1 && act(m.settings_profile_cancel(), r.cancel)}
              {act(m.compute_recovery_title(), r.confirm, r.pending, "primary")}
            </div>
          </Section>
        ) : (
          candidates.map((row) => (
            <div className="compute-panel" key={row.key}>
              <Row
                title={row.machine ?? m.compute_recovery_candidate({ id: row.label })}
                description={[c.workspaceLabel(row.workspaceId), row.endpoint]
                  .filter(Boolean)
                  .join(" · ")}
                action={act(
                  m.compute_recovery_select(),
                  () => r.select(row.key),
                  r.pending
                )}
              />
            </div>
          ))
        )}
        {!r.pending && r.page && !candidates.length && (
          <output>{m.compute_recovery_none()}</output>
        )}
        <div className="compute-actions compute-recovery-actions">
          {!r.pending &&
            !candidates.length &&
            act(m.compute_retry(), () => void r.discover())}
          {r.page?.nextCursor &&
            act(m.compute_recovery_next(), () => void r.discover(r.page?.nextCursor))}
        </div>
      </>
    );
  } else if (screen === "maintenance") {
    const operation = h.state?.operation;
    const failed = operation?.outcome === "failed";
    // A failed request names the step where it stopped: the earlier steps are done, the later ones did not start.
    const phase = failed
      ? (operation.failedPhase ?? "preparing")
      : (operation?.phase ?? "preparing");
    const index =
      phase === "preparing"
        ? 0
        : phase === "stopping"
          ? 1
          : phase === "installing" || phase === "removing"
            ? 2
            : phase === "checking"
              ? 3
              : 4;
    const step = (at: number) =>
      operation?.outcome === "succeeded" || index > at
        ? "ready"
        : index === at
          ? failed
            ? "failed"
            : "preparing"
          : "not_started";
    body = (
      <>
        <div className="compute-notice">
          <output>{h.title}</output>
          <p className="compute-muted">
            {failed
              ? maintenanceFailureReason(operation, m)
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
        {h.retryFailed && (
          <p role="alert" className="compute-error">
            {m.compute_maintenance_retry_failed()}
          </p>
        )}
        {h.error && (
          <p role="alert" className="compute-error">
            {h.error}
          </p>
        )}
        {h.unfinished &&
          (operation?.failureCode === "host_start_failed" && !h.readingError
            ? act(
                m.compute_maintenance_action_reinstall_reset(),
                () => c.run("reinstall_reset"),
                !c.canRun("reinstall_reset"),
                "destructive"
              )
            : act(
                h.readingError
                  ? m.compute_check_status()
                  : m.compute_maintenance_continue(),
                h.resume,
                h.pending
              ))}
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
              ? cardActions(card.actions.slice(0, 1))
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
            (item.actions?.retry || w.needsRetry(item)) &&
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
              description={w.problemReason(item)}
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
              {item.deletion.error !== "original_device_offline" &&
                act(m.compute_check_status(), () => w.openWorkload(item))}
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
  else body = null;
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
