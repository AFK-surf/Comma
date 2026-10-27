import type { ComputeNodeState, HostMaintenanceState } from "@comma/native-bridge";
import type { useCommaMessages } from "@comma/i18n/react";
import { computeProblemMessage } from "./useComputeNode";

type Messages = ReturnType<typeof useCommaMessages>;

/** The four states a person sees for this Mac's compute environment. */
export type ComputeCardKind = "not_enabled" | "preparing" | "available" | "attention";

/** What one action of the card does. The controller runs it. */
export type ComputeCardActionId =
  | "enable"
  | "retry"
  | "remove"
  | "recover"
  | "update_host"
  | "reinstall_reset"
  | "reset_local_record"
  | "manage_storage"
  | "resume_maintenance"
  | "check_status";

export interface ComputeCardAction {
  id: ComputeCardActionId;
  label: string;
}

export interface ComputeCard {
  kind: ComputeCardKind;
  /** The badge text. */
  label: string;
  /** One sentence: the reason, the progress or what the state permits. */
  reason: string;
  /** When Main gives up automatic continuation, while preparing (ISO time). */
  deadlineAt?: string | undefined;
  /** At most one primary action; a version choice has two. */
  actions: ComputeCardAction[];
  /** One information line beside the state, such as Main's automatic erase and reinstall. */
  notice?: string | undefined;
}

export interface ComputeCardInput {
  state: ComputeNodeState | null | undefined;
  maintenance: {
    state: HostMaintenanceState | undefined;
    /** A request is in flight or Main has an unfinished receipt. */
    active: boolean;
    title: string;
  };
  /** A finished maintenance whose workspace owner is not read again yet. */
  workspaceUnconfirmed: boolean;
  /** The last read of the node failed. */
  readFailed?: boolean;
  /** The workspace this Mac works for, as a person reads it. */
  workspace: string;
  /** Whether the current account manages the workspace. Local actions do not need it. */
  canManage: boolean;
  /** The workspace is read and the account may only view it: the card says so instead of an action. */
  readOnly?: boolean;
}

/** Actions that change the workspace connection need workspace management permission. */
const workspaceActions = new Set<ComputeCardActionId>([
  "enable",
  "retry",
  "remove",
  "recover",
]);

const action = (id: ComputeCardActionId, label: string): ComputeCardAction => ({
  id,
  label,
});

/** Maps Main's node and maintenance state to one card: one state, one reason, at most one action. */
export function computeNodeCard(input: ComputeCardInput, m: Messages): ComputeCard {
  const described = describe(input, m);
  const card = input.maintenance.state?.automaticReset
    ? { ...described, notice: m.compute_maintenance_automatic_reset() }
    : described;
  if (input.canManage) return card;
  const actions = card.actions.filter((entry) => !workspaceActions.has(entry.id));
  return actions.length === card.actions.length
    ? card
    : {
        ...card,
        reason:
          input.readOnly && card.kind !== "attention"
            ? m.compute_ui_readonly()
            : card.reason,
        actions,
      };
}

function describe(input: ComputeCardInput, m: Messages): ComputeCard {
  const s = input.state;
  const host = input.maintenance.state;
  const operation = host?.operation;
  const retry = action("retry", m.compute_retry());
  const reinstallReset = action(
    "reinstall_reset",
    m.compute_maintenance_action_reinstall_reset()
  );
  const attention = (
    reason: string,
    actions: ComputeCardAction[] = []
  ): ComputeCard => ({
    kind: "attention",
    label: m.compute_attention(),
    reason,
    actions,
  });
  const preparing = (reason: string): ComputeCard => ({
    kind: "preparing",
    label: m.compute_preparing(),
    reason,
    deadlineAt: s?.status === "processing" ? s.deadlineAt : undefined,
    actions: [],
  });

  // The whole-Mac components come first: while they need attention no node action can finish.
  if (host?.recordUnreadable || s?.issue === "local_record_unreadable")
    return attention(m.compute_reason_record_unreadable(), [
      action("reset_local_record", m.compute_reset_local_record()),
    ]);
  if (operation?.outcome === "failed")
    return attention(
      maintenanceFailureReason(operation, m),
      operation.failureCode === "host_start_failed"
        ? [reinstallReset]
        : [action("resume_maintenance", m.compute_maintenance_continue())]
    );
  if (host?.hostStartFailure)
    return attention(m.compute_reason_host_start_failed(), [reinstallReset]);
  if (input.maintenance.active) return preparing(input.maintenance.title);
  if (input.workspaceUnconfirmed)
    return input.readFailed
      ? attention(m.compute_read_failed(), [
          action("check_status", m.compute_check_status()),
        ])
      : preparing(m.compute_maintenance_checking());
  if (!s) return preparing(m.compute_loading());
  const notEnabled: ComputeCard = {
    kind: "not_enabled",
    label: m.compute_not_enabled(),
    reason: m.compute_not_enabled_note({ workspace: input.workspace }),
    actions: [action("enable", m.compute_enable())],
  };
  // Main finished the removal: no earlier result of the removed installation applies. An unconfirmed cloud result
  // (a scoped 404) stays in diagnostics: the server retires its own record, and enabling again authorizes anew.
  if (s.status === "removed") return notEnabled;

  if (
    s.status === "action_required" ||
    (s.status === "ready" &&
      s.issue !== undefined &&
      s.issue !== "connection" &&
      s.issue !== "shell_initialization_pending") ||
    s.issue === "revoked"
  )
    return attention(...needsAttention(s, m, retry, reinstallReset));
  if (s.status === "processing")
    return preparing(
      s.operation?.kind === "drain"
        ? m.compute_stopping()
        : s.operation?.kind === "remove"
          ? m.compute_removing()
          : m.compute_preparing_note()
    );
  if (s.status === "ready")
    return s.observationFresh && s.facets.connection === "connected" && !s.issue
      ? {
          kind: "available",
          label: m.compute_available(),
          reason: m.compute_available_note({ workspace: input.workspace }),
          actions: [],
        }
      : preparing(m.compute_connecting_note());
  return notEnabled;
}

