defmodule SalixWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_web,
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
      # :inets — :httpd_util.convert_request_date for If-Modified-Since.
      extra_applications: [:logger, :inets, :ssh],
      mod: {SalixWeb.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:salix_store, in_umbrella: true},
      {:salix_agent, in_umbrella: true},
      {:salix_im, in_umbrella: true},
      {:salix_mcp, in_umbrella: true},
      {:salix_meet, in_umbrella: true},
      {:salix_calendar, in_umbrella: true},
      {:salix_env, in_umbrella: true},
      {:salix_cluster, in_umbrella: true},
      # Voice call core: Twilio and comma.voice.v1 carrier sockets live here.
      {:salix_voice, in_umbrella: true},
      {:salix_signal, in_umbrella: true},
      # Compile the sourced-context processor contract without making Salix
      # start the BFT subsystem on Salix-only nodes.
      {:bridge_for_teams_core, in_umbrella: true, runtime: false},
      # Site LLM proxy (SalixLlm.SiteProxy — willow serveSiteLLM).
      {:salix_llm, in_umbrella: true},
      # Trajectory-eval trend page reads ClickHouse aggregates
      # (SalixAnalytics.TrajectoryEvalQueries).
      {:salix_analytics, in_umbrella: true},
      {:systems_observability, in_umbrella: true},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      {:phoenix_pubsub, "~> 2.1"},
      {:hammer_backend_redis, "~> 7.1"},
      {:redix, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:websockex, "~> 0.5"},
      # Admin dashboard LiveView stack. Served on the SAME Bandit listener as the
      # JSON API (port 4000) via a `/dash` prefix branch in SalixWeb.Endpoint that
      # delegates to SalixWeb.DashboardEndpoint (a `server: false` Phoenix endpoint).
      {:phoenix, "~> 1.7.14"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_template, "~> 1.0"},
      # Phoenix LiveDashboard (mounted under /dash/live-dashboard behind the
      # admin-token auth). It reads the shared metric definitions.
      {:phoenix_live_dashboard, "~> 0.8"},
      {:mdex, "~> 0.13"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
