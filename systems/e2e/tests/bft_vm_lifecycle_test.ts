import { setDefaultTimeout, test } from "bun:test";
import { runVmLifecycle } from "../helpers/vm_lifecycle.ts";

// Builds and subprocesses here take longer than the five-second default.
setDefaultTimeout(30 * 60_000);

test("BridgeForTeams Cloudflare VM lifecycle", async () => {
  await runVmLifecycle("bft", "cloudflare");
});
