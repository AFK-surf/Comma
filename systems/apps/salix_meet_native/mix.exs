defmodule SalixMeetNative.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_meet_native,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {SalixMeetNative.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:systems_clock, in_umbrella: true},
      {:protobuf, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.6"},
      {:ex_ice, "~> 0.16.1"},
      {:ex_dtls, "~> 0.18.1"},
      {:ex_libsrtp, "~> 0.7.4"},
      {:ex_sctp, "~> 0.1.3"},
      {:ex_rtp, "~> 0.4.1"},
      {:ex_rtcp, "~> 0.4.2"},
      {:membrane_core, "~> 1.0"},
      {:decimal, "~> 3.1", override: true},
      {:membrane_opus_plugin, "== 0.21.0"},
      {:membrane_audio_mix_plugin, "~> 0.16.5"},
      {:membrane_ogg_plugin, "~> 0.5.2"},
      {:membrane_file_plugin, "~> 0.17"},
      {:plug, "~> 1.16", only: :test}
    ] ++ private_deps()
  end

  defp private_deps do
    for mix_file <- Path.wildcard(Path.expand("../../private/*/mix.exs", __DIR__)) do
      dir = Path.dirname(mix_file)
      {dir |> Path.basename() |> String.to_atom(), path: dir}
    end
  end
end
