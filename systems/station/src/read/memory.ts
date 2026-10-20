// The agents' memory, for the pages to show (GET /memory; the agents write it): the global one, and the shared skills
// (projects' memories among them). admin/mod.rs's route over agent_home.rs `agent_home_paths` and `list_skills`.
import { lstatSync, readFileSync, readdirSync, readlinkSync } from "node:fs";
import { joinPath } from "../ops/paths.ts";
import type { Json } from "./store.ts";

/// The skills the station brings (agent_home.rs BUILTIN_SKILLS, and FEEDBACK_SKILL): rewritten at every start, so not
/// edited on the pages.
const BUILTIN = ["stillfail-jobs", "stillfail-show", "stillfail-viz", "stillfail-feedback"];
/// What a project memory's description starts with.
const PROJECT_PREFIX = "项目记忆：";

/// Path::join as Rust has it: an absolute path replaces, nothing is normalised.
const joined = joinPath;

/// std::fs::read_to_string: the file as UTF-8, none when it does not read or is not UTF-8.
const STRICT = new TextDecoder("utf-8", { fatal: true });
function readText(path: string): string | null {
  try {
    return STRICT.decode(readFileSync(path));
  } catch {
    return null;
  }
}

function readJson(path: string): Json {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return {};
  }
}

/// config.rs: the agents' home, `agentHome` in config.json under the data directory (default `agent`).
function agentHome(raw: Json, dataDir: string): string {
  return joined(dataDir, typeof raw?.agentHome === "string" ? raw.agentHome : "agent");
}

/// What a skill's sharing is (share/index.ts): shared from here (config.json `sharedSkills`), a copy of another
/// front: a SKILL.md's frontmatter field (`key: value`), if it has one.
function front(text: string, key: string): string | null {
  if (!text.startsWith("---\n")) return null;
  const body = text.slice(4);
  const end = body.indexOf("\n---");
  if (end < 0) return null;
  for (const raw of body.slice(0, end).split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (line.startsWith(`${key}:`)) return line.slice(key.length + 1).trim().replace(/^"+|"+$/g, "");
  }
  return null;
}

/// Rust's String order (bytes of UTF-8).
const byBytes = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));

/// station's (its link into <data>/share/<id>/skill, from the station state.json says), or neither (null).
function sharing(dataDir: string, raw: Json, dir: string, name: string): Json {
  const hosted = raw?.sharedSkills?.[name];
  if (typeof hosted === "string" || typeof hosted?.id === "string") {
    const station = readJson(joined(dataDir, "mesh/cloud.json"))?.station ?? "";
    let conflicts: string[] = [];
    try {
      conflicts = readdirSync(joined(dir, name)).filter((n) => /^SKILL\.conflict-.*\.md$/.test(n));
    } catch {}
    return { id: typeof hosted === "string" ? hosted : hosted.id, role: "host", host: station, allow: Array.isArray(hosted?.allow) ? hosted.allow : null, conflicts };
  }
  try {
    const path = joined(dir, name);
    if (!lstatSync(path).isSymbolicLink()) return null;
    const m = /\/share\/(sh-[0-9a-z]+)\/skill$/.exec(readlinkSync(path));
    const had = m ? readJson(joined(dataDir, "share/state.json"))?.borrowed?.[m[1]!] : undefined;
    return had ? { id: m![1], role: "user", host: had.host ?? "", allow: Array.isArray(had.allow) ? had.allow : null, conflicts: [] } : null;
  } catch {
    return null;
  }
}

function listSkills(home: string, dataDir: string, raw: Json): Json[] {
  const dir = joined(home, "skills");
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  const skills = names.flatMap((name) => {
    const text = readText(joined(joined(dir, name), "SKILL.md"));
    if (text === null) return [];
    const description = front(text, "description") ?? "";
    const builtin = BUILTIN.includes(name);
    return [{ name, description, project: description.startsWith(PROJECT_PREFIX), builtin, text, share: builtin ? null : sharing(dataDir, raw, dir, name) }];
  });
  return skills.sort((a, b) => Number(a.builtin) - Number(b.builtin) || Number(!a.project) - Number(!b.project) || byBytes(a.name, b.name));
}

/// GET /memory.
export function memory(dataDir: string): Json {
  const raw = readJson(joined(dataDir, "config.json"));
  const home = agentHome(raw, dataDir);
  const path = joined(home, "MEMORY.md");
  return { global: { path, text: readText(path) ?? "" }, skills: listSkills(home, dataDir, raw) };
}
