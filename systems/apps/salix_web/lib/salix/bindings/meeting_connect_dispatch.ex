defmodule Salix.Bindings.MeetingConnectDispatch do
  @moduledoc false

  @behaviour SalixMeet.Ports.MeetingDispatch

  alias SalixEnv.Connector.Live
  alias SalixEnv.Registry
  alias SalixStore.Ids
  alias SalixMeet.Store

  @impl true
  def join(payload) do
    case SalixMeet.MeetingRuntimePolicy.select(payload) do
      {:ok, "connected_runtime"} ->
        group_id = to_string(payload["group_id"] || "")

        case select_meeting_env(group_id) do
          {:ok, connector_run_id} ->
            with {:ok, request} <- add_llm_capability(payload, connector_run_id) do
              Live.request(connector_run_id, "meeting_join", request)
            end

          {:error, _} = err ->
            err
        end

      {:ok, "compute_workload"} ->
        SalixMeet.MeetingComputeCarrier.join(payload)

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def send_chat(payload) do
    meeting_id = to_string(payload["meeting_id"] || "")
    text = to_string(payload["text"] || "")

    cond do
      meeting_id == "" ->
        {:error, :missing_meeting_id}

      text == "" ->
        {:error, :missing_text}

      true ->
        with {:ok, source} <- SalixMeet.MeetingRuntimePolicy.select(payload) do
          send_chat_for_source(source, payload, meeting_id, text)
        end
    end
  end

  @impl true
  def session_status(payload) do
    meeting_id = to_string(payload["meeting_id"] || "")
    group_id = to_string(payload["group_id"] || "")

    cond do
      meeting_id == "" ->
        {:error, :missing_meeting_id}

      group_id == "" ->
        {:error, :missing_group_id}

      true ->
        with {:ok, "connected_runtime"} <- SalixMeet.MeetingRuntimePolicy.select(payload),
             {:ok, connect_id} <- meeting_connect_id(meeting_id, payload),
             {:ok, connector_run_id} <- select_meeting_env(group_id, connect_id),
             {:ok, result} <-
               Live.request(connector_run_id, "meeting_session_status", %{
                 "meeting_id" => meeting_id
               }) do
          classify_session_status(result)
        else
          # Three-valued read: any resolution, transport, or carrier gap is
          # "unavailable" — never folded into a definite answer. Only the
          # runtime's own exact reply may say live or none.
          _other -> {:ok, :unavailable}
        end
    end
  end

  defp classify_session_status(%{"status" => "live"}), do: {:ok, :live}
  defp classify_session_status(%{"status" => "none"}), do: {:ok, :none}

  # Liveness is unknowable, but the connector attests the pinned meet-native
  # contract: join is idempotent by meeting_id, so a re-dispatch is safe on
  # the runtime-authority face of RFC contract one even without a definite
  # answer. Only the connector's own reply may attest this — a transport or
  # resolution gap below stays plain unavailable.
  defp classify_session_status(%{"status" => "unavailable", "join_idempotent" => true}),
    do: {:ok, :unavailable_idempotent}

  defp classify_session_status(_result), do: {:ok, :unavailable}

  defp send_chat_for_source("compute_workload", payload, meeting_id, text) do
    SalixMeet.MeetingComputeCarrier.send_chat(
      Map.merge(payload, %{"meeting_id" => meeting_id, "text" => text})
    )
  end

  defp send_chat_for_source("connected_runtime", payload, meeting_id, text) do
    group_id = to_string(payload["group_id"] || "")

    # Resolve the connector run fresh per send, but keep the durable connect_id
    # selected by the meeting. Reconnect changes the run id, not the owner.
    with {:ok, connect_id} <- meeting_connect_id(meeting_id, payload),
         {:ok, connector_run_id} <- select_meeting_env(group_id, connect_id) do
      Live.request(connector_run_id, "meeting_send_chat", %{
        "meeting_id" => meeting_id,
        "message_id" => payload["message_id"],
        "text" => text
      })
    end
  end

  defp add_llm_capability(payload, connector_run_id) do
    agent_id = to_string(payload["meeting_agent_id"] || "")
    session_id = to_string(payload["meeting_session_id"] || "")

    cond do
      not Ids.valid_agent_id?(agent_id) ->
        {:error, :invalid_meeting_agent_id}

      not Ids.valid_session_id?(session_id) ->
        {:error, :invalid_meeting_session_id}

      true ->
        agent = %{
          "tenant_id" => payload["tenant_id"],
          "group_id" => payload["group_id"],
          "agent_id" => agent_id
        }

        case SalixAgent.ExternalAgentRuntime.mint_llm_capability(
               agent,
               session_id,
               connector_run_id
             ) do
          {:ok, cap} ->
            _ = store_llm_capability_hash(payload["meeting_id"], cap["token_hash"])
            {:ok, Map.put(payload, "llm_capability_token", cap["token"])}

          {:error, _} = error ->
            error
        end
    end
  end

  defp store_llm_capability_hash(meeting_id, hash)
       when is_binary(meeting_id) and meeting_id != "" and is_binary(hash) and hash != "" do
    SalixMeet.Store.update_state_retrying(meeting_id, fn state ->
      Map.put(state, "llm_capability_hash", hash)
    end)
  end

  defp store_llm_capability_hash(_meeting_id, _hash), do: :ok

  defp meeting_connect_id(meeting_id, payload) do
    payload_connect_id = payload["connect_id"]

    case Store.get(meeting_id) do
      {:ok, %{"state" => %{"connect_id" => connect_id}}, _etag}
      when is_binary(connect_id) and connect_id != "" ->
        cond do
          is_nil(payload_connect_id) or payload_connect_id == connect_id ->
            {:ok, connect_id}

          true ->
            {:error, :meeting_connector_identity_mismatch}
        end

      _ ->
        {:error, :meeting_connector_identity_missing}
    end
  end

  defp select_meeting_env(group_id, connect_id \\ nil) do
    case Registry.list_connected_by_group(group_id) do
      {:ok, records} ->
        records
        |> Enum.filter(&meeting_ready?/1)
        |> Enum.filter(fn record ->
          is_nil(connect_id) or get_in(record, ["meta", "connect_id"]) == connect_id
        end)
        |> case do
          [rec | _] -> {:ok, rec["connector_run_id"]}
          [] -> {:error, :no_meeting_runtime_available}
        end

      {:error, _} = err ->
        err
    end
  end

  defp meeting_ready?(record) do
    meta = record["meta"] || %{}
    capabilities = meta["capabilities"] || %{}
    runtimes = meta["agent_runtimes"] || []

    record["status"] == "connected" and
      (capabilities["meeting_runtime"] == true or
         Enum.any?(runtimes, &(is_map(&1) and &1["kind"] == "meeting" and &1["ready"] == true)))
  end
end
