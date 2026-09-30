import { isAbsolute } from "node:path";
import type { SynchronicityProvider } from "./index";

/** The existing default Drive mount, including a custom or retained legacy source. */
export async function resolveLocalDriveTarget(
  drive: Pick<SynchronicityProvider, "state">
) {
  const state = await drive.state();
  const source = state.spaces.find((space) => space.id === state.defaultSpace);
  const localRoot = source?.sourcePath;
  if (
    state.status !== "ready" ||
    !state.defaultSpace ||
    !localRoot ||
    !isAbsolute(localRoot)
  )
    throw new Error("Drive is unavailable. Open Drive and try again.");
  return { localRoot, space: state.defaultSpace };
}
