import { createGateway, type GatewayEnv } from "./app";
import { ManagedSandbox } from "./managed_sandbox";
export class Sandbox extends ManagedSandbox {}
export class SandboxStandard1 extends ManagedSandbox {}
export { ReplayGuard } from "./replay_guard";

export default createGateway<GatewayEnv>({
  getSandbox(env, id, profile) {
    const binding = profile === "cf-standard-1" ? env.SandboxStandard1 : env.Sandbox;
    // getSandbox() configures the DO asynchronously, outside the owner permit.
    // idFromName preserves the SDK's existing name -> DO identity mapping.
    return binding.get(binding.idFromName(id));
  },
});
