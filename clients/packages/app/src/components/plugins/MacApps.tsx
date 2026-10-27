import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import {
  getNativeBridge,
  macAppIds,
  type MacAppIcons,
  type MacAppId,
  type MacAppPermissionState,
  type MacAppState,
  type MacAppsSnapshot,
} from "@comma/native-bridge";
import { Button } from "@comma/ui/components/Button";
import {
  AudioIcon,
  CalendarIcon,
  ChatBubbleIcon,
  EyeIcon,
  FileTextIcon,
  InboxIcon,
  ListChecksIcon,
  MacbookIcon,
  PeopleCircleIcon,
  PinIcon,
  SettingsSliderHorizontalIcon,
} from "@comma/ui/components/icons";
import {
  PluginDetail,
  PluginDetailSection,
  PluginResourceRow,
  type PluginDefinition,
  type PluginDetailCopy,
} from "@comma/ui/components/plugins";
import { toast } from "@comma/ui/components/toast";
import { Toggle } from "@comma/ui/components/toggle";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";

/**
 * The Mac apps plugin in Comma on a Mac. Installing it connects this Mac to the
 * workspace (the `mac-apps` plugin with this device); inside it, one switch per
 * app, stored on this Mac by Main (`macApps.*`). Every app starts off.
 */

export const MAC_APPS_PLUGIN_ID = "mac-apps";

type Messages = ReturnType<typeof useCommaMessages>;

/** Shown when this Mac has no icon for an app. */
const fallbackIcons: Record<MacAppId | "mac", ReactNode> = {
  mac: <MacbookIcon />,
  calendar: <CalendarIcon />,
  reminders: <ListChecksIcon />,
  contacts: <PeopleCircleIcon />,
  messages: <ChatBubbleIcon />,
  mail: <InboxIcon />,
  notes: <FileTextIcon />,
  music: <AudioIcon />,
  maps: <PinIcon />,
  system: <SettingsSliderHorizontalIcon />,
  vision: <EyeIcon />,
};

export function appName(messages: Messages, app: MacAppId): string {
  switch (app) {
    case "calendar":
      return messages.plugins_mac_app_calendar();
    case "reminders":
      return messages.plugins_mac_app_reminders();
    case "contacts":
      return messages.plugins_mac_app_contacts();
    case "messages":
      return messages.plugins_mac_app_messages();
    case "mail":
      return messages.plugins_mac_app_mail();
    case "notes":
      return messages.plugins_mac_app_notes();
    case "music":
      return messages.plugins_mac_app_music();
    case "maps":
      return messages.plugins_mac_app_maps();
    case "system":
      return messages.plugins_mac_app_system();
    case "vision":
      return messages.plugins_mac_app_vision();
  }
}

/**
 * The app's own macOS icon, drawn as an SVG so the artwork tile sizes it like
 * every other plugin's logo; nothing while the icons load, so no other icon
 * flashes first.
 */
export function artwork(
  icons: MacAppIcons | undefined,
  key: MacAppId | "mac"
): ReactNode {
  if (!icons) return null;
  const src = icons[key];
  return src ? (
    <svg viewBox="0 0 1 1">
      <image height="1" href={src} width="1" />
    </svg>
  ) : (
    fallbackIcons[key]
  );
}

/** The app's own icon when this Mac drew it, its design-system icon otherwise (chat cards on any client). */
export function appIcon(icons: MacAppIcons | undefined, key: MacAppId): ReactNode {
  return icons?.[key] ? artwork(icons, key) : fallbackIcons[key];
}

/** The Mac apps plugin's logo where plugins are listed outside Plugins (the "@" menu): this Mac's icon, else the design-system Mac. */
export function MacAppsPluginIcon() {
  const icons = useMacAppIcons();
  return <>{icons?.mac ? artwork(icons, "mac") : fallbackIcons.mac}</>;
}

