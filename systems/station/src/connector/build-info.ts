// Release provenance reported in metadata and the status file. The component keeps the name Salix already keys
// releases and installs by ("salix-connect"); the station replaces that component in place.
import type { BuildInfo } from "./status.ts";
import { goArch, goOs } from "./system-info.ts";

export const COMPONENT_NAME = "salix-connect";

export function currentBuildInfo(overrides: { releaseId?: string } = {}): BuildInfo {
  return {
    component: COMPONENT_NAME,
    version: process.env.COMMA_STATION_VERSION ?? "dev",
    release_id: overrides.releaseId ?? process.env.COMMA_STATION_RELEASE_ID ?? "development",
    commit: process.env.COMMA_STATION_COMMIT ?? "unknown",
    built_at: process.env.COMMA_STATION_BUILT_AT ?? "unknown",
    goos: goOs(),
    goarch: goArch(),
    go_version: `node ${process.version}`,
  };
}
