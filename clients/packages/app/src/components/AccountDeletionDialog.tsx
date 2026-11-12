import { getActiveCommaConfig } from "@comma/config";
import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { useState } from "react";
import { openNativePlatformExternalUrl } from "../nativePlatformActions";
import { useWorkspacePreference } from "./activeWorkspace";

type Step =
  | { kind: "confirm" }
  | { kind: "type-email" }
  | { kind: "subscription" }
  | { kind: "code"; challengeId: string };

function errorCode(error: unknown): string | undefined {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" ? code : undefined;
}

/**
 * Settings › Danger zone › Delete account: confirm, type the account email, get a code by email, delete with it. A subscription that still
 * renews blocks deletion until renewal is turned off in the billing portal. Once deleted, the session ends and the
 * app shows sign-in.
 */
export function AccountDeletionDialog({
  email,
  onClose,
}: {
  email: string;
  onClose: () => void;
}) {
  const m = useCommaMessages();
  const call = useCall();
  const workspace = useWorkspacePreference();
  const [step, setStep] = useState<Step>({ kind: "confirm" });
  const [code, setCode] = useState("");
  const [typedEmail, setTypedEmail] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();

  const run = async (work: () => Promise<void>) => {
    setPending(true);
    setError(undefined);
    try {
      await work();
    } catch (failure) {
      const reason = errorCode(failure);
      if (reason === "subscription_active") setStep({ kind: "subscription" });
      else if (reason === "invalid_verification_code")
        setError(m.settings_delete_account_invalid_code());
      else if (reason === "rate_limited")
        setError(m.settings_delete_account_rate_limited());
      else setError(m.settings_delete_account_failed());
    } finally {
      setPending(false);
    }
  };

  const sendCode = () =>
    void run(async () => {
      const { challengeId } = await call("accountDeletion.requestCode", {});
      setCode("");
      setStep({ kind: "code", challengeId });
    });

  const deleteAccount = (challengeId: string) =>
    void run(async () => {
      await call("accountDeletion.delete", { challengeId, code });
      onClose();
    });

  const openPortal = () =>
    void run(async () => {
      if (!workspace) return;
      const config = getActiveCommaConfig();
      const session = await call("billing.portal", {
        workspace,
        return: { apiBase: config.apiBaseUrl, environment: config.channel },
      });
      await openNativePlatformExternalUrl(session.url);
      onClose();
    });

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

  if (step.kind === "subscription")
    return (
      <Dialog
        {...shared}
        title={m.settings_delete_account_subscription_title()}
        description={m.settings_delete_account_subscription_description()}
        actions={[
          cancel,
          {
            label: m.settings_delete_account_manage_subscription(),
            hierarchy: "primary",
            disabled: pending || !workspace,
            onPress: openPortal,
          },
        ]}
      />
    );

  if (step.kind === "type-email")
    return (
      <Dialog
        {...shared}
        variant="input"
        title={m.settings_delete_account()}
        description={m.settings_delete_account_type_email_description({ email })}
        input={{
          "aria-label": m.settings_delete_account_type_email_label(),
          autoFocus: true,
          value: typedEmail,
          onChange: (event) => {
            setTypedEmail(event.target.value);
            setError(undefined);
          },
          ...(error ? { errorMessage: error } : {}),
        }}
        actions={[
          cancel,
          {
            label: m.settings_delete_account_send_code(),
            hierarchy: "destructive",
            disabled:
              pending || typedEmail.trim().toLowerCase() !== email.trim().toLowerCase(),
            onPress: sendCode,
          },
        ]}
      />
    );

  if (step.kind === "code")
    return (
      <Dialog
        {...shared}
        variant="input"
        title={m.settings_delete_account()}
        description={m.settings_delete_account_code_description({ email })}
        input={{
          "aria-label": m.settings_delete_account_code_label(),
          autoFocus: true,
          maxLength: 6,
          value: code,
          onChange: (event) => {
            setCode(event.target.value.replace(/\D/g, ""));
            setError(undefined);
          },
          ...(error ? { errorMessage: error } : {}),
        }}
        actions={[
          cancel,
          {
            label: m.settings_delete_account_confirm(),
            hierarchy: "destructive",
            disabled: pending || code.length !== 6,
            onPress: () => deleteAccount(step.challengeId),
          },
        ]}
      />
    );

  return (
    <Dialog
      {...shared}
      title={m.settings_delete_account()}
      description={error ?? m.settings_delete_account_confirm_description({ email })}
      actions={[
        cancel,
        {
          label: m.settings_delete_account_continue(),
          hierarchy: "destructive",
          disabled: pending,
          onPress: () => {
            setTypedEmail("");
            setError(undefined);
            setStep({ kind: "type-email" });
          },
        },
      ]}
    />
  );
}
