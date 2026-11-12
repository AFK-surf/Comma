import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge, type BlenderSnapshot } from "@comma/native-bridge";
import {
  PluginDetail,
  PluginDetailSection,
  PluginResourceRow,
  type PluginDefinition,
  type PluginDetailCopy,
} from "@comma/ui/components/plugins";
import { Button } from "@comma/ui/components/Button";
import { FileIcon } from "@comma/ui/components/icons";
import { toast } from "@comma/ui/components/toast";
import { Toggle } from "@comma/ui/components/toggle";
import { useCallback, useEffect, useState } from "react";
import { PluginBrandArtwork } from "./PluginBrandArtwork";

/**
 * The Blender plugin in Comma on a computer. Installing it connects this
 * computer to the workspace (the core's `plugin.install` with this device);
 * uninstalling removes it from that workspace. The bridge into Blender is this
 * computer's own switch, kept by Main (`blender.*`) for every workspace: Main
 * turns it on when a workspace first connects, unless the user turned it off.
 */

export const BLENDER_PLUGIN_ID = "blender";

export interface Blender {
  /** Comma on a computer that serves Blender. */
  available: boolean;
  snapshot: BlenderSnapshot | undefined;
  pending: boolean;
  install(): Promise<void>;
  uninstall(): Promise<void>;
  setEnabled(enabled: boolean): Promise<void>;
  open(): Promise<void>;
  chooseApp(): Promise<void>;
}

