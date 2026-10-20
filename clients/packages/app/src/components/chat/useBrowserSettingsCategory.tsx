import { useCall } from "@comma/core-client";
import { useEffect, useState } from "react";
import { getNativeBridge } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { type SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { useActiveWorkspaceId } from "../activeWorkspace";
import { BrowserImportDialog } from "./BrowserImportDialog";

/**
 * Settings › Browser entry for importing another browser's sign-ins into the
 * browser sidebar. The browser sidebar toolbar opens the same dialog.
 */
function useBrowserImportSection() {
  const m = useCommaMessages();
  const bridge = getNativeBridge();
  // The import reads another browser's cookies through the macOS keychain;
  // Windows' app has no importer behind the button.
  const available = bridge.platform === "electron" && bridge.os !== "windows";
  const [open, setOpen] = useState(false);
  if (!available) return { section: undefined, overlay: undefined };
  return {
    section: {
      id: "browser.import",
      title: m.settings_browser_import_title(),
      items: [
        {
          id: "browser.import-run",
          title: m.settings_browser_import_action(),
          description: m.settings_browser_import_action_description(),
          keywords: ["chrome", "arc", "edge", "cookie", "import", "导入", "登录"],
          control: {
            type: "button" as const,
            label: m.settings_browser_import_button(),
            onPress: () => setOpen(true),
          },
        },
      ],
    },
    overlay: open ? <BrowserImportDialog onClose={() => setOpen(false)} /> : undefined,
  };
}

/**
 * The Settings › Browser category: the workspace's shared browser logins, and
 * sign-ins imported from another browser on this Mac.
 */
export function useBrowserSettingsCategory() {
  const m = useCommaMessages();
  const call = useCall();
  const browserImport = useBrowserImportSection();
  const workspaceId = useActiveWorkspaceId();
  const [confirmation, setConfirmation] = useState<string>();
  const [pending, setPending] = useState(false);
  const [result, setResult] = useState<{ workspace: string; message: string }>();
  // A confirmation names the workspace it clears: another workspace starts over.
  useEffect(() => {
    setConfirmation(undefined);
    setResult(undefined);
  }, [workspaceId]);
  const clear = async () => {
    if (!confirmation || pending) return;
    const workspace = confirmation;
    setPending(true);
    try {
      await call("browser.clearStorage", { workspace });
      setResult({ workspace, message: m.settings_browser_storage_success() });
      setConfirmation(undefined);
    } catch (error) {
      setResult({
        workspace,
        message:
          (error as { code?: unknown } | null)?.code === "browser_shared_profile_in_use"
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
      ...(browserImport.section ? [browserImport.section] : []),
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
    ) : (
      browserImport.overlay
    ),
  };
  return category;
}
