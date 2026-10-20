// A station profile as the Profiles' logic takes it (systems/profiles: the one Comma's AccountPool runs too, through the
// mesh addon): stored in config.json as that Profile already, with its health (the accounts' check and allowance)
// given as its status and quota.
import { loadMesh } from "../mesh/native.ts";
import type { Profile as RuntimeProfile } from "./runtime.ts";

type Json = any;

/// A station profile with its health, as systems/profiles' Profile.
export function unified(p: RuntimeProfile & Json, health?: { check?: Json | null; quota?: Json | null } | null): Json {
  const out: Json = { ...p, source: typeof p.source === "string" ? p.source : "custom", credential: typeof p.credential === "string" ? p.credential : "env" };
  // What the Profile's logic does not take: the station's own fields, and the hub's derived ones.
  for (const k of ["home", "key", "share", "fast", "background_on_message", "runtimes", "backgroundOnMessage"]) delete out[k];
  if (out.runtime !== "claude" && out.runtime !== "codex") delete out.runtime;
  const state = health?.check?.state;
  out.status = state === "ok" || state === "login" || state === "failed" ? state : "unknown";
  const quota = health?.quota;
  if (quota && quota.state === "ok" && Array.isArray(quota.windows)) {
    out.quota = {
      windows: quota.windows.map((w: Json) => ({
        label: String(w.label ?? ""),
        used_percent: Number(w.usedPercent),
        resets_at: typeof w.resetsAt === "number" ? w.resetsAt : null,
        minutes: typeof w.minutes === "number" ? w.minutes : null,
      })),
      observed_at: typeof quota.checkedAt === "number" && quota.checkedAt > 0 ? quota.checkedAt : null,
    };
  }
  return out;
}

export const profilesNative = () => loadMesh();
