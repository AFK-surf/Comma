import { runAgentVmInteraction } from "../helpers/agent_vm_interaction.ts";

Deno.test({
  name: "Comma agent turn reaches Cloudflare VM through env.exec",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    await runAgentVmInteraction("comma");
  },
});
