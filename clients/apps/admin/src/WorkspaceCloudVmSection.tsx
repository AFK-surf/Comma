import { Button } from "@comma/ui";
import { useState } from "react";
import { createIdempotencyKey, type AdminApi, type AdminWorkspaceVm } from "./adminApi";
import { guardedAdminCommand } from "./adminErrors";
import {
  AdminConfirmationDialog,
  AdminNotice,
  DetailList,
  NativeField,
  ReasonField,
} from "./adminUi";

export function WorkspaceCloudVmSection({
  api,
  current,
  onAccessDenied,
  ready,
  userId,
}: {
  api: AdminApi;
  current: AdminWorkspaceVm;
  onAccessDenied: () => void;
  ready: boolean;
  userId: string;
}) {
  const [saved, setSaved] = useState(current);
  const [enabled, setEnabled] = useState(current.enabled);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [notice, setNotice] = useState<string>();
  const [idempotencyKey, setIdempotencyKey] = useState(() =>
    createIdempotencyKey("workspace-vm")
  );
  const expected = `workspace-vm:${current.workspace_id}:${enabled ? "enable" : "disable"}`;
  const failed = saved.convergence_status === "terminal_failed";

  return (
    <section aria-labelledby="workspace-cloud-vm-title" className="admin-agent-models">
      <div className="admin-drawer-section-header">
        <div>
          <h3 id="workspace-cloud-vm-title">Cloud VM</h3>
          <p>Desired configuration for this Workspace’s shared cloud VM</p>
        </div>
      </div>
      {notice ? (
        <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
      ) : null}
      {failed ? (
        <AdminNotice
          message="Workspace configuration failed to apply. Check the provider configuration, then retry this setting."
          tone="error"
        />
      ) : null}
      <DetailList
        items={[
          { label: "Saved setting", value: saved.enabled ? "Enabled" : "Disabled" },
          {
            label: "Configuration sync",
            value: saved.convergence_status ?? "No operation recorded",
          },
        ]}
      />
      <p className="admin-drawer-note">
        Changes apply asynchronously to the Workspace Router and default Worker.
        Configuration sync does not indicate VM readiness. Disabling may remove the
        shared VM when no other agents or runtime installations need it.
      </p>
      {!ready ? (
        <p className="admin-drawer-note">
          Cloud VM settings can be changed when the Workspace is ready.
        </p>
      ) : (
        <form
          className="admin-command-form"
          onSubmit={(event) => {
            event.preventDefault();
            setConfirming(true);
          }}
        >
          <NativeField label="Cloud VM setting">
            <select
              disabled={busy}
              value={enabled ? "enabled" : "disabled"}
              onChange={(event) => {
                setEnabled(event.target.value === "enabled");
                setIdempotencyKey(createIdempotencyKey("workspace-vm"));
              }}
            >
              <option value="enabled">Enabled</option>
              <option value="disabled">Disabled</option>
            </select>
          </NativeField>
          <ReasonField
            onChange={(value) => {
              setReason(value);
              setIdempotencyKey(createIdempotencyKey("workspace-vm"));
            }}
            value={reason}
          />
          <div className="admin-command-actions">
            <Button
              isDisabled={
                busy ||
                (enabled === saved.enabled && !failed) ||
                reason.trim().length < 3
              }
              type="submit"
            >
              Review Cloud VM change
            </Button>
          </div>
        </form>
      )}
      <AdminConfirmationDialog
        expected={expected}
        isOpen={confirming}
        onBusyChange={setBusy}
        onConfirm={async () => {
          const updated = await guardedAdminCommand(
            api.updateUserWorkspaceVm(userId, current.workspace_id, {
              enabled,
              reason: reason.trim(),
              confirmation: expected,
              idempotencyKey,
            }),
            onAccessDenied
          );
          setSaved(updated);
          setReason("");
          setIdempotencyKey(createIdempotencyKey("workspace-vm"));
          setNotice(
            "Cloud VM setting saved. Configuration is queued; use Refresh to check progress."
          );
        }}
        onOpenChange={setConfirming}
        title={enabled ? "Enable Cloud VM?" : "Disable Cloud VM?"}
      />
    </section>
  );
}
