/**
 * Presentation facts for Settings → Devices, kept apart from the hook so the
 * mapping from Connector observations to what a reader is told is testable on
 * its own.
 */

/** Agents Comma can hand work to. Other discovered runtimes stay internal. */
export const agentProviderLabels: Record<string, string> = {
  codex: "Codex",
  claude: "Claude Code",
  pi: "Pi",
  kimi: "Kimi",
};

/** Whether Comma can reach the computer at all, before any permission question. */
export type DeviceReach = "connected" | "connecting" | "offline";

export type AgentState = "available" | "blocked" | "unavailable";

export interface AgentObservation {
  status?: string | undefined;
  issue?: string | undefined;
  message?: string | undefined;
  version?: string | undefined;
}

export interface AgentDescription {
  state: AgentState;
  /** Version and, only when it adds something, the Connector's own reason. */
  detail?: string;
}

const osLabels: Record<string, string> = {
  darwin: "macOS",
  linux: "Linux",
  win32: "Windows",
  windows: "Windows",
};

/** The two facts that tell one computer from another in a list of rows. */
export function deviceSystem(os?: string, arch?: string): string | undefined {
  const parts = [os ? (osLabels[os] ?? os) : undefined, arch].filter(Boolean);
  return parts.length ? parts.join(" · ") : undefined;
}

/**
 * A read-only device blocks every agent on it, so the permission this page
 * owns decides the row rather than the Connector's next observation: the
 * reader sees their own switch take effect instead of a stale instruction to
 * flip it. An agent already answered by the switch or by the computer's own
 * status keeps its reason off the row, because that reason is the line above.
 */
export function describeAgent(
  observation: AgentObservation,
  device: { reach: DeviceReach; permits: boolean }
): AgentDescription {
  const state: AgentState =
    device.reach !== "connected"
      ? "unavailable"
      : !device.permits || observation.issue === "permission_required"
        ? "blocked"
        : observation.status === "ready" || observation.status === "available"
          ? "available"
          : "unavailable";
  const explained = state === "unavailable" && device.reach === "connected";
  const detail = [
    observation.version?.trim(),
    explained ? observation.message?.trim() : undefined,
  ]
    .filter(Boolean)
    .join(" · ");
  return detail ? { state, detail } : { state };
}
