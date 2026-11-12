import { Fragment, useEffect, useRef, type ReactNode } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { InputField } from "@comma/ui/components/input";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { CubeIcon, MoreHorizontalIcon, ReloadIcon } from "@comma/ui/components/icons";
import {
  DeviceSettingsSection as Section,
  DeviceSettingsRow as Row,
  DeviceSettingsFacts as Facts,
  DeviceSettingsStatus as Status,
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
import {
  maintenanceFailureReason,
  maintenanceNeedsReset,
  reinstallLabel,
} from "./computeNodeCard";

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
  const back = home;
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
          index === 0 ? "primary" : "secondary-gray"
        )}
      </Fragment>
    ));
  const available = card.kind === "available";
  const workloadStatus = (item: CommaComputeWorkload) =>
    w.deleteUncertainId === item.id
      ? m.compute_delete_result_unknown()
      : item.phase === "cloud_retired"
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
                  ? "—"
                  : formatComputeBytes(
                      String(item.runtime_policy.resources.writable_quota_bytes)
                    )
                : item
                  ? "—"
                  : "2 GiB",
            ],
            [
              m.compute_ui_pid_limit(),
              item?.runtime_policy
                ? (item.runtime_policy.resources.pid_max ?? "—")
                : item
                  ? "—"
                  : "512",
            ],
            [
              m.compute_ui_network(),
              ["none", "deny_all"].includes(item?.runtime_policy?.egress_mode ?? "") ||
              !item
                ? m.compute_ui_no_network()
                : item.runtime_policy?.egress_mode === "public_internet"
                  ? m.compute_network_internet()
                  : item.runtime_policy?.egress_mode === "allow_all"
                    ? m.compute_network_allowed()
                    : "—",
            ],
          ]}
        />
      </div>
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
          {item.actions?.rename && w.deleteUncertainId !== item.id && (
            <MenuItem
              id="rename"
              isDisabled={w.pending}
              onAction={() => w.openDialog("rename", item)}
            >
              {m.compute_rename()}
            </MenuItem>
          )}
          {item.actions?.delete && w.deleteUncertainId !== item.id && (
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
        : screen === "authorization"
          ? m.compute_recovery_title()
          : screen === "create"
            ? m.compute_new_shell()
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
            h.state?.selectedReleaseId ?? m.compute_maintenance_version_unknown(),
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
          </span>
          <div className="compute-actions">
            {unavailable ? (
              act(m.compute_ui_desktop(), () => requestDesktopApp("compute-node"))
            ) : (
              <>{cardActions()}</>
            )}
          </div>
        </div>
        {/* On a computer's card these are in its menu; on the page alone they follow the row. */}
        {!unavailable && !renderHome && (
          <div className="compute-summary-actions">
            {c.binding &&
              c.canManage &&
              act(
                m.compute_ui_stop(),
                () => c.openConfirm("drain"),
                false,
                "link-gray"
              )}
            {c.binding &&
              c.canManage &&
              !card.actions.some((action) => action.id === "remove") &&
              act(
                m.compute_ui_disconnect(),
                () => c.openConfirm("remove"),
                false,
                "link-gray"
              )}
            {act(m.compute_local_settings(), () => go("settings"), false, "link-gray")}
          </div>
        )}
      </section>
    );
  const deletionAction = (
    item: CommaComputeWorkload,
    hierarchy: "link-gray" | "tertiary-gray"
  ) => {
    const reconfirm =
      w.legacyDeleteTargetId === item.id &&
      item.generation !== undefined &&
      item.actions?.delete;
    return act(
      w.canContinueDeletion
        ? m.compute_continue_deletion()
        : reconfirm
          ? m.compute_reconfirm_deletion()
          : m.compute_check_status(),
      w.canContinueDeletion
        ? w.resumeDeletion
        : reconfirm
          ? () => w.openDialog("delete", item)
          : w.checkDeletion,
      w.pending,
      hierarchy
    );
  };
  const resource = (item: CommaComputeWorkload) => (
    <DeviceSettingsResource
      key={item.id}
      name={w.workloadLabel(item)}
      description={w.location(item)}
      onOpen={() => w.openWorkload(item)}
      actions={
        <>
          {w.deleteUncertainId === item.id
            ? deletionAction(item, "link-gray")
            : w.rowActionError?.id === item.id
              ? act(m.compute_ui_check_result(), w.refresh, w.pending, "link-gray")
              : w.needsRetry(item) &&
                act(
                  m.compute_retry(),
                  () => void w.retry(item),
                  w.pending,
                  "link-gray"
                )}
          {menu(item)}
        </>
      }
      statusNote={
        w.deleteUncertainId === item.id
          ? undefined
          : w.rowActionError?.id === item.id
            ? w.rowActionError.message
            : item.phase === "action_required"
              ? w.problemReason(item)
              : undefined
      }
      status={
        <Status
          tone={w.deleteUncertainId === item.id ? "warning" : workTone(item)}
          pending={
            w.deleteUncertainId !== item.id &&
            ["allocating", "starting"].includes(item.phase ?? "")
          }
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
        <div className="compute-actions">
          <Button
            hierarchy="tertiary-gray"
            size={w.observationPaused ? "sm" : "xs"}
            className={
              w.observationPaused
                ? deviceSettingsButtonClassName
                : deviceSettingsMenuClassName
            }
            iconOnly={!w.observationPaused}
            iconLeading={<ReloadIcon />}
            aria-label={
              w.observationPaused
                ? m.compute_continue_checking()
                : m.compute_workloads_refresh()
            }
            onPress={w.refresh}
          >
            {w.observationPaused ? m.compute_continue_checking() : null}
          </Button>
          {w.canManage &&
            act(m.compute_new_shell(), w.openCreate, w.pending || !!w.creation)}
        </div>
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
      {(w.creation || w.createError) && (
        <div className="compute-notice">
          <p role={w.createError ? "alert" : undefined}>
            {w.creation && w.pending
              ? m.compute_workloads_creating()
              : w.createError || m.compute_creation_unknown()}
          </p>
          {w.creation && (
            <>
              <p className="compute-muted">{m.compute_creation_recovery()}</p>
              {act(m.compute_retry_creation(), () => void w.create(), w.pending)}
            </>
          )}
        </div>
      )}
      {w.error && w.projection && (
        <p role="alert" className="compute-error">
          {w.error}
        </p>
      )}
      {(w.hasPreviousPage || w.projection?.next_workload_cursor) && (
        <div className="compute-actions">
          {w.hasPreviousPage && act(m.compute_first_page(), w.firstPage)}
          {w.projection?.next_workload_cursor && act(m.compute_next_page(), w.nextPage)}
        </div>
      )}
    </Section>
  );
  const environments = l.data?.environments ?? [];
  const disposalScopes = [
    ...new Map(
      environments.flatMap((row) =>
        row.disposalScope ? [[row.disposalScope.key, row.disposalScope] as const] : []
      )
    ).values(),
  ];
  // Main supplies short identity discriminators here, not environment names.
  const environmentRow = (row: (typeof environments)[number]) => (
    <div className="compute-environment" key={row.key}>
      <Row
        title={m.compute_local_data_group()}
        description={[
          row.label ? `…${row.label}` : undefined,
          l.fresh && row.state !== "unknown" ? l.stateLabel(row.state) : undefined,
          row.privateDiskBytes !== undefined
            ? formatComputeBytes(row.privateDiskBytes)
            : undefined,
        ]
          .filter(Boolean)
          .join(" · ")}
        action={
          (!row.disposalScope || row.canReadWorkloads) && (
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
                  {!row.disposalScope && (
                    <MenuItem
                      id="scope"
                      isDisabled={!row.canDisposeLocal || !l.fresh || l.mutating}
                      onAction={() => void l.dispose(row.key)}
                    >
                      {m.compute_ui_remove_local()}
                    </MenuItem>
                  )}
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
          )
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
              () => void l.readWorkloads(row.key, l.cloudWorkloads?.nextCursor)
            )}
        </div>
      )}
    </div>
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
                h.failed && h.state?.operation
                  ? maintenanceFailureReason(h.state.operation, m)
                  : m.compute_maintenance_shared_scope()
              }
              action={
                h.failed &&
                h.state?.operation &&
                maintenanceNeedsReset(h.state.operation) ? (
                  act(
                    m.compute_maintenance_action_reinstall_reset(),
                    () => maintenance("reinstall_reset"),
                    h.pending,
                    "destructive"
                  )
                ) : h.unfinished ? (
                  act(m.compute_maintenance_continue(), h.resume, h.pending)
                ) : h.needsInstall ? (
                  act(
                    reinstallLabel(h.state?.operation, m),
                    () => maintenance("reinstall"),
                    h.blocked
                  )
                ) : (
                  <div className="compute-actions">
                    {!(
                      h.state?.selectedReleaseId &&
                      h.state.installedReleaseId === h.state.selectedReleaseId
                    ) &&
                      act(
                        m.compute_maintenance_update(),
                        () => maintenance("update"),
                        h.blocked
                      )}
                    {act(
                      m.compute_ui_repair(),
                      () => maintenance("reinstall"),
                      h.blocked
                    )}
                  </div>
                )
              }
            />
            {!h.needsInstall && (
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
            )}
          </div>
          {h.error && !h.state?.operation?.problem && <p role="alert">{h.error}</p>}
        </Section>

        <Section title={m.compute_disk_title()}>
          <div className="compute-panel compute-inset">
            {disk && l.data?.collectedAt ? (
              <ComputeDiskUsage
                usedBytes={disk.usedBytes}
                capacityBytes={disk.capacityBytes}
                collectedAt={l.data.collectedAt}
                breakdown={l.fresh ? disk : undefined}
                labels={{
                  used: m.compute_disk_used(),
                  imageRuntime: m.compute_disk_image_runtime(),
                  buildCache: m.compute_disk_build_cache(),
                  privateData: m.compute_disk_private_data(),
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
            {disposalScopes.map((scope) => (
              <div className="compute-environment" key={scope.key}>
                <Row
                  title={m.compute_local_data_group()}
                  action={
                    <MenuTrigger>
                      <Button
                        className={`compute-menu ${deviceSettingsMenuClassName}`}
                        hierarchy="tertiary-gray"
                        size="xs"
                        iconOnly
                        iconLeading={<MoreHorizontalIcon />}
                        aria-label={`${scope.label} ${m.compute_more()}`}
                      />
                      <MenuPopover>
                        <Menu>
                          <MenuItem
                            id="delete"
                            tone="destructive"
                            isDisabled={
                              !l.fresh ||
                              l.mutating ||
                              !environments.some(
                                (row) => row.key === scope.key && row.canDisposeLocal
                              )
                            }
                            onAction={() => void l.dispose(scope.key)}
                          >
                            {m.compute_force_delete()}
                          </MenuItem>
                        </Menu>
                      </MenuPopover>
                    </MenuTrigger>
                  }
                />
                {environments
                  .filter((row) => row.disposalScope?.key === scope.key)
                  .map(environmentRow)}
              </div>
            ))}
            {environments.filter((row) => !row.disposalScope).map(environmentRow)}
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
            <p>
              {l.disposal.outcome === "unknown"
                ? m.compute_local_delete_unknown()
                : m.compute_local_delete_pending()}
            </p>
            {act(m.compute_finish_remove(), () => void l.resumeDisposal(), l.mutating)}
          </div>
        )}
        <details className="compute-diagnostics">
          <summary>{m.compute_clear_all_data()}</summary>
          <p className="compute-muted">{m.compute_clear_all_data_warning()}</p>
          <div className="compute-actions compute-note">
            {act(
              m.compute_ui_confirm_clear(),
              () => maintenance("clear"),
              h.blocked,
              "destructive"
            )}
          </div>
        </details>
        {l.error && <p role="alert">{l.error}</p>}
        {diagnostics}
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
        {w.createError && <p role="alert">{w.createError}</p>}
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
            w.deleteUncertainId !== item.id &&
            w.needsRetry(item) &&
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
              description={
                w.deleteUncertainId !== item.id && item.phase === "action_required"
                  ? w.problemReason(item)
                  : undefined
              }
              action={
                <Status
                  tone={w.deleteUncertainId === item.id ? "warning" : workTone(item)}
                >
                  {workloadStatus(item)}
                </Status>
              }
            >
              {(w.detailError ||
                (w.rowActionError?.id === item.id &&
                  w.deleteUncertainId !== item.id &&
                  w.rowActionError.message)) && (
                <p role="alert" className="compute-error">
                  {w.detailError || w.rowActionError?.message}
                </p>
              )}
            </Row>
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
              {w.deleteUncertainId === item.id
                ? deletionAction(item, "tertiary-gray")
                : act(
                    m.compute_check_status(),
                    w.refreshDetail,
                    w.pending,
                    "tertiary-gray"
                  )}
              {!item.owner &&
                w.deleteUncertainId !== item.id &&
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
                act(m.compute_check_status(), w.refreshDetail)}
            </div>
          )}
        {item.owner || item.uses?.length ? (
          <Section title={m.compute_usage()}>
            <p className="compute-muted">{m.compute_ui_owner_note()}</p>
            <div className="compute-actions compute-note">
              {item.uses?.map((use) => (
                <p key={`${use.kind}-${use.id}`}>
                  {use.label ??
                    (use.kind === "meeting"
                      ? m.settings_meeting()
                      : m.compute_use_service())}
                </p>
              ))}
            </div>
            {item.uses_truncated && <p>{m.compute_more_uses()}</p>}
          </Section>
        ) : null}
        <details className="compute-diagnostics">
          <summary>{m.compute_shell_policy()}</summary>
          {policy(item)}
        </details>
        {item.actions?.delete && w.deleteUncertainId !== item.id && (
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
        <details className="compute-diagnostics">
          <summary>{m.compute_diagnostics()}</summary>
          <Facts
            rows={[
              [m.compute_identifier(), item.id],
              [m.compute_ui_network(), item.runtime_policy?.egress_mode ?? "—"],
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
  } else body = null;
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
      subtitle={`${screen === "workload" && w.current ? `${kindLabel(w.current.kind)} · ` : ""}${screen === "settings" ? m.compute_this_mac() : (w.workspaceName ?? c.workspaceLabel(c.workspaceId))}`}
    >
      {body}
    </DeviceSettingsDetail>
  );
}
