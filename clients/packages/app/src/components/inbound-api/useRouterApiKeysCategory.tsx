import { useCallback, useEffect, useRef, useState } from "react";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { SettingsCategoryDefinition } from "@comma/ui";
import type {
  CommaApiClient,
  CommaRouterApiKey,
  CommaRouterApiKeyCreated,
} from "../../api";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "../activeWorkspace";
import { RouterApiKeysPage, type RouterApiKeyDraft } from "./RouterApiKeysSettings";

/**
 * The Settings › Inbound API category: the keys that let an external service
 * post a message to this workspace's Router. A page of its own, like Labels.
 *
 * A freshly minted key's plaintext lives in this hook's state only: it is
 * never written to storage, and it is gone the moment the person dismisses
 * the panel or leaves the category.
 */
export function useRouterApiKeysCategory(
  api: CommaApiClient,
  enabled: boolean
): SettingsCategoryDefinition {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  // The active workspace, as the Models category resolves it: the remembered
  // choice, else the first workspace the API lists.
  const [workspaceId, setWorkspaceId] = useState(readActiveWorkspaceId);
  useEffect(() => subscribeActiveWorkspace(setWorkspaceId), []);
  const [activeWorkspaceId, setActiveWorkspaceId] = useState<string>();

  const [keys, setKeys] = useState<CommaRouterApiKey[]>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(false);
  const [saveError, setSaveError] = useState(false);
  const [busy, setBusy] = useState<string>();
  const [created, setCreated] = useState<CommaRouterApiKeyCreated>();
  const generation = useRef(0);

  const load = useCallback(async () => {
    const request = ++generation.current;
    setLoading(true);
    setError(false);
    try {
      const id = workspaceId ?? (await api.listWorkspaces())[0]?.id;
      if (!id) throw new Error("workspace unavailable");
      const next = await api.listRouterApiKeys(id);
      if (request !== generation.current) return;
      setActiveWorkspaceId(id);
      setKeys(next);
    } catch {
      if (request === generation.current) setError(true);
    } finally {
      if (request === generation.current) setLoading(false);
    }
  }, [api, workspaceId]);

  // Leaving the category (or a reload) supersedes any request in flight, and
  // the plaintext of a just-minted key does not survive leaving the page.
  const invalidate = useCallback(() => {
    generation.current++;
  }, []);
  useEffect(() => {
    if (enabled) void load();
    else setCreated(undefined);
    return invalidate;
  }, [enabled, load, invalidate]);

  const mutate = useCallback(
    async (key: string, run: () => Promise<unknown>) => {
      setBusy(key);
      setSaveError(false);
      try {
        await run();
        await load();
      } catch {
        setSaveError(true);
      } finally {
        setBusy(undefined);
      }
    },
    [load]
  );

  const onCreate = useCallback(
    (draft: RouterApiKeyDraft) => {
      if (!activeWorkspaceId) return;
      void mutate("create", async () => {
        setCreated(await api.createRouterApiKey(activeWorkspaceId, draft));
      });
    },
    [api, activeWorkspaceId, mutate]
  );
  const onRename = useCallback(
    (keyId: string, name: string) => {
      if (!activeWorkspaceId) return;
      void mutate(keyId, () =>
        api.updateRouterApiKey(activeWorkspaceId, keyId, { name })
      );
    },
    [api, activeWorkspaceId, mutate]
  );
  const onSetStatus = useCallback(
    (keyId: string, status: "active" | "disabled") => {
      if (!activeWorkspaceId) return;
      void mutate(keyId, () =>
        api.updateRouterApiKey(activeWorkspaceId, keyId, { status })
      );
    },
    [api, activeWorkspaceId, mutate]
  );
  const onDelete = useCallback(
    (keyId: string) => {
      if (!activeWorkspaceId) return;
      void mutate(keyId, () => api.deleteRouterApiKey(activeWorkspaceId, keyId));
    },
    [api, activeWorkspaceId, mutate]
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
        loading={loading && !keys}
        locale={locale}
        onCreate={onCreate}
        onDelete={onDelete}
        onDismissCreated={() => setCreated(undefined)}
        onRename={onRename}
        onRetry={() => void load()}
        onSetStatus={onSetStatus}
        workspaceId={activeWorkspaceId}
      />
    ),
  };
}
