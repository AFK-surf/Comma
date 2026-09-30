defmodule SalixVoice.Application do
  @moduledoc """
  Voice call supervision (docs/messaging-voice.md).

  Starts the `:pg` scope `SalixVoice.PG` that locates calls across the
  cluster, a `Task.Supervisor` for work a call hands off (Router ingress,
  billing), and the `SalixVoice.CallSupervisor` that runs one
  `SalixVoice.CallActor` per live call on the node that holds its media.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{id: SalixVoice.PG, start: {:pg, :start_link, [SalixVoice.PG]}},
      {Task.Supervisor, name: SalixVoice.TaskSupervisor},
      {DynamicSupervisor, name: SalixVoice.CallSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SalixVoice.Supervisor)
  end
end