export function macAppsPlugin(
  messages: Messages,
  icons: MacAppIcons | undefined
): PluginDefinition {
  return {
    icon: artwork(icons, "mac"),
    description: messages.plugins_mac_description(),
    id: MAC_APPS_PLUGIN_ID,
    name: messages.plugins_mac_name(),
    summary: messages.plugins_mac_summary(),
  };
}

/** An Automation target that is not running cannot be asked about; it was allowed when turned on. */
const allowed = (state: MacAppPermissionState) =>
  state === "granted" || state === "unknown";
const refused = (state: MacAppPermissionState) =>
  state === "denied" || state === "restricted";

export interface MacApps {
  /** Comma on a Mac that serves the Mac apps. */
  available: boolean;
  snapshot: MacAppsSnapshot | undefined;
  /** Undefined while they load. */
  icons: MacAppIcons | undefined;
  pending: ReadonlySet<MacAppId>;
  /** Apps macOS did not allow when the user turned them on; they stayed off. */
  notAllowed: ReadonlySet<MacAppId>;
  setEnabled(app: MacAppId, enabled: boolean): Promise<void>;
  install(): Promise<void>;
  uninstall(): Promise<void>;
  openSettings(requirement: string): void;
}

/** One read per bridge: Main draws the icons once. */
const iconRequests = new WeakMap<object, Promise<MacAppIcons>>();

function macAppIcons(bridge: ReturnType<typeof getNativeBridge>) {
  let request = iconRequests.get(bridge);
  if (!request) {
    request = bridge.macApps.icons().catch(() => ({}));
    iconRequests.set(bridge, request);
  }
  return request;
}

/** The Mac apps' icons as this Mac draws them; undefined while they load and outside Comma on a Mac. */
export function useMacAppIcons(): MacAppIcons | undefined {
  const bridge = getNativeBridge();
  const onMac = bridge.platform === "electron" && bridge.os === "macos";
  const [icons, setIcons] = useState<MacAppIcons>();
  useEffect(() => {
    if (!onMac) return;
    let current = true;
    void macAppIcons(bridge).then((next) => {
      if (current) setIcons(next);
    });
    return () => {
      current = false;
    };
  }, [onMac, bridge]);
  return icons;
}

