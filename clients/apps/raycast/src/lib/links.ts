// The links the desktop app takes from this extension (clients/apps/electron/src/main/launcher-link.ts). A link
// shows a window, puts words in Home's draft, or asks the person to confirm a connection. It never sends.

/** The longest text a compose link may carry. The desktop app ignores a longer one. */
export const COMPOSE_MAX_CHARS = 8_000;

/** No application on this computer takes the link: Comma is not installed, or it is another environment's. */
export class CommaAppMissing extends Error {
  constructor() {
    super("No Comma app took the link.");
  }
}

export function homeLink(scheme: string): string {
  return `${scheme}://home`;
}

/** The link that puts `text` in Home's draft, marked as written in Raycast; undefined when it cannot carry it. */
export function composeLink(scheme: string, text: string): string | undefined {
  if (!text.trim() || [...text].length > COMPOSE_MAX_CHARS) return undefined;
  return `${scheme}://home/compose?text=${encodeURIComponent(text)}&entry=raycast`;
}

export function taskLink(
  scheme: string,
  task: { workspaceId: string; groupId: string; conversationId: string }
): string {
  return `${scheme}://task/${[task.workspaceId, task.groupId, task.conversationId]
    .map(encodeURIComponent)
    .join("/")}`;
}

export function connectLink(scheme: string, challenge: string): string {
  return `${scheme}://connect/raycast?challenge=${encodeURIComponent(challenge)}`;
}
