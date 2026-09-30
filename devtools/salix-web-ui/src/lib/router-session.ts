export async function agentGroupRouterSessionId(
  routerAgentId: string,
  groupId: string,
  channelKind = "bridge",
): Promise<string> {
  const joined = [
    "router-session-v1",
    routerAgentId.trim(),
    groupId.trim(),
    channelKind.trim() || "bridge",
  ].join("\0");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(joined),
  );
  const hex = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return `router-${hex.slice(0, 32)}`;
}
