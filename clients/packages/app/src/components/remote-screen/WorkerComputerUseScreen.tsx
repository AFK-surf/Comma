import { useMemo, useState } from "react";
import { useActiveWorkspaceId } from "../activeWorkspace";
import {
  screenPageId,
  useOptionalChatSidebar,
} from "../chat-sidebar/ChatSidebarContext";
import { useChatProductLease } from "../chat/ChatProvider";
import { useOptionalCommaClientSettings } from "../commaClientSettings";
import { usePresentedRecords } from "../chat/session-history/SessionHistory";
import { sessionHistoryEntries } from "../chat/session-history/model/sessionHistoryEntries";
import { useHistoryRecords } from "../chat/session-history/model/sessionHistoryLive";
import {
  useSessionHistory,
  type SessionHistoryInput,
} from "../chat/session-history/useSessionHistory";
import { openComputerUseSession } from "./computerUseSession";
import { ScreenStreamWindow } from "./ScreenStreamWindow";
import { useDeviceScreenSource } from "./useDeviceScreenSource";

/** The screen an Agent drives, on surfaces that may read its Session history, when the setting is on. */
export function FocusComputerUseScreen(history: SessionHistoryInput) {
  const lease = useChatProductLease();
  // Off unless the person turned it on in Settings.
  const settings = useOptionalCommaClientSettings();
  return lease && settings?.computerUseScreenEnabled ? (
    <WorkerComputerUseScreen history={history} />
  ) : null;
}

/**
 * While an Agent drives an app on a computer through computer use, shows that
 * app live in a small card. The person may close it; it returns with the
 * Agent's next session. Closing it leaves the Agent's work alone. Opened in
 * the side panel, the screen shows there and the card makes way.
 */
function WorkerComputerUseScreen({ history }: { history: SessionHistoryInput }) {
  const sidebar = useOptionalChatSidebar();
  const workspace = useActiveWorkspaceId();
  const { snapshot } = useSessionHistory(history, "latest");
  const records = useHistoryRecords(snapshot);
  const items = usePresentedRecords(records);
  const session = useMemo(
    () => openComputerUseSession(sessionHistoryEntries(records, items)),
    [records, items]
  );
  const device = session?.device;
  const apps = session?.apps.join("\n") ?? "";
  const key = device === undefined ? undefined : `${device}\n${apps}`;
  const [closed, setClosed] = useState<string>();

  if (!workspace || device === undefined || key === undefined || closed === key)
    return null;
  const appList = apps ? apps.split("\n") : [];
  const page = { device, apps: appList };
  const inPanel =
    sidebar?.isOpen === true &&
    sidebar.activeSession?.activeSurface === "screen" &&
    sidebar.activeSession.activeScreenPageId === screenPageId(page);
  if (inPanel) return null;
  return (
    <DeviceScreenCard
      containment={document.querySelector<HTMLElement>(".comma-route-outlet")}
      apps={appList}
      device={device}
      key={key}
      onClose={() => setClosed(key)}
      onExpand={
        sidebar
          ? () =>
              sidebar.openScreen(
                sidebar.activeHost ?? {
                  workspaceId: workspace,
                  groupId: history.groupId,
                  conversationId: history.conversationId,
                },
                { ...page, workspaceId: workspace }
              )
          : undefined
      }
      workspace={workspace}
    />
  );
}

function DeviceScreenCard({
  workspace,
  device,
  apps,
  containment,
  onExpand,
  onClose,
}: {
  containment: HTMLElement | null;
  workspace: string;
  device: string;
  apps: string[];
  onExpand: (() => void) | undefined;
  onClose(): void;
}) {
  const source = useDeviceScreenSource(workspace, device, apps);
  return (
    <ScreenStreamWindow
      appName={apps.length ? apps.join(", ") : undefined}
      containment={containment}
      deckKey={`${device}\n${apps.join("\n")}`}
      onClose={onClose}
      onExpand={onExpand}
      source={source}
    />
  );
}
