import { useCall } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { useState } from "react";

type Step =
  | { kind: "intro" }
  | { kind: "current-code"; challengeId: string }
  | { kind: "new-email"; challengeId: string; code: string }
  | { kind: "new-code"; challengeId: string; email: string };

function errorCode(error: unknown): string | undefined {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" ? code : undefined;
}

/** When the account that has the new email is deleted (`email_pending_deletion`), as the server said it. */
function deletionTime(error: unknown): Date | undefined {
  const at = (error as { detail?: { deletion_scheduled_at?: unknown } } | null)?.detail
    ?.deletion_scheduled_at;
  const time = typeof at === "string" ? new Date(at) : undefined;
  return time && !Number.isNaN(time.getTime()) ? time : undefined;
}

/**
 * Settings › Account › Email: move the account to another email. A code goes to the current email, then a code to
 * the new one; with both the email changes. The account, its Workspaces and this session stay.
 */
export function EmailChangeDialog({
  email,
  onClose,
}: {
  email: string;
  onClose: () => void;
}) {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const [step, setStep] = useState<Step>({ kind: "intro" });
  const [value, setValue] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();

  const message = (failure: unknown) => {
    switch (errorCode(failure)) {
      case "invalid_verification_code":
        return m.settings_change_email_invalid_code();
      case "invalid_email":
        return m.settings_change_email_invalid_email();
      case "same_email":
        return m.settings_change_email_same_email();
      case "email_taken":
        return m.settings_change_email_taken();
      case "email_changed":
        return m.settings_change_email_changed();
      case "email_pending_deletion": {
        const time = deletionTime(failure);
        return time
          ? m.settings_change_email_pending_deletion({
              date: time.toLocaleDateString(locale, { dateStyle: "medium" }),
            })
          : m.settings_change_email_taken();
      }
      case "rate_limited":
        return m.settings_change_email_rate_limited();
      default:
        return m.settings_change_email_failed();
    }
  };

  const run = async (work: () => Promise<void>) => {
    setPending(true);
    setError(undefined);
    try {
      await work();
    } catch (failure) {
      setError(message(failure));
    } finally {
      setPending(false);
    }
  };

  const go = (next: Step) => {
    setValue("");
    setStep(next);
  };

  const cancel = {
    label: m.settings_profile_cancel(),
    hierarchy: "secondary-gray" as const,
    onPress: onClose,
  };
  const shared = {
    isOpen: true,
    isDismissable: !pending,
    onOpenChange: (open: boolean) => {
      if (!open) onClose();
    },
  };
  const codeInput = {
    "aria-label": m.settings_change_email_code_label(),
    autoFocus: true,
    inputMode: "numeric" as const,
    maxLength: 6,
    value,
    onChange: (event: { target: { value: string } }) => {
      setValue(event.target.value.replace(/\D/g, ""));
      setError(undefined);
    },
    ...(error ? { errorMessage: error } : {}),
  };

  if (step.kind === "current-code")
    return (
      <Dialog
        {...shared}
        variant="input"
        title={m.settings_change_email()}
        description={m.settings_change_email_current_code_description({ email })}
        input={codeInput}
        actions={[
          cancel,
          {
            label: m.settings_change_email_continue(),
            hierarchy: "primary",
            disabled: value.length !== 6,
            onPress: () =>
              go({ kind: "new-email", challengeId: step.challengeId, code: value }),
          },
        ]}
      />
    );

  if (step.kind === "new-email")
    return (
      <Dialog
        {...shared}
        variant="input"
        title={m.settings_change_email()}
        description={m.settings_change_email_new_email_description()}
        input={{
          "aria-label": m.settings_change_email_new_email_label(),
          autoFocus: true,
          type: "email",
          value,
          onChange: (event) => {
            setValue(event.target.value);
            setError(undefined);
          },
          ...(error ? { errorMessage: error } : {}),
        }}
        actions={[
          cancel,
          {
            label: m.settings_change_email_send_code(),
            hierarchy: "primary",
            disabled: pending || value.trim() === "",
            onPress: () =>
              void run(async () => {
                const newEmail = value.trim();
                try {
                  const { challengeId } = await call("emailChange.requestNewCode", {
                    email: newEmail,
                    challengeId: step.challengeId,
                    code: step.code,
                  });
                  go({ kind: "new-code", challengeId, email: newEmail });
                } catch (failure) {
                  const reason = errorCode(failure);
                  // A wrong first code is typed again where it was asked for. A taken email used the first code up
                  // (it is checked before the email is looked up), so the change starts again.
                  if (reason === "invalid_verification_code")
                    go({ kind: "current-code", challengeId: step.challengeId });
                  else if (
                    reason === "email_taken" ||
                    reason === "email_pending_deletion"
                  )
                    go({ kind: "intro" });
                  throw failure;
                }
              }),
          },
        ]}
      />
    );

  if (step.kind === "new-code")
    return (
      <Dialog
        {...shared}
        variant="input"
        title={m.settings_change_email()}
        description={m.settings_change_email_new_code_description({
          email: step.email,
        })}
        input={codeInput}
        actions={[
          cancel,
          {
            label: m.settings_change_email_confirm(),
            hierarchy: "primary",
            disabled: pending || value.length !== 6,
            onPress: () =>
              void run(async () => {
                await call("emailChange.confirm", {
                  challengeId: step.challengeId,
                  code: value,
                });
                onClose();
              }),
          },
        ]}
      />
    );

  return (
    <Dialog
      {...shared}
      title={m.settings_change_email()}
      description={error ?? m.settings_change_email_intro_description({ email })}
      actions={[
        cancel,
        {
          label: m.settings_change_email_send_code(),
          hierarchy: "primary",
          disabled: pending,
          onPress: () =>
            void run(async () => {
              const { challengeId } = await call("emailChange.requestCode", {});
              go({ kind: "current-code", challengeId });
            }),
        },
      ]}
    />
  );
}
