defmodule SystemsObservability.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    SystemsObservability.Resource.put_current()
    :ok = SystemsObservability.Instrumentation.setup()

    Supervisor.start_link([SystemsObservability.Runtime],
      strategy: :one_for_one,
      name: SystemsObservability.Supervisor
    )
  end
end
