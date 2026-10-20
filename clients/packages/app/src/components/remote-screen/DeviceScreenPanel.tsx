import type { ChatSidebarScreenPage } from "../chat-sidebar/ChatSidebarContext";
import { ScreenStreamPanel } from "./ScreenStreamPanel";
import { useDeviceScreenSource } from "./useDeviceScreenSource";

/** A side panel screen page: the big screen of the computer it names. */
export function DeviceScreenPanel({
  page,
  active,
}: {
  page: ChatSidebarScreenPage;
  active: boolean;
}) {
  const source = useDeviceScreenSource(page.workspaceId, page.device, page.apps);
  return (
    <ScreenStreamPanel
      active={active}
      appName={page.apps.length ? page.apps.join(", ") : undefined}
      source={source}
    />
  );
}
