import { useCall, useDoing, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { miniAppCapabilityLabel } from "@comma/ui/components/mini-apps";
import { type SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { toast } from "@comma/ui/components/toast";
import { useActiveWorkspace } from "../activeWorkspace";

type Item = SettingsCategoryDefinition["sections"][number]["items"][number];

/**
 * Settings › Apps: the capabilities this Workspace granted each app (revoked here, for what runs now too), and the
 * shared apps it added (removed here). The core reads the Workspace's apps (`miniApps`) while the page shows.
 */
export function useMiniAppsSettingsCategory(
  enabled: boolean
): SettingsCategoryDefinition {
  const messages = useCommaMessages();
  const call = useCall();
  const resolved = useActiveWorkspace(enabled);
  const workspace = resolved?.workspace?.id ?? "";
  const { value } = useTopic(
    enabled && workspace ? { topic: "miniApps", workspace } : null
  );
  const revoking = useDoing("miniApps.grants.set");
  const removing = useDoing("miniApps.uninstall");
  const apps = value?.apps ?? [];
  const failed = () => toast.error(messages.settings_apps_failed());
  const loading = enabled && (!value || value.status === "loading");

  const access: Item[] = apps
    .filter((app) => app.grants.length > 0)
    .map((app) => ({
      id: `apps.access.${app.id}`,
      title: app.name,
      description: messages.settings_apps_allowed({
        capabilities: app.grants
          .map((g) => miniAppCapabilityLabel(messages, g))
          .join(", "),
      }),
      control: {
        type: "button",
        label: messages.settings_apps_revoke(),
        disabled: revoking?.stage === "running",
        onPress: () =>
          void call("miniApps.grants.set", {
            workspace,
            app: app.id,
            grants: [],
          }).catch(failed),
      },
    }));
  const installed: Item[] = apps
    .filter((app) => app.installed)
    .map((app) => ({
      id: `apps.installed.${app.id}`,
      title: app.name,
      description: messages.mini_app_by_author({ author: app.author.name }),
      control: {
        type: "button",
        label: messages.mini_app_remove(),
        tone: "danger",
        disabled: removing?.stage === "running",
        onPress: () =>
          void call("miniApps.uninstall", { workspace, app: app.id }).catch(failed),
      },
    }));
  const status = (section: string, empty: string): Item[] =>
    loading
      ? [
          {
            id: `${section}.loading`,
            title: messages.mini_apps_loading(),
            layout: "stack",
            control: {
              type: "custom",
              content: <LoadingIndicator label={messages.mini_apps_loading()} />,
            },
          },
        ]
      : value?.status === "failed"
        ? [{ id: `${section}.failed`, title: messages.mini_apps_load_failed() }]
        : [{ id: `${section}.empty`, title: empty }];
  return {
    id: "apps",
    icon: "apps",
    label: messages.settings_apps(),
    sections: [
      {
        id: "apps.access",
        title: messages.settings_apps_access(),
        items: access.length
          ? access
          : status("apps.access", messages.settings_apps_access_empty()),
      },
      {
        id: "apps.installed",
        title: messages.settings_apps_installed(),
        items: installed.length
          ? installed
          : status("apps.installed", messages.settings_apps_installed_empty()),
      },
    ],
  };
}
