import {
  pathWithAsdf,
  resolveProviderEnv,
  run,
  startPostgres,
  type VmProvider,
  type VmSurface,
} from "./vm_lifecycle.ts";

const SALIX_ROOT = new URL("../..", import.meta.url).pathname;
const DEFAULT_TIMEOUT_MS = 10 * 60_000;

export type RunAgentVmInteractionOptions = {
  provider?: VmProvider;
  timeoutMs?: number;
};

export async function runAgentVmInteraction(
  surface: VmSurface,
  opts: RunAgentVmInteractionOptions = {},
) {
  const provider = opts.provider ?? "cloudflare";
  const providerEnv = await resolveProviderEnv([provider]);
  if (providerEnv.skip) return skipOrThrow(providerEnv.skip);

  const pg = await startPostgres();

  try {
    await run("mix", ["run", "scripts/agent_vm_interaction_e2e.exs"], {
      cwd: SALIX_ROOT,
      timeoutMs: opts.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      env: {
        ...Deno.env.toObject(),
        ...providerEnv.env,
        PATH: pathWithAsdf(),
        MIX_ENV: "test",
        BRIDGE_TEST_DB_PORT: String(pg.port),
        BILLING_TEST_DB_PORT: String(pg.port),
        COMMA_TEST_DB_PORT: String(pg.port),
        SALIX_AGENT_VM_E2E_SURFACE: surface,
        SALIX_AGENT_VM_E2E_PROVIDER: provider,
        SALIX_VM_E2E_TIMEOUT_MS:
          Deno.env.get("SALIX_VM_E2E_TIMEOUT_MS") ?? "300000",
      },
    });
  } finally {
    await Promise.allSettled(providerEnv.cleanup.map((cleanup) => cleanup()));
    await pg.close();
  }
}

function skipOrThrow(message: string) {
  if (Deno.env.get("SALIX_VM_E2E_STRICT") === "1") throw new Error(message);
  console.log(`AGENT_VM_INTERACTION_E2E: SKIP ${message}`);
}
