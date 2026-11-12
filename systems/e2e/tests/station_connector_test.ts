import { setDefaultTimeout, test } from "bun:test";
import { remote } from "./station_connector_cases.ts";

// Builds and subprocesses here take longer than the five-second default.
setDefaultTimeout(30 * 60_000);

test(remote.name, remote.fn);
