import type { StoredMessage } from "./types";

export function hasToolCalls(msg: StoredMessage): boolean {
  if (msg.role !== "assistant") return false;
  try {
    const parsed = JSON.parse(msg.content);
    return parsed.tool_calls?.length > 0;
  } catch {
    return false;
  }
}

export function forkableMessageIds(msgs: StoredMessage[]): Set<number> {
  const ids = new Set<number>();
  for (let i = 0; i < msgs.length; i++) {
    if (msgs[i].role !== "assistant") continue;
    if (hasToolCalls(msgs[i])) continue;
    ids.add(msgs[i].message_id);
  }
  return ids;
}

export function latestForkableMessageId(msgs: StoredMessage[]): number | null {
  let latest: number | null = null;
  for (const msg of msgs) {
    if (msg.role !== "assistant") continue;
    if (hasToolCalls(msg)) continue;
    latest = msg.message_id;
  }
  return latest;
}
