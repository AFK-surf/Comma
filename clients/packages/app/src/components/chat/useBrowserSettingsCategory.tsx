import { useEffect, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog, type SettingsCategoryDefinition } from "@comma/ui";
import { CommaApiError, type CommaApiClient } from "../../api";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "../activeWorkspace";

/** The Settings › Browser category: the workspace's shared browser logins. */
export function useBrowserSettingsCategory(api: CommaApiClient) {
  const m = useCommaMessages();
  const [workspaceId, setWorkspaceId] = useState(readActiveWorkspaceId);
  const [confirmation, setConfirmation] = useState<string>();
  const [pending, setPending] = useState(false);
  const [result, setResult] = useState<{ workspace: string; message: string }>();
  useEffect(
    () =>
      subscribeActiveWorkspace((id) => {
        setWorkspaceId(id);
        setConfirmation(undefined);
        setResult(undefined);
      }),
    []
  );
  const clear = async () => {
    if (!confirmation || pending) return;
    const workspace = confirmation;
    setPending(true);
    try {
      await api.clearBrowserStorage(workspace);
      setResult({ workspace, message: m.settings_browser_storage_success() });
      setConfirmation(undefined);
    } catch (error) {
      setResult({
        workspace,
        message:
          error instanceof CommaApiError &&
          error.body?.error === "browser_shared_profile_in_use"
            ? m.settings_browser_storage_busy()
            : m.settings_browser_storage_failed(),
      });
    } finally {
      setPending(false);
    }
  };
  const message =
    result && result.workspace === workspaceId ? result.message : undefined;
  const category: SettingsCategoryDefinition = {
    id: "browser",
    icon: "browser",
    label: m.settings_browser(),
    keywords: ["cookie", "login", "登录"],
    sections: [
      {
        id: "browser.logins",
        title: m.settings_browser(),
        items: [
          {
            id: "browser.shared-logins",
            title: m.settings_browser_storage_title(),
            description: message ?? m.settings_browser_storage_description(),
            control: {
              type: "button",
              label: m.settings_browser_storage_clear(),
              disabled: !workspaceId || pending,
              onPress: () => {
                setResult(undefined);
                setConfirmation(workspaceId);
              },
            },
          },
        ],
      },
    ],
    overlay: confirmation ? (
      <Dialog
        isOpen
        isDismissable={!pending}
        onOpenChange={(open) => {
          if (!open && !pending) setConfirmation(undefined);
        }}
        title={m.settings_browser_storage_confirm()}
        description={
          result?.workspace === confirmation
            ? result.message
            : m.settings_browser_storage_warning()
        }
        actions={[
          {
            label: m.settings_profile_cancel(),
            hierarchy: "secondary-gray",
            disabled: pending,
            onPress: () => setConfirmation(undefined),
          },
          {
            label: m.settings_browser_storage_confirm(),
            hierarchy: "primary",
            disabled: pending,
            onPress: () => void clear(),
          },
        ]}
      />
    ) : undefined,
  };
  return category;
}
