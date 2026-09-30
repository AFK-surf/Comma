defmodule SalixMeet.Application do
  @moduledoc """
  Meeting-layer supervision. Starts a unique `Registry` keyed by
  meeting id and a `DynamicSupervisor` that runs one `SalixMeet.Meeting` per
  live meeting. Leadership is held by CAS-renewing `meet/{id}/state.json`, so
  meetings survive node loss and are resumable on restart.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    warn_runtime_driver_conflict()

    children =
      [
        {Registry, keys: :unique, name: SalixMeet.Registry},
        # Bounded reads run here with `async_nolink/2`, so a crashing read is a
        # typed `{:exit, _}` for the caller instead of a linked kill.
        {Task.Supervisor, name: SalixMeet.TaskSupervisor},
        {DynamicSupervisor, name: SalixMeet.MeetingSup, strategy: :one_for_one}
      ] ++ projection_auditor_child() ++ delivery_child()

    opts = [strategy: :one_for_one, name: SalixMeet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc "Start (or resume) the meeting process for `id`."
  def start_meeting(id, opts \\ []) do
    spec = {SalixMeet.Meeting, [id: id] ++ opts}
    DynamicSupervisor.start_child(SalixMeet.MeetingSup, spec)
  end

  defp delivery_child do
    case Application.get_env(:salix_meet, :delivery) do
      opts when is_list(opts) -> [{SalixMeet.Delivery, opts}]
      _ -> []
    end
  end

  # `meetings.runtime_url` takes precedence over `meetings.driver` in
  # config/runtime.exs. Both being set almost always means a stale example
  # runtime_url is silently disabling the connector driver — every calendar
  # join then targets the HTTP runtime instead. Warn loudly at boot.
  defp warn_runtime_driver_conflict do
    url = Application.get_env(:salix_meet, :runtime_base_url)
    mode = Application.get_env(:salix_meet, :runtime_driver_mode)

    if is_binary(url) and String.trim(url) != "" and is_binary(mode) and
         String.trim(mode) == "connector" do
      Logger.warning(
        "meetings.runtime_url overrides meetings.driver=\"connector\": " <>
          "the HTTP meeting runtime driver is in effect, not the connector driver"
      )
    end

    :ok
  end

  defp projection_auditor_child do
    case Application.get_env(:salix_meet, :meeting_group_projection_auditor) do
      opts when is_list(opts) -> [{SalixMeet.MeetingGroupProjectionAuditor, opts}]
      _ -> []
    end
  end
end