export function useBlender({
  workspaceId,
}: {
  workspaceId: string | undefined;
}): Blender {
  const bridge = getNativeBridge();
  const onDesktop =
    bridge.platform === "electron" &&
    (bridge.os === "macos" || bridge.os === "windows");
  const call = useCall();
  const messages = useCommaMessages();
  const [snapshot, setSnapshot] = useState<BlenderSnapshot>();
  const [deviceId, setDeviceId] = useState<string>();
  const [pending, setPending] = useState(false);

  // Replays, acknowledgements and events can arrive out of order; only newer snapshots win.
  const accept = useCallback((next: BlenderSnapshot) => {
    setSnapshot((current) =>
      current && current.revision > next.revision ? current : next
    );
  }, []);

  useEffect(() => {
    if (!onDesktop) return;
    return bridge.blender.state.subscribe(accept);
  }, [accept, onDesktop, bridge]);

  // Blender windows open and close behind Comma's back; a look at the page reads them again.
  useEffect(() => {
    if (!onDesktop) return;
    const refresh = () =>
      void bridge.blender.state
        .get()
        .then(accept)
        .catch(() => undefined);
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, [accept, onDesktop, bridge]);

  useEffect(() => {
    if (!onDesktop || !workspaceId) return;
    return bridge.connectorRuntime.state.subscribe((state) => {
      setDeviceId(
        state.scopes.find((scope) => scope.workspaceId === workspaceId)?.deviceId
      );
    });
  }, [onDesktop, bridge, workspaceId]);

  const install = useCallback(async () => {
    if (!workspaceId) return;
    if (!deviceId) {
      toast.error(messages.plugins_blender_no_device());
      return;
    }
    await call("plugin.install", {
      workspace: workspaceId,
      plugin: BLENDER_PLUGIN_ID,
      deviceId,
    }).catch(() => undefined);
  }, [call, deviceId, messages, workspaceId]);

  const uninstall = useCallback(async () => {
    if (!workspaceId) return;
    await call("plugin.uninstall", {
      workspace: workspaceId,
      plugin: BLENDER_PLUGIN_ID,
    }).catch(() => undefined);
  }, [call, workspaceId]);

  const local = useCallback(
    async (run: () => Promise<BlenderSnapshot | undefined>) => {
      setPending(true);
      try {
        const next = await run();
        if (next) accept(next);
      } catch {
        // The native gateway passes no reason for a thrown error.
        toast.error(messages.plugins_blender_action_failed());
      } finally {
        setPending(false);
      }
    },
    [accept, messages]
  );

  const setEnabled = useCallback(
    (enabled: boolean) => local(() => bridge.blender.setEnabled({ enabled })),
    [bridge, local]
  );
  const open = useCallback(
    () =>
      local(async () => {
        const opened = await bridge.blender.open({});
        if (!opened.opened)
          toast.error(
            opened.reason === "start_failed"
              ? messages.plugins_blender_start_failed({ path: opened.path })
              : messages.plugins_blender_none()
          );
        return undefined;
      }),
    [bridge, local, messages]
  );
  const chooseApp = useCallback(
    () => local(() => bridge.blender.chooseApp()),
    [bridge, local]
  );

  return {
    available: onDesktop,
    snapshot,
    pending,
    install,
    uninstall,
    setEnabled,
    open,
    chooseApp,
  };
}

/** The bridge state's names for a Blender window: its file, or that it has none yet. */
function windowName(
  messages: ReturnType<typeof useCommaMessages>,
  file: string | undefined
) {
  if (!file) return messages.plugins_blender_untitled();
  return file.split(/[\\/]/).pop() ?? file;
}

/** One line on whether Agents can use Blender on this computer, and what to do next. */
function status(
  messages: ReturnType<typeof useCommaMessages>,
  snapshot: BlenderSnapshot,
  installed: boolean
) {
  if (installed && !snapshot.enabled) return messages.plugins_blender_off();
  if (snapshot.installs.length === 0) return messages.plugins_blender_none();
  if (installed && snapshot.instances.length > 0)
    return messages.plugins_blender_connected({
      count: snapshot.instances.length,
      formattedCount: snapshot.instances.length.toLocaleString(),
    });
  if (installed && snapshot.waiting === 0) return messages.plugins_blender_no_windows();
  const versions = [
    ...new Set(
      snapshot.installs.flatMap((install) => (install.version ? [install.version] : []))
    ),
  ];
  return versions.length
    ? messages.plugins_blender_found_versions({ versions: versions.join(", ") })
    : messages.plugins_blender_found();
}

export function BlenderDetail({
  copy,
  definition,
  installed,
  installPending,
  blender,
  onBack,
  onTryInChat,
  uninstallPending,
}: {
  copy: Partial<PluginDetailCopy>;
  definition: PluginDefinition;
  installed: boolean;
  installPending: boolean;
  blender: Blender;
  onBack: () => void;
  onTryInChat: () => void;
  uninstallPending: boolean;
}) {
  const messages = useCommaMessages();
  const snapshot = blender.snapshot;
  const connected = installed && snapshot?.enabled === true;
  // Opening or choosing Blender does nothing for Agents while this computer's switch is off.
  const actions = snapshot !== undefined && (!installed || snapshot.enabled);
  // The switch below is this plugin's one MCP; its catalog row would only repeat it.
  const { mcps: _mcps, ...plugin } = definition;

  return (
    <PluginDetail
      className="comma-plugins-route"
      copy={copy}
      installed={installed}
      installPending={installPending}
      onBack={onBack}
      onInstall={() => void blender.install()}
      onTryInChat={onTryInChat}
      onUninstall={() => void blender.uninstall()}
      plugin={plugin}
      uninstallPending={uninstallPending}
    >
      <PluginDetailSection
        action={
          actions ? (
            <div className="flex items-center gap-xs pr-md">
              <Button
                className="h-7 px-lg py-xs"
                hierarchy="tertiary-gray"
                isDisabled={blender.pending}
                onPress={() => void blender.chooseApp()}
                size="sm"
              >
                {messages.plugins_blender_choose()}
              </Button>
              {snapshot.installs.length > 0 ? (
                <Button
                  className="h-7 px-lg py-xs"
                  hierarchy="secondary-gray"
                  isDisabled={blender.pending}
                  onPress={() => void blender.open()}
                  size="sm"
                >
                  {messages.plugins_blender_open()}
                </Button>
              ) : null}
            </div>
          ) : null
        }
        title={messages.plugins_blender_computer()}
      >
        <ul className="m-0 flex list-none flex-col gap-xs p-0">
          <PluginResourceRow
            resource={{
              icon: <PluginBrandArtwork brand="blender" name="Blender" />,
              id: "switch",
              name: definition.name,
              ...(snapshot ? { detail: status(messages, snapshot, installed) } : {}),
              ...(installed
                ? {
                    trailingContent: (
                      <Toggle
                        aria-label={messages.plugins_blender_switch()}
                        checked={snapshot?.enabled === true}
                        disabled={blender.pending || snapshot === undefined}
                        onChange={() =>
                          void blender.setEnabled(snapshot?.enabled !== true)
                        }
                        size="sm"
                      />
                    ),
                  }
                : {}),
            }}
          />
          {connected
            ? snapshot.instances.map((instance) => (
                <PluginResourceRow
                  key={instance.id}
                  resource={{
                    icon: <FileIcon className="text-fg-tertiary" />,
                    id: instance.id,
                    name: windowName(messages, instance.file),
                    trailingContent: (
                      <span className="shrink-0 text-sm text-quaternary">
                        {instance.dirty
                          ? `${instance.version} · ${messages.plugins_blender_unsaved()}`
                          : instance.version}
                      </span>
                    ),
                  }}
                />
              ))
            : null}
        </ul>
        {connected && snapshot.waiting > 0 ? (
          <output className="mx-md block rounded-lg bg-secondary px-md py-sm text-sm text-secondary">
            {messages.plugins_blender_waiting()}
          </output>
        ) : null}
        {installed ? (
          <p className="mx-md my-0 text-sm text-quaternary">
            {messages.plugins_blender_switch_note()}
          </p>
        ) : null}
      </PluginDetailSection>
    </PluginDetail>
  );
}
