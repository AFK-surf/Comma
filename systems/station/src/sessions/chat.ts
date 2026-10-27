// What the station needs from a chat platform (the Rust station's chat/mod.rs): Slack is one, the station's own chat
// (./internal.ts) another. The hub routes what a surface says to sessions, and posts what agents write through it.
import type { Attachment } from "../store/store.ts";
import { tr, stationLang } from "../ops/i18n.ts";

export type Json = any;

export type ThreadRef = { channel: string; threadTs: string };

export type InboundMessage = {
  channel: string;
  threadTs: string;
  ts: string;
  user: string;
  text: string;
  /// Mentions the bot or is a direct message: may start a session. Other thread replies only continue one.
  addressed: boolean;
  /// Files shared with it, fetched (`download`) into the uploads of a session of its thread when it is recorded.
  files?: InboundFile[];
};

/// A file shared with a message, as the platform holds it. `url`: where its bytes are; null where the platform keeps
/// them back (a file over a free workspace's limit, a deleted one).
export type InboundFile = { id: string; name: string; size: number; url: string | null };

/// What a platform tells the station: a new message, or an edit of one already said (deletes are not taken: the
/// station keeps what was said).
export type ChatEvent =
  | { type: "message"; message: InboundMessage }
  | { type: "changed"; channel: string; threadTs: string; ts: string; text: string };

export type ChatMessage = { ts: string; user: string; text: string; fromBot: boolean; files?: InboundFile[] };

export type Person = { name: string; email: string };

/// Who posts, when it is a session's agent (chat_post): the session, the state its post records, and the milestones it
/// carries (a post of milestones alone has no text).
/// `cannotStart`: the post is the station's word that the Session's turn did not start, and why (the Task's host offers
/// another model with it).
export type PostFrom = { session: string; declared?: string | null; milestones?: string[] | null; cannotStart?: string };

/// A platform's event; it must finish keeping it before it resolves: the platform is acknowledged only after.
export type Handler = (event: ChatEvent) => Promise<void>;

export interface ChatSurface {
  /// The bot's own user id, once started.
  botUserId(): string;
  /// The bot's name on the platform (what people there call the agent), once started; empty where it has none.
  botName?(): string;
  /// The platform workspace (Slack team id) once started; threads are named by it.
  workspace(): string | null;
  /// Starts receiving.
  start?(handler: Handler): Promise<void>;
  /// Posts a message into the thread as written (Slack's mrkdwn, or Markdown in the station's chats) and gives the
  /// posted message's ts. `files` are attachments already copied into the session's uploads; surfaces that cannot carry
  /// files refuse them.
  post(thread: ThreadRef, message: string, files: Attachment[], from?: PostFrom): Promise<string>;
  /// A shared file's bytes, as the bot may read them; throws where it may not (a Slack app without files:read).
  download?(file: InboundFile): Promise<Uint8Array>;
  /// A person's display name, or null if unknown.
  userName?(user: string): Promise<string | null>;
  /// Says in the thread what the agent working for it is doing ("" when it is done), best effort, never waited on.
  /// `messageTs`: the message that started the work.
  working?(thread: ThreadRef, messageTs: string | null, status: string): void;
  /// Calls the platform's API as the bot (Slack's Web API): what the agent reaches through slack_api.
  api?(method: string, params: Record<string, Json>): Promise<Json>;
  /// A person's email, where the platform shares it.
  userEmail?(user: string): Promise<string | null>;
  /// What is already known of a person, without waiting (unknown ones are fetched in the background).
  knownPerson?(user: string): Person | null;
  knownChannel?(channel: string): string | null;
  /// A channel's name without the #, where the platform says; null for direct messages.
  channelName?(channel: string): Promise<string | null>;
  /// Messages in the thread strictly before `before`, oldest first, at most `limit`: what was said before the station
  /// joined a thread. Undefined where the platform cannot say (the station cannot join late there).
  history?(thread: ThreadRef, before: string, limit: number): Promise<ChatMessage[]> | undefined;
  stop?(): Promise<void>;
}

/// `api` as a surface without one answers (chat/mod.rs's default).
export async function callApi(chat: ChatSurface, method: string, params: Record<string, Json>): Promise<Json> {
  if (!chat.api) throw new Error(`${method}: this conversation has no API`);
  return chat.api(method, params);
}

/// Splits text for Slack's message size, preferring paragraph, then line boundaries. Slack messages go out as the
/// agent wrote them, in Slack's own formatting: no converting, only splitting what is too long for one message.
/// Lengths are in characters (code points), as the Rust's.
export function splitForSlack(text: string, limit: number): string[] {
  const chunks: string[] = [];
  let rest = Array.from(text);
  while (rest.length > limit) {
    const window = rest.slice(0, Math.min(limit, rest.length - 1) + 1);
    const last = (needle: string): number | null => {
      for (let i = window.length - needle.length; i >= 0; i--) {
        if (window.slice(i, i + needle.length).join("") === needle) return i;
      }
      return null;
    };
    let cut = last("\n\n") ?? 0;
    if (cut < limit / 2) cut = last("\n") ?? 0;
    if (cut < limit / 2) cut = limit;
    chunks.push(rest.slice(0, cut).join(""));
    let next = cut;
    while (rest[next] === "\n") next++;
    rest = rest.slice(next);
  }
  if (rest.length > 0 || chunks.length === 0) chunks.push(rest.join(""));
  return chunks;
}

/// A tool call in words for the status line, by the tool's name (Claude Code's or Codex's) (chat/status.rs
/// `tool_status`). Said in Slack by the station: in its own language.
export function toolStatus(tool: string): string {
  const lower = tool.toLowerCase();
  let name = lower;
  if (lower.startsWith("mcp__")) {
    const rest = lower.slice(5);
    const at = rest.indexOf("__");
    name = at >= 0 ? rest.slice(at + 2) : lower;
  }
  const starts = (prefixes: string[]) => prefixes.some((p) => name.startsWith(p));
  let key: string;
  if (starts(["read", "grep", "glob", "ls", "list", "view", "search_files", "stat"])) key = "station.status.readingFiles";
  else if (starts(["edit", "multiedit", "write", "apply_patch", "notebookedit", "delete", "copy"])) key = "station.status.editingFiles";
  else if (starts(["bash", "shell", "exec", "exec_command", "local_shell", "unified_exec", "run"])) key = "station.status.runningCommand";
  else if (starts(["websearch", "web_search", "search_query", "image_query"])) key = "station.status.searchingWeb";
  else if (starts(["webfetch", "fetch", "browse"])) key = "station.status.readingWeb";
  else if (starts(["task", "agent", "spawn"])) key = "station.status.delegating";
  else if (starts(["chat_", "slack"])) key = "station.status.readingSlack";
  else if (starts(["todowrite", "update_plan", "plan"])) key = "station.status.planning";
  else key = "station.status.working";
  return tr(stationLang(), key);
}
