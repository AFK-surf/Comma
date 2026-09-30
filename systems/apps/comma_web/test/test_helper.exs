Code.require_file("support/repo_sandbox.ex", __DIR__)
Code.require_file("support/convergence.ex", __DIR__)

ExUnit.start()

# Match the completed online-release state used by the other product suites,
# including when CommaWeb tests run without loading the BFT test helpers.
:ok = SalixStore.AgentConfigurationRollout.open()
:ok = SalixStore.AgentConfigurationRollout.complete()
