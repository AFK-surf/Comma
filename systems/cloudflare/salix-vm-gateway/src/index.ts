import { getSandbox, Sandbox } from "@cloudflare/sandbox";
import { createGateway, type GatewayEnv } from "./app";
export { Sandbox } from "@cloudflare/sandbox";
export class SandboxStandard1 extends Sandbox {}
export { ReplayGuard } from "./replay_guard";

export default createGateway<GatewayEnv>({
  getSandbox(env, id, opts, profile) {
    return getSandbox(profile === "cf-standard-1" ? env.SandboxStandard1 : env.Sandbox, id, {
      keepAlive: opts?.keepAlive,
      transport: "rpc",
    });
  },
});
