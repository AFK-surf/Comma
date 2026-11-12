import { useCore, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { InWindowNotice } from "@comma/ui/components/in-window-notice";
import { useEffect, useRef } from "react";
import {
  useOptionalChatSidebar,
  type ChatSidebarScreenPage,
} from "../chat-sidebar/ChatSidebarContext";
import { ScreenModelChooser, useOwnComputers, type ChosenScreen } from "./ScreenMenus";
import { ScreenStreamPanel } from "./ScreenStreamPanel";
import { useDeviceScreenSource } from "./useDeviceScreenSource";
import { useScreenListing } from "./useScreenListing";
import { useScreenToChat } from "./screenToChat";
import { recentScreenLogFiles } from "./screenLogBook";
import {
  closeScreenWindow,
  focusScreenWindow,
  openScreenWindow,
  useInScreenWindow,
} from "./screenWindows";

// A device missing from this many of the station's answers in a row is gone (they come about 5 s apart while the tab
// shows, so its tab goes some seconds after its device has, not within a bound). One alone may be adb starting over.
const GONE_AFTER_READS = 2;

/**
 * A side panel screen page: the big screen of the computer it names, or of one of its devices. While the screen shows
 * in a window of its own (screenWindows.ts), the page keeps its tab and says so in the screen's place: a screen shows
 * in one place at a time, and closing the window brings it back here.
 */
export function DeviceScreenPanel({
  page,
  active,
}: {
  page: ChatSidebarScreenPage;
  active: boolean;
}) {
  const messages = useCommaMessages();
  if (useInScreenWindow(page.id))
    return (
      <InWindowNotice
        description={messages.remote_screen_in_window_description()}
        onMoveBack={() => closeScreenWindow(page.id)}
        onShowWindow={() => focusScreenWindow(page.id)}
        testId="remote-screen-in-window"
        title={messages.remote_screen_in_window_title()}
      />
    );
  if (page.target === "models" && !page.screen)
    return <DeviceModels active={active} page={page} />;
  return <DeviceScreen active={active} page={page} place="panel" />;
}

/** What is chosen in a tab, in the tab's place: the tab closes, and one for the choice opens. */
function useChooseInTab(page: ChatSidebarScreenPage) {
  const sidebar = useOptionalChatSidebar();
  const host = sidebar?.activeHost;
  return (chosen: ChosenScreen) => {
    if (!host) return;
    sidebar?.closeScreenPage(host, page.id);
    sidebar?.openScreen(host, {
      workspaceId: page.workspaceId,
      apps: chosen.screen || chosen.target ? [] : page.apps,
      ...chosen,
    });
  };
}

/** A tab of a computer's simulators and emulators to start, where none ran: the one chosen takes its place. */
function DeviceModels({
  page,
  active,
}: {
  page: ChatSidebarScreenPage;
  active: boolean;
}) {
  return (
    <ScreenModelChooser
      active={active}
      device={page.device}
      onChoose={useChooseInTab(page)}
      workspace={page.workspaceId}
    />
  );
}

/**
 * The screen of a side panel page, in the panel or in its own window (`place`). A device that has gone closes its tab,
 * or its window.
 */
export function DeviceScreen({
  page,
  active,
  place,
}: {
  page: ChatSidebarScreenPage;
  active: boolean;
  place: "panel" | "window";
}) {
  const source = useDeviceScreenSource(
    page.workspaceId,
    page.device,
    page.apps,
    page.screen
  );
  const sidebar = useOptionalChatSidebar();
  const host = sidebar?.activeHost;
  const chooseInTab = useChooseInTab(page);
  // How this device reaches that computer's station now.
  const station = useOwnComputers(page.workspaceId).find(
    (one) => one.device_id === page.device
  )?.station_id;
  const { value: stations } = useTopic({
    topic: "stations",
    workspace: page.workspaceId,
  });
  const via = stations?.ownComputers?.find((one) => one.id === station)?.link.via;
  // A tab of a device shown while it is there: closed from here, another chat's tab or outside the app, its tab goes as
  // this tab shows. A station out of reach answers nothing, which says nothing of the device.
  const shown = page.screen;
  const listing = useScreenListing(
    page.workspaceId,
    page.device,
    active && shown !== undefined
  );
  const toChat = useScreenToChat();
  const core = useCore();
  const missed = useRef(0);
  const counted = useRef<typeof listing | undefined>(undefined);
  useEffect(() => {
    // (each answer once: what else makes this run is no read)
    if (!listing.read || !shown || counted.current === listing) return;
    counted.current = listing;
    missed.current = listing.screens.some(
      (one) => one.id === shown.id && one.instance === shown.instance
    )
      ? 0
      : missed.current + 1;
    if (missed.current < GONE_AFTER_READS) return;
    if (place === "window") closeScreenWindow(page.id);
    else if (host) sidebar?.closeScreenPage(host, page.id);
  }, [host, listing, page.id, place, shown, sidebar]);
  return (
    <ScreenStreamPanel
      active={active}
      appName={page.apps.length ? page.apps.join(", ") : undefined}
      controlKey={page.id}
      initialTarget={
        page.screen ? page.screen.id : page.target === "display" ? "display" : undefined
      }
      via={via}
      {...(place === "panel"
        ? { onOpenWindow: (from: Element) => void openScreenWindow(page, { from }) }
        : { onMoveBack: () => closeScreenWindow(page.id) })}
      onAskComma={
        toChat
          ? ({ picture, thumbnail, note }, name) =>
              toChat({
                workspace: page.workspaceId,
                device: page.device,
                screen: page.screen?.id ?? "display",
                name,
                picture,
                thumbnail,
                note,
                // (a screen that lists its app's logs: an older station lists none, and sends only the picture)
                files: page.screen?.capabilities.logs
                  ? recentScreenLogFiles(core, {
                      workspace: page.workspaceId,
                      device: page.device,
                      screen: page.screen.id,
                    })
                  : undefined,
              })
          : undefined
      }
      computer={{
        workspace: page.workspaceId,
        device: page.device,
        screen: page.screen,
        onClosed: () => {
          if (place === "window") closeScreenWindow(page.id);
          else if (host) sidebar?.closeScreenPage(host, page.id);
        },
        // What was chosen, in this tab's place. A window shows its one screen.
        onChoose: place === "window" ? undefined : chooseInTab,
      }}
      source={source}
    />
  );
}
