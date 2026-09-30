import { useCommaMessages } from "@comma/i18n/react";
import { CreatedSecretPanel, Dialog } from "@comma/ui";
import { useState } from "react";

const E164 = /^\+[1-9]\d{6,14}$/;

/** The one-time panel of a new connection code: the message to send on Signal. */
export function SignalCodePanel({
  command,
  number,
  onDismiss,
}: {
  command: string;
  number: string;
  onDismiss: () => void;
}) {
  const m = useCommaMessages();
  return (
    <CreatedSecretPanel
      badge={m.settings_signal_code_badge()}
      copiedLabel={m.common_copied()}
      copyLabel={m.settings_signal_copy_message()}
      description={m.settings_signal_code_description({ number })}
      doneLabel={m.settings_inbound_api_done()}
      label={m.settings_signal_code_title()}
      name={number}
      onDismiss={onDismiss}
      secret={command}
      testIds={{ root: "signal-code", secret: "signal-code-message" }}
    />
  );
}

/** The single question the Signal category asks at a time. */
export type SignalDialogState =
  | { kind: "number"; current: string }
  | { kind: "disconnect"; bindingId: string; name: string };

export interface SignalDialogProps {
  dialog: SignalDialogState;
  /** A localized reason the last write of this dialog failed. */
  error: string | undefined;
  pending: boolean;
  onClose: () => void;
  onSaveNumber: (number: string) => void;
  onDisconnect: (bindingId: string) => void;
}

export function SignalDialog(props: SignalDialogProps) {
  // Each dialog owns its draft; a new dialog starts from its own value.
  const key =
    props.dialog.kind + ("bindingId" in props.dialog ? props.dialog.bindingId : "");
  return <SignalDialogBody key={key} {...props} />;
}

function SignalDialogBody({
  dialog,
  error,
  pending,
  onClose,
  onSaveNumber,
  onDisconnect,
}: SignalDialogProps) {
  const m = useCommaMessages();
  const [draft, setDraft] = useState(dialog.kind === "number" ? dialog.current : "");
  const value = draft.trim();
  const cancel = {
    label: m.settings_profile_cancel(),
    hierarchy: "secondary-gray" as const,
    onPress: onClose,
  };
  const common = {
    isDismissable: true,
    isOpen: true,
    onOpenChange: (open: boolean) => {
      if (!open) onClose();
    },
  };

  if (dialog.kind === "number") {
    const valid = E164.test(value);
    return (
      <Dialog
        {...common}
        actions={[
          cancel,
          {
            label: m.settings_signal_save_number(),
            hierarchy: "primary",
            disabled: !valid || pending,
            onPress: () => onSaveNumber(value),
          },
        ]}
        description={m.settings_signal_number_dialog_description()}
        input={{
          autoFocus: true,
          label: m.settings_signal_number_label(),
          name: "number",
          type: "tel",
          placeholder: "+15551234567",
          maxLength: 16,
          value: draft,
          onChange: (event) => setDraft(event.target.value.replace(/[\s()-]/g, "")),
          ...(error
            ? { errorMessage: error }
            : value && !valid
              ? { hint: m.settings_signal_number_invalid() }
              : {}),
        }}
        title={m.settings_signal_number_row()}
        variant="input"
      />
    );
  }

  return (
    <Dialog
      {...common}
      actions={[
        cancel,
        {
          label: m.settings_signal_disconnect(),
          hierarchy: "destructive",
          disabled: pending,
          onPress: () => onDisconnect(dialog.bindingId),
        },
      ]}
      description={
        error ?? m.settings_signal_disconnect_description({ name: dialog.name })
      }
      title={m.settings_signal_disconnect_title()}
    />
  );
}
