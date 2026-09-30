defmodule SalixWeb.MeetingRuntime do
  @moduledoc """
  Ingest meeting runtime events delivered by a connector over the socket.

  Mirrors the HTTP `/v1/agent-groups/:id/meeting-agent/runtime-events` path:
  resolve the meeting, verify its runtime token, then deliver the event into
  the group's meeting agent.
  """

  def handle_connector_event(storage_env_id, params, meta) do
    meta = stringify_keys(meta || %{})

    with %{"event" => event} when is_map(event) <- params,
         event <- stringify_keys(event),
         meeting_id when meeting_id != "" <- trim(event["meeting_id"]),
         {:ok, %{"state" => state}, _etag} <- SalixMeet.Store.get(meeting_id),
         state <- stringify_keys(state || %{}),
         :ok <- verify_runtime_token(event["runtime_token"], state["runtime_token"]),
         :ok <- verify_scope(meta, state),
         {:ok, result} <-
           SalixMeet.Runtime.deliver_event(
             state["tenant_id"],
             state["group_id"],
             Map.delete(event, "runtime_token"),
             origin_env_id: storage_env_id
           ) do
      maybe_revoke_llm_capability(event, state)
      {:ok, result}
    else
      %{} -> {:error, :missing_event}
      "" -> {:error, :missing_meeting_id}
      {:error, _} = err -> err
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Ingest a Meeting event from the Workload-scoped Compute carrier."
  def handle_compute_event(params, origin_env_id \\ nil) when is_map(params) do
    with %{"event" => event} when is_map(event) <- params,
         event <- stringify_keys(event),
         meeting_id when meeting_id != "" <- trim(event["meeting_id"]),
         {:ok, %{"state" => state}, _etag} <- SalixMeet.Store.get(meeting_id),
         state <- stringify_keys(state || %{}),
         :ok <- verify_runtime_token(event["runtime_token"], state["runtime_token"]),
         {:ok, result} <-
           SalixMeet.Runtime.deliver_event(
             state["tenant_id"],
             state["group_id"],
             Map.delete(event, "runtime_token"),
             origin_env_id: origin_env_id
           ) do
      maybe_revoke_llm_capability(event, state)
      {:ok, result}
    else
      %{} -> {:error, :missing_event}
      "" -> {:error, :missing_meeting_id}
      {:error, _} = err -> err
      _ -> {:error, :unauthorized}
    end
  end

  defp verify_scope(meta, state) do
    if scope_match?(meta["tenant_id"], state["tenant_id"]) and
         scope_match?(meta["group_id"], state["group_id"]) do
      :ok
    else
      {:error, :scope_mismatch}
    end
  end

  defp scope_match?(presented, expected) do
    expected = trim(expected)
    expected != "" and trim(presented) == expected
  end

  @meeting_terminal_statuses ~w(done failed cancelled)

  defp maybe_revoke_llm_capability(event, state) do
    with true <- event["type"] == "meeting_runtime_update",
         true <- event["status"] in @meeting_terminal_statuses,
         hash when is_binary(hash) and hash != "" <- state["llm_capability_hash"] do
      _ = SalixAgent.ExternalAgentRuntime.revoke_runtime_capability_by_hash(hash)
      :ok
    else
      _ -> :ok
    end
  end

  defp verify_runtime_token(token, expected) do
    token = trim(token)
    expected = trim(expected)

    cond do
      token == "" or expected == "" -> {:error, :unauthorized}
      byte_size(token) != byte_size(expected) -> {:error, :unauthorized}
      Plug.Crypto.secure_compare(token, expected) -> :ok
      true -> {:error, :unauthorized}
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(other), do: other

  defp trim(value), do: String.trim(to_string(value || ""))
end
