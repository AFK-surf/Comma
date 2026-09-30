import type { Agent, AgentActivity } from "./types";

const terminalStatuses = new Set(["completed", "failed", "cancelled"]);

interface ActivityStatusSource {
  status: string;
  activity_status?: string;
}

export function aggregateAgentStatus(
  persistedStatus: string,
  sources: readonly ActivityStatusSource[],
): string {
  if (terminalStatuses.has(persistedStatus)) return persistedStatus;

  const statuses = sources.map(
    (source) => source.activity_status || source.status,
  );
  if (statuses.some((status) => status === "running" || status === "active"))
    return "running";
  if (statuses.includes("queued")) return "queued";
  if (statuses.includes("waiting")) return "waiting";
  return "paused";
}

export function projectAgentActivityStatuses(
  agents: readonly Agent[],
  activities: readonly AgentActivity[],
): Agent[] {
  const activitiesByAgent = new Map<string, AgentActivity[]>();
  for (const activity of activities) {
    const matches = activitiesByAgent.get(activity.agent_id) || [];
    matches.push(activity);
    activitiesByAgent.set(activity.agent_id, matches);
  }

  return agents.map((agent) => ({
    ...agent,
    status: aggregateAgentStatus(
      agent.status,
      activitiesByAgent.get(agent.agent_id) || [],
    ),
  }));
}
