// Stations kept linked whether shown or not, where the host says so (`StationMeshPorts.alwaysLinked`: the desktop
// app). While an account is signed in, each of its workspaces is followed as if the Stations area showed it (activity.ts),
// but only for the stations that host a Task of it not yet finished (as the device keeps the Task index,
// ../station-tasks.ts) and the person's own computers: a connection to each, its chats read when its event stream opens
// and kept on this device, and its events followed. So a Task's station says whether it asks its person anything
// before any view asks. Every other station is linked only while a view shows the workspace's stations; its presence
// comes from the workspace's station events meanwhile (index.ts).
//
// Bounds: what activity.ts and index.ts bound per followed workspace, for each workspace of the account (the control
// plane bounds how many a workspace has), with connections only to the stations hosting an unfinished Task and the
// person's own computers; one read of the workspaces per account when none was kept.
import { Effect } from "effect";
import type { Ctx } from "../ctx.ts";
import type { StationTasks } from "../station-tasks.ts";
import type { Workspaces } from "../workspaces.ts";
import type { StationActivity } from "./activity.ts";

const HOLDER = "always";

/** Follows the signed-in account's workspaces from now on, where the host stays on. */
export function keepStationsLinked(
  ctx: Ctx,
  workspaces: Workspaces,
  tasks: StationTasks,
  activity: StationActivity
): void {
  if (!ctx.host.stationMesh?.alwaysLinked) return;
  /** The workspaces followed, with the stations followed in each. */
  const held = new Map<string, ReadonlySet<string>>();
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
    for (const workspace of held.keys())
      if (!wanted.has(workspace)) {
        held.delete(workspace);
        activity.unhold(workspace, HOLDER);
      }
    for (const workspace of wanted) {
      const hosts = tasks.openHosts(workspace);
      const before = held.get(workspace);
      if (
        before &&
        before.size === hosts.size &&
        [...hosts].every((id) => before.has(id))
      )
        continue;
      held.set(workspace, hosts);
      activity.hold(workspace, HOLDER, hosts);
    }
  };
  // The list changes, and so does the account (Workspaces tells both); the kept Tasks move their stations.
  workspaces.onChange(follow);
  tasks.onKept(follow);
  follow();
}
