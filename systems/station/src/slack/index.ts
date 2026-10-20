// Slack on the station (server.rs's part of it, connections.rs, admin/slack.rs `remember_identities`): the connects'
// connections as config.json and the station's workspace say, the names Slack gives people and channels (kept in
// <data>/slack-names.json), and the app API with the configuration tokens in config.json.
//
// Connects connect while the station is in its workspace (`bound`) and follow config edits; out of it they disconnect.
// Each connected connect's surface is the hub's (`chats`), and what Slack says reaches the hub through `receive`.
import { join } from "node:path";
import type { Clock } from "effect";
import type { ConfigFile } from "../ops/config.ts";
import { log } from "../ops/log.ts";
import type { ChatEvent, ChatSurface } from "../sessions/chat.ts";
import type { Store } from "../store/store.ts";
import { type ConfigToken, SlackApps, type SlackAppLinks, slackAppLinks, upsertToken } from "./apps.ts";
import { type ConnectState, type Connection, Connections, type SlackConnect, slackConnects } from "./connections.ts";
import { NameBook } from "./names.ts";
import { SlackSurface } from "./surface.ts";
import { SlackClient } from "./web.ts";

type Json = any;

export type SlackOptions = {
  data: string;
  store: Store;
  config: ConfigFile;
  /// Takes what a connect's Slack says (the hub's `receive`); resolves once it is kept, and only then is Slack
  /// acknowledged.
  receive: (connect: string, event: ChatEvent) => Promise<void>;
  /// Whether the station is in its workspace: only then are connects connected.
  bound: () => boolean;
  /// Where Slack's Web API is (tests: a stand-in); default $STILLFAIL_SLACK_API, else Slack.
  client?: SlackClient;
  /// Socket Mode's ping and silence limits (tests make them short).
  pingMs?: number;
  staleMs?: number;
  /// The clock the surfaces' pings, retries and status lines run on (tests: a TestClock).
  clock?: Clock.Clock;
  /// How a connect's connection is made (tests); default a SlackSurface.
  create?: (connect: SlackConnect, book: NameBook, client: SlackClient) => Connection;
};

/// What is not yet anyone's of config.json's Slack parts, filtered as config.rs `parse_config` does.
export function configTokens(raw: Json): ConfigToken[] {
  return (Array.isArray(raw?.slackConfigTokens) ? raw.slackConfigTokens : []).filter(
    (t: Json) => t !== null && typeof t === "object" && typeof t.refreshToken === "string" && t.refreshToken !== "" && typeof t.teamId === "string" && t.teamId !== "" && typeof t.by === "string" && t.by !== "",
  );
}

/// A Slack app the station made with someone's configuration token, waiting for its connect (config.rs `SlackAppMade`).
export type SlackAppMade = {
  appId: string;
  name: string;
  teamId: string;
  by: string;
  created: number;
  oauth?: { state: string; clientId: string; clientSecret: string; redirectUri: string; install: string; botToken?: string; installedTeam?: string };
};

export function madeApps(raw: Json): SlackAppMade[] {
  return (Array.isArray(raw?.slackApps) ? raw.slackApps : []).filter(
    (a: Json) => a !== null && typeof a === "object" && typeof a.appId === "string" && a.appId !== "" && typeof a.by === "string" && a.by !== "",
  );
}

export type SlackParts = ReturnType<typeof makeConnections>;

