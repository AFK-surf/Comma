import { MiniAppFrame } from "./MiniAppFrame";

/**
 * An app as the whole of an external chat's panel, such as the page a Telegram button opens
 * (`task-panel.html?app_id=…`): the app's chrome and frame, inside the chat's safe area.
 */
export function MiniAppPanel({
  workspaceId,
  appId,
}: {
  workspaceId: string;
  appId: string;
}) {
  return (
    <main
      className="comma-embedded-task-panel bg-main-panel-bg p-sm text-primary"
      data-testid="mini-app-panel"
    >
      <MiniAppFrame
        appId={appId}
        className="min-h-0 flex-1"
        via={{ workspace: workspaceId }}
      />
    </main>
  );
}
