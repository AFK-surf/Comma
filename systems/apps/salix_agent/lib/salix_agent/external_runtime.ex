defmodule SalixAgent.ExternalRuntime do
  @moduledoc """
  Transport port for sending one input batch to an external runtime.
  """

  @type binding :: %{optional(String.t()) => term()}
  @type request :: %{
          required(:agent_id) => String.t(),
          required(:session_id) => String.t(),
          required(:dispatch_id) => String.t(),
          required(:binding) => binding(),
          required(:input_messages) => [map()],
          required(:system_prompt) => String.t() | nil
        }
  @type response ::
          {:accepted, %{required(String.t()) => term()}}
          | {:error, term()}

  @callback run(request()) :: response()
  @callback stop(map()) :: :ok | {:error, term()}
  @callback migration(map()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks stop: 1, migration: 1

  def migration(request), do: impl().migration(request)

  def stop(request) do
    driver = impl()

    if Code.ensure_loaded?(driver) and function_exported?(driver, :stop, 1),
      do: driver.stop(request),
      else: {:error, :stop_unavailable}
  end

  @spec run(request()) :: response()
  def run(%{} = request), do: impl().run(request)

  @spec impl() :: module()
  defp impl, do: Application.get_env(:salix_agent, :external_runtime_driver, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixAgent.ExternalRuntime

    @impl true
    def run(_request), do: {:error, :external_runtime_driver_not_configured}
  end
end
