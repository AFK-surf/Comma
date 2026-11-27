import { useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { PanelRightIcon } from "@comma/ui/components/icons";
import { memo, useRef, useState } from "react";
import {
  screenPageId,
  useOptionalChatSidebar,
} from "../../chat-sidebar/ChatSidebarContext";
import { ScreenStreamAction } from "../../remote-screen/ScreenStreamChrome";
import { useShown } from "../../remote-screen/ScreenLink";
import { ScreenStreamStage } from "../../remote-screen/ScreenStreamStage";
import type { ScreenStreamState } from "../../remote-screen/meshScreenStream";
import { useScreenQuality } from "../../remote-screen/screenQuality";
import { useDeviceScreenSource } from "../../remote-screen/useDeviceScreenSource";
import { useScreenDevicesEnabled } from "../../remote-screen/useScreenListing";
import { useScreenStreamShows } from "../../remote-screen/useScreenStreamShows";
import type { CodingPanelTarget } from "./CodingSession";

/**
 * A coding Task's sandbox's screen, live, in the conversation under what its Worker is doing: for the Task's owner
 * (`owner`, the sandbox's `place.screenOwner`), mounted while something is on that screen
 * (`place.screenActive`: a Session is using its browser on it). `device` is the Device the sandbox runs as
 * (`place.screenDevice`). It only looks; its action opens the screen in the side panel, and while the screen has a tab
 * there it shows there alone (a screen shows in one place at a time).
 *
 * It asks nothing by itself. The picture holds a view only while it is on the screen of a shown page, and that view
 * asks the sandbox to show its screen as it opens and while it is open (`devices.openScreenView` with `task`): one ask
 * for each view that opens, and at most one view for each such conversation in sight. A view the server refuses says
 * so in the picture's place.
 */
export const CodingScreenInline = memo(function CodingScreenInline({
  coding,
  owner,
  device,
  groupId,
}: {
  coding: CodingPanelTarget;
  owner: string;
  device: string;
  groupId: string;
}) {
  const enabled = useScreenDevicesEnabled();
  const sidebar = useOptionalChatSidebar();
  const { value: session } = useTopic({ topic: "session" });
  const mine = session?.phase === "signed_in" && session.userId === owner;
  const { workspaceId, taskId } = coding;
  if (!enabled || !mine) return null;
  const page = { device, apps: [], target: "display" as const };
  const inPanel =
    sidebar?.isOpen === true &&
    sidebar.activeSession?.screenPages?.some(
      (open) => open.id === screenPageId(page)
    ) === true;
  if (inPanel) return null;
  return (
    <CodingScreenPicture
      device={device}
      onExpand={
        sidebar
          ? () =>
              sidebar.openScreen(
                sidebar.activeHost ?? {
                  workspaceId,
                  groupId,
                  conversationId: taskId,
                },
                { ...page, workspaceId, task: taskId }
              )
          : undefined
      }
      task={taskId}
      workspace={workspaceId}
    />
  );
});

function CodingScreenPicture({
  workspace,
  device,
  task,
  onExpand,
}: {
  workspace: string;
  device: string;
  task: string;
  onExpand: (() => void) | undefined;
}) {
  const messages = useCommaMessages();
  const box = useRef<HTMLElement>(null);
  const shown = useShown(box);
  const source = useDeviceScreenSource(workspace, device, [], undefined, task);
  const [quality] = useScreenQuality();
  const [state, setState] = useState<ScreenStreamState>("connecting");
  const { stage } = useScreenStreamShows({
    target: "display",
    appName: undefined,
    dropControl: () => undefined,
  });
  return (
    // Its shape is the sandbox's display's from the first paint, so the conversation does not move as frames come.
    <section
      aria-label={messages.coding_screen_live()}
      className="comma-task-screen-inline"
      data-state={state}
      data-testid="task-screen-inline"
      ref={box}
    >
      {shown ? (
        <ScreenStreamStage
          {...stage}
          control={false}
          onState={setState}
          quality={quality}
          source={source}
          state={state}
          target="display"
        />
      ) : null}
      {onExpand ? (
        <div className="comma-remote-screen-actions">
          <ScreenStreamAction
            icon={<PanelRightIcon aria-hidden />}
            label={messages.remote_screen_expand()}
            onClick={onExpand}
          />
        </div>
      ) : null}
    </section>
  );
}
