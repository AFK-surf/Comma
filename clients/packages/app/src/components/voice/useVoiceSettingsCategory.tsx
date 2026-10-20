import { useCallback, useEffect, useState } from "react";
import { useCall, useTopic, type VoiceKeyCreated } from "@comma/core-client";
import type { CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { MoreHorizontalIcon } from "@comma/ui/components/icons";
import { type SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { type SettingsPanelItem } from "@comma/ui/components/settings-panel";
import { useWorkspacePreference } from "../activeWorkspace";
import {
  CreatedVoiceKeyPanel,
  VoiceDialog,
  type VoiceDialogState,
} from "./VoiceSettings";

type Messages = ReturnType<typeof useCommaMessages>;

function formatDate(ms: number | null | undefined, locale: CommaLocale): string {
  if (!ms) return "—";
  return new Date(ms).toLocaleDateString(locale, { month: "short", day: "numeric" });
}

function formatTime(ms: number, locale: CommaLocale): string {
  return new Date(ms).toLocaleTimeString(locale, {
    hour: "numeric",
    minute: "2-digit",
  });
}

/** The server's error code, as a refused core call carries it. */
function errorCode(error: unknown): string | undefined {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" ? code : undefined;
}

/** A failed number or PIN write, in words the person can act on. */
function numberErrorMessage(error: unknown, m: Messages): string {
  const status = (error as { status?: unknown } | null)?.status;
  const code = errorCode(error);
  if (code === "voice_number_in_use" || status === 409)
    return m.settings_voice_number_in_use();
  if (status === 429) return m.settings_voice_rate_limited();
  if (code === "invalid_code") return m.settings_voice_code_invalid();
  if (code === "voice_not_configured")
    return m.settings_voice_not_ready_not_configured();
  return m.settings_voice_verify_failed();
}

function readinessText(reason: string | null | undefined, m: Messages): string {
  if (reason === "disabled") return m.settings_voice_not_ready_disabled();
  if (
    reason === "not_configured" ||
    reason === "twilio_not_configured" ||
    reason === "no_platform_lines"
  )
    return m.settings_voice_not_ready_not_configured();
  return m.settings_voice_not_ready_other();
}

/**
 * Settings › Voice: the caller numbers verified for the workspace's voice line
 * (each proved by an SMS code, optionally guarded by a PIN), the voice agent
 * API keys that custom voice clients connect with, and whether voice calls are
 * available now (docs/messaging-voice.md).
 *
 * The core reads them while the page shows; each change is one of its calls. A
 * freshly minted key's plaintext comes back to this hook only: it is never
 * written to storage, and it is gone once the person dismisses it or leaves
 * the category.
 */
export function useVoiceSettingsCategory(enabled: boolean): SettingsCategoryDefinition {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const prefer = useWorkspacePreference();
  const { value } = useTopic(
    enabled && prefer !== undefined ? { topic: "voice", prefer } : null
  );
  const activeWorkspaceId = value?.workspace ?? undefined;
  const integration = value?.integration ?? undefined;
  const keys = value?.keys ?? undefined;
  const integrationError = value?.integrationError ?? false;
  const keysError = value?.keysError ?? false;
  const loading = enabled && !value;

  const [saveError, setSaveError] = useState<"numbers" | "keys">();
  const [busy, setBusy] = useState(false);
  const [created, setCreated] = useState<VoiceKeyCreated>();
  const [dialog, setDialog] = useState<VoiceDialogState>();
  const [dialogError, setDialogError] = useState<string>();
  const load = useCallback(
    () =>
      call("voice.refresh", {}).then(
        () => undefined,
        () => undefined
      ),
    [call]
  );

  useEffect(() => {
    if (enabled) return;
    setCreated(undefined);
    setDialog(undefined);
  }, [enabled]);

  const openDialog = useCallback((next: VoiceDialogState | undefined) => {
    setDialogError(undefined);
    setDialog(next);
  }, []);

  // A dialog write: on success the dialog closes (or moves on); on failure it
  // stays open with the reason.
  const runDialog = useCallback(
    async (
      run: (workspace: string) => Promise<VoiceDialogState | undefined>,
      describe: (error: unknown) => string
    ) => {
      if (!activeWorkspaceId) return;
      setBusy(true);
      setDialogError(undefined);
      setSaveError(undefined);
      try {
        openDialog(await run(activeWorkspaceId));
      } catch (error) {
        setDialogError(describe(error));
      } finally {
        setBusy(false);
      }
    },
    [activeWorkspaceId, openDialog]
  );

  // A row write without a dialog (enable/disable a key, remove a PIN).
  const mutate = useCallback(
    async (
      section: "numbers" | "keys",
      run: (workspace: string) => Promise<unknown>
    ) => {
      if (!activeWorkspaceId) return;
      setBusy(true);
      setSaveError(undefined);
      try {
        await run(activeWorkspaceId);
      } catch {
        setSaveError(section);
      } finally {
        setBusy(false);
      }
    },
    [activeWorkspaceId]
  );

  const saveFailed = m.settings_voice_save_failed();
  const numberError = (error: unknown) => numberErrorMessage(error, m);
  const keyError = () => saveFailed;

  const dialogs = {
    onStartVerification: (e164: string, line: string | undefined) =>
      void runDialog(async (workspace) => {
        await call("voice.startVerification", {
          workspace,
          e164,
          ...(line ? { line } : {}),
        });
        return { kind: "code", e164, line };
      }, numberError),
    onCheckCode: (e164: string, line: string | undefined, code: string) =>
      void runDialog(async (workspace) => {
        await call("voice.checkCode", {
          workspace,
          e164,
          code,
          ...(line ? { line } : {}),
        });
        return undefined;
      }, numberError),
    onSetPin: (e164: string, pin: string) =>
      void runDialog(async (workspace) => {
        await call("voice.setPin", { workspace, e164, pin });
        return undefined;
      }, numberError),
    onRemoveNumber: (e164: string) =>
      void runDialog(async (workspace) => {
        await call("voice.removeNumber", { workspace, e164 });
        return undefined;
      }, numberError),
    onCreateKey: (name: string) =>
      void runDialog(async (workspace) => {
        setCreated(await call("voice.createKey", { workspace, name }));
        return undefined;
      }, keyError),
    onRenameKey: (keyId: string, name: string) =>
      void runDialog(async (workspace) => {
        await call("voice.updateKey", { workspace, key: keyId, name });
        return undefined;
      }, keyError),
    onDeleteKey: (keyId: string) =>
      void runDialog(async (workspace) => {
        await call("voice.deleteKey", { workspace, key: keyId });
        return undefined;
      }, keyError),
  };

  const ready = integration?.readiness.ready === true;
  const lines = integration?.lines ?? [];
  const retry = {
    type: "button" as const,
    label: m.common_retry(),
    onPress: () => void load(),
  };

  const numberItems: SettingsPanelItem[] = [];
  if (integrationError) {
    numberItems.push({
      id: "voice.numbers.error",
      title: m.settings_voice_numbers(),
      errorMessage: m.settings_voice_error(),
      control: retry,
    });
  } else if (!integration) {
    numberItems.push({
      id: "voice.numbers.loading",
      title: m.settings_voice_numbers(),
      description: m.settings_voice_loading(),
      descriptionLoading: loading,
    });
  } else {
    if (lines.length === 0) {
      numberItems.push({
        id: "voice.line.none",
        title: m.settings_voice_no_line(),
        description: m.settings_voice_no_line_description(),
      });
    }
    for (const line of lines) {
      numberItems.push({
        id: `voice.line.${line}`,
        title: m.settings_voice_line({ line }),
        description: m.settings_voice_line_description(),
        control: {
          type: "button",
          label: m.settings_voice_add_number(),
          disabled: busy,
          onPress: () => openDialog({ kind: "add-number", line }),
        },
      });
    }
    for (const number of integration.numbers) {
      const locked = number.status === "locked" && number.pin_locked_until;
      numberItems.push({
        id: `voice.number.${number.e164}.${number.line ?? ""}`,
        title: number.e164,
        description: [
          m.settings_voice_number_verified({
            date: formatDate(number.verified_at, locale),
          }),
          locked
            ? m.settings_voice_pin_locked({
                time: formatTime(number.pin_locked_until ?? 0, locale),
              })
            : number.pin_set
              ? m.settings_voice_pin_set()
              : m.settings_voice_pin_not_set(),
        ].join(" · "),
        status: locked
          ? { label: m.settings_voice_status_locked(), color: "warning" }
          : { label: m.settings_voice_status_verified(), color: "success" },
        control: {
          type: "menu",
          icon: <MoreHorizontalIcon />,
          label: m.settings_voice_number_actions(),
          disabled: busy,
          items: [
            {
              id: "pin",
              label: number.pin_set
                ? m.settings_voice_change_pin()
                : m.settings_voice_set_pin(),
              onPress: () => openDialog({ kind: "pin", e164: number.e164 }),
            },
            ...(number.pin_set
              ? [
                  {
                    id: "clear-pin",
                    label: m.settings_voice_clear_pin(),
                    onPress: () =>
                      void mutate("numbers", (workspace) =>
                        call("voice.setPin", { workspace, e164: number.e164, pin: "" })
                      ),
                  },
                ]
              : []),
            {
              id: "remove",
              label: m.settings_voice_remove_number(),
              tone: "destructive" as const,
              onPress: () => openDialog({ kind: "remove-number", e164: number.e164 }),
            },
          ],
        },
      });
    }
    const first = numberItems[0];
    if (saveError === "numbers" && first) {
      numberItems[0] = { ...first, errorMessage: saveFailed };
    }
  }

  const keyItems: SettingsPanelItem[] = [];
  if (created) {
    keyItems.push({
      id: "voice.keys.created",
      title: m.settings_voice_key_created_title(),
      layout: "stack",
      control: {
        type: "custom",
        content: (
          <CreatedVoiceKeyPanel
            created={created}
            onDismiss={() => setCreated(undefined)}
          />
        ),
      },
    });
  }
  keyItems.push({
    id: "voice.keys.new",
    title: m.settings_voice_keys_connect(),
    description:
      keys && keys.length === 0
        ? `${m.settings_voice_keys_description()} ${m.settings_voice_keys_none()}`
        : m.settings_voice_keys_description(),
    ...(keysError
      ? { errorMessage: m.settings_voice_error(), control: retry }
      : {
          ...(saveError === "keys" ? { errorMessage: saveFailed } : {}),
          control: {
            type: "button" as const,
            label: m.settings_voice_new_key(),
            disabled: busy || !keys || !activeWorkspaceId,
            onPress: () => openDialog({ kind: "new-key" }),
          },
        }),
  });
  for (const apiKey of keys ?? []) {
    const active = apiKey.status === "active";
    keyItems.push({
      id: `voice.key.${apiKey.key_id}`,
      title: apiKey.name,
      description: m.settings_voice_key_details({
        prefix: apiKey.prefix,
        created: formatDate(
          apiKey.created_at ? apiKey.created_at * 1000 : null,
          locale
        ),
        used: formatDate(
          apiKey.last_used_at ? apiKey.last_used_at * 1000 : null,
          locale
        ),
      }),
      status: active
        ? { label: m.settings_inbound_api_status_active(), color: "success" }
        : { label: m.settings_inbound_api_status_disabled(), color: "gray" },
      control: {
        type: "menu",
        icon: <MoreHorizontalIcon />,
        label: m.settings_inbound_api_actions(),
        disabled: busy,
        items: [
          {
            id: "rename",
            label: m.settings_inbound_api_rename(),
            onPress: () =>
              openDialog({
                kind: "rename-key",
                keyId: apiKey.key_id,
                name: apiKey.name,
              }),
          },
          {
            id: "toggle",
            label: active
              ? m.settings_inbound_api_disable()
              : m.settings_inbound_api_enable(),
            onPress: () =>
              void mutate("keys", (workspace) =>
                call("voice.updateKey", {
                  workspace,
                  key: apiKey.key_id,
                  status: active ? "disabled" : "active",
                })
              ),
          },
          {
            id: "delete",
            label: m.settings_inbound_api_delete(),
            tone: "destructive",
            onPress: () =>
              openDialog({
                kind: "delete-key",
                keyId: apiKey.key_id,
                name: apiKey.name,
              }),
          },
        ],
      },
    });
  }

  const readinessItem: SettingsPanelItem = {
    id: "voice.readiness.status",
    title: m.settings_voice_readiness_title(),
    ...(integration
      ? {
          description: ready
            ? m.settings_voice_ready()
            : readinessText(integration.readiness.reason, m),
          status: ready
            ? { label: m.settings_voice_status_ready(), color: "success" as const }
            : { label: m.settings_voice_status_not_ready(), color: "gray" as const },
        }
      : { description: m.settings_voice_loading(), descriptionLoading: loading }),
  };

  return {
    id: "voice",
    icon: "voice",
    keywords: [
      "phone",
      "call",
      "voice",
      "sms",
      "pin",
      "comma-voice",
      "电话",
      "语音",
      "通话",
    ],
    label: m.settings_voice(),
    title: m.settings_voice(),
    sections: [
      { id: "voice.numbers", title: m.settings_voice_numbers(), items: numberItems },
      { id: "voice.keys", title: m.settings_voice_keys(), items: keyItems },
      {
        id: "voice.readiness",
        title: m.settings_voice_readiness(),
        items: [readinessItem],
      },
    ],
    ...(dialog
      ? {
          overlay: (
            <VoiceDialog
              dialog={dialog}
              error={dialogError}
              onClose={() => openDialog(undefined)}
              pending={busy}
              {...dialogs}
            />
          ),
        }
      : {}),
  };
}
