defmodule Mix.Tasks.Compile.SubscriptionWorker do
  use Mix.Task.Compiler
  @app_dir __DIR__
  def run(_args) do
    source = Path.expand("../../account-proxy", @app_dir)
    output = Path.join(@app_dir, "priv/subscription_worker")
    # Release image builds supply the binary from the Go build stage.
    if File.dir?(source) do
      case System.cmd("make", ["-s", "-C", source, "OUT=" <> output], stderr_to_stdout: true) do
        {_, 0} -> {:ok, []}
        {message, _} -> Mix.raise("subscription worker build failed: " <> message)
      end
    else
      {:noop, []}
    end
  end
end

defmodule Mix.Tasks.Compile.TailcatGateway do
  use Mix.Task.Compiler
  @app_dir __DIR__
  def run(_args) do
    source = Path.expand("../../tailcat-gateway", @app_dir)
    output = Path.join(@app_dir, "priv/tailcat_gateway")
    # Release image builds supply the binary from the Go build stage.
    if File.dir?(source) do
      case System.cmd("make", ["-s", "-C", source, "OUT=" <> output], stderr_to_stdout: true) do
        {_, 0} -> {:ok, []}
        {message, _} -> Mix.raise("tailcat gateway build failed: " <> message)
      end
    else
      {:noop, []}
    end
  end
end

defmodule Mix.Tasks.Compile.Spinfoam do
  @moduledoc """
  Stages the pinned prebuilt spinfoam runtime (background Loops) into this
  app's `priv/spinfoam` by downloading the release package for this platform
  and verifying its digest. The release image supplies the same binary from
  its fetch stage. A platform without a release package compiles fine and
  reports background loops unavailable at runtime (fail closed, no fallback).
  """
  use Mix.Task.Compiler
  @app_dir __DIR__

  def run(_args) do
    script = Path.expand("../../native/spinfoam/fetch.sh", @app_dir)
    output = Path.join(@app_dir, "priv/spinfoam")

    cond do
      File.exists?(output) and System.get_env("SPINFOAM_REBUILD") in [nil, "", "0"] ->
        {:noop, []}

      not File.exists?(script) ->
        {:noop, []}

      true ->
        case System.cmd("bash", [script, "OUT=" <> output], stderr_to_stdout: true) do
          {_, 0} ->
            {:ok, []}

          {_message, 3} ->
            Mix.shell().info(
              "spinfoam: no release package for this platform; background loops stay unavailable locally"
            )

            {:noop, []}

          {message, _} ->
            Mix.raise("spinfoam fetch failed: " <> message)
        end
    end
  end
end

defmodule SalixAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:subscription_worker, :tailcat_gateway, :spinfoam] ++ Mix.compilers(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssh],
      mod: {SalixAgent.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:systems_observability, in_umbrella: true},
      {:salix_ifc, in_umbrella: true},
      {:salix_store, in_umbrella: true},
      {:salix_media, in_umbrella: true},
      {:salix_verified_kernel, path: "../../native/verified_kernel"},
      {:req, "~> 0.5"},
      {:mint, "~> 1.0"},
      {:mint_web_socket, "~> 1.0.6"},
      {:jason, "~> 1.4"},
      {:floki, "~> 0.38.4"},
      {:ex_json_schema, "~> 0.11"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:bandit, "~> 1.5", only: :test},
      {:plug, "~> 1.16", only: :test},
      {:websock_adapter, "~> 0.5", only: :test}
    ]
  end
end
