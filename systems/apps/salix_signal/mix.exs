defmodule SalixSignal.MixProject do
  use Mix.Project

  # Signal runtime: processes, storage and network on top of the pure
  # protocol core in `salix_signal_proto` (PLAN "Workstream C").
  #
  # Call media needs libopus: the build needs its headers and pkg-config
  # (Debian: libopus-dev pkg-config), the release image the runtime library
  # (libopus0). The NIF is in c_src/.
  def project do
    [
      app: :salix_signal,
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
      extra_applications: [:logger, :crypto],
      mod: {SalixSignal.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:salix_signal_proto, in_umbrella: true},
      {:salix_voice, in_umbrella: true},
      # Durable account state (PLAN "Durable state") and ring placement of
      # the account owner process (PLAN "Design rules").
      {:salix_store, in_umbrella: true},
      {:salix_cluster, in_umbrella: true},
      {:elixir_make, "~> 0.9", runtime: false},
      # ICE and TURN for call media (PLAN "Libraries").
      {:ex_ice, "~> 0.16.1"},
      # Chat WebSocket client for the service client (PLAN "Libraries").
      {:mint_web_socket, "~> 1.0.6"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      # Fake chat service in the service client tests.
      {:bandit, "~> 1.5", only: :test},
      {:websock_adapter, "~> 0.5", only: :test}
    ]
  end
end