export function useMacApps({
  workspaceId,
  installed,
}: {
  workspaceId: string | undefined;
  /** Whether the workspace has the `mac-apps` plugin installed. */
  installed: boolean;
}): MacApps {
  const bridge = getNativeBridge();
  const onMac = bridge.platform === "electron" && bridge.os === "macos";
  const call = useCall();
  const messages = useCommaMessages();
  const [snapshot, setSnapshot] = useState<MacAppsSnapshot>();
  const [icons, setIcons] = useState<MacAppIcons>();
  const [deviceId, setDeviceId] = useState<string>();
  const [pending, setPending] = useState<ReadonlySet<MacAppId>>(new Set());
  const [notAllowed, setNotAllowed] = useState<ReadonlySet<MacAppId>>(new Set());

  // Replays, acknowledgements and events can arrive out of order; only newer snapshots win.
  const accept = useCallback((next: MacAppsSnapshot) => {
    setSnapshot((current) =>
      current && current.revision > next.revision ? current : next
    );
  }, []);

  useEffect(() => {
    if (!onMac) return;
    return bridge.macApps.state.subscribe(accept);
  }, [accept, onMac, bridge]);

  const available =
    onMac && snapshot !== undefined && snapshot.status !== "unavailable";

  useEffect(() => {
    if (!available) return;
    let current = true;
    void macAppIcons(bridge).then((next) => {
      if (current) setIcons(next);
    });
    return () => {
      current = false;
    };
  }, [available, bridge]);

  // macOS permissions change in System Settings, behind Comma's back.
  useEffect(() => {
    if (!onMac) return;
    const refresh = () =>
      void bridge.macApps.state
        .get()
        .then(accept)
        .catch(() => undefined);
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, [accept, onMac, bridge]);

  useEffect(() => {
    if (!onMac || !workspaceId) return;
    return bridge.connectorRuntime.state.subscribe((state) => {
      setDeviceId(
        state.scopes.find((scope) => scope.workspaceId === workspaceId)?.deviceId
      );
    });
  }, [onMac, bridge, workspaceId]);

  // Installing again makes Salix rediscover which tools this Mac serves.
  const install = useCallback(async () => {
    if (!workspaceId) return;
    if (!deviceId) {
      toast.error(messages.plugins_mac_no_device());
      return;
    }
    await call("plugin.install", {
      workspace: workspaceId,
      plugin: MAC_APPS_PLUGIN_ID,
      deviceId,
    }).catch(() => undefined);
  }, [call, deviceId, messages, workspaceId]);

  const installedRef = useRef(installed);
  installedRef.current = installed;

  const setEnabled = useCallback(
    async (app: MacAppId, enabled: boolean) => {
      setPending((current) => new Set(current).add(app));
      try {
        const result = await bridge.macApps.setEnabled({ app, enabled });
        accept(result.snapshot);
        // The switch stays off when macOS did not allow the app: say so, also when
        // macOS never showed its prompt.
        const refusedNow = enabled && !result.enabled;
        setNotAllowed((current) => {
          const next = new Set(current);
          if (refusedNow) next.add(app);
          else next.delete(app);
          return next;
        });
        if (refusedNow)
          toast.error(
            messages.plugins_mac_not_allowed({ name: appName(messages, app) })
          );
        if (installedRef.current) await install();
      } finally {
        setPending((current) => {
          const next = new Set(current);
          next.delete(app);
          return next;
        });
      }
    },
    [accept, bridge, install, messages]
  );

  // The switches belong to this Mac and every workspace connected on it, so
  // uninstalling from one workspace leaves them.
  const uninstall = useCallback(async () => {
    if (!workspaceId) return;
    await call("plugin.uninstall", {
      workspace: workspaceId,
      plugin: MAC_APPS_PLUGIN_ID,
    }).catch(() => undefined);
  }, [call, workspaceId]);

  const openSettings = useCallback(
    (requirement: string) =>
      void bridge.macApps.openPrivacySettings({ requirement }).catch(() => undefined),
    [bridge]
  );

  return {
    available,
    snapshot,
    icons,
    pending,
    notAllowed,
    setEnabled,
    install,
    uninstall,
    openSettings,
  };
}

/** What still keeps an app from working, with the way to System Settings; nothing when it works. */
function AccessNotice({
  app,
  macApps,
  messages,
}: {
  app: MacAppState;
  macApps: MacApps;
  messages: Messages;
}) {
  // Asked for when turned on and needed by every tool: without it the app cannot work.
  // An app macOS just did not allow names what it asked for, whatever it reports now.
  const blocking = app.requirements.find(
    (entry) =>
      entry.onEnable &&
      ((entry.tools.length === 0 && refused(entry.state)) ||
        (!app.enabled && macApps.notAllowed.has(app.id) && entry.state !== "granted"))
  );
  const missing = app.enabled
    ? app.requirements.find((entry) => !allowed(entry.state))
    : undefined;
  const requirement = blocking ?? missing;
  if (!requirement) return null;
  return (
    <span className="flex shrink-0 items-center gap-sm text-sm">
      <span className="whitespace-nowrap text-fg-warning-primary">
        {blocking ? messages.plugins_mac_denied() : messages.plugins_mac_partial()}
      </span>
      <Button
        className="h-7 px-md"
        hierarchy="tertiary-gray"
        onPress={() => macApps.openSettings(requirement.requirement)}
        size="sm"
      >
        {messages.plugins_mac_open_settings()}
      </Button>
    </span>
  );
}

const timeFormat = new Intl.DateTimeFormat(undefined, {
  hour: "2-digit",
  minute: "2-digit",
});

function outcomeLabel(messages: Messages, outcome: string) {
  if (outcome === "ok") return messages.plugins_mac_outcome_ok();
  if (outcome === "permission_required")
    return messages.plugins_mac_outcome_permission();
  if (outcome === "plugin_off") return messages.plugins_mac_outcome_off();
  return messages.plugins_mac_outcome_failed();
}

const RECENT_ACTIVITY = 10;

/** The Mac apps plugin: installed, a switch for each app and this Mac's recent calls. */
export function MacAppsDetail({
  copy,
  installed,
  installPending,
  macApps,
  onBack,
  onTryInChat,
  uninstallPending,
}: {
  copy: PluginDetailCopy;
  installed: boolean;
  installPending: boolean;
  macApps: MacApps;
  onBack: () => void;
  onTryInChat: () => void;
  uninstallPending: boolean;
}) {
  const messages = useCommaMessages();
  const snapshot = macApps.snapshot;
  const apps: readonly MacAppState[] = snapshot?.apps.length
    ? snapshot.apps
    : macAppIds.map((id) => ({ id, enabled: false, tools: [], requirements: [] }));
  const toolTitles = new Map(
    apps.flatMap((app) => app.tools.map((tool) => [tool.name, tool.title] as const))
  );
  const activity = installed
    ? (snapshot?.activity ?? []).slice(0, RECENT_ACTIVITY)
    : [];

  return (
    <PluginDetail
      className="comma-plugins-route"
      copy={copy}
      installed={installed}
      installPending={installPending}
      onBack={onBack}
      onInstall={() => void macApps.install()}
      onTryInChat={onTryInChat}
      onUninstall={() => void macApps.uninstall()}
      plugin={macAppsPlugin(messages, macApps.icons)}
      uninstallPending={uninstallPending}
    >
      <PluginDetailSection title={messages.plugins_mac_apps()}>
        {snapshot?.status === "error" ? (
          <output className="mx-md block rounded-lg bg-secondary px-md py-sm text-sm text-secondary">
            {messages.plugins_mac_load_failed()}
          </output>
        ) : null}
        <ul className="m-0 flex list-none flex-col gap-xs p-0">
          {apps.map((app) => {
            const name = appName(messages, app.id);
            return (
              <PluginResourceRow
                key={app.id}
                resource={{
                  icon: artwork(macApps.icons, app.id),
                  id: app.id,
                  name,
                  // Apps are turned on once the plugin is installed.
                  ...(installed
                    ? {
                        trailingContent: (
                          <span className="flex shrink-0 items-center gap-md">
                            <AccessNotice
                              app={app}
                              macApps={macApps}
                              messages={messages}
                            />
                            <Toggle
                              aria-label={messages.plugins_mac_toggle_named({ name })}
                              checked={app.enabled}
                              disabled={macApps.pending.has(app.id)}
                              onChange={() =>
                                void macApps.setEnabled(app.id, !app.enabled)
                              }
                              size="sm"
                            />
                          </span>
                        ),
                      }
                    : {}),
                }}
              />
            );
          })}
        </ul>
      </PluginDetailSection>
      {activity.length ? (
        <PluginDetailSection title={messages.plugins_mac_activity()}>
          <ul className="m-0 flex list-none flex-col gap-xs p-0">
            {activity.map((entry) => (
              <PluginResourceRow
                key={`${entry.at}-${entry.tool}`}
                resource={{
                  icon: artwork(macApps.icons, entry.app),
                  id: `${entry.at}-${entry.tool}`,
                  name: toolTitles.get(entry.tool) ?? entry.tool,
                  trailingContent: (
                    <span className="shrink-0 text-sm text-quaternary tabular-nums">
                      <time dateTime={entry.at}>
                        {timeFormat.format(new Date(entry.at))}
                      </time>
                      {` · ${outcomeLabel(messages, entry.outcome)}`}
                    </span>
                  ),
                }}
              />
            ))}
          </ul>
        </PluginDetailSection>
      ) : null}
    </PluginDetail>
  );
}
