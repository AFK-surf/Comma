// The seam between the station and a coding-agent runtime (Claude Code, Codex), as the Rust station's runtime/mod.rs has it:
// everything above is runtime-agnostic. A driver opens sessions; what a session's runtime does comes back as events,
// in order, to the one listener it was opened with. Processes run under runners (./runner.ts): a station that starts
// again takes its sessions up from the runners (`adopt`), from what the previous one left (`snapshot`) or, after a
// crash, from what the runner kept unread.

export type FailureReason = "auth" | "rate_limit" | "model" | "exited" | "other";

export type TurnOutcome = { kind: "completed" } | { kind: "aborted" } | { kind: "failed"; reason: FailureReason; message: string };

/// A turn's steps as they happen (runtime/mod.rs `LiveEvent`, the same JSON).
export type LiveEvent =
  | { kind: "start"; id: string; step: "text" | "thinking" | "tool"; tool?: string; input?: string; subagent?: boolean; parent?: string }
  | { kind: "delta"; id: string; field: "text" | "input" | "output"; text: string }
  | { kind: "end"; id: string }
  | { kind: "phase"; phase: "starting" | "requesting" | "responding" | "working" };

/// What a session's runtime says, in order.
export type RuntimeEvent =
  /// A turn started without a prompt of ours: input written while the previous turn was finishing became a turn.
  | { type: "turnStarted" }
  | { type: "turnEnded"; outcome: TurnOutcome }
  /// The runtime process (or its shared host) went away; the session is unusable.
  | { type: "closed"; why: string }
  | { type: "live"; event: LiveEvent };

export type Profile = {
  id: string;
  runtime: "claude" | "codex";
  /// The profile's home (CLAUDE_CONFIG_DIR / CODEX_HOME).
  home: string;
  /// Whatever else the profile's config says (env, access kind, machine…): read by the drivers as runtime/*.rs do.
  [key: string]: unknown;
};

export type OpenOptions = {
  /// The station's session key: the runner's id is made from it.
  key: string;
  profile: Profile;
  cwd: string;
  /// Runtime-native session id to resume; a new session when absent.
  resume?: string;
  model?: string;
  /// Reasoning effort, in the runtime's own terms.
  effort?: string;
  /// Appended to the runtime's own system prompt.
  instructions: string;
  /// Bearer token the session presents to the station's MCP endpoint.
  mcpToken: string;
  mcpUrl: string;
  /// Stable per-session routing id for provider affinity headers.
  route: string;
};

export interface AgentSession {
  /// Runtime-native id: claude session id, codex thread id. Persist it to resume.
  id(): string;
  busy(): boolean;
  /// Starts a turn. Fails when a turn is already running (or the runtime cannot take one as it is).
  prompt(text: string): Promise<void>;
  /// Adds input to the running turn. False when nothing is running or the turn cannot take it.
  steer(text: string): Promise<boolean>;
  /// Moves the tool calls the running turn waits on to the background (Claude's ctrl+b); nothing for a runtime that
  /// cannot.
  backgroundTools(): Promise<void>;
  /// Interrupts the running turn; its end still arrives as turnEnded.
  abort(): Promise<void>;
  /// Releases the session; ends the runtime process when it is not shared.
  dispose(): Promise<void>;
  /// What a next station needs to take this session up (its turn's state): written by the session layer at handover.
  snapshot(): unknown;
  /// Lets go of the process without ending it (this station stops; a next one adopts it).
  detach(): void;
}

export interface AgentDriver {
  runtime(): "claude" | "codex";
  open(options: OpenOptions, events: (event: RuntimeEvent) => void): Promise<AgentSession>;
  /// Takes up a session whose process a runner kept: `snapshot` as the previous station left it, or null after a crash
  /// (then what the runner kept unread says where the turn is). What it does comes to `events` from now on.
  adopt(options: OpenOptions, snapshot: unknown | null, events: (event: RuntimeEvent) => void): Promise<AgentSession>;
  /// Ends every process this driver started.
  shutdown(): Promise<void>;
  /// Lets go of every process without ending them (handover).
  detach(): void;
}

/// A random UUID (v4), as runtimes take for session ids.
export const uuid = () => crypto.randomUUID();

/// The station's own environment, less what would let a runtime authenticate as something other than its profile.
export function cleanEnv(scrubbed: string[]): Record<string, string> {
  return Object.fromEntries(Object.entries(process.env).filter((e): e is [string, string] => e[1] !== undefined && !scrubbed.includes(e[0])));
}
