defmodule SalixIFC.MixProject do
  use Mix.Project

  # Pure information-flow facade. No supervision tree and no domain
  # I/O. Every decision about whether labelled content may flow to a
  # destination is computed in Lean from explicit finite facts supplied by the
  # caller. Impure resolvers (membership projections, receipt stores, policy
  # records, the clock) live in the calling apps. Structs and the storage
  # codec remain here. The native package owns decisions and runtime proofs.
  def project do
    [
      app: :salix_ifc,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: []]
  end

  # The only runtime dependency is the generic, statically linked Lean kernel.
  defp deps do
    [
      {:salix_verified_kernel, path: "../../native/verified_kernel"},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
