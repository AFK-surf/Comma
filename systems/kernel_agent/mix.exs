defmodule KernelAgent.MixProject do
  use Mix.Project

  # A standalone agent runtime over the verified kernel. Its only dependency is
  # the kernel, so every decision it needs must come from Lean.
  def project do
    [
      app: :kernel_agent,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [{:salix_verified_kernel, path: "../native/verified_kernel"}]
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl, :crypto]]
end
