defmodule SalixAgent.MeetingLLMCapability do
  @moduledoc """
  The capability a meeting bot presents to call its Agent's LLM.

  `Salix.Bindings.MeetingConnectDispatch` mints one for each meeting connect
  and sends the raw token to the Connector that joins the meeting. The
  Connector calls `/llm/chat` through a `runtime_proxy` frame
  (`SalixWeb.RuntimeProxy`). Salix stores only the token hash, under
  `ctl/runtime_capabilities/`. A capability is valid only from the Connector
  run that received it, and only in its Tenant and Group. It expires after
  72 hours, and `SalixWeb.MeetingRuntime` revokes it when the meeting ends.
  """

  alias SalixStore.{Ids, Keys, S3}

  @ttl_seconds 72 * 60 * 60

  @doc "Mint a capability for the meeting Session of `agent`, bound to `connector_run_id`."
  def mint(%{} = agent, session_id, connector_run_id) do
    with true <- Ids.valid_session_id?(session_id) || {:error, :invalid_session_id},
         true <-
           present?(connector_run_id) || {:error, {:bad_request, "connector_run_id is required"}} do
      raw =
        "salix_runtime_" <> (SystemsRuntime.Proc.random_bytes(16) |> Base.encode16(case: :lower))

      hash = token_hash(raw)
      now = SystemsClock.system_time(:second)

      capability = %{
        "token_hash" => hash,
        "tenant_id" => agent["tenant_id"],
        "group_id" => agent["group_id"],
        "agent_id" => agent["agent_id"],
        "session_id" => session_id,
        "connector_run_id" => connector_run_id,
        "llm_allowed" => true,
        "created_at" => now,
        "expires_at" => now + @ttl_seconds
      }

      case S3.put(Keys.ctl_runtime_capability(hash), Jason.encode!(capability),
             if_none_match: "*"
           ) do
        {:ok, _} -> {:ok, Map.put(capability, "token", raw)}
        {:error, :precondition_failed} -> {:error, :capability_conflict}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Look up an unexpired capability by its raw token."
  def validate(raw_token) when is_binary(raw_token) and raw_token != "" do
    with {:ok, %{body: body}} <- S3.get(Keys.ctl_runtime_capability(token_hash(raw_token))),
         {:ok, capability} when is_map(capability) <- Jason.decode(body) do
      if expired?(capability), do: {:error, :unauthorized}, else: {:ok, capability}
    else
      {:error, :not_found} -> {:error, :unauthorized}
      {:ok, _invalid} -> {:error, :unauthorized}
      {:error, reason} -> {:error, {:capability_lookup_failed, reason}}
    end
  end

  def validate(_raw_token), do: {:error, :unauthorized}

  @doc """
  Check that the caller is the Connector run the capability was minted for,
  and that the transport's Tenant and Group (when known) match it.
  """
  def validate_scope(capability, connector_run_id, meta)
      when is_map(capability) and is_map(meta) do
    cond do
      present?(meta["tenant_id"]) and meta["tenant_id"] != capability["tenant_id"] ->
        {:error, :unauthorized}

      present?(meta["group_id"]) and meta["group_id"] != capability["group_id"] ->
        {:error, :unauthorized}

      trim(capability["connector_run_id"]) != trim(connector_run_id) ->
        {:error, :stale_connector_transport_generation}

      true ->
        :ok
    end
  end

  def validate_scope(_capability, _connector_run_id, _meta), do: {:error, :unauthorized}

  @doc "Delete a capability by its token hash."
  def revoke_by_hash(token_hash) when is_binary(token_hash) and token_hash != "",
    do: S3.delete(Keys.ctl_runtime_capability(token_hash))

  def revoke_by_hash(_), do: {:error, :invalid_token_hash}

  defp expired?(%{"expires_at" => expires_at}) when is_integer(expires_at),
    do: expires_at <= SystemsClock.system_time(:second)

  defp expired?(_capability), do: false

  defp token_hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp present?(value), do: trim(value) != ""
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
