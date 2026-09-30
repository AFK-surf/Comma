# :live_llm runs against a real LLM endpoint (SALIX_E2E_LLM_API_KEY required);
# opt in with `mix test --include live_llm`.
# :activation_latency is a hardware-sensitive performance reproduction. Opt in explicitly.
# The native driver suite launches only the supplied local Chromium executable.
local_browser = if System.get_env("BROWSER_DRIVER_CHROMIUM"), do: [], else: [:browser_local]
ExUnit.start(exclude: [:live_llm, :activation_latency, :browser_live] ++ local_browser)

# Session-work recovery uses the shared SalixStore Postgres projection. Bring
# up and migrate that test database so the SalixAgent suite is independently
# runnable instead of relying on another umbrella app's test helper.
SalixStore.RepoTestSetup.ensure!()
