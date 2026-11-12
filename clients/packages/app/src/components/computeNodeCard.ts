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
  | "manage_storage"
  | "resume_maintenance"
  | "reinstall_reset"
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
  const card = describe(input, m);
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
  const state = input.state;
  const base = { actions: [] as ComputeCardAction[] };
  const attention = (reason: string, primary?: ComputeCardAction): ComputeCard => ({
    kind: "attention",
    label: m.compute_attention(),
    reason,
    actions: primary ? [primary] : [],
  });
  if (input.maintenance.state?.recordUnreadable)
    return attention(
      m.compute_reason_record_unreadable(),
      action("check_status", m.compute_check_status())
    );
  if (input.maintenance.state?.operation?.outcome === "failed")
    return attention(
      maintenanceFailureReason(input.maintenance.state.operation, m),
      maintenanceNeedsReset(input.maintenance.state.operation)
        ? action("reinstall_reset", m.compute_maintenance_action_reinstall_reset())
        : action("resume_maintenance", m.compute_maintenance_continue())
    );
  if (input.maintenance.active)
    return {
      ...base,
      kind: "preparing",
      label: m.compute_preparing(),
      reason: input.maintenance.title,
    };
  if (!state)
    return {
      ...base,
      kind: "preparing",
      label: m.compute_preparing(),
      reason: m.compute_loading(),
    };
  if (state.status === "action_required") {
    const primary = state.primaryAction;
    const labels = {
      continue:
        state.currentRequest?.kind === "remove"
          ? m.compute_continue_remove()
          : state.currentRequest?.kind === "drain"
            ? m.compute_continue_stop()
            : m.compute_continue_enable(),
      remove: m.compute_finish_remove(),
      recover: m.compute_recovery_title(),
      update_host:
        input.maintenance.state?.installation === "not_installed"
          ? reinstallLabel(input.maintenance.state.operation, m)
          : m.compute_maintenance_update(),
      check_status: m.compute_check_status(),
    };
    return attention(
      state.problem
        ? computeProblemMessage(state.problem, m, state)
        : m.compute_attention_note(),
      primary
        ? action(primary === "continue" ? "retry" : primary, labels[primary])
        : undefined
    );
  }
  if (state.status === "processing")
    return {
      ...base,
      kind: "preparing",
      label: m.compute_preparing(),
      reason:
        state.currentRequest?.kind === "remove"
          ? m.compute_removing()
          : state.currentRequest?.kind === "drain"
            ? m.compute_stopping()
            : m.compute_preparing_note(),
      deadlineAt: state.deadlineAt,
    };
  if (state.status === "ready")
    return {
      ...base,
      kind: "available",
      label: m.compute_available(),
      reason: m.compute_available_note({ workspace: input.workspace }),
    };
  return {
    kind: "not_enabled",
    label: m.compute_not_enabled(),
    reason: m.compute_not_enabled_note({ workspace: input.workspace }),
    actions: [action("enable", m.compute_enable())],
  };
}

/** Continuing this failed request cannot help: only a confirmed reinstall on empty data moves on. */
export function maintenanceNeedsReset(
  operation: NonNullable<HostMaintenanceState["operation"]>
): boolean {
  return operation.outcome === "failed" && operation.failureCode !== undefined;
}

/** The reinstall action of an absent Host. It names kept data only while the last request left some. */
export function reinstallLabel(
  operation: HostMaintenanceState["operation"],
  m: Messages
): string {
  return operation?.action === "uninstall" &&
    operation.dataPolicy === "reset" &&
    operation.outcome === "succeeded"
    ? m.compute_maintenance_action_install()
    : m.compute_maintenance_action_reinstall();
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
  if (operation.failureCode === "target_older_than_data")
    return m.compute_problem_target_older_than_data();
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
