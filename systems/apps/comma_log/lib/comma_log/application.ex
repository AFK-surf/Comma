defmodule CommaLog.Application do
  @moduledoc """
  Starts the single shared `CommaLog` JSONL logger. As a library dependency of
  every subsystem's storage/core app, this boots before them — so any app's
  startup steps can already log.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [CommaLog]
    Supervisor.start_link(children, strategy: :one_for_one, name: CommaLog.Supervisor)
  end
end
