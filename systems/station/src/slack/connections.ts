// Keeps one chat connection per enabled connect with both tokens (connections.rs), following the config: a new or
// re-credentialed connect is (re)connected, a removed or disabled one disconnected, the rest left alone. Rapid edits
// apply in order.
import { log } from "../ops/log.ts";
import type { ChatEvent, ChatSurface, Handler } from "../sessions/chat.ts";
import { type SlackIdentity, type SocketStatus, shownIdentity } from "./surface.ts";

type Json = any;

/// A connect as config.json has it, as far as its connection goes (config.rs `Connect`, `SlackTokens`).
export type SlackConnect = {
  id: string;
  enabled: boolean;
  appToken: string;
  botToken: string;
  appId: string | null;
  /// Its Slack workspace, as last seen.
  team: { id: string; name: string } | null;
  botName: string | null;
  botImage: string | null;
};

/// What a connect is called: its bot's name in its Slack workspace, else its id.
export const connectName = (c: SlackConnect) => c.botName ?? c.id;

const nonEmpty = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/// config.json's connects, as their connections read them.
export function slackConnects(raw: Json): SlackConnect[] {
  return (Array.isArray(raw?.connects) ? raw.connects : []).map((c: Json): SlackConnect => {
    const slack = c?.slack ?? {};
    const team = slack.team;
    return {
      id: String(c?.id ?? ""),
      enabled: c?.enabled !== false,
      appToken: typeof slack.appToken === "string" ? slack.appToken : "",
      botToken: typeof slack.botToken === "string" ? slack.botToken : "",
      appId: nonEmpty(slack.appId),
      team: team !== null && typeof team === "object" && nonEmpty(team.id) !== null ? { id: team.id, name: typeof team.name === "string" ? team.name : "" } : null,
      botName: nonEmpty(slack.botName),
      botImage: nonEmpty(slack.botImage),
    };
  });
}

/// A connect's link to its platform, as the pages show it.
export type ConnectState =
  | { state: "disabled" }
  | { state: "no_tokens" }
  | { state: "starting" }
  | { state: "connected" | "reconnecting"; botUserId: string; lastError: string | null; workspace: ReturnType<typeof shownIdentity> | null }
  | { state: "error"; error: string };

/// A live chat connection: a surface, and how its link stands.
export interface Connection extends ChatSurface {
  start(handler: Handler): Promise<void>;
  stop(): Promise<void>;
  socket(): SocketStatus;
  identity(): SlackIdentity | null;
  /// Hears whenever `socket` or `identity` changes; gives the function that stops it.
  onChange(listener: () => void): () => void;
  /// Reads again who the bot is and where (its name changed in Slack, say); listeners hear of it.
  refreshIdentity(): Promise<void>;
}

export type Create = (connect: SlackConnect) => Connection;
export type OnEvent = (connect: string, event: ChatEvent) => Promise<void>;

const tokenKey = (c: SlackConnect) => `${c.appToken}\n${c.botToken}`;

export class Connections {
  /// Live connections by connect id; the hub reads it on every use.
  private chats = new Map<string, Connection>();
  private unlisten = new Map<string, () => void>();
  private tokens = new Map<string, string>();
  private errors = new Map<string, string>();
  private create: Create;
  private onEvent: OnEvent;
  /// Rapid edits apply in order.
  private chain: Promise<void> = Promise.resolve();
  private listeners = new Set<() => void>();

  constructor(create: Create, onEvent: OnEvent) {
    this.create = create;
    this.onEvent = onEvent;
  }

  chat(id: string): Connection | undefined {
    return this.chats.get(id);
  }

  ids(): string[] {
    return [...this.chats.keys()];
  }

  /// Hears whenever what `state` reports may have changed; gives the function that stops it.
  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed() {
    for (const listener of this.listeners) {
      try {
        listener();
      } catch (error) {
        log.warn("slack", "a listener of the connects failed", { error: (error as Error).message });
      }
    }
  }

  /// Reads again who a connect's bot is (its name, its workspace), as Slack says now.
  async refreshIdentity(id: string) {
    await this.chat(id)?.refreshIdentity();
  }

  state(connect: SlackConnect): ConnectState {
    if (!connect.enabled) return { state: "disabled" };
    if (connect.appToken === "" || connect.botToken === "") return { state: "no_tokens" };
    const error = this.errors.get(connect.id);
    if (error !== undefined) return { state: "error", error };
    const chat = this.chat(connect.id);
    if (!chat) return { state: "starting" };
    const botUserId = chat.botUserId();
    if (botUserId === "") return { state: "starting" };
    const socket = chat.socket();
    const identity = chat.identity();
    return { state: socket.connected ? "connected" : "reconnecting", botUserId, lastError: socket.lastError, workspace: identity ? shownIdentity(identity) : null };
  }

  /// Brings connections in line with `connects`. Serialized, so rapid edits apply in order.
  reconcile(connects: SlackConnect[]): Promise<void> {
    return this.serially(async () => {
      await this.apply(connects);
      this.changed();
    });
  }

  stopAll(): Promise<void> {
    return this.serially(async () => {
      const chats = [...this.chats.entries()];
      this.chats.clear();
      this.tokens.clear();
      for (const [id] of chats) this.drop(id);
      for (const [, chat] of chats) await chat.stop();
      if (chats.length > 0) this.changed();
    });
  }

  private serially(f: () => Promise<void>): Promise<void> {
    const turn = this.chain.then(f);
    this.chain = turn.catch(() => {});
    return turn;
  }

  private drop(id: string) {
    this.unlisten.get(id)?.();
    this.unlisten.delete(id);
  }

  private async apply(connects: SlackConnect[]) {
    const wanted = new Map(connects.filter((c) => c.enabled && c.appToken !== "" && c.botToken !== "").map((c) => [c.id, c]));
    for (const [id, chat] of [...this.chats]) {
      const want = wanted.get(id);
      if (want && this.tokens.get(id) === tokenKey(want)) continue;
      log.info("slack", "disconnecting", { connect: id });
      this.chats.delete(id);
      this.tokens.delete(id);
      this.drop(id);
      await chat.stop();
    }
    for (const id of [...this.errors.keys()]) if (!wanted.has(id)) this.errors.delete(id);
    for (const connect of wanted.values()) {
      if (this.chats.has(connect.id)) continue;
      this.errors.delete(connect.id);
      let chat: Connection | null = null;
      try {
        chat = this.create(connect);
        // Its link's changes are the connects' changes.
        this.unlisten.set(connect.id, chat.onChange(() => this.changed()));
        const id = connect.id;
        await chat.start((event) => this.onEvent(id, event));
        log.info("slack", "connected", { connect: connect.id, botUserId: chat.botUserId() });
        this.chats.set(connect.id, chat);
        this.tokens.set(connect.id, tokenKey(connect));
      } catch (e) {
        const error = (e as Error).message;
        log.error("slack", "failed to connect", { connect: connect.id, error });
        this.drop(connect.id);
        // Started this far: what it opened is closed again.
        await chat?.stop().catch(() => {});
        this.errors.set(connect.id, error);
      }
    }
  }
}
