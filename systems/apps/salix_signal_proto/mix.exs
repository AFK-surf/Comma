defmodule SalixSignalProto.MixProject do
  use Mix.Project

  # Pure Signal protocol core: no processes, no storage, no network. Every
  # public function is a deterministic function of its inputs (randomness is
  # an explicit argument where the algorithm takes one), so each can be
  # differential-tested against the external oracle.
  #
  # Secret-dependent curve operations run in one small C NIF over libsodium
  # (c_src/). The build needs the libsodium headers and pkg-config; the
  # release image needs the libsodium runtime library.
  def project do
    [
      app: :salix_signal_proto,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      # Protobuf codecs with schemas written from the CRS (PLAN "Libraries").
      {:protobuf, "~> 0.17"},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
