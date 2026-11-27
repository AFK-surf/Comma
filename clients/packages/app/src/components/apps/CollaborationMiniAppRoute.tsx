import { useCommaMessages } from "@comma/i18n/react";
import { MiniAppNotice } from "@comma/ui/components/mini-apps";
import { useState } from "react";
import { MiniAppFrame } from "./MiniAppFrame";

/**
 * A Mini App opened from a collaborative Task (`/#/collaborations/:groupId/:taskId/apps/:appId`).
 * Mounted inside Comma's authenticated shell so unauthenticated visitors or external guests sign in
 * first and land directly on the Mini App. If the viewer is not an active member (404), shows a
 * clean unavailable state.
 */
export function CollaborationMiniAppRoute({
  groupId,
  taskId,
  appId,
  version,
}: {
  groupId: string;
  taskId: string;
  appId: string;
  version?: number | undefined;
}) {
  const messages = useCommaMessages();
  const [gone, setGone] = useState<"unavailable" | "disabled">();

  if (gone) {
    return (
      <div
        className="flex flex-1 flex-col"
        data-testid="collaboration-mini-app-unavailable"
      >
        <MiniAppNotice kind={gone} reason={messages.collab_mini_app_unavailable()} />
      </div>
    );
  }

  return (
    <div
      className="flex min-h-0 min-w-0 flex-1 flex-col"
      data-testid="collaboration-mini-app-route"
    >
      <MiniAppFrame
        appId={appId}
        onGone={setGone}
        variant="flush"
        version={version}
        via={{ collaboration: { group: groupId, task: taskId } }}
      />
    </div>
  );
}
