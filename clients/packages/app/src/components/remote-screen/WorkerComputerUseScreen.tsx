import type { ListedScreen } from "@comma/core-client";
import { memo, useMemo, useState } from "react";
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
import { useScreenDevicesEnabled, useScreenListing } from "./useScreenListing";

/** The screen an Agent drives, on surfaces that may read its Session history, when the setting is on. */
export const FocusComputerUseScreen = memo(function FocusComputerUseScreen(
  history: SessionHistoryInput
) {
  const lease = useChatProductLease();
  // Off unless the person turned it on in Settings.
  const settings = useOptionalCommaClientSettings();
  return lease && settings?.computerUseScreenEnabled ? (
    <WorkerComputerUseScreen history={history} />
  ) : null;
});

/**
 * While an Agent drives an app on a computer through computer use, shows that
 * app live in a small card. The person may close it; it returns with the
 * Agent's next session. Closing it leaves the Agent's work alone. While the
 * screen has a tab in the open side panel, shown or not, it lives there and
 * there is no card. The panel closed, the card shows it again.
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
  const screenId = session?.screen;
  const key =
    device === undefined ? undefined : `${device}\n${apps}\n${screenId ?? ""}`;
  const [closed, setClosed] = useState<string>();

  if (!workspace || device === undefined || key === undefined || closed === key)
    return null;
  // A leased Android device: shown as the computer lists it, only looking (the card never drives it).
  if (screenId)
    return (
      <AndroidScreenCard
        containment={document.querySelector<HTMLElement>(".comma-route-outlet")}
        device={device}
        key={key}
        onClose={() => setClosed(key)}
        screenId={screenId}
        workspace={workspace}
      />
    );
  const appList = apps ? apps.split("\n") : [];
  const page = { device, apps: appList };
  const inPanel =
    sidebar?.isOpen === true &&
    sidebar.activeSession?.screenPages?.some(
      (open) => open.id === screenPageId(page)
    ) === true;
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

function AndroidScreenCard({
  workspace,
  device,
  screenId,
  containment,
  onClose,
}: {
  containment: HTMLElement | null;
  workspace: string;
  device: string;
  screenId: string;
  onClose(): void;
}) {
  const { screens } = useScreenListing(workspace, device, useScreenDevicesEnabled());
  const screen = screens.find((one) => one.id === screenId);
  return screen ? (
    <AndroidScreenWindow
      containment={containment}
      device={device}
      onClose={onClose}
      screen={screen}
      workspace={workspace}
    />
  ) : null;
}

function AndroidScreenWindow({
  workspace,
  device,
  screen,
  containment,
  onClose,
}: {
  containment: HTMLElement | null;
  workspace: string;
  device: string;
  screen: ListedScreen;
  onClose(): void;
}) {
  const source = useDeviceScreenSource(workspace, device, [], screen);
  return (
    <ScreenStreamWindow
      appName={screen.title}
      containment={containment}
      deckKey={`${device}\n${screen.id}`}
      onClose={onClose}
      source={source}
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
