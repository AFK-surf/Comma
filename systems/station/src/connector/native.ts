// The connector's native calls, from the station's mesh addon (native/mesh/src/nofollow.rs).
import { loadMesh } from "../mesh/native.ts";

export type StationNative = {
  openatNofollow(dirFd: number, name: string, directory: boolean): number;
  openDirectoryNofollow(path: string): number;
};

export const stationNative = (): StationNative => loadMesh() as unknown as StationNative;
