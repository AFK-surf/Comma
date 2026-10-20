// `stillfail-station channel [stable|beta] [--app DIR] [--data DIR]` (the Rust station's main.rs): the channel the
// station is updated on, set when one is named, then said on the last line (`bin/stillfail update [--beta|--stable]`
// reads it). A station running there holds the config (an edit of its own would write over one made beside it): it is
// asked (SIGHUP to the pid in run/station.json, the channel in run/channel-ask) and its answer waited for; with none
// running, the config is written here.
//
// Unlike the Rust command, Node cannot try run/station.lock (flock): whether a station runs is told by run/station.json
// (its pid there, alive, a station's command, and saying it takes the ask: `channel: 1`), as the installer tells it.
import { existsSync, mkdirSync, readFileSync, rmSync, watch } from "node:fs";
import { basename, dirname, join } from "node:path";
import { Effect, Latch, Option } from "effect";
import { ConfigFile } from "../ops/config.ts";
import { flag } from "../ops/files.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { CHANNEL_ANSWER, CHANNEL_ASK, writeWhole } from "./updates.ts";
import { type Channel, channelOf, channelOfId } from "./versions.ts";
import { platform } from "../platform/index.ts";

const configPath = (data: string) => process.env.STILLFAIL_CONFIG || process.env.EMBER_CONFIG || join(data, "config.json");

/// Whether `pid` is a station (its command says so), as the installer checks it: a pid left in station.json may be
/// another process's by now.
export const isStation = (pid: number): boolean => platform.isLauncher(pid);

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
};

/// Sets the channel in the config (`stillfail update --beta`/`--stable` with no station running to ask). A config that
/// is there but cannot be read is not written over.
export function setChannelIn(data: string, channel: Channel) {
  const path = configPath(data);
  if (existsSync(path)) JSON.parse(readFileSync(path, "utf8"));
  new ConfigFile(data).update((raw) => {
    raw.updateChannel = channel;
  });
}

/// Puts the station of `data` on `channel`: the running station asked when there is one that takes the ask, else the
/// config written here. Its refusal is thrown with its words.
export async function setChannel(data: string, channel: Channel, waitMs: number, station: (pid: number) => boolean = isStation): Promise<void> {
  const run = join(data, "run");
  mkdirSync(run, { recursive: true });
  let said: any = null;
  try {
    said = JSON.parse(readFileSync(join(run, "station.json"), "utf8"));
  } catch {}
  const pid = Number.isSafeInteger(said?.pid) && said.pid > 0 ? (said.pid as number) : null;
  if (pid === null || said?.channel !== 1 || !alive(pid) || !station(pid)) return setChannelIn(data, channel);
  const answer = join(run, CHANNEL_ANSWER);
  rmSync(answer, { force: true });
  writeWhole(join(run, CHANNEL_ASK), channel);
  try {
    // The launcher hears it (Unix's SIGHUP, a line on Windows' pipe) and tells the station's process.
    await platform.askLauncher(pid, "hup");
  } catch (e) {
    rmSync(join(run, CHANNEL_ASK), { force: true });
    throw new Error(tr(stationLang(), "station.cli.signalFailed", { pid, error: (e as Error).message }));
  }
  const text = Option.getOrNull(await Effect.runPromise(answerIn(answer, waitMs)));
  if (text !== null) {
    rmSync(answer, { force: true });
    const t = text.trim();
    if (t.startsWith("ok")) return;
    throw new Error(t.startsWith("error ") ? t.slice(6) : t);
  }
  rmSync(join(run, CHANNEL_ASK), { force: true });
  throw new Error(tr(stationLang(), "station.cli.noAnswer"));
}

/// The running station's answer in `path`, once it is there: looked at as its directory changes (the answer is written
/// aside and moved in) and every 100 ms besides (a change can go unheard); none after `waitMs`.
function answerIn(path: string, waitMs: number): Effect.Effect<Option.Option<string>> {
  const read = () => {
    try {
      return readFileSync(path, "utf8");
    } catch {
      return null;
    }
  };
  return Effect.scoped(
    Effect.gen(function* () {
      const changed = Latch.makeUnsafe(false);
      yield* Effect.acquireRelease(
        Effect.sync(() => {
          try {
            const watcher = watch(dirname(path), (_, name) => {
              if (name === null || name === basename(path)) changed.openUnsafe();
            });
            watcher.on("error", () => {});
            return watcher;
          } catch {
            return null;
          }
        }),
        (watcher) => Effect.sync(() => watcher?.close()),
      );
      for (;;) {
        changed.closeUnsafe();
        const text = read();
        if (text !== null) return text;
        yield* Effect.raceFirst(Effect.sleep(100), changed.await);
      }
    }),
  ).pipe(Effect.timeoutOption(waitMs));
}

/// The command: `args` as the station was given them (after `channel`, a channel or none; `--app`, `--data`). Says
/// the channel on stdout; a refusal on stderr, exit code 1 (as the Rust command's error); a usage error, exit code 2.
export async function channelCommand(args: string[], data: string): Promise<number> {
  const app = flag(args, "--app");
  const positional = args.filter((a, i) => !a.startsWith("--") && !(i > 0 && ["--app", "--data", "--port", "--handoff", "--node"].includes(args[i - 1]!)));
  const named = positional.slice(positional.indexOf("channel") + 1);
  if (named.length > 1) return 2;
  try {
    if (named[0] !== undefined) {
      const channel = channelOfId(named[0]);
      if (channel === null) throw new Error(tr(stationLang(), "station.cli.badChannel", { channel: named[0] }));
      await setChannel(data, channel, 10_000);
    }
    let raw: any = {};
    const path = configPath(data);
    if (existsSync(path)) raw = JSON.parse(readFileSync(path, "utf8"));
    // No --app: as the Rust command, the release is "" (a CHANNEL beside where it runs).
    console.log(channelOf(raw, app ?? ""));
    return 0;
  } catch (e) {
    console.error(`Error: ${(e as Error).message}`);
    return 1;
  }
}
