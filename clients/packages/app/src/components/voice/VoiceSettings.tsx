import { useCommaMessages } from "@comma/i18n/react";
import { CreatedSecretPanel, Dialog } from "@comma/ui";
import { useState } from "react";
import type { CommaVoiceApiKeyCreated } from "../../api";

const E164 = /^\+[1-9]\d{6,14}$/;
const PIN = /^\d{4,8}$/;

export function isE164(value: string): boolean {
  return E164.test(value);
}

/** Where the copyable example keeps a new voice key. */
const VOICE_KEY_FILE = "~/.comma-voice-key";

/**
 * The `comma-voice` commands a person pastes to try a new key. The key goes to a
 * file only its owner can read and reaches the CLI through `--key-file`, so it
 * is in no `comma-voice` command line or environment. The Salix base URL and
 * the Group id come from the server-built readiness URL, whose path names the
 * Group.
 */
export function voiceKeyExample(created: CommaVoiceApiKeyCreated): string {
  const match = /^(.*)\/v1\/agent-groups\/([^/]+)\/voice$/.exec(
    created.readiness_url ?? ""
  );
  const server = match?.[1] ?? "<salix-base-url>";
  const group = match?.[2] ? decodeURIComponent(match[2]) : "<group-id>";
  return [
    `export COMMA_VOICE_SERVER='${server}'`,
    `export COMMA_VOICE_GROUP='${group}'`,
    `(umask 077; printf '%s' '${created.key}' > ${VOICE_KEY_FILE})`,
    `comma-voice check --key-file ${VOICE_KEY_FILE} && comma-voice call --key-file ${VOICE_KEY_FILE}`,
  ].join("\n");
}

/** The one-time panel: the plaintext of a just-minted voice key. */
export function CreatedVoiceKeyPanel({
  created,
  onDismiss,
}: {
  created: CommaVoiceApiKeyCreated;
  onDismiss: () => void;
}) {
  const m = useCommaMessages();
  return (
    <CreatedSecretPanel
      badge={m.settings_inbound_api_shown_once()}
      copiedLabel={m.common_copied()}
      copyExampleLabel={m.settings_voice_copy_command()}
      copyLabel={m.common_copy()}
      description={m.settings_voice_key_created_description()}
      doneLabel={m.settings_inbound_api_done()}
      example={voiceKeyExample(created)}
      label={m.settings_voice_key_created_title()}
      name={created.name}
      onDismiss={onDismiss}
      secret={created.key}
      testIds={{
        root: "voice-key-created",
        secret: "voice-key-secret",
        example: "voice-key-example",
      }}
    />
  );
}

/** The single question the Voice category asks at a time. */
export type VoiceDialogState =
  | { kind: "add-number"; line: string | undefined }
  | { kind: "code"; e164: string; line: string | undefined }
  | { kind: "pin"; e164: string }
  | { kind: "remove-number"; e164: string }
  | { kind: "new-key" }
  | { kind: "rename-key"; keyId: string; name: string }
  | { kind: "delete-key"; keyId: string; name: string };

export interface VoiceDialogProps {
  dialog: VoiceDialogState;
  /** A localized reason the last write of this dialog failed. */
  error: string | undefined;
  pending: boolean;
  onClose: () => void;
  onStartVerification: (e164: string, line: string | undefined) => void;
  onCheckCode: (e164: string, line: string | undefined, code: string) => void;
  onSetPin: (e164: string, pin: string) => void;
  onRemoveNumber: (e164: string) => void;
  onCreateKey: (name: string) => void;
  onRenameKey: (keyId: string, name: string) => void;
  onDeleteKey: (keyId: string) => void;
}

/**
 * Every Voice dialog is one field or one confirmation, so it keeps the dialog
 * shape and is mounted through the category's `overlay`.
 */
export function VoiceDialog(props: VoiceDialogProps) {
  // Each dialog owns its draft; a new dialog starts empty.
  const key =
    props.dialog.kind +
    ("e164" in props.dialog ? props.dialog.e164 : "") +
    ("keyId" in props.dialog ? props.dialog.keyId : "");
  return <VoiceDialogBody key={key} {...props} />;
}

