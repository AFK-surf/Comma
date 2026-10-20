// The API providers a profile can reach with a key, and where each speaks which protocol: systems/profiles' sources,
// the list Comma's Profiles use too (through the mesh addon).

import { loadMesh } from "../mesh/native.ts";

export type Protocol = "chat_completions" | "responses" | "anthropic";

/// How Claude Code is given the key: some endpoints read `x-api-key`, others a bearer token, a few either.
export type ClaudeAuth = "apiKey" | "bearer" | "both";

export type Source = {
  id: string;
  name: string;
  chat?: string;
  responses?: string;
  anthropic?: string;
  /// A native decision endpoint (Jev's), for the automatic decisions only.
  decision?: string;
  /// The address is the person's (cloudflare, azure, custom), not the provider's.
  endpointRequired: boolean;
  /// For one at the reader's own address: the protocols it can speak there.
  protocols: Protocol[];
  /// Works without a key (a server of one's own).
  keyOptional: boolean;
  auth: ClaudeAuth;
  /// OpenCode's gateways refuse a request without `x-opencode-session`.
  sessionHeader: boolean;
};

/// What a source is in sources.json (systems/profiles), as the station names its parts.
type Shared = {
  id: string;
  name: string;
  kind: "api_key" | "subscription";
  endpoints: { chat_completions?: string; responses?: string; anthropic?: string; decision?: string };
  protocols: Protocol[];
  endpoint_required: boolean;
  key_optional: boolean;
  auth: "api_key" | "bearer" | "both";
  session_header: boolean;
  group: "labs" | "gateways" | "hosted" | "local";
};

/// The API sources (the subscriptions are a profile's runtime), in the order they are offered: the ones Comma offers too,
/// and the station's own (Ollama on its network, Jev for its decisions).
export const SOURCES: Source[] = (JSON.parse(loadMesh().profileSources()) as Shared[])
  .filter((s) => s.kind === "api_key")
  .map((s) => ({
    id: s.id,
    name: s.name,
    chat: s.endpoints.chat_completions,
    responses: s.endpoints.responses,
    anthropic: s.endpoints.anthropic,
    decision: s.endpoints.decision,
    endpointRequired: s.endpoint_required,
    protocols: s.protocols,
    keyOptional: s.key_optional,
    auth: s.auth === "api_key" ? "apiKey" : s.auth,
    sessionHeader: s.session_header,
  }));
const GROUPS = new Map((JSON.parse(loadMesh().profileSources()) as Shared[]).map((s) => [s.id, s.group]));

export const find = (id: string): Source | undefined => SOURCES.find((s) => s.id === id);

/// The two made before this list, as an access kind of their own (shapes `legacy`): not offered again as a provider.
export const LEGACY: Record<string, "anthropic-api" | "opencode-go"> = { anthropic: "anthropic-api", "opencode-go": "opencode-go" };

/// How the picker groups them (shapes `Group`): labs, gateways, hosted, local.
export function groupOf(id: string): "labs" | "gateways" | "hosted" | "local" {
  return GROUPS.get(id) ?? "labs";
}

/// An address as it is kept: trimmed, without a trailing slash; none unless it is an http(s) address.
export function cleanEndpoint(text: string): string | undefined {
  return loadMesh().cleanEndpoint(text) ?? undefined;
}

export type Endpoints = { chat?: string; responses?: string; anthropic?: string; decision?: string };

/// The endpoints of a source; for one at the person's own address, derived from it and the protocol chosen for it (none
/// chosen: all it can speak). Undefined when the address is needed and is not a usable one.
export function endpoints(source: Source, endpoint: string | undefined, protocol: string | undefined): Endpoints | undefined {
  const at = loadMesh().profileEndpoints(source.id, endpoint ?? null, protocol ?? null);
  if (at === null) return undefined;
  const e = JSON.parse(at) as Shared["endpoints"];
  return { chat: e.chat_completions, responses: e.responses, anthropic: e.anthropic, decision: e.decision };
}

/// The runtimes a provider's profile can run, from where it speaks: Anthropic's protocol is Claude Code's, Responses
/// Codex's.
export const runtimesOf = (at: Endpoints): ("claude" | "codex")[] => [
  ...(at.anthropic !== undefined ? (["claude"] as const) : []),
  ...(at.responses !== undefined ? (["codex"] as const) : []),
];
