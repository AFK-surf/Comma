import { setDefaultTimeout, test } from "bun:test";
import { runAgentVmInteraction } from "../helpers/agent_vm_interaction.ts";

// Builds and subprocesses here take longer than the five-second default.
setDefaultTimeout(30 * 60_000);

test("BridgeForTeams agent turn reaches Cloudflare VM through env.exec", async () => {
  await runAgentVmInteraction("bft");
});
