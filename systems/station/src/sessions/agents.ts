// The agents' side of the station (server.rs `App::start`): the hub with its drivers, background jobs, tasks for other
// stations, the agents' tools and their door (/mcp). Made here and given to the rest; nothing else starts an agent.
//
// What the previous station process ran goes on (docs/station-ts.md, 已定 1): a station that stops hands its sessions
// over (run/handover.json) and the next takes them up, runtimes and all, from their runners. Under the launcher the
// next process is up before the previous one hands over: it takes up only once that one is gone (run/hub.json says
// which process holds the sessions), and opens the agents' door only then, so no call reaches a hub without its session.
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Context, Effect, Layer, Stream } from "effect";
import { Fibers, wall } from "../ops/fibers.ts";
import { ClaudeDriver } from "../agents/claude.ts";
import { CodexDriver } from "../agents/codex.ts";
import { Jobs, notifyEndpoint } from "../jobs/jobs.ts";
import { Remote } from "../jobs/remote.ts";
import { Tasks } from "../tasks/tasks.ts";
import { ConfigFile } from "../ops/config.ts";
import type { Control } from "../ops/launcher.ts";
import { log } from "../ops/log.ts";
import { AdbShares, ControlPlane, Events, Key, Paths, Readers, Store } from "../services.ts";
import { Notifier } from "../cloud/notify.ts";
import { adbTools } from "../tools/adb.ts";
import { appTools } from "../tools/apps.ts";
import { archiveTools } from "../tools/archive.ts";
import { feedbackTools, tellFixed } from "../tools/feedback.ts";
import { signedPost } from "../cloud/signed.ts";
import { version } from "../ops/version.ts";
import { chatTools } from "../tools/chat.ts";
import { type AgentsDoor, openAgentsDoor } from "../tools/http.ts";
import { jobTools } from "../tools/jobs.ts";
import { McpEndpoint, UNBOUND_REFUSAL } from "../tools/mcp.ts";
import { remoteTools } from "../tools/remote.ts";
import { UsageCounter } from "../usage/counter.ts";
import { type Accounts, checkConfig, makeAccounts } from "../accounts/index.ts";
import { AccountSources } from "../accounts/sources.ts";
import { Sharing } from "../share/index.ts";
import { overview } from "../api/overview.ts";
import { type SlackParts, makeConnections } from "../slack/index.ts";
import type { Viewer } from "../mesh/credential.ts";
import type { Lang } from "../ops/i18n.ts";
import { type Updates, makeUpdates } from "../updates/updates.ts";
import { hubConfig } from "./config.ts";
import { ColdRooms } from "./cold.ts";
import { Hub } from "./hub.ts";
import { Coding } from "../tasks/coding.ts";
import { InternalChat } from "./internal.ts";
import { autoArchive } from "./lifecycle.ts";
import { fromPeer } from "./messages.ts";
import { forPeer, READ } from "./others.ts";
import { reviewUndecided, startReview } from "./review.ts";

/// server.rs `encode` (encodeURIComponent).
const encode = encodeURIComponent;

/// How long a drain waits for running turns to end, and how long a drained station waits to be stopped before it takes
/// turns again (whoever asked went away).
const DRAIN_LIMIT_MS = 600_000;
const DRAINED_LIMIT_MS = 300_000;
/// How long the previous station process is waited for before its sessions are taken up all the same.
const PREVIOUS_LIMIT_MS = 40_000;

export type AgentsParts = {
  /// The previous station process gone (or given up on): the agents' side waits for it, and a fixed mesh port too.
  previousGone: Promise<void>;
  hub: Hub;
  jobs: Jobs;
  remote: Remote;
  mcp: McpEndpoint;
  config: ConfigFile;
  usage: UsageCounter;
  updates: Updates;
  accounts: Accounts;
  /// What this station shares with the workspace's other stations, and uses of theirs.
  sharing: Sharing;
  /// Tasks kept here with Sessions of other stations taking part, and Tasks kept elsewhere Sessions here take part in.
  tasks: Tasks;
  slack: SlackParts;
  /// Where the station is in its control plane while in a workspace.
  place(): { origin: string; workspace: string; station: string } | null;
  /// A desktop app's connection to one of its Workspaces is up: the station is in a workspace (as cloud.json would
  /// say of an enrolled one) until the function it gives is called.
  joined(): () => void;
  /// GET /overview as `viewer` sees it.
  overview(viewer: Viewer, lang: Lang): Promise<unknown>;
};

