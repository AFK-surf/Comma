/**
 * Reads the client core makes for the active workspace on its own, whatever
 * page is open: the Router's models, the workspace's task requests and its
 * own-request setting. A spec that refuses every request it does not expect
 * answers these as absent, so a new background read is added here once, not in
 * each spec.
 */
const backgroundWorkspaceReads =
  /^\/v1\/comma\/workspaces\/[^/]+\/(agent-models|task-requests|task-request-grants|task-request-own)$/;

export function isBackgroundWorkspaceRead(method: string, pathname: string): boolean {
  return method === "GET" && backgroundWorkspaceReads.test(pathname);
}

/**
 * Channels that Settings › Channels reads whenever it opens, answered as not set
 * up on this server, for a spec about another channel. A new channel's read is
 * added here once, not in each spec.
 */
const unconfiguredChannels: Array<[RegExp, unknown]> = [
  [
    /^\/v1\/comma\/workspaces\/[^/]+\/integrations\/line$/,
    { configured: false, connection_active: false, pending_claim: null, link: null },
  ],
];

export function unconfiguredChannelRead(method: string, pathname: string): unknown {
  if (method !== "GET") return undefined;
  return unconfiguredChannels.find(([path]) => path.test(pathname))?.[1];
}
