defmodule Salix.Bindings.MeetingConnectDispatch do
  @moduledoc false

  @behaviour SalixMeet.Ports.MeetingDispatch

  @vmm_station_wait_seconds 15

  alias SalixEnv.Connector.Live
  alias SalixEnv.Registry
  alias Salix.Bindings.MeetingNativeRuntime
  alias SalixStore.Ids
  alias SalixMeet.Store

  @impl true
  def join(payload) do
    case payload["runtime_target"] do
      target when is_map(target) -> dispatch_target(payload, target)
      _ -> join_unselected(payload)
    end
  end

  defp join_unselected(payload) do
    case SalixMeet.MeetingRuntimePolicy.select(payload) do
      {:ok, "automatic"} ->
        join_automatic(payload)

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

      {:ok, "native_runtime"} ->
        MeetingNativeRuntime.join(payload)

      {:error, _} = error ->
        error
    end
  end

  # Automatic placement prefers the Group's VMM Station, a station of the Group
  # that runs meet-native beside it, then another connected meeting
  # runtime, then native. A rejected station target leaves only native.
  defp join_automatic(payload) do
    cond do
      rejected_source?(payload, "connected_runtime") -> join_native(payload)
      true -> join_vmm_station_or_connected(payload)
    end
  end

  defp join_vmm_station_or_connected(payload) do
    case vmm_station_record(payload) do
      {:ok, record} ->
        join_connected_record(payload, record)

      {:error, reason} when reason in [:ambiguous_vmm_hosts, :ambiguous_vmm_environments] ->
        {:error, reason}

      {:error, _reason} ->
        join_connected(payload)
    end
  end

  # The Group's VMM Station, made and woken when the Group has an authorized
  # Host, once it is connected with its meeting runtime: at most 15 seconds.
  defp vmm_station_record(payload) do
    tenant = payload["tenant_id"]
    group = payload["group_id"]

    with {:ok, workload} <- SalixStore.Compute.ensure_group_station(tenant, group) do
      device = "dev-station-" <> workload.id
      _ = SalixStore.ComputeGroupStation.wake_device(tenant, group, device)
      await_meeting_device(tenant, group, device, @vmm_station_wait_seconds)
    end
  end

  defp await_meeting_device(tenant, group, device, remaining) do
    case Registry.get_device(tenant, group, device) do
      {:ok, record} ->
        if meeting_ready?(record), do: {:ok, record}, else: wait_meeting_device(tenant, group, device, remaining)

      _ ->
        wait_meeting_device(tenant, group, device, remaining)
    end
  end

  defp wait_meeting_device(_tenant, _group, _device, 0), do: {:error, :meeting_runtime_not_ready}

  defp wait_meeting_device(tenant, group, device, remaining) do
    SystemsClock.sleep(1_000)
    await_meeting_device(tenant, group, device, remaining - 1)
  end

  defp rejected_source?(payload, source),
    do: Enum.any?(payload["runtime_rejections"] || [], &(&1["source"] == source))

  defp join_connected(payload) do
    case select_meeting_record(payload["group_id"]) do
      {:ok, record} -> join_connected_record(payload, record)
      {:error, _reason} -> join_native(payload)
    end
  end

  defp join_connected_record(payload, record) do
    target = %{
      "source" => "connected_runtime",
      "device_id" => record["device_id"],
      "connect_id" => get_in(record, ["meta", "connect_id"])
    }

    # Capability minting precedes selection and cannot send a join.
    case add_llm_capability(payload, record["connector_run_id"]) do
      {:ok, request} ->
        with {:ok, selected} <- select_target(request, target) do
          dispatch_connected(selected, target, record["connector_run_id"])
        end

      {:error, _reason} ->
        join_native(payload)
    end
  end

  defp join_native(payload) do
    target = %{"source" => "native_runtime"}

    with {:ok, selected} <- select_target(payload, target),
         do: MeetingNativeRuntime.join(selected)
  end

  defp select_target(payload, target) do
    with {:ok, doc, _etag} <-
           Store.select_join_runtime(
             payload["meeting_id"],
             payload["join_dispatch_generation"],
             target
           ) do
      {:ok,
       payload
       |> Map.merge(
         Map.take(
           doc["state"],
           ~w(runtime_source runtime_target)
         )
       )}
    end
  end

  defp reject_target(payload, target, reason),
    do:
      Store.reject_join_runtime(
        payload["meeting_id"],
        payload["join_dispatch_generation"],
        target,
        reason
      )

  defp dispatch_target(payload, %{"source" => "native_runtime"}),
    do: MeetingNativeRuntime.join(payload)

  defp dispatch_target(payload, %{"source" => "connected_runtime"} = target) do
    with {:ok, record} <- current_target_record(payload, target),
         {:ok, request} <- add_llm_capability(payload, record["connector_run_id"]) do
      dispatch_connected(request, target, record["connector_run_id"])
    end
  end

  defp dispatch_connected(payload, target, connector_run_id) do
    case Live.request(connector_run_id, "meeting_join", payload) do
      {:ok, %{"accepted" => false} = rejection} ->
        if SalixMeet.Outcome.normalize(rejection["reason_code"]) do
          with {:ok, _doc, _etag} <-
                 Store.refuse_join_runtime(
                   payload["meeting_id"],
                   payload["join_dispatch_generation"],
                   target,
                   rejection["reason_code"]
                 ) do
            {:error, {:meeting_join_rejected, rejection["reason_code"]}}
          end
        else
          with {:ok, doc, _etag} <- reject_target(payload, target, rejection),
               do: join_native(after_rejection(payload, doc))
        end

      result ->
        result
    end
  end

  defp after_rejection(payload, doc) do
    payload
    |> Map.drop(~w(runtime_target llm_capability_token))
    |> Map.put("runtime_source", "automatic")
    |> Map.put(
      "runtime_rejections",
      get_in(doc, ["state", "join_dispatch", "runtime_rejections"]) || []
    )
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

      SalixMeet.MeetingRuntimePolicy.select(payload) == {:ok, "native_runtime"} ->
        MeetingNativeRuntime.session_status(payload)

      SalixMeet.MeetingRuntimePolicy.select(payload) == {:ok, "automatic"} and
        is_nil(payload["runtime_target"]) and
          SystemsRuntime.get_env(:salix_meet, :runtime_driver) ==
            SalixMeet.RuntimeDriver.Connector ->
        {:ok, :none}

      true ->
        with {:ok, "connected_runtime"} <- SalixMeet.MeetingRuntimePolicy.select(payload),
             {:ok, connect_id} <- meeting_connect_id(meeting_id, payload),
             {:ok, connector_run_id} <- selected_meeting_env(payload, group_id, connect_id),
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

  defp send_chat_for_source("automatic", _payload, _meeting_id, _text),
    do: {:error, :meeting_runtime_not_selected}

  defp send_chat_for_source("native_runtime", payload, meeting_id, text) do
    MeetingNativeRuntime.send_chat(
      Map.merge(payload, %{"meeting_id" => meeting_id, "text" => text})
    )
  end

  defp send_chat_for_source("connected_runtime", payload, meeting_id, text) do
    group_id = to_string(payload["group_id"] || "")

    # Resolve the connector run fresh per send, but keep the durable connect_id
    # selected by the meeting. Reconnect changes the run id, not the owner.
    with {:ok, connect_id} <- meeting_connect_id(meeting_id, payload),
         {:ok, connector_run_id} <- selected_meeting_env(payload, group_id, connect_id) do
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

        case SalixAgent.MeetingLLMCapability.mint(agent, session_id, connector_run_id) do
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
      {:ok,
       %{
         "state" => %{
           "runtime_target" => %{"source" => "connected_runtime", "connect_id" => connect_id}
         }
       }, _etag} ->
        {:ok, connect_id}

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
    case Registry.page_by_group(group_id, limit: 100) do
      {:ok, %{records: records}} ->
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

  defp select_meeting_record(group_id) do
    with {:ok, %{records: records}} <- Registry.page_by_group(group_id, limit: 100) do
      case Enum.find(records, &meeting_ready?/1) do
        nil -> {:error, :no_meeting_runtime_available}
        record -> {:ok, record}
      end
    end
  end

  defp selected_meeting_env(%{"runtime_target" => target} = payload, _group_id, _connect_id)
       when is_map(target) do
    with {:ok, record} <- current_target_record(payload, target),
         do: {:ok, record["connector_run_id"]}
  end

  defp selected_meeting_env(_payload, group_id, connect_id),
    do: select_meeting_env(group_id, connect_id)

  defp current_target_record(payload, target) do
    with {:ok, record} <-
           Registry.get_device(payload["tenant_id"], payload["group_id"], target["device_id"]),
         true <- meeting_ready?(record),
         true <- get_in(record, ["meta", "connect_id"]) == target["connect_id"] do
      {:ok, record}
    else
      _ -> {:error, :no_meeting_runtime_available}
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
