// Stations kept linked whether shown or not, where the host says so (`StationMeshPorts.alwaysLinked`: the desktop
// app). While an account is signed in, each of its workspaces' stations is followed as if the Stations area showed it
// (activity.ts): a connection to each station, its chats read when its event stream opens and kept on this device, and
// its events followed. So a station's Tasks are current on this device before any view asks for them.
//
// Bounds: what activity.ts and index.ts bound per followed workspace, for each workspace of the account (the control
// plane bounds how many a workspace has); one read of the workspaces per account when none was kept.
import { Effect } from "effect";
import type { Ctx } from "../ctx.ts";
import type { Workspaces } from "../workspaces.ts";
import type { StationActivity } from "./activity.ts";

const HOLDER = "always";

/** Follows the signed-in account's workspaces from now on, where the host stays on. */
export function keepStationsLinked(
  ctx: Ctx,
  workspaces: Workspaces,
  activity: StationActivity
): void {
  if (!ctx.host.stationMesh?.alwaysLinked) return;
  /** The workspaces followed. */
  const held = new Set<string>();
  /** The account whose workspaces were read for this, when none were kept. */
  let read: string | null = null;
  // Follows the account's workspaces, and lets any other go.
  const follow = () => {
    const account = ctx.session.current();
    const list = account ? workspaces.list(account) : null;
    if (account && !list && read !== account.dbName) {
      read = account.dbName;
      ctx.runner.fork(workspaces.refresh().pipe(Effect.ignore));
    }
    const wanted = new Set((list ?? []).map((w) => w.id));
    for (const workspace of held)
      if (!wanted.has(workspace)) {
        held.delete(workspace);
        activity.unhold(workspace, HOLDER);
      }
    for (const workspace of wanted)
      if (!held.has(workspace)) {
        held.add(workspace);
        activity.hold(workspace, HOLDER);
      }
  };
  // The list changes, and so does the account (Workspaces tells both).
  workspaces.onChange(follow);
  follow();
}
