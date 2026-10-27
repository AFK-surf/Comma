import { Button } from "@comma/ui/components/Button";
import { confirmationBusy } from "./adminModel";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import { InputField } from "@comma/ui/components/input";
import { useId } from "react";
import { AdminConfirmationDialog, AdminNotice, AdminRow } from "./adminUi";
import {
  MAX_SANDBOX_LIMIT,
  workspaceSandboxLimitForm,
  type WorkspaceSandboxLimitModel,
} from "./WorkspaceSandboxLimitModel";
import { messages } from "@comma/i18n";

/** The Workspace's own coding sandbox limit (WorkspaceSandboxLimitModel.ts). */
export function WorkspaceSandboxLimitSection({
  model,
}: {
  model: WorkspaceSandboxLimitModel;
}) {
  const run = useAdminCommand();
  const state = useAdminState(model.state);
  const busy = useAdminState(model.confirmation.state, confirmationBusy);
  const { editing, limit, loadError, notice, view } = state;
  const { canReview, saved, valid } = workspaceSandboxLimitForm(state, busy);
  const titleId = useId();

  return (
    <section aria-labelledby={titleId} className="admin-row-group">
      <AdminRow
        description={
          view
            ? messages.admin_sandbox_limit_detail({
                current:
                  view.effective == null
                    ? messages.admin_none()
                    : String(view.effective),
                fallback:
                  view.default == null
                    ? messages.admin_not_set()
                    : String(view.default),
              })
            : undefined
        }
        title={messages.admin_sandbox_limit()}
        titleId={titleId}
      >
        {view && !editing ? (
          <>
            <span className="admin-row-value">
              {saved === null ? messages.admin_sandbox_limit_default() : String(saved)}
            </span>
            <Button
              aria-label={messages.admin_change_sandbox_limit()}
              hierarchy="secondary-gray"
              onPress={() => run(model.edit)}
              size="sm"
            >
              {messages.admin_change()}
            </Button>
          </>
        ) : null}
      </AdminRow>
      {notice ? (
        <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
      ) : null}
      {loadError ? <AdminNotice message={loadError} tone="error" /> : null}
      {view && editing ? (
        <form
          className="admin-row admin-row-form"
          onSubmit={(event) => {
            event.preventDefault();
            run(model.review);
          }}
        >
          <InputField
            aria-label={messages.admin_workspace_sandbox_limit()}
            className="w-full"
            disabled={busy}
            hint={
              valid
                ? messages.admin_sandbox_limit_hint({ max: String(MAX_SANDBOX_LIMIT) })
                : messages.admin_sandbox_limit_hint_invalid({
                    max: String(MAX_SANDBOX_LIMIT),
                  })
            }
            inputMode="numeric"
            maxLength={3}
            onChange={(event) => run(model.setLimit(event.target.value))}
            value={limit}
          />
          <div className="admin-row-end">
            <Button
              hierarchy="secondary-gray"
              isDisabled={busy}
              onPress={() => run(model.cancelEdit)}
              size="sm"
            >
              {messages.admin_cancel()}
            </Button>
            <Button isDisabled={!canReview} size="sm" type="submit">
              {messages.admin_save_sandbox_limit()}
            </Button>
          </div>
        </form>
      ) : null}
      <AdminConfirmationDialog confirmation={model.confirmation} />
    </section>
  );
}
