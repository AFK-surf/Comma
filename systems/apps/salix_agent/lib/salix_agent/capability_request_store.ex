defmodule SalixAgent.CapabilityRequestStore do
  @moduledoc """
  Agent-facing durable capability request write seam.

  Tests can replace the active implementation through
  `:capability_request_store_mod`. Production defaults to
  `SalixAgent.CapabilityRequests`.
  """

  @callback create_capability_request(attrs :: %{optional(String.t() | atom()) => term()}) ::
              {:ok, map()} | {:error, term()}

  @doc "Optional read-only pending query for capability surfaces; recovery uses reconciliation."
  @callback pending_capability_request?(
              agent_id :: String.t(),
              session_id :: String.t(),
              tool_call_id :: String.t()
            ) :: boolean()

  @callback cancel_capability_request(
              agent_id :: String.t(),
              session_id :: String.t(),
              tool_call_id :: String.t(),
              reason :: String.t()
            ) :: {:ok, map() | :not_found} | {:error, term()}

  @callback reconcile_capability_request(String.t(), String.t(), String.t(), map() | nil) ::
              {:ok, map() | :not_found} | {:error, term()}

  @optional_callbacks pending_capability_request?: 3, reconcile_capability_request: 4

  @doc "The configured implementation module."
  @spec impl() :: module()
  def impl,
    do:
      Application.get_env(
        :salix_agent,
        :capability_request_store_mod,
        SalixAgent.CapabilityRequests
      )

  @spec create_capability_request(%{optional(String.t() | atom()) => term()}) ::
          {:ok, map()} | {:error, term()}
  def create_capability_request(attrs) when is_map(attrs) do
    impl().create_capability_request(attrs)
  end

  def execution_fields(request) when is_map(request) do
    deadline =
      cond do
        not is_map(request["result"]) and is_integer(request["settlement_deadline_ms"]) ->
          request["settlement_deadline_ms"]

        is_integer(request["expires_at"]) ->
          request["expires_at"] * 1_000

        true ->
          1
      end

    %{
      "capability_request_id" => request["request_id"],
      "capability_deadline_ms" => deadline
    }
  end

  @spec cancel_capability_request(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map() | :not_found} | {:error, term()}
  def cancel_capability_request(agent_id, session_id, tool_call_id, reason) do
    impl().cancel_capability_request(agent_id, session_id, tool_call_id, reason)
  end

  def reconcile_capability_request(agent_id, session_id, tool_call_id, execution_result \\ nil) do
    impl().reconcile_capability_request(agent_id, session_id, tool_call_id, execution_result)
  rescue
    error -> {:error, {:capability_request_store_failed, error}}
  catch
    kind, reason -> {:error, {:capability_request_store_failed, {kind, reason}}}
  end
end
