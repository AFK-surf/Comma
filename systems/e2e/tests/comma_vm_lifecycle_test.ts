import { runVmLifecycle } from "../helpers/vm_lifecycle.ts";

Deno.test({
  name: "Comma Cloudflare VM lifecycle",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    await runVmLifecycle("comma", "cloudflare");
  },
});
