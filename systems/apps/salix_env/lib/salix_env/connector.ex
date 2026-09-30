defmodule SalixEnv.Connector do
  @moduledoc """
  Behaviour for dispatching a request to a live connector run.

  A connector is the transport that carries a small request envelope to a
  registered `salix-connect` session and returns its response. The registry
  (`SalixEnv.Registry`) tracks the current run and its owner node; this
  behaviour is the dispatch transport for one run. Keeping it a behaviour lets
  the real transport and the in-memory `SalixEnv.Connector.Fake` be swapped via
  config without touching call sites.

  `dispatch/2` takes the current `connector_run_id`.
  """

  @type connector_run_id :: String.t()
  @type request :: map()
  @type response :: map()

  @callback dispatch(connector_run_id(), request()) ::
              {:ok, response()} | {:error, :disconnected} | {:error, term()}

  @doc "Dispatch via the configured connector backend (`:salix_env, :connector`)."
  @spec dispatch(connector_run_id(), request()) :: {:ok, response()} | {:error, term()}
  def dispatch(connector_run_id, request), do: backend().dispatch(connector_run_id, request)

  defp backend, do: Application.get_env(:salix_env, :connector, SalixEnv.Connector.Fake)
end
