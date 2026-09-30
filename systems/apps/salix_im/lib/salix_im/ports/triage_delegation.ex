defmodule SalixIM.Ports.TriageDelegation do
  @moduledoc """
  Outbound port from native Triage to the BFT project/Router authority.

  Prepare/commit revalidate the project, Router and selected Worker around
  source freshness, then create the canonical Task. Current commands return
  created. Immutable legacy decisions without worker_ref retain routed Router
  admission. Worker authorization is checked through this same port.
  """

  @callback prepare(claim :: map(), delegation :: map(), request_id :: String.t()) ::
              {:ok, term()} | {:error, term(), boolean()}
  @callback commit(prepared :: term()) :: {:ok, map()} | {:error, term(), boolean()}
  @callback authorize_target(map(), String.t(), String.t()) ::
              :ok | {:error, term(), boolean()}

  def prepare(claim, delegation, request_id) do
    impl().prepare(claim, delegation, request_id)
  end

  def commit(prepared), do: impl().commit(prepared)

  def authorize_target(original, router_agent_id, worker_agent_id),
    do: impl().authorize_target(original, router_agent_id, worker_agent_id)

  defp impl,
    do: Application.get_env(:salix_im, :triage_delegation_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.TriageDelegation

    @impl true
    def prepare(_claim, _delegation, _request_id),
      do: {:error, :triage_delegation_not_configured, false}

    @impl true
    def commit(_prepared), do: {:error, :triage_delegation_not_configured, false}

    @impl true
    def authorize_target(_original, _router_agent_id, _worker_agent_id),
      do: {:error, :triage_delegation_not_configured, false}
  end
end
