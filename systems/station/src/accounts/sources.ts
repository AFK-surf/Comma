// Which account each runtime runs on for each Workspace this desktop station is connected to (RFC43 §3.1): the
// account source, `none` (the default), `local` (the machine's own login, the `machine-<runtime>` profile), `endpoint`
// (a model server this computer reaches, such as Ollama on localhost: the `local-model-<runtime>` profile) or
// `workspace` (the profiles the Workspace's Salix lends this station's instance for it). A model server on the person's
// own computer or network is reached only from here: Salix never has its address. The source is a value in
// config.json (`accountSources: {<workspace>: {<runtime>: {source, by, at}}}`), set only by a person's choice; none is
// picked for them. A Workspace is the one a desktop connection (connector/instances/<id>.json, `comma.workspace_id`)
// names; its Tasks come through the instance's host `salix:<id>`.
//
// The machine's own login of a runtime is read and used only while some Workspace has `local` for it.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { isMachine, type Runtime } from "../agents/profiles.ts";
import type { ConfigFile } from "../ops/config.ts";
import { wall } from "../ops/fibers.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import type { Profile } from "../sessions/config.ts";

type Json = any;

export type Source = "none" | "local" | "endpoint" | "workspace";
export type SourceChoice = { source: Source; by: string; at: number };
export const SOURCES: readonly Source[] = ["none", "local", "endpoint", "workspace"];
export const RUNTIMES: readonly Runtime[] = ["codex", "claude"];

/// The desktop app's connections, one per signed-in Workspace: a desktop config file each, named `<id>.json`.
export const INSTANCES_DIR = join("connector", "instances");
/// The host an instance's Salix is to the station (its Tasks, the profiles it lends).
export const INSTANCE_HOST = "salix:";
export const instanceHost = (id: string) => `${INSTANCE_HOST}${id}`;
const INSTANCE_ID = /^[A-Za-z0-9_-]{1,128}$/;

/// The profile of the model server this computer runs a runtime on (`endpoint`), one per runtime for every Workspace.
export const localModelId = (runtime: Runtime) => `local-model-${runtime}`;

const isObject = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);
export const sourceOf = (v: unknown): Source | undefined => (SOURCES.includes(v as Source) ? (v as Source) : undefined);
const title = (r: Runtime) => (r === "claude" ? "Claude Code" : "Codex");

/// A Session refused for its Workspace's source: the reason is the person's to read.
export class SourceRefusal extends Error {}

/// A desktop connection: its instance id, its Workspace, and that Workspace's name where the file says it.
export type Instance = { id: string; workspaceId: string; name: string | null };

export class AccountSources {
  private readonly config: ConfigFile;
  private readonly dir: string;
  private readonly now: () => number;
  private readonly managed: boolean;

  constructor(deps: { config: ConfigFile; data: string; now?: () => number; managed?: boolean }) {
    this.config = deps.config;
    this.dir = join(deps.data, INSTANCES_DIR);
    this.now = deps.now ?? wall.now;
    this.managed = deps.managed === true;
  }

  /// The desktop connections there are now.
  instances(): Instance[] {
    let names: string[];
    try {
      names = readdirSync(this.dir);
    } catch {
      return [];
    }
    return names.flatMap((name) => {
      const id = name.endsWith(".json") ? name.slice(0, -".json".length) : "";
      const one = INSTANCE_ID.test(id) ? this.instance(id) : null;
      return one ? [one] : [];
    });
  }

  private instance(id: string): Instance | null {
    try {
      const file = JSON.parse(readFileSync(join(this.dir, `${id}.json`), "utf8"));
      const workspaceId = String(file?.comma?.workspace_id ?? file?.connector?.workspace_id ?? "").trim();
      if (workspaceId === "") return null;
      const name = typeof file?.comma?.workspace_name === "string" && file.comma.workspace_name.trim() !== "" ? file.comma.workspace_name.trim() : null;
      return { id, workspaceId, name };
    } catch {
      return null;
    }
  }

  /// The instance host of a Workspace (its connection's), when it is connected.
  hostOf(workspace: string): string | null {
    const found = this.instances().find((i) => i.workspaceId === workspace);
    return found ? instanceHost(found.id) : null;
  }

