// The connector's commands on the station's command line: `comma-client` (the `comma` the agents run, to Main's
// client control API) and `computer-use` (the app's permission flow and an agent's actions), as the Go connector had
// them, and `restore-archive` (a Workload's archive onto its disk, before its station starts). Each prints what it got
// and returns the exit code.
import { resolve } from "node:path";
import { Effect, Exit } from "effect";
import { runtimeDir } from "../ops/files.ts";
import { COMMA_CLIENT_CONTROL_URL_ENV, liveClientControl, runCommaClientCli } from "./comma-client-cli.ts";
import { applyConfigFile, normalizeConfig, parseArgs } from "./config.ts";
import { makeComputerUse } from "./computer-use.ts";
import { archiveName, archiveStateDir, restoreBeforeStart, signedStorageUrl } from "./durable-archive.ts";

const env = () => process.env as Record<string, string | undefined>;

export async function commaClientCommand(args: string[]): Promise<number> {
  const endpoint = (env()[COMMA_CLIENT_CONTROL_URL_ENV] ?? "").trim().replace(/\/+$/, "");
  const ran = await Effect.runPromiseExit(
    runCommaClientCli(args, { env: env(), stdout: (text) => process.stdout.write(text) }).pipe(Effect.provide(liveClientControl(endpoint))),
  );
  if (Exit.isSuccess(ran)) return 0;
  process.stderr.write(`comma: ${errorText(ran)}\n`);
  return 1;
}

/** `computer-use <action> [--config PATH] [--json OBJECT]`: the result as JSON, as the agents read it. */
export async function computerUseCommand(args: string[]): Promise<number> {
  const action = args[0];
  if (!action || action.startsWith("-")) {
    process.stderr.write("usage: computer-use <action> [--config path] [--json '{...}']\n");
    return 2;
  }
  let params: Record<string, unknown> = {};
  const flags: string[] = [];
  for (let i = 1; i < args.length; i++) {
    if (args[i] === "--json") {
      try {
        const parsed = JSON.parse(args[++i] ?? "");
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
        params = parsed as Record<string, unknown>;
      } catch (error) {
        process.stderr.write(`--json must be a JSON object: ${(error as Error).message}\n`);
        return 2;
      }
    } else flags.push(args[i]);
  }
  const configured = await Effect.runPromiseExit(
    Effect.gen(function* () {
      const { cfg, explicit } = parseArgs(flags, env());
      if (cfg.configPath) yield* applyConfigFile(cfg, explicit);
      normalizeConfig(cfg);
      return cfg;
    }),
  );
  if (Exit.isFailure(configured)) {
    process.stderr.write(`${errorText(configured)}\n`);
    return 2;
  }
  const computerUse = makeComputerUse(configured.value, (effect) => void Effect.runFork(effect));
  const result = await Effect.runPromise(computerUse.call({ ...params, action }));
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return 0;
}

/** The environment variable a Container's start names its archive in (connector/durable-archive.ts `decodeRestore`). */
export const RESTORE_ARCHIVE_ENV = "SALIX_RESTORE_ARCHIVE";

/**
 * `restore-archive`: unpacks the archive the start named onto the station's root (as `run` takes it: --root or
 * SALIX_CONNECTOR_ROOT), where no station has started yet. `data` is the data directory of the station that will start
 * there (as `run` takes it: --data): an archive's runtime state under it is not this machine's and is not restored.
 * 0 once the disk is that archive; 1, with why, otherwise: the caller then starts no station.
 */
export async function restoreArchiveCommand(args: string[] = [], hostSuffix?: string, data?: string): Promise<number> {
  const ran = await Effect.runPromiseExit(
    Effect.gen(function* () {
      const { cfg } = yield* Effect.try({ try: () => parseArgs(args, env()), catch: (e) => e as Error });
      const restore = (env()[RESTORE_ARCHIVE_ENV] ?? "").trim();
      if (!restore) return yield* Effect.fail(new Error(`${RESTORE_ARCHIVE_ENV} names no archive`));
      // A Workload's station keeps its state under its root (connector.ts `runtimeStateRoot`).
      const runtime = data ? archiveName(resolve(cfg.root), runtimeDir(resolve(data))) : null;
      return yield* restoreBeforeStart({
        root: cfg.root,
        dir: archiveStateDir(cfg.externalStateRoot || cfg.root),
        restore,
        allowedUrl: signedStorageUrl(hostSuffix ?? cfg.archiveHostSuffix),
        runtime: runtime === null ? [] : [runtime],
      });
    }),
  );
  if (Exit.isSuccess(ran)) {
    const { operation, bytes, entries, files, timings } = ran.value;
    // The same answered again (a receipt from before timings were kept) has only its size.
    const took = timings ? `, ${entries} entries, ${files} files; ms from start: ${Object.entries(timings).map(([step, ms]) => `${step.replace(/_ms$/, "")} ${ms}`).join(", ")}` : "";
    process.stderr.write(`archive ${operation} restored (${bytes} bytes${took})\n`);
    return 0;
  }
  process.stderr.write(`archive not restored: ${errorText(ran)}\n`);
  return 1;
}

function errorText(exit: Exit.Exit<unknown, unknown>): string {
  if (Exit.isSuccess(exit)) return "";
  const reason = exit.cause.reasons?.[0] as { error?: unknown; defect?: unknown } | undefined;
  const error = reason?.error ?? reason?.defect;
  return error instanceof Error ? error.message : String(error ?? "failed");
}
