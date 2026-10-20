// The shared agent home (from the Rust station's agent_home.rs): one MEMORY.md and one skills/ directory used by every profile of
// both runtimes. It lives in the data dir, not the repository, since it holds team-specific memory. Each profile home
// links to it under the name its runtime loads automatically; the station's own skills are written into it at start.
// Their text is src/skills/*.md, read from there when running from source and from dist/skills/ (copied there by the
// build) when bundled.
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { log } from "../ops/log.ts";
import type { Runtime } from "./config.ts";

export const agentHomePaths = (agentHome: string): [string, string] => [join(agentHome, "MEMORY.md"), join(agentHome, "skills")];

/// The skills the station brings, by directory name: about its own tools, so they are rewritten at every start and
/// change with the station (the team's own skills sit beside them).
const BUILTIN_SKILLS = ["stillfail-jobs", "stillfail-show", "stillfail-viz"];
/// When to offer a bug report to the still.fail team: only from a station on the stable channel, beside the
/// `feedback_send` tool; gone from one on the test channel (the team's own).
const FEEDBACK_SKILL = "stillfail-feedback";
/// The station's own skills as they were named before the rename: gone once the new ones are written (they would be
/// listed twice). A directory with more in it than the SKILL.md the station wrote is left.
const FORMER_BUILTIN_SKILLS = ["ember-jobs", "ember-show", "ember-viz"];

/// Where the skills' text is.
const skillsSource = (): URL => (import.meta.url.endsWith(".ts") ? new URL("../skills/", import.meta.url) : new URL("./skills/", import.meta.url));

/// A built-in skill's SKILL.md, as the station has it.
export const builtinSkill = (name: string): string => readFileSync(new URL(`${name}.md`, skillsSource()), "utf8");

/// Whether a directory holds nothing but the SKILL.md the station wrote.
function onlySkill(dir: string): boolean {
  try {
    return lstatSync(dir).isDirectory() && readdirSync(dir).every((e) => e === "SKILL.md");
  } catch {
    return false;
  }
}

/// Writes the station's own skills into the shared skills directory; `feedback`: the stillfail-feedback skill too
/// (else it is taken away, unless someone added to it).
export function writeBuiltinSkills(agentHome: string, feedback: boolean) {
  const [, skills] = agentHomePaths(agentHome);
  for (const name of FORMER_BUILTIN_SKILLS) {
    const dir = join(skills, name);
    if (onlySkill(dir)) rmSync(dir, { recursive: true, force: true });
  }
  if (!feedback && onlySkill(join(skills, FEEDBACK_SKILL))) rmSync(join(skills, FEEDBACK_SKILL), { recursive: true, force: true });
  for (const name of feedback ? [...BUILTIN_SKILLS, FEEDBACK_SKILL] : BUILTIN_SKILLS) {
    const text = builtinSkill(name);
    const dir = join(skills, name);
    mkdirSync(dir, { recursive: true });
    const path = join(dir, "SKILL.md");
    let now: string | null = null;
    try {
      now = readFileSync(path, "utf8");
    } catch {}
    if (now !== text) writeFileSync(path, text);
  }
}

export type ProfileHome = { id: string; runtimes: Runtime[]; home: string };

const isLink = (path: string) => {
  try {
    return lstatSync(path).isSymbolicLink();
  } catch {
    return false;
  }
};

function link(target: string, path: string) {
  let meta;
  try {
    meta = lstatSync(path);
  } catch {
    symlinkSync(target, path);
    return;
  }
  if (meta.isSymbolicLink() && readlinkSync(path) === target) return;
  // A real file or a different link: someone configured it by hand. Leave it and say so.
  log.warn("agent_home", "not linking the agent home over an existing path", { path, target });
}

/// Creates the agent home if missing and links it into every profile home.
export function linkAgentHome(agentHome: string, profiles: ProfileHome[]) {
  const [memory, skills] = agentHomePaths(agentHome);
  mkdirSync(skills, { recursive: true });
  if (!existsSync(memory)) writeFileSync(memory, "# still.fail memory\n");
  for (const { runtimes, home } of profiles) {
    mkdirSync(home, { recursive: true });
    // Each runtime it runs reads the memory under its own name.
    for (const runtime of runtimes) link(memory, join(home, runtime === "claude" ? "CLAUDE.md" : "AGENTS.md"));
    link(skills, join(home, "skills"));
  }
}

/// One place for each runtime's transcripts, shared by every profile that runs it: a session is the station's, not an
/// account's, so any account can take it on (another, when one's quota is used up) with all it had. Each profile home's
/// transcript directory (Claude Code's projects/, Codex's sessions/) is a link there. A real directory in its place is
/// left alone, with a warning (the profile then keeps its own).
export function linkTranscripts(dataDir: string, profiles: ProfileHome[]) {
  for (const { id, runtimes, home } of profiles) {
    for (const runtime of runtimes) {
      const shared = join(dataDir, "transcripts", runtime);
      mkdirSync(shared, { recursive: true });
      mkdirSync(home, { recursive: true });
      const path = join(home, runtime === "claude" ? "projects" : "sessions");
      if (!existsSync(path) && !isLink(path)) symlinkSync(shared, path);
      else if (!isLink(path) || readlinkSync(path) !== shared) log.warn("agent_home", "a profile's transcripts are not in the shared place", { profile: id, path });
    }
  }
}
