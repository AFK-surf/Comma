import { Button } from "@comma/ui/components/Button";
import { confirmationBusy } from "./adminModel";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import { InputField } from "@comma/ui/components/input";
import { useId } from "react";
import { AdminConfirmationDialog, AdminNotice, AdminRow } from "./adminUi";
import { workspaceSignalForm, type WorkspaceSignalModel } from "./WorkspaceSignalModel";
import { messages } from "@comma/i18n";

/** The Workspace's own Signal number (WorkspaceSignalModel.ts). */
export function WorkspaceSignalSection({ model }: { model: WorkspaceSignalModel }) {
  const run = useAdminCommand();
  const state = useAdminState(model.state);
  const busy = useAdminState(model.confirmation.state, confirmationBusy);
  const { editing, loadError, notice, number, view } = state;
  const { canReview, saved, valid } = workspaceSignalForm(state, busy);
  const titleId = useId();

  return (
    <section aria-labelledby={titleId} className="admin-row-group">
      <AdminRow
        description={
          view
            ? messages.admin_signal_detail({
                current: view.effective?.e164 ?? messages.admin_none(),
                platform: view.platform?.e164 ?? messages.admin_not_set(),
              })
            : undefined
        }
        title={messages.admin_signal_number()}
        titleId={titleId}
      >
        {view && !editing ? (
          <>
            <span className="admin-row-value">
              {saved || messages.admin_platform_number()}
            </span>
            <Button
              aria-label={messages.admin_change_signal_number()}
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
            aria-label={messages.admin_workspace_signal_number()}
            className="w-full"
            disabled={busy}
            hint={
              valid
                ? messages.admin_signal_hint()
                : messages.admin_signal_hint_invalid()
            }
            inputMode="tel"
            maxLength={16}
            onChange={(event) => run(model.setNumber(event.target.value))}
            value={number}
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
              {messages.admin_save_signal_number()}
            </Button>
          </div>
        </form>
      ) : null}
      <AdminConfirmationDialog confirmation={model.confirmation} />
    </section>
  );
}
