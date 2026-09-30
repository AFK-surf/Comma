defmodule Comma do
  @moduledoc """
  The Comma systems launcher.

  The umbrella ships as one release (`comma`) inside a single Docker image, but a
  pod can run one or several **subsystems** from that one artifact. Each
  subsystem is a set of OTP applications; in the release those apps are bundled
  in `:load` mode (loaded, not started), and this app starts only the ones
  selected for the node.

  Selection comes from `:enabled_subsystems` in app env — set by
  `config/runtime.exs` from the `COMMA_SUBSYSTEMS` env var (comma-separated
  subsystem names) — and defaults to every subsystem in the build.

  See `Comma.Application` for the boot path.
  """

  # Subsystem -> its OTP applications, in start order. The same apps are listed
  # as `:load` in the umbrella release (../../mix.exs); keep the two in sync
  # when a subsystem's app set changes. Add a new subsystem by adding an entry
  # here and listing its apps as `:load` in the release.
  @subsystems %{
    alert_router: [
      :alert_router
    ],
    salix: [
      :salix_store,
      :salix_calendar,
      :salix_analytics,
      :billing_core,
      :billing_commerce,
      :billing_stripe,
      :salix_agent,
      :salix_cluster,
      :salix_llm,
      :salix_env,
      :salix_im,
      :salix_voice,
      :salix_signal_proto,
      :salix_signal,
      :salix_mcp,
      :salix_web,
      :salix_migrate,
      :salix_media,
      :salix_meet
    ],
    comma_product: [
      :billing_core,
      :billing_commerce,
      :billing_stripe,
      :comma_core,
      :comma_web,
      :comma_tui,
      :comma_ssh
    ],
    bridge_for_teams: [
      :billing_core,
      :billing_commerce,
      :bridge_for_teams_core,
      :bridge_for_teams_web
    ]
  }

  @doc "Every subsystem known to this build."
  def known_subsystems, do: Map.keys(@subsystems)

  @doc "The OTP applications comprising `subsystem`, in start order."
  def apps(subsystem), do: Map.fetch!(@subsystems, subsystem)

  @doc """
  The subsystems enabled for this node: `:enabled_subsystems` from app env when
  set (see `config/runtime.exs`), otherwise every known subsystem.
  """
  def enabled_subsystems do
    case Application.fetch_env(:comma, :enabled_subsystems) do
      {:ok, list} when is_list(list) -> list
      _ -> known_subsystems()
    end
  end
end