function VoiceDialogBody({
  dialog,
  error,
  pending,
  onClose,
  onStartVerification,
  onCheckCode,
  onSetPin,
  onRemoveNumber,
  onCreateKey,
  onRenameKey,
  onDeleteKey,
}: VoiceDialogProps) {
  const m = useCommaMessages();
  const [draft, setDraft] = useState(dialog.kind === "rename-key" ? dialog.name : "");
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

  switch (dialog.kind) {
    case "add-number": {
      const valid = isE164(value);
      return (
        <Dialog
          {...common}
          actions={[
            cancel,
            {
              label: m.settings_voice_send_code(),
              hierarchy: "primary",
              disabled: !valid || pending,
              onPress: () => onStartVerification(value, dialog.line),
            },
          ]}
          description={m.settings_voice_add_number_description()}
          input={{
            autoFocus: true,
            label: m.settings_voice_number_label(),
            name: "e164",
            type: "tel",
            placeholder: "+15551234567",
            maxLength: 16,
            value: draft,
            onChange: (event) => setDraft(event.target.value.replace(/[\s()-]/g, "")),
            ...(error
              ? { errorMessage: error }
              : value && !valid
                ? { hint: m.settings_voice_number_invalid() }
                : {}),
          }}
          title={m.settings_voice_add_number_title()}
          variant="input"
        />
      );
    }
    case "code":
      return (
        <Dialog
          {...common}
          actions={[
            cancel,
            {
              label: m.settings_voice_resend(),
              hierarchy: "secondary-gray",
              shortcut: false,
              disabled: pending,
              onPress: () => onStartVerification(dialog.e164, dialog.line),
            },
            {
              label: m.settings_voice_verify(),
              hierarchy: "primary",
              disabled: !/^\d{4,10}$/.test(value) || pending,
              onPress: () => onCheckCode(dialog.e164, dialog.line, value),
            },
          ]}
          description={m.settings_voice_code_description({ e164: dialog.e164 })}
          input={{
            autoFocus: true,
            label: m.settings_voice_code_label(),
            name: "code",
            maxLength: 10,
            value: draft,
            onChange: (event) => setDraft(event.target.value.replace(/\s/g, "")),
            ...(error ? { errorMessage: error } : {}),
          }}
          title={m.settings_voice_code_title()}
          variant="input"
        />
      );
    case "pin": {
      const valid = PIN.test(value);
      return (
        <Dialog
          {...common}
          actions={[
            cancel,
            {
              label: m.settings_voice_save_pin(),
              hierarchy: "primary",
              disabled: !valid || pending,
              onPress: () => onSetPin(dialog.e164, value),
            },
          ]}
          description={m.settings_voice_pin_description({ e164: dialog.e164 })}
          input={{
            autoFocus: true,
            label: m.settings_voice_pin_label(),
            name: "pin",
            type: "password",
            maxLength: 8,
            value: draft,
            onChange: (event) => setDraft(event.target.value.replace(/\D/g, "")),
            ...(error
              ? { errorMessage: error }
              : value && !valid
                ? { hint: m.settings_voice_pin_invalid() }
                : {}),
          }}
          title={m.settings_voice_pin_title()}
          variant="input"
        />
      );
    }
    case "remove-number":
      return (
        <Dialog
          {...common}
          actions={[
            cancel,
            {
              label: m.settings_voice_remove_number(),
              hierarchy: "destructive",
              disabled: pending,
              onPress: () => onRemoveNumber(dialog.e164),
            },
          ]}
          description={
            error ?? m.settings_voice_remove_number_description({ e164: dialog.e164 })
          }
          title={m.settings_voice_remove_number_title()}
        />
      );
    case "new-key":
    case "rename-key": {
      const renaming = dialog.kind === "rename-key";
      const save =
        dialog.kind === "rename-key"
          ? () => onRenameKey(dialog.keyId, value)
          : () => onCreateKey(value);
      return (
        <Dialog
          {...common}
          actions={[
            cancel,
            {
              label: renaming
                ? m.settings_inbound_api_rename()
                : m.settings_inbound_api_create(),
              hierarchy: "primary",
              disabled: !value || pending,
              onPress: save,
            },
          ]}
          {...(renaming ? {} : { description: m.settings_voice_new_key_description() })}
          input={{
            autoFocus: true,
            label: m.settings_inbound_api_name_label(),
            maxLength: 80,
            name: "name",
            placeholder: m.settings_voice_key_name_placeholder(),
            value: draft,
            onChange: (event) => setDraft(event.target.value),
            ...(error ? { errorMessage: error } : {}),
          }}
          title={
            renaming ? m.settings_inbound_api_rename() : m.settings_voice_new_key()
          }
          variant="input"
        />
      );
    }
    case "delete-key":
      return (
        <Dialog
          {...common}
          actions={[
            cancel,
            {
              label: m.settings_inbound_api_delete(),
              hierarchy: "destructive",
              disabled: pending,
              onPress: () => onDeleteKey(dialog.keyId),
            },
          ]}
          description={
            error ?? m.settings_voice_key_delete_description({ name: dialog.name })
          }
          title={m.settings_voice_key_delete_title()}
        />
      );
  }
}
