import type { SessionHistoryEntry } from "../chat/session-history/model/sessionHistoryEntries";
import { entryArguments } from "../chat/thread/activity/workerProgress";

/** The computer-use session a Worker has open: the computer it drives and the apps it named. */
export type ComputerUseSession = {
  device: string;
  /** App names from `start`. Empty when the Worker named none: the frontmost app. */
  apps: readonly string[];
};

const COMPUTER_USE = "env.computer_use";

/**
 * The computer-use session that the loaded steps leave open, if any. `start`
 * opens it and `end` or `stop` closes it. A later action without a loaded
 * `start` (it left the bounded page) still shows which computer is driven.
 */
export function openComputerUseSession(
  entries: readonly SessionHistoryEntry[]
): ComputerUseSession | undefined {
  let session: ComputerUseSession | undefined;
  for (const entry of entries) {
    if (!entry.tool || entry.item.tools[0] !== COMPUTER_USE) continue;
    if (entry.item.kind === "error") continue;
    const args = entryArguments(entry);
    const action =
      typeof args.action === "string" ? args.action.trim().replaceAll("-", "_") : "";
    if (action === "end" || action === "stop") {
      session = undefined;
      continue;
    }
    const device = typeof args.device_id === "string" ? args.device_id : "";
    if (!device) continue;
    if (action === "start") session = { device, apps: startApps(args.args) };
    else if (session?.device !== device && !PASSIVE_ACTIONS.has(action))
      session = { device, apps: [] };
  }
  return session;
}

// Actions a Worker may take with no session open.
const PASSIVE_ACTIONS = new Set([
  "help",
  "mode_help",
  "status",
  "permissions_status",
  "open_permission_flow",
  "read_image",
]);

function startApps(args: unknown): string[] {
  const apps = (args as { apps?: unknown } | null)?.apps;
  return Array.isArray(apps)
    ? apps.filter((app): app is string => typeof app === "string" && app !== "")
    : [];
}