export class Agents extends Context.Service<Agents, AgentsParts>()("stillfail/Agents") {}

/// Whether a process is alive (signal 0).
function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

/// Waits for the station process that held the sessions before (run/hub.json) to be gone.
async function previousGone(run: string) {
  let pid = 0;
  try {
    pid = JSON.parse(readFileSync(join(run, "hub.json"), "utf8")).pid;
  } catch {
    return;
  }
  if (typeof pid !== "number" || pid === process.pid || !alive(pid)) return;
  log.info("hub", "waiting for the previous station process to hand over", { pid });
  const until = wall.now() + PREVIOUS_LIMIT_MS;
  // A process's end can only be looked for (another program's: the machine's time): every 100 ms, for the seconds a
  // handover takes.
  while (alive(pid) && wall.now() < until) await wall.sleep(100);
  if (alive(pid)) log.warn("hub", "the previous station process is still there; taking up its sessions all the same", { pid });
}

export const AgentsLive = (control: Control, managed: boolean) =>
  Layer.effect(
    Agents,
    Effect.gen(function* () {
      const { data, app } = yield* Paths;
      const store = yield* Store;
      const plane = yield* ControlPlane;
      const cloud = plane.state;
      const readers = yield* Readers;
      const events = yield* Events;
      const key = yield* Key;
      const shares = yield* AdbShares;
      const run = join(data, "run");
      const config = new ConfigFile(data);
      // An edit is taken only if it checks out as config.rs `parse_config` would have it.
      config.check = checkConfig;
      const place = () => {
        const s = cloud.state;
        return s && s.workspace && !cloud.removed() ? s : null;
      };
      // The desktop app's station joins no workspace by enrolling: its connections to the app's Workspaces put it in them.
      let desktopConnections = 0;
      const bound = () => place() !== null || desktopConnections > 0;
      // Session pages are still.fail cloud's (`<origin>/o/…`); other control planes have none to link to.
      const pageOf = (key: string) => {
        const s = place();
        return s && plane.spec().pages ? `${s.origin}/o/${s.workspace}/${s.station}/${encode(key)}` : undefined;
      };

      const settings = () => hubConfig(config.raw(), data);
      // Which account each desktop Workspace's runtimes run on here (none until a person chooses).
      const sources = new AccountSources({ config, data, managed });
      // What other stations of the workspace share with this one, and what it shares (made below, once the accounts are).
      let sharing: Sharing | null = null;
      const borrowed = (p: unknown) => sharing?.borrowedSubscription(p) === true;
      const codex = new CodexDriver({
        data,
        currentProfile: (id) => settings().profiles.find((p) => p.id === id),
        lent: { borrowed, write: (p) => sharing!.lendCodex(p) },
      });
      const hub: Hub = new Hub({
        config: settings,
        store,
        // The connects' Slack (made below); the station's own chat is the hub's.
        chats: (id) => slack.chats(id),
        drivers: [
          new ClaudeDriver({ data, machineToken: (env) => accounts.machineToken(env), lent: { borrowed, token: (p) => sharing!.lendClaude(p) } }),
          codex,
        ],
        mcpUrl: () => door?.url ?? "",
        internal: new InternalChat(),
        link: pageOf,
        cold: new ColdRooms(() => hub),
        eligible: (profiles, runtime, host, lang) => sources.eligible(profiles, runtime, host, lang),
      });
      // No turn until the agents' door is open: a runtime started before has no MCP endpoint, and Codex does not
      // connect to it again for that thread.
      hub.hold("starting");
      // Background jobs and web services: their agents told through the hub; a service's link is its session's page
      // with its port.
      const jobs = new Jobs({
        store,
        data,
        notify: (session, text) => {
          try {
            hub.notify(session, text);
          } catch (error) {
            log.warn("jobs", "job notice not given", { session, error: (error as Error).message });
          }
        },
        link: (session, job) => {
          const page = pageOf(session);
          return page ? `${page}?service=${encode(job)}` : null;
        },
      });
      const remote = new Remote({ data, store, jobs, notify: (session, text) => hub.notify(session, text), config: () => config.raw() });
      hub.setJobs(jobs);
      hub.onPeer((station, request) => remote.ask(station, request));
      hub.onClose((session) => remote.closeSession(session));
      remote.setInbox((peer, request) => (request?.method === READ ? forPeer(hub, peer, request) : fromPeer(hub, peer, request)));
      // Tasks with Sessions of other stations taking part, and Tasks of other stations Sessions here take part in.
      const tasks = new Tasks(hub, () => (station, request) => remote.ask(station, request));
      hub.setTasks(tasks);
      remote.setTasks((peer, request) => tasks.handle(peer, request));
      tasks.begin();
      // In a coding sandbox (one L4ES gave a GitHub grant), coding Sessions work in checkouts of their repositories
      // (tasks/coding.ts).
      const coding = new Coding({ reposDir: hub.reposDir() });
      if (coding.begin()) {
        hub.coding = coding;
        void coding
          .identity(process.env.COMMA_GIT_USER_NAME, process.env.COMMA_GIT_USER_EMAIL)
          .catch((error) => log.warn("coding", "the git identity was not set", { error: (error as Error).message }));
      }

      const tools = [
        ...chatTools(hub),
        ...archiveTools(hub),
        ...remoteTools(remote),
        ...adbTools(() => shares.list(), () => {
          const s = place();
          return s && plane.spec().pages ? `${s.origin}/w/${s.workspace}/s/${s.station}/adb` : null;
        }),
        ...jobTools(jobs, (key) => store.getSession(key)?.workspace ?? null),
        // Only to coding Sessions of a Task that builds a Mini App.
        ...appTools(tasks),
      ];
      // The station's and the runtimes' versions, read at start and every few hours; updated from the pages, or by
      // itself while nothing runs and nobody looks (auto update).
      const updates = makeUpdates({
        app,
        data,
        config,
        // Where its releases are: still.fail cloud's origin, Comma's `/stations` (ControlPlane.releaseBase).
        origin: () => plane.releaseBase(),
        running: () => hub.running(),
        inUse: () => events.inUse(),
      });
      updates.start();
      // `stillfail update --beta|--stable` asks a running station by SIGHUP (run/channel-ask).
      control.on("hup", () => updates.answerChannelAsk());

      // Bug reports to the still.fail team, from stations on the stable channel (updates.rs `channel_of`), in still.fail
      // cloud only: feedback is no part of the control plane (another provider's stations send none).
      const stable = updates.channel() === "stable" && plane.spec().feedback;
      const sendReport = async (report: any) => {
        if (cloud.removed()) throw new Error("this station was removed from its workspace");
        report.context = { ...(report.context ?? {}), version: version() };
        return signedPost(cloud, key, "/v1/feedback", "stillfail-station-feedback-v1", report);
      };
      const fixed = async (told: string[]) => {
        if (cloud.removed()) return { fixed: [] };
        return { ...(await signedPost(cloud, key, "/v1/feedback/fixed", "stillfail-station-feedback-fixed-v1", { told })), station: version() };
      };
      if (stable) tools.push(...feedbackTools(store, (k) => pageOf(k) ?? null, () => (cloud.state ? sendReport : null)));
      // Outside a workspace its agents do not reach out of it: their outward tools are refused.
      const mcp = new McpEndpoint((token) => store.sessionByToken(token)?.key, tools, () => (bound() ? undefined : UNBOUND_REFUSAL));

      // The connects' Slack: connected while the station is in its workspace, once the sessions are taken up (a
      // Socket Mode event goes to one connection of an app; two processes' would split them).
      const slack: SlackParts = makeConnections({ data, store, config, receive: (connect, event) => hub.receive(connect, event), bound: () => taken && bound() });
      let taken = false;
      // The names the pages show of Slack people and channels are the readers' (from the names book); a connection
      // looks up those it does not know yet as it hears of them: who wrote, and where.
      const learn = (thread: number, people: string[]) => {
        const t = store.getThread(thread);
        if (t === null || t.surface === "ember") return;
        const connect = store.threadSessions(thread).map((m) => m.connect).find((c) => c !== "ember");
        const chat = connect === undefined ? undefined : slack.chat(connect);
        if (chat === undefined) return;
        chat.knownChannel?.(t.channel);
        for (const user of people) chat.knownPerson?.(user);
      };
      const unlearn = store.subscribe((change) => {
        if (change.type === "thread") learn(change.id, [...new Set(change.entries.filter((e) => e.authorKind === "person").map((e) => e.author))]);
      });
      // A connect connected: the Slack threads people read lately, learned once.
      const learned = new Set<string>();
      const unlearnConnected = slack.onChange(() => {
        for (const c of slack.connects()) {
          if (learned.has(c.id) || slack.state(c.id)?.state !== "connected") continue;
          learned.add(c.id);
          for (const t of store.listThreads("", null, null).slice(0, 200)) {
            if (t.sessions.some((m) => m.connect === c.id)) learn(t.thread.id, [...t.people.flatMap((p) => (p.startsWith(`slack:${c.id}:`) ? [p.slice(`slack:${c.id}:`.length)] : []))]);
          }
        }
      });

      // Profiles, sign-ins, allowances and the machine's own logins; the Claude driver's machine token renewed by it.
      const hostName = (p: any) => {
        const host = p?.share?.host;
        return cloud.state?.peers.find((x) => x?.id === host)?.name ?? host ?? null;
      };
      const accounts: Accounts = makeAccounts({
        data, store, config, hub, sources, workspace: () => place()?.workspace ?? null, reviewUndecided: () => startReview(hub), codex: () => codex as any, following: () => events.inUse(), checkOnStart: true,
        shared: { status: (p) => sharing!.status(p), view: (p) => sharing?.profileView(p) ?? null, hostName },
      });
      accounts.start();
      sharing = new Sharing({
        data, config, cloud,
        ask: (station, request) => remote.ask(station, request),
        agentHome: () => settings().agentHome,
        env: process.env as Record<string, string | undefined>,
        claudeToken: (p) => accounts.claudeToken(p),
        codexRunning: (id) => codex.running(id),
        machineAllowed: (runtime) => accounts.machineAllowed(runtime),
        status: (id) => { const h = accounts.health(id); return { check: h.check ?? null, quota: h.quota ?? null }; },
        changed: () => events.overviewChanged(),
        recheck: () => accounts.recheckBorrowed(),
      });
      remote.setShares((peer, request) => sharing!.handle(peer, request));
      sharing.start();
      const slackView = {
        connection: (c: any) => slack.state(c.id),
        teams: (viewer: Viewer) => slack.overview(viewer.email).slackTeams,
        apps: (viewer: Viewer) => slack.overview(viewer.email).slackApps,
      };
      const view = (viewer: Viewer, lang: Lang) => overview({ store, hub, cloud, config: () => config.raw(), accounts, updates, slack: slackView }, viewer, lang);

      // The readers say what runs, and which chats clients made: the hub's.
      readers.processes = () => hub.processes();
      readers.clientKeys = () => hub.clientKeys();
      events.follow({
        live: (key, from, last, send) => {
          const id = hub.live.subscribe(key, from, last, send);
          return () => hub.live.unsubscribe(key, id);
        },
        overview: view,
        processState: (key) => hub.processState(key),
        followed: () => accounts.followed(),
      });
      // A runtime installed or updated from the pages: the machine's logins read again.
      updates.onRuntimeChanged(() => void accounts.machine?.refresh());
      // What the overview shows changes: told on the event streams.
      const unlistenOverview = [
        accounts.onChange(() => events.overviewChanged()),
        // The sidebar names connects and their Slack workspaces.
        slack.onChange(() => (events.overviewChanged(), events.rowsChanged(null))),
        updates.changes(() => events.overviewChanged()),
        config.listen(() => (events.overviewChanged(), events.rowsChanged(null))),
        cloud.listen(() => events.overviewChanged()),
      ];

      // In a workspace, or out of it, as cloud.json and the desktop app's connections say, from now on.
      let inWorkspace = bound();
      let following = Promise.resolve();
      const refollow = () => (following = following.then(follow, follow));
      const follow = async () => {
        const now = bound();
        if (now === inWorkspace) return;
        inWorkspace = now;
        // Before the sessions are taken up, `start` holds them or goes on as it finds `inWorkspace` (a desktop app's
        // connection comes up at once).
        if (!taken) return;
        if (now) {
          log.info("station", "in a workspace: connects, turns and jobs go on");
          await slack.reconcile();
          hub.recover();
          jobs.relaunch();
          hub.release("unbound");
        } else {
          const why = cloud.removed() ? "the station was removed from its workspace" : "the station is in no workspace";
          log.warn("station", "out of its workspace: ending the agents' runtimes, stopping jobs and services", { why });
          hub.hold("unbound");
          await hub.suspendAll();
          await slack.stopAll();
          await jobs.stopAll(why);
        }
      };
      yield* plane.changes.pipe(
        Stream.runForEach(() => Effect.promise(refollow)),
        Effect.forkScoped,
      );

      let door: AgentsDoor | null = null;
      let handing = false;
      // Taken up once the previous process is gone; then the door opens, and what was cut off resumes.
      const previous = previousGone(run);
      const start = async () => {
        await previous;
        mkdirSync(run, { recursive: true });
        writeFileSync(join(run, "hub.json"), JSON.stringify({ pid: process.pid }) + "\n");
        if (!inWorkspace) hub.hold("unbound");
        await hub.takeUp();
        // The launcher's socket; on its own, 4750 or the port config.json names (taken by something else: a free one,
        // unless it was named, ports.rs).
        const named = config.raw()?.http?.port;
        const notified = (authorization: string | undefined, body: Buffer) => notifyEndpoint(jobs, authorization, body);
        // Behind the launcher's entrance (launcher.ts `ports`): any port here, its port the one agents are told.
        const at = control.mcpFd !== undefined ? { fd: control.mcpFd } : control.ports ? { port: 0, shown: control.ports.mcp } : { port: Number(named ?? 4750) };
        try {
          door = await openAgentsDoor(at, mcp, notified);
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "EADDRINUSE" || named !== undefined) throw error;
          door = await openAgentsDoor({ port: 0 }, mcp, notified);
        }
        jobs.setNotifyUrl(door.url.replace(/\/mcp$/, "/jobs/notify"));
        // Taken over and serving: the launcher's entrance comes here now (not before: launcher/src/lifecycle.rs).
        control.serving("mcp", door.port);
        log.info("station", "agents' door open", { url: door.url });
        taken = true;
        hub.release("starting");
        if (inWorkspace) {
          // In one since it was held above, say: what waited goes on.
          hub.release("unbound");
          await slack.reconcile();
          if (slack.connects().length === 0 && place() !== null) log.warn("station", "no connect is connected; add or enable one in the workspace's settings");
          hub.recover();
          jobs.relaunch();
        } else {
          hub.hold("unbound");
        }
        if (!inWorkspace && cloud.removed()) {
          // Removed, and the station stopped before it stopped its jobs (or crashed): what still runs is ended now.
          await jobs.stopAll("the station was removed from its workspace");
        }
      };
      yield* Effect.forkScoped(Effect.promise(() => start().catch((e) => {
        log.error("hub", "the agents' side did not start", { error: (e as Error).message });
        control.failed(`the agents' side did not start: ${(e as Error).message}`);
      })));

      // What the agents spent, read from their transcripts: now, and after each turn ends.
      const usage = new UsageCounter({ store, config: () => ({ dataDir: data, profiles: settings().profiles }), clock: hub.clock });
      usage.start();

      // What the chats' people hear about while no client of theirs runs: pushed by the control plane.
      const notifier = new Notifier(store, readers, cloud, (notices) => Effect.runPromise(plane.notify(notices)));

      // The bug reports its agents sent that are fixed and out: each session told, a few minutes after the start and
      // every hour (the cloud has no way to say so as it happens).
      const tellingFixed = () =>
        void tellFixed(fixed, (session, text) => hub.notify(session, text)).catch((error) => log.warn("feedback", "fixed bug reports not read", { error: (error as Error).message }));
      // What runs on a clock here (on the hub's): ended at the handover, below.
      const time = new Fibers("station", hub.clock);
      if (stable) {
        time.after(300_000, tellingFixed);
        time.every(3_600_000, tellingFixed);
      }

      // Chats idle long enough go to the archive: looked at every hour.
      time.every(3_600_000, () => {
        try {
          autoArchive(hub, hub.now());
        } catch (error) {
          log.warn("hub", "auto-archiving failed", { error: (error as Error).message });
        }
      });

      // The archive review turned on, or given another model: the done chats no decision has answered are reviewed then,
      // not only the ones that end all_done from now on; and once after the start (the profiles' checks read by then).
      const reviewing = () => void reviewUndecided(hub).catch((error) => log.warn("hub", "reviewing done chats failed", { error: (error as Error).message }));
      let rule = hub.config().automaticDecisions.completion;
      const unlistenRule = config.listen(() => {
        const now = hub.config().automaticDecisions.completion;
        const changed = now.enabled && (!rule.enabled || now.model !== rule.model);
        rule = now;
        if (changed) reviewing();
      });
      time.after(120_000, reviewing);

      // A drain (SIGUSR1): no new turns; said when none runs (run/drained), turns again if nobody stops the station.
      let draining = false;
      control.on("drain", () => {
        if (draining) return;
        draining = true;
        log.info("station", "draining: no new turns; waiting for running ones to end");
        hub.hold("drain");
        const done = (said: "idle" | "timeout") => {
          stopListening();
          limit();
          log.info("station", "drained", { said });
          writeFileSync(join(run, "drained"), `${said}\n`);
          control.drained(said);
          time.after(DRAINED_LIMIT_MS, () => {
            log.warn("station", "drained but not stopped; taking turns again");
            rmSync(join(run, "drained"), { force: true });
            hub.release("drain");
            draining = false;
          });
        };
        // A turn's end is a session change: looked at then, not on a timer.
        const stopListening = store.subscribe((change) => {
          if (change.type === "session" && !hub.anyRunning()) done("idle");
        });
        const limit = time.after(DRAIN_LIMIT_MS, () => done("timeout"));
        if (!hub.anyRunning()) done("idle");
      });

      // Stopping hands the sessions over, whether to the next process now (handover) or the next start: their runtimes
      // run on under their runners.
      yield* Effect.addFinalizer(() =>
        Effect.promise(async () => {
          if (handing) return;
          handing = true;
          await time.close();
          await sharing?.close();
          unlistenRule();
          notifier.close();
          // Slack's events go to the next process from now on.
          unlearn();
          unlearnConnected();
          await slack.close();
          await door?.close(30_000);
          try {
            await hub.handOver();
          } catch (error) {
            log.warn("hub", "sessions not handed over; they resume the usual way", { error: (error as Error).message });
            await hub.shutdown();
          }
          await jobs.shutdown();
          await usage.stop();
          await updates.close();
          await accounts.close();
          for (const stop of unlistenOverview) stop();
          if (existsSync(join(run, "hub.json"))) {
            try {
              if (JSON.parse(readFileSync(join(run, "hub.json"), "utf8")).pid === process.pid) rmSync(join(run, "hub.json"), { force: true });
            } catch {}
          }
        }),
      );
      return Agents.of({ previousGone: previous, hub, jobs, remote, mcp, config, usage, updates, accounts, sharing: sharing!, tasks, slack, overview: view, place: () => { const s = place(); return s ? { origin: s.origin, workspace: s.workspace, station: s.station } : null; },
        joined: () => {
          desktopConnections++;
          void refollow();
          let left = false;
          return () => {
            if (left) return;
            left = true;
            desktopConnections--;
            void refollow();
          };
        },
      });
    }),
  );
