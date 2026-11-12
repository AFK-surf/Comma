// A desktop's own station on the mesh, with no enrollment and no roster row: each Workspace the app is signed in to is
// a Connector run in its Group, and a run that proves the station's key can ask Salix for that Group's facts (the
// workspace ids a credential may name, the keys, the revocations, the device's owner). One key thus serves several
// Groups: a credential's `ws` picks the run whose facts judge it. cloud.json holds one workspace and the roster holds a
// key in one Group; neither fits a desktop, and a roster row would show the computer to every member.
//
// A computer is its owner's. A credential is admitted only for the owner of the device in that Group: another member,
// or a read-only one, is refused here whatever Salix issued them. Salix says again about each minute what it says of the
// Group, so a lost role is usually heard of within that: a refresh period, not a promise, as a push can be late or lost.
//
// A run seen to drop (a blip to Salix) leaves what is open running for at most GRACE_MS and never past the credential's
// expiry: a direct path does not go with Salix. Nothing new is admitted meanwhile, and past it the connections close.
// The grace starts when the drop is detected. A network that goes silent takes the read timeout to detect
// (WEBSOCKET_READ_TIMEOUT, connector.ts), so a revocation may go unheard for that long plus GRACE_MS, about 105 seconds.
// A run that ends on purpose (signed out, the setting turned off) or that Salix took back ends them at once.
import { COMMA } from "../cloud/provider.ts";
import { workspaceIds } from "../cloud/state.ts";
import { wall } from "../ops/fibers.ts";
import { type Admitted, type Revocation, readOnly, revoked, verifyMember } from "./credential.ts";

/// How long what is open outlives a run after its drop was detected.
export const GRACE_MS = 60_000;

export type DeviceMeshFacts = {
  workspace: string;
  workspace_was?: string[];
  grant_keys: unknown;
  revocations: Revocation[];
  /// The Comma user who owns this device in the Group: the only person admitted for it.
  owner: string;
  relay_urls: string[];
  /// Which way goes first (`RoutePolicy`, @comma/mesh); none: `salix-first`.
  route_policy?: string;
};

const strings = (value: unknown): string[] => (Array.isArray(value) ? value.filter((s): s is string => typeof s === "string" && s !== "") : []);

/// The facts as Salix said them; null when they name no one to admit, as Salix's null says: it admits no one.
export function deviceMeshFacts(raw: unknown): DeviceMeshFacts | null {
  const facts = raw as Record<string, unknown> | null | undefined;
  if (typeof facts?.workspace !== "string" || facts.workspace === "" || typeof facts.owner !== "string" || facts.owner === "") return null;
  return {
    workspace: facts.workspace,
    workspace_was: strings(facts.workspace_was),
    grant_keys: facts.grant_keys,
    revocations: Array.isArray(facts.revocations) ? (facts.revocations as Revocation[]) : [],
    owner: facts.owner,
    relay_urls: strings(facts.relay_urls),
    ...(typeof facts.route_policy === "string" ? { route_policy: facts.route_policy } : {}),
  };
}

/// The workspace a credential says it is for, not yet verified.
function workspaceOf(credential: string): string {
  try {
    const ws = JSON.parse(Buffer.from(credential.split(".")[1] ?? "", "base64url").toString()).ws;
    return typeof ws === "string" ? ws : "";
  } catch {
    return "";
  }
}

export class DeviceMeshAdmissions {
  /// Each run's facts, by the connection that was told them.
  readonly #runs = new Map<object, DeviceMeshFacts>();
  /// The runs that dropped, each with what ends its grace.
  readonly #dropped = new Map<object, () => void>();
  readonly #listeners = new Set<() => void>();

  /// What the run `via` was told now; null: it admits no one (it ended, or Salix took its facts back).
  set(via: object, facts: DeviceMeshFacts | null): void {
    this.#dropped.get(via)?.();
    this.#dropped.delete(via);
    if (facts) {
      this.#runs.set(via, facts);
      // The run that replaces one that dropped is the one that knows: what it says stands, a revocation above all.
      for (const [other, cancel] of this.#dropped) {
        if (this.#runs.get(other)?.workspace !== facts.workspace) continue;
        cancel();
        this.#dropped.delete(other);
        this.#runs.delete(other);
      }
    } else if (!this.#runs.delete(via)) return;
    for (const listener of [...this.#listeners]) listener();
  }

  /// The connection to Salix that told `via` went, and may come back.
  dropped(via: object, graceMs: number = GRACE_MS): void {
    if (!this.#runs.has(via) || this.#dropped.has(via)) return;
    this.#dropped.set(via, wall.after(graceMs, () => this.set(via, null)));
  }

  active(): boolean {
    return this.#runs.size > 0;
  }

  /// Every run's relays, each once: a run's Salix names them, so changing them is that Salix's configuration.
  relays(): string[] {
    return [...new Set([...this.#runs.values()].flatMap((facts) => facts.relay_urls))];
  }

  /// Which way goes first, as a run's Salix says: `relay-first` only when every run does, Salix's own Group's say. Read
  /// when the endpoint binds, with the runs there at that moment: later words move nothing until it is bound again.
  routePolicy(): string | undefined {
    const said = [...this.#runs.values()].map((facts) => facts.route_policy);
    return said.length > 0 && said.every((policy) => policy === "relay-first") ? "relay-first" : undefined;
  }

  /// The one place that says who sees this computer's screens, and who drives it: its owner, as admitted. Several people
  /// on one computer, later, is a change here and to nothing on the wire.
  mayView(admitted: Admitted): boolean {
    return this.holds(admitted);
  }

  mayControl(admitted: Admitted): boolean {
    return this.holds(admitted) && !readOnly(admitted.viewer);
  }

  /// The member `credential` names, when it is this device's owner; a refusal otherwise.
  admit(credential: string, peer: string): Admitted {
    if (this.#runs.size === 0) throw new Error("this computer is in no workspace");
    // The workspace it says picks the run that judges it; verifyMember then checks every word of it. One that dropped
    // may not know of a revocation: it admits no one.
    const ws = workspaceOf(credential);
    const facts = [...this.#runs].find(([via, run]) => !this.#dropped.has(via) && workspaceIds(run).includes(ws))?.[1];
    if (!facts) throw new Error("credential is for another workspace");
    const admitted = verifyMember(credential, facts.grant_keys, workspaceIds(facts), peer, facts.revocations, COMMA.credential);
    if (admitted.viewer.sub !== facts.owner) throw new Error("only this computer's owner may reach it");
    if (readOnly(admitted.viewer)) throw new Error("a read-only member may not reach this computer");
    return admitted;
  }

  /// Whether a credential admitted earlier still holds: unexpired, its run is there, for the same owner, and has not
  /// revoked it.
  holds(admitted: Admitted): boolean {
    if (admitted.exp * 1000 <= wall.now()) return false;
    return [...this.#runs.values()].some(
      (facts) => workspaceIds(facts).includes(admitted.viewer.workspace) && facts.owner === admitted.viewer.sub && !revoked(admitted, facts.revocations),
    );
  }

  /// Told at each change of what any run says; gives the function that stops it.
  listen(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => void this.#listeners.delete(listener);
  }
}