  /// Whether `host` is a desktop connection's; its Workspace, null when its file is gone or names none.
  workspaceOfHost(host: string): string | null {
    if (!host.startsWith(INSTANCE_HOST)) return null;
    const id = host.slice(INSTANCE_HOST.length);
    return INSTANCE_ID.test(id) ? (this.instance(id)?.workspaceId ?? null) : null;
  }

  private stored(): Record<string, Json> {
    const s = this.config.raw()?.accountSources;
    return isObject(s) ? s : {};
  }

  /// Workspaces with a choice recorded.
  chosenWorkspaces(): string[] {
    return Object.keys(this.stored());
  }

  /// The person's choice for a Workspace's runtime; null when none was made.
  choice(workspace: string, runtime: Runtime): SourceChoice | null {
    const c = this.stored()[workspace]?.[runtime];
    const source = sourceOf(c?.source);
    if (!source) return null;
    return { source, by: typeof c.by === "string" ? c.by : "", at: typeof c.at === "number" ? c.at : 0 };
  }

  source(workspace: string, runtime: Runtime): Source {
    return this.choice(workspace, runtime)?.source ?? "none";
  }

  /// Records a person's choice.
  set(workspace: string, runtime: Runtime, source: Source, by: string) {
    this.config.update((raw) => {
      const all = isObject(raw.accountSources) ? raw.accountSources : (raw.accountSources = {});
      const ws = isObject(all[workspace]) ? all[workspace] : (all[workspace] = {});
      ws[runtime] = { source, by, at: this.now() };
    });
  }

  /// Whether the machine's own login of a runtime is in use: some Workspace chose `local` for it.
  localActive(runtime: Runtime): boolean {
    if (this.managed) return false;
    return Object.values(this.stored()).some((ws) => isObject(ws) && ws[runtime]?.source === "local");
  }

  /// The profiles a Workspace's instance host lent this station (all runtimes).
  lent(profiles: Profile[], host: string | null): Profile[] {
    return host === null ? [] : profiles.filter((p) => isObject(p.share) && p.share.borrowed === true && p.share.host === host);
  }

  /// Of a runtime's profiles, those a Session may run on, by where it came from: a desktop connection's host keeps to
  /// its Workspace's source (refused with the reason under `none`, or with nothing in the source); anything else may
  /// use any but the machine's login not in use and what a Workspace lent for its own Tasks.
  eligible(profiles: Profile[], runtime: Runtime, host: string | null, lang: Lang = stationLang()): Profile[] {
    // A Workload's connection lends its cloud accounts. Desktop opt-in and
    // other local profiles grant that managed connection no account access.
    if (this.managed) return this.lent(profiles, host ?? "salix").filter((p) => p.runtimes.includes(runtime));
    if (host !== null && host.startsWith(INSTANCE_HOST)) {
      const workspace = this.workspaceOfHost(host);
      const source = workspace === null ? "none" : this.source(workspace, runtime);
      if (source === "none") throw new SourceRefusal(tr(lang, "station.source.none", { runtime: title(runtime) }));
      if (source === "local") {
        const local = profiles.filter((p) => isMachine(p) && p.runtimes.includes(runtime));
        if (local.length === 0) throw new SourceRefusal(tr(lang, "station.source.localMissing", { runtime: title(runtime) }));
        return local;
      }
      if (source === "endpoint") {
        const server = profiles.filter((p) => p.id === localModelId(runtime) && p.runtimes.includes(runtime));
        if (server.length === 0) throw new SourceRefusal(tr(lang, "station.source.endpointMissing", { runtime: title(runtime) }));
        return server;
      }
      const lent = this.lent(profiles, host).filter((p) => p.runtimes.includes(runtime));
      if (lent.length === 0) throw new SourceRefusal(tr(lang, "station.source.workspaceMissing", { runtime: title(runtime) }));
      return lent;
    }
    return profiles.filter((p) => {
      if (!p.runtimes.includes(runtime)) return false;
      if (isMachine(p)) return this.localActive(runtime);
      const host = isObject(p.share) && p.share.borrowed === true ? String(p.share.host ?? "") : "";
      return !host.startsWith(INSTANCE_HOST);
    });
  }
}
