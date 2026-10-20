import { useCallback, useEffect, useState } from "react";
import { useCall, useTopic, type RouterKeyCreated } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { useWorkspacePreference } from "../activeWorkspace";
import { RouterApiKeysPage, type RouterApiKeyDraft } from "./RouterApiKeysSettings";

/**
 * The Settings › Inbound API category: the keys that let an external service
 * post a message to this workspace's Router. A page of its own, like Labels.
 * The core reads them while the page shows; each change is one of its calls.
 *
 * A freshly minted key's plaintext comes back to this hook only: it is never
 * written to storage, and it is gone the moment the person dismisses the
 * panel or leaves the category.
 */
export function useRouterApiKeysCategory(enabled: boolean): SettingsCategoryDefinition {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  // The active workspace, as the Models category resolves it: the remembered
  // choice, else the first workspace the API lists.
  const prefer = useWorkspacePreference();
  const { value } = useTopic(
    enabled && prefer !== undefined ? { topic: "routerKeys", prefer } : null
  );
  const activeWorkspaceId = value?.workspace ?? undefined;
  const keys = value?.keys ?? undefined;
  const error = value?.error ?? false;

  const [saveError, setSaveError] = useState(false);
  const [busy, setBusy] = useState<string>();
  const [created, setCreated] = useState<RouterKeyCreated>();

  useEffect(() => {
    if (!enabled) setCreated(undefined);
  }, [enabled]);

  const mutate = useCallback(async (key: string, run: () => Promise<unknown>) => {
    setBusy(key);
    setSaveError(false);
    try {
      await run();
    } catch {
      setSaveError(true);
    } finally {
      setBusy(undefined);
    }
  }, []);

  const onCreate = useCallback(
    (draft: RouterApiKeyDraft) => {
      if (!activeWorkspaceId) return;
      void mutate("create", async () => {
        setCreated(
          await call("routerKeys.create", {
            workspace: activeWorkspaceId,
            name: draft.name,
          })
        );
      });
    },
    [call, activeWorkspaceId, mutate]
  );
  const onRename = useCallback(
    (key: string, name: string) => {
      if (!activeWorkspaceId) return;
      void mutate(key, () =>
        call("routerKeys.rename", { workspace: activeWorkspaceId, key, name })
      );
    },
    [call, activeWorkspaceId, mutate]
  );
  const onSetStatus = useCallback(
    (key: string, status: "active" | "disabled") => {
      if (!activeWorkspaceId) return;
      void mutate(key, () =>
        call("routerKeys.setStatus", { workspace: activeWorkspaceId, key, status })
      );
    },
    [call, activeWorkspaceId, mutate]
  );
  const onDelete = useCallback(
    (key: string) => {
      if (!activeWorkspaceId) return;
      void mutate(key, () =>
        call("routerKeys.delete", { workspace: activeWorkspaceId, key })
      );
    },
    [call, activeWorkspaceId, mutate]
  );

  return {
    id: "inbound-api",
    icon: "inbound-api",
    keywords: ["api", "key", "webhook", "inbound", "external", "接入", "密钥"],
    label: messages.settings_inbound_api(),
    title: messages.settings_inbound_api_title(),
    sections: [
      {
        id: "inbound-api.keys",
        title: messages.settings_inbound_api_title(),
        items: [
          {
            id: "inbound-api.keys.table",
            title: messages.settings_inbound_api_title(),
            description: messages.settings_inbound_api_description(),
          },
        ],
      },
    ],
    content: (
      <RouterApiKeysPage
        busy={busy}
        created={created}
        error={
          error
            ? messages.settings_inbound_api_error()
            : saveError
              ? messages.settings_inbound_api_save_failed()
              : undefined
        }
        keys={keys}
        loading={enabled && !keys && !error}
        locale={locale}
        onCreate={onCreate}
        onDelete={onDelete}
        onDismissCreated={() => setCreated(undefined)}
        onRename={onRename}
        onRetry={() => void call("routerKeys.refresh", {}).catch(() => undefined)}
        onSetStatus={onSetStatus}
        workspaceId={activeWorkspaceId}
      />
    ),
  };
}
