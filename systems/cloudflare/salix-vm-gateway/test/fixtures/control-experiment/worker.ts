// Isolated experiment entrypoint. Never use this module in a serving Gateway.
import { Sandbox as SDKSandbox } from "@cloudflare/sandbox";
import { ManagedSandbox } from "../../../src/managed_sandbox";
import { createGateway, type GatewayEnv } from "../../../src/app";
import { authorize } from "../../../src/auth";
import { parseControlPermit, type ControlPermit } from "../../../src/control";
export { ReplayGuard } from "../../../src/replay_guard";

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

class ExperimentSandbox extends ManagedSandbox {
  async experimentDelayed(action: string, permit: ControlPermit, delay: number) {
    await pause(delay);
    return action === "ensure" ? this.salixEnsure(permit, true) : Response.json(await this.salixDestroy(permit));
  }

  async experimentTimedImport(permit: ControlPermit, delay: number) {
    const imported = this.salixForward(permit, new Request("http://localhost:8080/archive", {
      method: "POST", body: JSON.stringify({ action: "finish", operation: "fixture-import", delay_ms: delay }),
    }), "import", "fixture-import");
    this.ctx.waitUntil(imported.then(() => undefined, () => undefined));
    return Promise.race([imported, pause(250).then(() => Response.json({ timed_out: true }, { status: 504 }))]);
  }

  experimentEvict() { this.ctx.abort("isolated control experiment eviction"); }
  async experimentCleanup() { await this.ctx.container!.destroy(); return { running: this.ctx.container!.running }; }
}

export class Sandbox extends ExperimentSandbox {}
export class SandboxStandard1 extends ExperimentSandbox {}

export class LegacySandbox extends SDKSandbox {
  #delay = 0;
  override async onStart() {}
  override async startAndWaitForPorts(...args: Parameters<SDKSandbox["startAndWaitForPorts"]>) {
    await pause(this.#delay);
    return super.startAndWaitForPorts(...args);
  }
  async experimentLateStart(delay: number) {
    this.#delay = delay;
    const probe = this.containerFetch(new Request("http://localhost:8080/readyz"), 8080);
    await pause(250);
    await this.ctx.container!.destroy();
    const response = await probe;
    return { response: response.status, running_after_destroy: this.ctx.container!.running };
  }
  async experimentCleanup() { await this.ctx.container!.destroy(); return { running: this.ctx.container!.running }; }
}

type Env = Omit<GatewayEnv, "Sandbox" | "SandboxStandard1"> & {
  Sandbox: DurableObjectNamespace<Sandbox>;
  SandboxStandard1: DurableObjectNamespace<SandboxStandard1>;
  LegacySandbox: DurableObjectNamespace<LegacySandbox>;
};
const gateway = createGateway<GatewayEnv>({ getSandbox: (env, id, profile) => {
  const binding = profile === "cf-standard-1" ? env.SandboxStandard1 : env.Sandbox;
  return binding.get(binding.idFromName(id));
} });

export default {
  async fetch(request: Request, env: Env) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/experiment/")) return gateway.fetch(request, env as unknown as GatewayEnv);
    const auth = await authorize(request, env);
    if (!auth.ok) return auth.response;
    const match = /^\/experiment\/(standard1|standard2|legacy)\/(exp-[a-z0-9-]+)\/(delay-ensure|delay-destroy|timeout-import|evict|legacy-start|cleanup)$/.exec(url.pathname);
    if (!match || request.method !== "POST") return Response.json({ error: "invalid_experiment" }, { status: 400 });
    const [, profile, id, action] = match;
    const body = await request.json() as { control?: unknown; delay_ms?: number };
    const delay = Math.min(15_000, Math.max(1_000, body.delay_ms ?? 2_000));
    try {
      if (profile === "legacy") {
        const stub = env.LegacySandbox.get(env.LegacySandbox.idFromName(id));
        return Response.json(action === "cleanup" ? await stub.experimentCleanup() : await stub.experimentLateStart(delay));
      }
      const binding = profile === "standard1" ? env.SandboxStandard1 : env.Sandbox;
      const stub = binding.get(binding.idFromName(id));
      if (action === "evict") { await stub.experimentEvict(); return new Response(); }
      if (action === "cleanup") return Response.json(await stub.experimentCleanup());
      const permit = parseControlPermit(body.control);
      if (action === "timeout-import") return await stub.experimentTimedImport(permit, delay);
      return await stub.experimentDelayed(action === "delay-ensure" ? "ensure" : "destroy", permit, delay);
    } catch (error) {
      return Response.json({ error: error instanceof Error ? error.message : "experiment_error" }, { status: 409 });
    }
  },
};
