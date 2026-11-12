// The Comma station as the connector of an e2e scenario. STATION_E2E_APP names
// a station release for this machine (systems/station/scripts/bundle.sh DIR
// PLATFORM, which CI runs before the tests); this writes an executable that
// runs it with the connector flags the scenario passes. The scenarios start
// that executable as STATION_CONNECTOR_BIN.
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type StationConnector = { bin: string; cleanup: () => Promise<void> };

export async function stationConnector(): Promise<StationConnector> {
  const app = process.env.STATION_E2E_APP;
  if (!app) {
    throw new Error(
      "STATION_E2E_APP is not set: lay out the station first (sh systems/station/scripts/bundle.sh DIR PLATFORM)",
    );
  }
  const root = await mkdtemp(join(tmpdir(), "e2e-station-"));
  // Each run has its own data directory, and ends with the scenario that started it.
  const bin = join(root, "station-connector");
  await writeFile(
    bin,
    `#!/bin/sh
data=$(mktemp -d "${root}/data.XXXXXX")
exec "${app}/mesh/target/release/comma-station" run --app "${app}" --data "$data" --with-parent -- "$@"
`,
  );
  await chmod(bin, 0o755);
  return { bin, cleanup: () => rm(root, { recursive: true, force: true }) };
}
