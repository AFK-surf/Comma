import { Button } from "@comma/ui";
import { useEffect, useState } from "react";
import {
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type AdminWorkspaceSignalNumber,
} from "./adminApi";
import { adminErrorMessage, guardedAdminCommand } from "./adminErrors";
import {
  AdminConfirmationDialog,
  AdminNotice,
  DetailList,
  NativeField,
  ReasonField,
} from "./adminUi";

const E164 = /^\+[1-9]\d{6,14}$/;

/**
 * The Workspace's own Signal number, which overrides the platform number for
 * new Signal connections (docs/messaging-voice.md). Salix owns the setting;
 * the change is an audited Admin command.
 */
export function WorkspaceSignalSection({
  api,
  onAccessDenied,
  userId,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  userId: string;
}) {
  const [view, setView] = useState<AdminWorkspaceSignalNumber>();
  const [loadError, setLoadError] = useState<string>();
  const [number, setNumber] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [editing, setEditing] = useState(false);
  const [notice, setNotice] = useState<string>();
  const [idempotencyKey, setIdempotencyKey] = useState(() =>
    createIdempotencyKey("workspace-signal-number")
  );

  useEffect(() => {
    const request = new AbortController();
    void api
      .getUserWorkspaceSignalNumber(userId, { signal: request.signal })
      .then((loaded) => {
        if (request.signal.aborted) return;
        setView(loaded);
        setNumber(loaded.override?.e164 ?? "");
      })
      .catch((error: unknown) => {
        if (request.signal.aborted || isAdminSessionRejection(error)) return;
        if (isAdminAccessDenied(error)) {
          onAccessDenied();
          return;
        }
        setLoadError(
          adminErrorMessage(error, "Unable to load the Workspace Signal number.")
        );
      });
    return () => request.abort();
  }, [api, onAccessDenied, userId]);

  const value = number.trim();
  const saved = view?.override?.e164 ?? "";
  const expected = `workspace-signal-number:${userId}:${value}`;
  const valid = value === "" || E164.test(value);

  return (
    <section aria-labelledby="workspace-signal-title" className="admin-agent-models">
      <div className="admin-drawer-section-header">
        <div>
          <h3 id="workspace-signal-title">Signal number</h3>
          <p>The number that new Signal connections of this Workspace message</p>
        </div>
      </div>
      {notice ? (
        <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
      ) : null}
      {loadError ? <AdminNotice message={loadError} tone="error" /> : null}
      {view ? (
        <>
          <DetailList
            items={[
              { label: "Workspace number", value: saved || "Not set" },
              { label: "Platform number", value: view.platform?.e164 ?? "Not set" },
              { label: "In use", value: view.effective?.e164 ?? "No Signal number" },
            ]}
          />
          <p className="admin-drawer-note">
            Leave the field empty to use the platform number. Connected chats keep the
            number they connected with.
          </p>
          {!editing ? (
            <div className="admin-command-actions">
              <Button hierarchy="secondary-gray" onPress={() => setEditing(true)}>
                Change Signal number
              </Button>
            </div>
          ) : null}
          {editing ? (
            <form
              className="admin-command-form"
              onSubmit={(event) => {
                event.preventDefault();
                setConfirming(true);
              }}
            >
              <NativeField
                hint={
                  valid
                    ? "E.164, for example +15551234567"
                    : "Enter + and the country code."
                }
                label="Workspace Signal number"
              >
                <input
                  disabled={busy}
                  inputMode="tel"
                  maxLength={16}
                  onChange={(event) => {
                    setNumber(event.target.value.replace(/[\s()-]/g, ""));
                    setIdempotencyKey(createIdempotencyKey("workspace-signal-number"));
                  }}
                  value={number}
                />
              </NativeField>
              <ReasonField
                onChange={(next) => {
                  setReason(next);
                  setIdempotencyKey(createIdempotencyKey("workspace-signal-number"));
                }}
                value={reason}
              />
              <div className="admin-command-actions">
                <Button
                  isDisabled={
                    busy || !valid || value === saved || reason.trim().length < 3
                  }
                  type="submit"
                >
                  Review Signal number change
                </Button>
              </div>
            </form>
          ) : null}
        </>
      ) : null}
      <AdminConfirmationDialog
        expected={expected}
        isOpen={confirming}
        onBusyChange={setBusy}
        onConfirm={async () => {
          const updated = await guardedAdminCommand(
            api.updateUserWorkspaceSignalNumber(userId, {
              number: value,
              reason: reason.trim(),
              confirmation: expected,
              idempotencyKey,
            }),
            onAccessDenied
          );
          setView(updated);
          setNumber(updated.override?.e164 ?? "");
          setReason("");
          setEditing(false);
          setIdempotencyKey(createIdempotencyKey("workspace-signal-number"));
          setNotice(
            updated.override?.e164
              ? `Signal number set to ${updated.override.e164}.`
              : "The Workspace now uses the platform Signal number."
          );
        }}
        onOpenChange={setConfirming}
        title={
          value ? "Set the Workspace Signal number?" : "Use the platform Signal number?"
        }
      />
    </section>
  );
}