export function makeConnections(options: SlackOptions) {
  const { config, store } = options;
  const client = options.client ?? new SlackClient();
  // Slack's names for people and channels, kept on disk; learning new ones refreshes what shows them.
  // Saved before the pages are told: the readers read the names from the file.
  const names = new NameBook(join(options.data, "slack-names.json"), { saveAfterMs: 200, learnAfterMs: 400 });
  names.onLearn(() => {
    for (const session of store.listSessions()) store.notify(session.key);
  });
  const create =
    options.create ??
    ((c: SlackConnect, book: NameBook, web: SlackClient) =>
      new SlackSurface({ appToken: c.appToken, botToken: c.botToken, client: web, book, pingMs: options.pingMs, staleMs: options.staleMs, clock: options.clock }));
  const connections = new Connections((c) => create(c, names, client), options.receive);
  const connects = () => slackConnects(config.raw());
  const connect = (id: string) => connects().find((c) => c.id === id);

  // The configuration tokens are config.json's; a rotated one is kept there.
  const apps = new SlackApps({
    client,
    load: () => configTokens(config.raw()),
    save: (token) => {
      try {
        config.update((raw) => {
          raw.slackConfigTokens = upsertToken(Array.isArray(raw.slackConfigTokens) ? raw.slackConfigTokens : [], token);
        });
      } catch (error) {
        log.warn("slack", "slack configuration token not saved", { error: (error as Error).message });
      }
    },
  });

  let closed = false;
  /// In line with config.json while in the workspace; out of it, none connected.
  const reconcile = async () => {
    if (closed) return;
    if (options.bound()) await connections.reconcile(connects());
    else await connections.stopAll();
  };

  /// Keeps what each connected connect is known by, its Slack workspace and its bot's name there, as Slack says now:
  /// a connect shows by them while it is not connected too.
  const rememberIdentities = () => {
    const changed: [string, { id: string; name: string }, string, string | null][] = [];
    for (const c of connects()) {
      const state = connections.state(c);
      if (state.state !== "connected" && state.state !== "reconnecting") continue;
      const seen = state.workspace;
      if (!seen || seen.teamId === "") continue;
      const same = c.team !== null && c.team.id === seen.teamId && c.team.name === seen.team && c.botName === seen.botName && c.botImage === seen.botImage;
      if (!same) changed.push([c.id, { id: seen.teamId, name: seen.team }, seen.botName, seen.botImage]);
    }
    if (changed.length === 0) return;
    try {
      config.update((raw) => {
        for (const c of Array.isArray(raw.connects) ? raw.connects : []) {
          const found = changed.find(([id]) => id === c.id);
          if (!found) continue;
          const [, team, botName, botImage] = found;
          c.slack = c.slack !== null && typeof c.slack === "object" ? c.slack : {};
          c.slack.team = team;
          c.slack.botName = botName;
          if (botImage !== null) c.slack.botImage = botImage;
          else delete c.slack.botImage;
        }
      });
    } catch (error) {
      log.warn("slack", "slack identities not kept", { error: (error as Error).message });
    }
  };
  // Looked at once after a burst of changes, not inside them.
  let remembering = false;
  const listeners = new Set<() => void>();
  connections.onChange(() => {
    for (const listener of listeners) {
      try {
        listener();
      } catch {}
    }
    if (remembering || closed) return;
    remembering = true;
    setImmediate(() => {
      remembering = false;
      if (!closed) rememberIdentities();
    });
  });

  // Edits apply as they are saved.
  const unlisten = config.listen(() => {
    void reconcile().catch((error) => log.warn("slack", "connects not brought in line with the config", { error: (error as Error).message }));
  });

  return {
    connections,
    names,
    apps,
    client,
    /// A connected connect's surface, for the hub (HubOptions.chats).
    chats: (id: string): ChatSurface | undefined => connections.chat(id),
    /// A connected connect's connection.
    chat: (id: string): Connection | undefined => connections.chat(id),
    /// config.json's connects, as their connections read them.
    connects,
    /// In line with config.json and the workspace now: connected while in it, disconnected out of it.
    reconcile,
    stopAll: () => connections.stopAll(),
    refreshIdentity: (id: string) => connections.refreshIdentity(id),
    /// A connect's link to Slack as the pages show it (the overview's `connection`).
    state: (c: string | SlackConnect): ConnectState | null => {
      const found = typeof c === "string" ? connect(c) : c;
      return found ? connections.state(found) : null;
    },
    /// Hears whenever what `state` reports may have changed (the overview's events).
    onChange: (listener: () => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    /// What the overview says of Slack for a viewer (views.rs): the apps they made that wait for a connect, and the
    /// Slack workspaces they can make apps in (never a token).
    overview: (viewer: string) => slackOverview(config.raw(), viewer),
    /// Stops listening, disconnects every connect, and keeps the names learned.
    close: async () => {
      closed = true;
      unlisten();
      listeners.clear();
      await connections.stopAll();
      await names.close();
    },
  };
}

/// The overview's Slack parts for a viewer (admin/views.rs `overview`'s slackApps, `slack_teams`).
export function slackOverview(raw: Json, by: string): { slackApps: Json[]; slackTeams: Json[] } {
  const tokens = configTokens(raw);
  const slackApps = madeApps(raw)
    .filter((a) => a.by === by)
    .map((a) => {
      const links: SlackAppLinks = slackAppLinks(a.appId, a.teamId);
      return {
        appId: a.appId,
        name: a.name,
        teamId: a.teamId,
        team: tokens.find((t) => t.teamId === a.teamId)?.owner?.team ?? null,
        created: a.created,
        links,
        install: a.oauth?.install ?? null,
        state: a.oauth?.state ?? null,
        installed: typeof a.oauth?.botToken === "string",
        installedTeam: a.oauth?.installedTeam ?? null,
      };
    });
  const slackTeams = tokens
    .filter((t) => t.by === by)
    .map((t) => ({ teamId: t.teamId, name: t.owner?.team ? t.owner.team : t.teamId, owner: t.owner ?? null }));
  return { slackApps, slackTeams };
}

export { Connections, slackConnects, connectName } from "./connections.ts";
export type { ConnectState, Connection, SlackConnect } from "./connections.ts";
export { SlackSurface, toEvent, identityOf, verifySlackTokens, shownIdentity } from "./surface.ts";
export type { SlackIdentity, SocketStatus } from "./surface.ts";
export { NameBook } from "./names.ts";
export { ThreadStatus } from "./status.ts";
export { SlackClient, SlackApiError, apiBase } from "./web.ts";
export * from "./apps.ts";
