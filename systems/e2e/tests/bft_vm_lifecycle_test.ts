import { runVmLifecycle } from "../helpers/vm_lifecycle.ts";

Deno.test({
  name: "BridgeForTeams Cloudflare VM lifecycle",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    await runVmLifecycle("bft", "cloudflare");
  },
});
