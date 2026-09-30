defmodule SalixAgent.MeetingRuntime do
  @moduledoc """
  Agent-facing operations used by the meeting runtime.

  `salix_meet` owns meeting records and provider state. This module owns the
  hidden meeting agent record and translates meeting events into internal
  session deliveries. Meeting session mutation is committed by
  `InternalSessionActor`; meeting artifacts still go through the agent
  workspace operation API.
  """

  alias SalixAgent.{
    AgentActor,
    AgentWorkspace,
    FileBackend,
    InternalSession,
    InternalSessionStore,
    Placement,
    StorageAuthorization,
    Templates
  }

  alias SalixStore.Agent, as: StoreAgent
  alias SalixStore.{Ids, Keys, S3}

  @doc "Ensure the hidden meeting agent record and state exist."
  @spec ensure_agent(map()) :: :ok | {:error, term()}
  def ensure_agent(request) when is_map(request) do
    request = stringify(request)

    with :ok <- validate_identity(request),
         :ok <-
           verify_existing_agent_slot(
             request["tenant_id"],
             request["group_id"],
             request["agent_id"],
             request["session_id"]
           ),
         {:ok, request} <- ensure_meeting_template(request),
         :ok <- ensure_agent_record(request),
         :ok <- ensure_agent_state(request) do
      :ok
    end
  end

  @doc "Verify the hidden meeting agent record and state still match the group."
  @spec verify_agent(map()) :: :ok | {:error, term()}
  def verify_agent(request) when is_map(request) do
    request = stringify(request)

    with :ok <- validate_identity(request),
         :ok <-
           verify_agent_record(
             request["tenant_id"],
             request["group_id"],
             request["agent_id"],
             request["session_id"]
           ) do
      verify_agent_state(request["agent_id"], request["session_id"])
    end
  end

  @doc "Prepare an agent workspace write event without committing it."
  @spec prepare_workspace_write(String.t(), String.t(), binary()) ::
          {:ok, map()} | {:error, term()}
  def prepare_workspace_write(agent_id, path, data),
    do: StorageAuthorization.prepare_managed_write(agent_id, path, data, actor_type: "meeting")

  @doc "Prepare an agent workspace write event from a byte stream (large artifacts)."
  @spec prepare_workspace_write_stream(String.t(), String.t(), Enumerable.t()) ::
          {:ok, map()} | {:error, term()}
  def prepare_workspace_write_stream(agent_id, path, stream),
    do:
      StorageAuthorization.prepare_managed_write_stream(agent_id, path, stream,
        actor_type: "meeting"
      )

  @doc "Read an immutable manifest entry from the hidden meeting agent workspace."
  @spec stat_workspace(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def stat_workspace(agent_id, path) do
    if FileBackend.normal_path?(path) do
      AgentWorkspace.entry(agent_id, path)
    else
      {:error, :session_runtime_path_requires_session_context}
    end
  end

  @doc "Read a normal file from the hidden meeting agent workspace."
  @spec read_workspace(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_workspace(agent_id, path) do
    if FileBackend.normal_path?(path) do
      case FileBackend.read(%{agent_id: agent_id}, path) do
        {:ok, body, _truncated?} -> {:ok, body}
        {:error, _} = err -> err
      end
    else
      {:error, :session_runtime_path_requires_session_context}
    end
  end

  @doc "Stream a normal file from the hidden meeting agent workspace."
  @spec stream_workspace(String.t(), String.t()) ::
          {:ok, Enumerable.t(), non_neg_integer()} | {:error, term()}
  def stream_workspace(agent_id, path) do
    if FileBackend.normal_path?(path) do
      FileBackend.stream(%{agent_id: agent_id}, path)
    else
      {:error, :session_runtime_path_requires_session_context}
    end
  end

  @doc "Check the meeting session's durable source-id ledger before replaying provider effects."
  @spec event_committed?(String.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def event_committed?(agent_id, session_id, source_id)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(source_id) do
    case InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        {:ok, InternalSession.query(session, :input_dedupe_member?, source_id)}

      {:error, _} = error ->
        error
    end
  end

  @doc "Check whether this source already committed its deterministic workspace operation."
  @spec workspace_event_committed?(String.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def workspace_event_committed?(agent_id, session_id, source_id)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(source_id) do
    operation_id = delivery_workspace_operation_id(agent_id, session_id, source_id)

    case AgentWorkspace.operation_result(agent_id, operation_id) do
      {:ok, %{"source_message_id" => ^source_id}} -> {:ok, true}
      {:ok, %{source_message_id: ^source_id}} -> {:ok, true}
      {:ok, _other} -> {:error, :workspace_event_identity_mismatch}
      {:error, :not_found} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  @doc "Commit one prepared meeting event into the hidden meeting agent session."
  @spec commit_event(map()) :: {:ok, :created | :duplicate} | {:error, term()}
  def commit_event(request) when is_map(request) do
    request = stringify(request)

    with :ok <- validate_identity(request) do
      commit_meeting_event(
        request["agent_id"],
        request["session_id"],
        request["source_id"],
        request["event"],
        request["billing_context"] || %{},
        List.wrap(request["vfs_events"]),
        request["now"]
      )
    end
  end

  defp ensure_meeting_template(request) do
    ref = request["template_id"]

    case existing_template_id(ref) do
      {:ok, id} ->
        {:ok, Map.put(request, "template_id", id)}

      :none ->
        rec = %{
          "template_id" => ref,
          "name" => request["name"],
          "model" => "internal/noop",
          "provider" => "internal/noop",
          "provider_config" => %{},
          "request_headers" => %{},
          "image_config" => %{},
          "video_config" => %{},
          "vision_describer_config" => %{},
          "analyze_config" => %{},
          "max_tokens" => 65_536,
          "context_tokens" => 0,
          "hidden" => true,
          "purpose" => "meeting",
          "created_at" => request["now"]
        }

        case S3.put(Keys.ctl_template(ref), Jason.encode!(rec), if_none_match: "*") do
          {:ok, _} -> {:ok, request}
          {:error, :precondition_failed} -> {:ok, request}
          {:error, _} = err -> err
        end
    end
  end

  defp validate_identity(request) do
    tenant_id = request["tenant_id"]
    group_id = request["group_id"]
    agent_id = request["agent_id"]
    session_id = request["session_id"]

    if Ids.valid_group_id_for_tenant?(group_id, tenant_id) and
         Ids.valid_agent_id_for_group?(agent_id, group_id) and
         Ids.valid_session_id?(session_id) do
      :ok
    else
      invalid(:invalid_agent_identity)
    end
  end

  defp existing_template_id(ref) do
    cond do
      match?({:ok, _}, Templates.get(ref)) ->
        {:ok, ref}

      true ->
        case Enum.find(Templates.list_admin(), &(&1["name"] == ref)) do
          %{"template_id" => id} when is_binary(id) and id != "" -> {:ok, id}
          _ -> :none
        end
    end
  end

  defp ensure_agent_state(request) do
    case StoreAgent.peek(request["agent_id"]) do
      {:ok, _head} ->
        verify_agent_state(request["agent_id"], request["session_id"])

      {:error, :not_found} ->
        with {:ok, _pid} <- Placement.ensure_started(request["agent_id"], create: true),
             {:ok, status} when status in [:committed, :duplicate] <-
               stage_meeting_session_create(request) do
          :ok
        end

      {:error, _} = err ->
        err
    end
  end

  defp stage_meeting_session_create(request) do
    case AgentActor.stage_delivery(
           request["agent_id"],
           %{
             source_message_id: "meeting-agent:ensure:" <> request["session_id"],
             payload: %{
               kind: "session_create",
               session_id: request["session_id"],
               name: request["name"],
               hidden: true,
               billing_context: request["billing_context"] || %{},
               created_at: request["now"]
             }
           }
         ) do
      {:ok, :committed, _targets} -> {:ok, :committed}
      {:ok, :duplicate} -> {:ok, :duplicate}
      {:error, _} = err -> err
    end
  end

  defp ensure_agent_record(request) do
    rec = %{
      "agent_id" => request["agent_id"],
      "tenant_id" => request["tenant_id"],
      "group_id" => request["group_id"],
      "role" => "meeting",
      "name" => request["name"],
      "system_prompt" => request["system_prompt"],
      "router_system_prompt" => "",
      "template_id" => request["template_id"],
      "provider" => "internal/noop",
      "db_namespace" => "salix:" <> request["agent_id"],
      "status" => "idle",
      "purpose" => "meeting",
      "hidden" => true,
      "created_at" => request["now"],
      "heartbeat_schedule_id" => Ids.new_schedule_id(),
      "tool_router_enabled" => false,
      "vm" => %{"enabled" => false}
    }

    case S3.put(Keys.ctl_agent(request["agent_id"]), Jason.encode!(rec), if_none_match: "*") do
      {:ok, _} ->
        :ok

      {:error, :precondition_failed} ->
        verify_agent_record(
          request["tenant_id"],
          request["group_id"],
          request["agent_id"],
          request["session_id"]
        )

      {:error, _} = err ->
        err
    end
  end

  defp verify_existing_agent_slot(tenant_id, group_id, agent_id, session_id) do
    with :ok <- verify_existing_agent_record(tenant_id, group_id, agent_id, session_id) do
      verify_existing_agent_state(agent_id, session_id)
    end
  end

  defp verify_existing_agent_record(tenant_id, group_id, agent_id, session_id) do
    case read_json(Keys.ctl_agent(agent_id)) do
      {:ok, record} -> validate_agent_record(record, tenant_id, group_id, agent_id, session_id)
      {:error, :not_found} -> :ok
      {:error, _} = err -> err
    end
  end

  defp verify_existing_agent_state(agent_id, session_id) do
    case StoreAgent.peek(agent_id) do
      {:ok, _head} -> validate_agent_state(agent_id, session_id)
      {:error, :not_found} -> :ok
      {:error, _} = err -> err
    end
  end

  defp verify_agent_record(tenant_id, group_id, agent_id, session_id) do
    case read_json(Keys.ctl_agent(agent_id)) do
      {:ok, record} -> validate_agent_record(record, tenant_id, group_id, agent_id, session_id)
      {:error, :not_found} -> invalid(:missing_agent_record)
      {:error, _} = err -> err
    end
  end

  defp validate_agent_record(record, tenant_id, group_id, agent_id, _session_id) do
    with :ok <- expect(record["agent_id"] == agent_id, :agent_record_id_mismatch),
         :ok <- expect(record["tenant_id"] == tenant_id, :agent_record_tenant_mismatch),
         :ok <- expect(record["group_id"] == group_id, :agent_record_group_mismatch),
         :ok <- expect(record["role"] == "meeting", :agent_record_role_mismatch),
         :ok <- expect(record["purpose"] == "meeting", :agent_record_purpose_mismatch),
         :ok <- expect(record["hidden"] == true, :agent_record_visibility_mismatch) do
      :ok
    end
  end

  defp verify_agent_state(agent_id, session_id) do
    validate_agent_state(agent_id, session_id)
  end

  defp validate_agent_state(agent_id, session_id) do
    with {:ok, session} <- fetch_meeting_session(agent_id, session_id),
         :ok <-
           expect(InternalSession.get(session, :hidden) == true, :agent_state_visibility_mismatch) do
      :ok
    end
  end

  defp fetch_meeting_session(agent_id, session_id) do
    case InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> invalid(:missing_meeting_session)
      {:error, _} = err -> err
    end
  end

  defp commit_meeting_event(
         agent_id,
         session_id,
         source_id,
         event,
         billing_context,
         vfs_events,
         now
       ) do
    with {:ok, _head} <- StoreAgent.peek(agent_id) do
      case AgentActor.stage_delivery(
             agent_id,
             meeting_delivery(session_id, source_id, event, billing_context, vfs_events, now)
           ) do
        {:ok, :committed, _targets} -> {:ok, :created}
        {:ok, :duplicate} -> {:ok, :duplicate}
        {:error, _} = err -> err
      end
    end
  end

  defp meeting_delivery(session_id, source_id, event, billing_context, vfs_events, now) do
    %{
      source_message_id: source_id,
      payload: %{
        kind: "session_log",
        session_id: session_id,
        name: "Meeting",
        hidden: true,
        role: "event",
        content: Jason.encode!(%{"type" => "meeting_event", "event" => stringify(event)}),
        billing_context: billing_context || %{},
        created_at: now,
        events: List.wrap(vfs_events)
      }
    }
  end

  defp delivery_workspace_operation_id(agent_id, session_id, source_id),
    do: "delivery-workspace:" <> agent_id <> ":" <> session_id <> ":" <> source_id

  defp read_json(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp expect(true, _reason), do: :ok
  defp expect(false, reason), do: invalid(reason)

  defp invalid(reason), do: {:error, {:invalid_meeting_agent, reason}}

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
