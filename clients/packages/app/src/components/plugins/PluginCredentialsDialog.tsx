import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { useEffect, useState } from "react";
import type { Plugin as CommaPlugin } from "@comma/core-client";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../../nativePlatformActions";

export function PluginCredentialsDialog({
  plugin,
  configuration,
  operation,
  pending,
  error,
  onClose,
  onSubmit,
}: {
  plugin: CommaPlugin;
  configuration: NonNullable<CommaPlugin["credentialSetup"]>;
  operation?: "install" | "reauthorize";
  pending: boolean;
  error?: string;
  onClose(): void;
  onSubmit(values: Record<string, string>): void;
}) {
  const messages = useCommaMessages();
  const [value, setValue] = useState("");
  const [copied, setCopied] = useState(false);

  // When a fresh PKCE attempt replaces helpUrl / attemptId in place, clear the stale code input.
  useEffect(() => {
    setValue("");
  }, [configuration.attemptId, configuration.helpUrl]);

  if (configuration.format === "show")
    return (
      <Dialog
        isOpen
        onOpenChange={(open) => {
          if (!open) onClose();
        }}
        title={messages.plugins_show_title({ name: plugin.name })}
        description={messages.plugins_show_description({ name: plugin.name })}
        actions={[
          {
            label: messages.plugins_show_done(),
            hierarchy: "primary",
            onPress: onClose,
          },
        ]}
      >
        <div className="flex w-full flex-col gap-md">
          <div className="flex w-full items-end gap-sm">
            <InputField
              readOnly
              className="min-w-0 flex-1 ph-no-capture"
              label={configuration.label}
              value={configuration.value ?? ""}
              onFocus={(event) => event.target.select()}
            />
            <Button
              hierarchy="secondary-gray"
              onPress={() =>
                void nativePlatformClipboard
                  .writeText(configuration.value ?? "")
                  .then(() => setCopied(true))
              }
            >
              {copied ? messages.common_copied() : messages.common_copy()}
            </Button>
          </div>
          <p className="m-0 text-sm text-secondary">
            {messages.plugins_show_once({ name: plugin.name })}
          </p>
        </div>
      </Dialog>
    );

  if (configuration.format === "oauth_code") {
    const isReconnect = operation === "reauthorize";
    const trimmed = value.trim();
    const valid = trimmed.length > 0 && trimmed.length <= 4096;
    const inlineError = error ?? configuration.error;
    const submitOAuthCode = () => {
      if (valid && !pending) onSubmit({ [configuration.key]: trimmed });
    };

    return (
      <Dialog
        isOpen
        isDismissable={!pending}
        onOpenChange={(open) => {
          if (!open && !pending) onClose();
        }}
        title={
          isReconnect
            ? messages.plugins_oauth_code_reconnect_title({ name: plugin.name })
            : messages.plugins_oauth_code_title({ name: plugin.name })
        }
        description={
          isReconnect
            ? messages.plugins_oauth_code_reconnect_description({ name: plugin.name })
            : messages.plugins_oauth_code_description({ name: plugin.name })
        }
        actions={[
          {
            label: messages.plugins_personal_source_cancel(),
            hierarchy: "secondary-gray",
            disabled: pending,
            onPress: onClose,
          },
          {
            label: pending
              ? isReconnect
                ? messages.plugins_oauth_code_reconnecting()
                : messages.plugins_credentials_connecting()
              : isReconnect
                ? messages.plugins_oauth_code_reconnect()
                : messages.plugins_credentials_connect(),
            hierarchy: "primary",
            disabled: pending || !valid,
            onPress: submitOAuthCode,
          },
        ]}
      >
        <div className="flex w-full flex-col gap-md" aria-busy={pending}>
          <div className="flex flex-col gap-sm">
            <p className="m-0 text-sm text-secondary">
              {messages.plugins_oauth_code_step_1()}
            </p>
            <Button
              className="w-fit"
              hierarchy="secondary-gray"
              isDisabled={pending}
              onPress={() => void openNativePlatformExternalUrl(configuration.helpUrl)}
            >
              {messages.plugins_oauth_code_sign_in_google()}
            </Button>
            <p className="m-0 text-xs text-quaternary">
              {messages.plugins_oauth_code_consent_hint()}
            </p>
          </div>
          <div className="flex flex-col gap-sm">
            <p className="m-0 text-sm text-secondary">
              {messages.plugins_oauth_code_step_2()}
            </p>
            <InputField
              autoComplete="off"
              className="w-full ph-no-capture"
              disabled={pending}
              label={configuration.label}
              maxLength={4096}
              placeholder={messages.plugins_oauth_code_placeholder()}
              type="text"
              value={value}
              onChange={(event) => setValue(event.target.value)}
            />
          </div>
          {inlineError ? (
            <p className="m-0 text-sm text-error-primary" role="alert">
              {inlineError}
            </p>
          ) : null}
        </div>
      </Dialog>
    );
  }
  const trimmed = value.trim();
  const valid = trimmed.length > 0 && trimmed.length <= 4096 && !/\s/.test(trimmed);
  const submit = () => {
    if (valid && !pending) onSubmit({ [configuration.key]: trimmed });
  };

  return (
    <Dialog
      isOpen
      isDismissable={!pending}
      onOpenChange={(open) => {
        if (!open && !pending) onClose();
      }}
      title={
        plugin.installed
          ? messages.plugins_credentials_update_title({ name: plugin.name })
          : messages.plugins_credentials_title({ name: plugin.name })
      }
      description={messages.plugins_credentials_description({
        name: plugin.name,
        credential: configuration.label,
      })}
      actions={[
        {
          label: messages.plugins_personal_source_cancel(),
          hierarchy: "secondary-gray",
          disabled: pending,
          onPress: onClose,
        },
        {
          label: pending
            ? plugin.installed
              ? messages.plugins_credentials_updating()
              : messages.plugins_credentials_connecting()
            : plugin.installed
              ? messages.plugins_credentials_update()
              : messages.plugins_credentials_connect(),
          hierarchy: "primary",
          disabled: pending || !valid,
          onPress: submit,
        },
      ]}
    >
      <div className="flex w-full flex-col gap-md" aria-busy={pending}>
        <InputField
          autoComplete="off"
          className="w-full ph-no-capture"
          disabled={pending}
          label={configuration.label}
          maxLength={4096}
          type="password"
          value={value}
          onChange={(event) => setValue(event.target.value)}
        />
        <p className="m-0 text-sm text-secondary">
          {messages.plugins_credentials_scope({
            name: plugin.name,
            credential: configuration.label,
          })}
        </p>
        <button
          className="w-fit text-sm text-brand-secondary underline underline-offset-2"
          onClick={() => void openNativePlatformExternalUrl(configuration.helpUrl)}
          type="button"
        >
          {messages.plugins_credentials_help({ credential: configuration.label })}
        </button>
        {error ? (
          <p className="m-0 text-sm text-error-primary" role="alert">
            {error}
          </p>
        ) : null}
      </div>
    </Dialog>
  );
}