/**
 * Why a maintenance request failed, from the step where it stopped, and what the person does next. It never shows
 * the native message, which can hold local paths.
 */
export function maintenanceFailureReason(
  operation: NonNullable<HostMaintenanceState["operation"]>,
  m: Messages
): string {
  if (operation.failureCode === "host_start_failed")
    return m.compute_reason_host_start_failed();
  const reason =
    operation.failedPhase === "stopping"
      ? m.compute_maintenance_failed_stopping()
      : operation.failedPhase === "installing"
        ? m.compute_maintenance_failed_installing()
        : operation.failedPhase === "removing"
          ? m.compute_maintenance_failed_removing()
          : operation.failedPhase === "checking"
            ? m.compute_maintenance_failed_checking()
            : m.compute_maintenance_failed_preparing();
  return m.compute_maintenance_retry_hint({ reason });
}

function needsAttention(
  s: ComputeNodeState,
  m: Messages,
  retry: ComputeCardAction,
  reinstallReset: ComputeCardAction
): [string, ComputeCardAction[]] {
  const problem = s.problem;
  const issue = s.issue;
  const offered = s.recoveryActions ?? [];
  const reason = (fallback: string) =>
    problem ? computeProblemMessage(problem, m, s) : fallback;
  const remove = action("remove", m.settings_compute_node_remove());
  if (problem === "insufficient_disk" || issue === "insufficient_disk")
    return [
      computeProblemMessage("insufficient_disk", m, s),
      [action("manage_storage", m.compute_ui_manage_storage())],
    ];
  if (problem === "registration_revoked" || issue === "revoked")
    return [m.compute_problem_registration_revoked(), [remove]];
  // Enable again retires the old installation and starts a new one in one step.
  if (problem === "registration_invalid")
    return [
      m.compute_problem_registration_invalid(),
      [action("enable", m.compute_reenable())],
    ];
  if (issue === "unsupported") return [m.compute_unsupported(), []];
  if (problem === "automatic_retry_exhausted" || issue === "retry_budget_exhausted")
    return [m.compute_problem_automatic_retry_exhausted(), [retry]];
  if (problem === "target_older_than_data")
    return [m.compute_problem_target_older_than_data(), [reinstallReset]];
  if (problem === "host_update_interrupts_work" || issue === "host_update_required")
    return [
      m.compute_problem_host_update_interrupts_work(),
      [action("update_host", m.compute_update_interrupting_work())],
    ];
  if (problem === "local_data_migration" || issue === "local_data_migration")
    return [m.compute_problem_local_data_migration(), [reinstallReset]];
  if (problem === "clock_skew" || problem === "identity_mismatch")
    return [computeProblemMessage(problem, m, s), [retry]];
  if (issue === "capability_missing")
    return [
      m.compute_host_update_required(),
      [action("update_host", m.compute_maintenance_update())],
    ];
  if (issue === "authorization" || issue === "authorization_unavailable")
    return [
      issue === "authorization"
        ? m.compute_authorization_problem()
        : m.compute_current_login_unavailable(),
      [action("recover", m.compute_recovery_title())],
    ];
  if (issue === "removal_incomplete" || offered.includes("finish_remove"))
    return [
      reason(m.compute_removal_incomplete()),
      [action("remove", m.compute_finish_remove())],
    ];
  const fallback =
    issue === "preparation_failed"
      ? m.compute_preparation_problem()
      : issue === "enable_incomplete"
        ? m.compute_enable_incomplete()
        : issue === "connection"
          ? m.compute_connection_problem()
          : issue === "operation_unknown"
            ? m.compute_operation_unknown()
            : m.compute_attention_note();
  if (offered.includes("continue_enable")) return [reason(fallback), [retry]];
  if (offered.includes("reset_local_record"))
    return [
      reason(fallback),
      [action("reset_local_record", m.compute_reset_local_record())],
    ];
  if (offered.includes("update_host"))
    return [
      reason(fallback),
      [action("update_host", m.compute_update_interrupting_work())],
    ];
  if (offered.includes("reinstall_reset")) return [reason(fallback), [reinstallReset]];
  if (offered.includes("check_status"))
    return [reason(fallback), [action("check_status", m.compute_check_status())]];
  return [reason(fallback), []];
}
