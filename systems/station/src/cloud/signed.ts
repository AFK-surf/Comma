// What the station posts to its control plane signed with its key (the Rust station's feedback.rs `send`, notify.rs):
// the body's sha256 under "<tag>:<origin>:<station>:<ts>:<digest>", in the x-stillfail-* headers (and x-ember-* where
// the Rust sends those too). Comma reads the same headers (contract §1).
import { nowSecs } from "../ops/files.ts";
import { type StationKey, sha256hex } from "./key.ts";
import type { Cloud } from "./state.ts";

export async function signedPost(cloud: Cloud, key: StationKey, path: string, tag: string, value: unknown, former = false, name = "still.fail cloud"): Promise<any> {
  const s = cloud.state;
  if (s === null) throw new Error(`this station is not in ${name}`);
  const body = JSON.stringify(value);
  const ts = nowSecs();
  const signature = key.sign(`${tag}:${s.origin}:${s.station}:${ts}:${sha256hex(body)}`);
  const headers: Record<string, string> = { "content-type": "application/json" };
  for (const prefix of former ? ["stillfail", "ember"] : ["stillfail"]) {
    headers[`x-${prefix}-station`] = s.station;
    headers[`x-${prefix}-ts`] = String(ts);
    headers[`x-${prefix}-signature`] = signature;
  }
  const response = await fetch(`${s.origin}${path}`, { method: "POST", headers, body, signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`${name} answered ${response.status}: ${await response.text().catch(() => "")}`);
  const text = await response.text();
  return text === "" ? null : JSON.parse(text);
}
