import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { useState } from "react";
import type { Plugin as CommaPlugin } from "@comma/core-client";
import { openNativePlatformExternalUrl } from "../../nativePlatformActions";

export function PluginCredentialsDialog({
  plugin,
  configuration,
  pending,
  error,
  onClose,
  onSubmit,
}: {
  plugin: CommaPlugin;
  configuration: NonNullable<CommaPlugin["credentialSetup"]>;
  pending: boolean;
  error?: string;
  onClose(): void;
  onSubmit(values: Record<string, string>): void;
}) {
  const messages = useCommaMessages();
  const [value, setValue] = useState("");
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
      description={messages.plugins_credentials_description({ name: plugin.name })}
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
          {messages.plugins_credentials_scope()}
        </p>
        <button
          className="w-fit text-sm text-brand-secondary underline underline-offset-2"
          onClick={() => void openNativePlatformExternalUrl(configuration.helpUrl)}
          type="button"
        >
          {messages.plugins_credentials_help()}
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
