import { Button } from "@comma/ui/components/Button";
import { Toggle } from "@comma/ui/components/toggle";
import { confirmationBusy } from "./adminModel";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import { useId } from "react";
import {
  AdminConfirmationDialog,
  AdminNotice,
  AdminRow,
  humanizeStatus,
} from "./adminUi";
import {
  workspaceCloudVmFailed,
  type WorkspaceCloudVmModel,
} from "./WorkspaceCloudVmModel";
import { messages } from "@comma/i18n";

/** The Workspace's Cloud VM setting: switching it asks for a reason, then saves. */
export function WorkspaceCloudVmSection({ model }: { model: WorkspaceCloudVmModel }) {
  const run = useAdminCommand();
  const state = useAdminState(model.state);
  const busy = useAdminState(model.confirmation.state, confirmationBusy);
  const { notice, saved } = state;
  const failed = workspaceCloudVmFailed(state);
  const titleId = useId();

  return (
    <section aria-labelledby={titleId} className="admin-row-group">
      <AdminRow
        description={`${
          saved.convergence_status
            ? messages.admin_vm_configuration({
                status: humanizeStatus(saved.convergence_status),
              })
            : messages.admin_vm_no_configuration()
        }${model.ready ? "" : messages.admin_vm_not_ready()}`}
        title={messages.admin_cloud_vm()}
        titleId={titleId}
      >
        {failed ? (
          <Button
            hierarchy="secondary-gray"
            isDisabled={!model.ready || busy}
            onPress={() => run(model.review(saved.enabled))}
            size="sm"
          >
            {messages.admin_retry()}
          </Button>
        ) : null}
        <Toggle
          aria-label={messages.admin_cloud_vm()}
          checked={saved.enabled}
          disabled={!model.ready || busy}
          onChange={(event) => run(model.review(event.target.checked))}
          size="sm"
        />
      </AdminRow>
      {notice ? (
        <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
      ) : null}
      {failed ? (
        <AdminNotice message={messages.admin_vm_failed()} tone="error" />
      ) : null}
      <AdminConfirmationDialog confirmation={model.confirmation} />
    </section>
  );
}
