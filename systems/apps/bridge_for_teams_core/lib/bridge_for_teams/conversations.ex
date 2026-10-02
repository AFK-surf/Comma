defmodule BridgeForTeams.Conversations do
  @moduledoc """
  Conversation read context for project-scoped dashboard surfaces.

  BridgeForTeams stores the project and agent records in Postgres, while
  conversation records live in Salix under the project's group id. This module
  keeps that Salix boundary behind the configured client implementation.
  """

  require Logger

  alias BridgeForTeams.{Accounts, Memberships, Observability}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Agent, Project}
  alias SalixStore.Ids

  @default_limit 100
  @bft_participant %{
    "actor_type" => "provider",
    "provider" => "bft",
    "target_key" => "bft",
    "role_label" => "bridge_for_teams",
    "state" => "active",
    "notification_filter" => %{"messages" => "none", "statuses" => "none"}
  }
  @transient [:unavailable, :timeout]

  @doc "Create a canonical agent Task with a Router delegator and Worker target."
  @spec create_project_task_conversation(
          Project.t(),
          Agent.t(),
          Agent.t(),
          map(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def create_project_task_conversation(
        %Project{salix_group_id: group_id} = project,
        %Agent{role: "router"} = router,
        %Agent{role: "worker"} = worker,
        attrs,
        opts \\ []
      )
      when is_map(attrs) do
    client = Client.impl()
    attrs = stringify(attrs)
    opts = Keyword.put_new(opts, :request_id, Ecto.UUID.generate())
    attrs = Map.put_new(attrs, "client_request_id", Keyword.fetch!(opts, :request_id))

    result =
      if Code.ensure_loaded?(client) and function_exported?(client, :create_task_conversation, 4) do
        client.create_task_conversation(
          group_id,
          router.salix_agent_id,
          worker.salix_agent_id,
          attrs
        )
      else
        {:error, :task_conversation_create_unavailable}
      end

    case result do
      {:ok, %{"conversation_id" => conversation_id} = created}
      when is_binary(conversation_id) and conversation_id != "" ->
        record_conversation_event(project, worker, conversation_id, "ok", nil, opts)
        maybe_record_conversation_audit(project, worker, conversation_id, opts)
        {:ok, created}

      {:ok, _invalid} ->
        {:error, {:invalid_salix_response, :conversation_id}}

      {:error, reason} = error ->
        record_conversation_event(project, worker, nil, "failed", reason, opts)
        maybe_record_conversation_write_attempt(error, project, worker, nil, opts)
        error
    end
  end

  @doc "Accept the current version of a Task after human review."
  @spec accept_project_task_review(Project.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def accept_project_task_review(
        %Project{salix_group_id: group_id},
        conversation_id,
        review_version
      )
      when is_binary(conversation_id) and is_integer(review_version) and
             review_version > 0 do
    Client.impl().accept_task_review(group_id, conversation_id, review_version)
  end

  @doc "Add or update the canonical Schedule on an existing Task conversation."
  @spec put_project_task_schedule(Project.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def put_project_task_schedule(project, conversation_id, attrs, opts \\ [])
      when is_binary(conversation_id) and is_map(attrs) do
    mutate_project_task_schedule(project, conversation_id, :put, stringify(attrs), opts)
  end

  @doc "Delete only the Task's Schedule, preserving its conversation and history."
  @spec delete_project_task_schedule(Project.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete_project_task_schedule(project, conversation_id, opts \\ []) do
    mutate_project_task_schedule(project, conversation_id, :delete, nil, opts)
  end

  @doc "Read the canonical recurrence for a Task Schedule owned by this conversation."
  @spec get_project_task_schedule(Project.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_project_task_schedule(
        %Project{salix_group_id: group_id},
        conversation_id,
        schedule_id
      ) do
    with {:ok, schedule} <- Client.impl().get_schedule(schedule_id),
         %{
           "receiver" => "task",
           "payload" => %{
             "agent_group_id" => ^group_id,
             "conversation_id" => ^conversation_id
           }
         } <- schedule do
      {:ok, schedule}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "List the first page of conversations for a project's Salix group."
  @spec list_project_conversations(Project.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_project_conversations(%Project{} = project, opts \\ []) do
    with {:ok, page} <- page_project_conversations(project, Keyword.delete(opts, :cursor)),
         do: {:ok, page.items}
  end

  @doc """
  Read one page of conversations for a project's Salix group, most recently
  updated first. `:limit` (default #{@default_limit}) bounds the page and
  `:cursor` continues after a previous page's `next_cursor`.
  """
  @spec page_project_conversations(Project.t(), keyword()) ::
          {:ok, %{items: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def page_project_conversations(%Project{salix_group_id: group_id} = project, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    list_opts = [limit: limit] ++ if(opts[:cursor], do: [cursor: opts[:cursor]], else: [])

    result =
      case Client.impl().list_group_conversations(group_id, list_opts) do
        {:ok, %{"data" => conversations} = page} when is_list(conversations) ->
          {:ok, %{items: conversations, next_cursor: next_cursor(page)}}

        {:ok, conversations} when is_list(conversations) ->
          {:ok, %{items: conversations, next_cursor: nil}}

        {:ok, _other} ->
          {:ok, %{items: [], next_cursor: nil}}

        {:error, reason} ->
          {:error, reason}
      end

    maybe_record_conversation_list_diagnostic(project, limit, result)

    result
  end

  defp maybe_record_conversation_list_diagnostic(
         %Project{} = project,
         limit,
         {:error, reason}
       )
       when reason in @transient do
    reason_class = Atom.to_string(reason)

    attrs = %{
      org_id: project.org_id,
      project_id: project.id,
      domain: "conversation",
      resource_type: "project_conversation_index",
      resource_id: project.id,
      source: "salix.conversation",
      event_type: "project.conversations.unavailable",
      severity: "warning",
      status: "unavailable",
      reason_class: reason_class,
      summary: "Project conversations could not be loaded from Salix",
      evidence: %{
        "project_id" => project.id,
        "salix_group_id" => project.salix_group_id,
        "surface" => "project_conversations",
        "list_limit" => limit,
        "reason_class" => reason_class,
        "status" => "unavailable"
      },
      correlation_id: "project:#{project.id}:conversations:index",
      occurred_at: DateTime.utc_now()
    }

    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, observability_reason} ->
        Logger.warning(
          "project_conversations_observability_failed reason=#{inspect(observability_reason)} project_id=#{project.id}"
        )
    end
  end

  defp maybe_record_conversation_list_diagnostic(_project, _limit, _result), do: :ok

  defp next_cursor(%{"next_cursor" => cursor}) when is_binary(cursor) and cursor != "",
    do: cursor

  defp next_cursor(_page), do: nil

  @doc """
  Create a project conversation bound to an agent participant.

  `attrs["kind"]` keeps the BFT presentation term. `"user_chat"` (the default)
  is written to Salix as `user_chat`; every work-item term is written as the
  canonical `agent_task` kind.
  """
  @spec create_project_conversation(Project.t(), Agent.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_project_conversation(
        %Project{salix_group_id: group_id} = project,
        %Agent{} = agent,
        attrs,
        opts \\ []
      ) do
    attrs = stringify(attrs)
    opts = Keyword.put_new(opts, :request_id, Ecto.UUID.generate())
    title = to_string(attrs["title"] || "")

    conversation_attrs =
      %{
        "client_request_id" => Keyword.fetch!(opts, :request_id),
        "title" => title,
        "kind" => conversation_kind(attrs["kind"]),
        "participants" => participants(agent)
      }
      |> Map.merge(conversation_create_extras(attrs))

    result =
      Client.impl().create_group_conversation(group_id, conversation_attrs)

    case result do
      {:ok, conversation} ->
        persisted_conversation_id = conversation["conversation_id"]
        record_conversation_event(project, agent, persisted_conversation_id, "ok", nil, opts)
        maybe_record_conversation_audit(project, agent, persisted_conversation_id, opts)
        {:ok, conversation}

      {:error, reason} = err ->
        record_conversation_event(project, agent, nil, "failed", reason, opts)
        maybe_record_conversation_write_attempt(err, project, agent, nil, opts)
        err
    end
  end

  @doc "Fetch a single project conversation."
  @spec get_project_conversation(Project.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_project_conversation(%Project{salix_group_id: group_id}, conversation_id) do
    Client.impl().get_group_conversation(group_id, conversation_id)
  end

  @doc "Read only the immutable Agent attachment at this Message's content index."
  @spec get_project_conversation_attachment(
          Project.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) ::
          {:ok, %{filename: String.t(), body: binary()}} | {:error, term()}
  def get_project_conversation_attachment(
        %Project{salix_group_id: group_id},
        conversation_id,
        message_id,
        index
      ) do
    Client.impl().get_group_conversation_attachment(group_id, conversation_id, message_id, index)
  end

  @doc "Subscribe the calling process to committed updates for one project conversation."
  @spec subscribe_project_conversation(Project.t(), String.t(), pid()) ::
          {:ok, map()} | {:error, term()}
  def subscribe_project_conversation(
        %Project{salix_group_id: group_id},
        conversation_id,
        subscriber
      )
      when is_pid(subscriber) do
    Client.impl().subscribe_group_conversation(group_id, conversation_id, subscriber)
  end

  @doc "List participants for a project conversation."
  @spec list_project_conversation_participants(Project.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_project_conversation_participants(
        %Project{salix_group_id: group_id},
        conversation_id,
        opts \\ []
      ) do
    case Client.impl().list_group_conversation_participants(group_id, conversation_id, opts) do
      {:ok, %{"participants" => participants}} when is_list(participants) ->
        {:ok, participants}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetch a project conversation and its messages in one Salix read snapshot.
  """
  @spec get_project_conversation_with_messages(Project.t(), String.t(), keyword()) ::
          {:ok, %{conversation: map(), messages: [map()]}} | {:error, term()}
  def get_project_conversation_with_messages(
        %Project{salix_group_id: group_id},
        conversation_id,
        opts \\ []
      ) do
    limit = Keyword.get(opts, :limit, @default_limit)
    snapshot_opts = opts |> Keyword.take([:after_id, :tail]) |> Keyword.put(:limit, limit)

    case Client.impl().get_group_conversation_with_messages(
           group_id,
           conversation_id,
           snapshot_opts
         ) do
      {:ok, %{"conversation" => conversation, "messages" => messages}}
      when is_map(conversation) and is_list(messages) ->
        {:ok, %{conversation: conversation, messages: messages}}

      {:ok, _other} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List messages for a project conversation."
  @spec list_project_conversation_messages(Project.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_project_conversation_messages(
        %Project{salix_group_id: group_id},
        conversation_id,
        opts \\ []
      ) do
    limit = Keyword.get(opts, :limit, @default_limit)
    message_opts = opts |> Keyword.take([:after_id, :tail]) |> Keyword.put(:limit, limit)

    case Client.impl().list_group_conversation_messages(group_id, conversation_id, message_opts) do
      {:ok, messages} when is_list(messages) -> {:ok, messages}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The agent's current in-memory activity surface — the last live
  thinking/typing/execution signal per running session (see
  `SalixAgent.ActivitySurface`) — for seeding a status display on connect.
  Best-effort: a runtime (or scripted test client) without the read degrades
  to `[]`, the same "liveness upgrade, never a correctness dependency"
  contract the event relay follows.
  """
  @spec list_agent_activities(Agent.t() | String.t() | nil) :: [map()]
  def list_agent_activities(%Agent{salix_agent_id: agent_id}), do: list_agent_activities(agent_id)

  def list_agent_activities(agent_id) when is_binary(agent_id) and agent_id != "" do
    impl = Client.impl()

    with true <- Code.ensure_loaded?(impl) and function_exported?(impl, :list_agent_activities, 1),
         {:ok, activities} when is_list(activities) <- impl.list_agent_activities(agent_id) do
      activities
    else
      _missing_or_error -> []
    end
  end

  def list_agent_activities(_agent), do: []

  @doc """
  Append a user message to a project conversation and let Salix deliver it.
  """
  @spec send_project_conversation_message(Project.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_project_conversation_message(
        %Project{salix_group_id: group_id} = project,
        conversation_id,
        text,
        opts \\ []
      ) do
    text = String.trim(to_string(text || ""))

    if text == "" do
      {:error, {:validation, :message_required}}
    else
      with {:ok, actor} <- authorize_message_actor(project, opts) do
        do_send_project_conversation_message(
          project,
          group_id,
          conversation_id,
          text,
          actor,
          opts
        )
      end
    end
  end

  def ensure_project_bft_participant(
        %Project{salix_group_id: group_id},
        conversation_id
      ) do
    Client.impl().ensure_group_conversation_provider_participant(
      group_id,
      conversation_id,
      @bft_participant
    )
  end

  defp authorize_message_actor(%Project{id: project_id}, opts) do
    case trim(Keyword.get(opts, :actor_user_id)) do
      "" ->
        {:ok, %{"actor_type" => "provider_system"}}

      user_id ->
        with {:ok, user} <- Accounts.get_user(user_id),
             :ok <- Memberships.authorize(user_id, :read, %{project_id: project_id}) do
          {:ok,
           %{
             "actor_type" => "provider_user",
             "user_id" => user.id,
             "user_name" => user.email,
             "display_name" => user.name || user.email
           }}
        end
    end
  end

  defp do_send_project_conversation_message(
         project,
         group_id,
         conversation_id,
         text,
         actor,
         opts
       ) do
    opts = Keyword.put_new(opts, :request_id, Ecto.UUID.generate())
    request_id = Keyword.fetch!(opts, :request_id)
    client_request_id = dashboard_message_request_id(request_id)

    result =
      with {:ok, participant} <- ensure_project_bft_participant(project, conversation_id),
           {:ok, participant_id} <- dashboard_participant_id(participant) do
        attrs =
          %{
            "client_request_id" => client_request_id,
            "kind" => "message",
            "provider" => "bft",
            "participant_id" => participant_id,
            "content" => [%{"type" => "text", "text" => text}],
            "metadata" => %{
              "source" => "bridge_for_teams_dashboard",
              "request_id" => request_id
            }
          }
          |> Map.merge(actor)

        Client.impl().append_group_conversation_message(group_id, conversation_id, attrs)
      end

    case result do
      {:ok, send_result} ->
        record_message_event(project, conversation_id, send_result, "ok", nil, opts)
        maybe_record_message_audit(project, conversation_id, send_result, opts)
        {:ok, send_result}

      {:error, reason} = err ->
        record_message_event(
          project,
          conversation_id,
          %{"client_request_id" => client_request_id},
          "failed",
          reason,
          opts
        )

        maybe_record_message_write_attempt(
          err,
          project,
          conversation_id,
          client_request_id,
          opts
        )

        err
    end
  end

  defp dashboard_participant_id(%{"participant_id" => participant_id}) do
    if Ids.valid_participant_id?(participant_id),
      do: {:ok, participant_id},
      else: {:error, {:invalid_salix_response, :participant_id}}
  end

  defp dashboard_participant_id(_participant),
    do: {:error, {:invalid_salix_response, :participant_id}}

  @doc "Read the local Salix debug trace for a runtime session."
  @spec get_session_trace(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_session_trace(agent_id, session_id, opts \\ []) do
    Client.impl().session_trace(agent_id, session_id, opts)
  end

  @doc "Read one backward-paginated page of a runtime session's durable records."
  @spec get_session_records(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_session_records(agent_id, session_id, opts \\ []) do
    Client.impl().session_records(agent_id, session_id, opts)
  end

  @doc "Read durable delivery/session diagnostics for one project conversation participant."
  @spec project_conversation_delivery_status(Project.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def project_conversation_delivery_status(
        %Project{salix_group_id: group_id},
        conversation_id,
        opts \\ []
      ) do
    Client.impl().group_conversation_delivery_status(group_id, conversation_id, opts)
  end

  def redeliver_message(%Project{salix_group_id: group_id}, conversation_id, attrs),
    do:
      Client.impl().redeliver_group_conversation_agent_message(
        group_id,
        conversation_id,
        attrs
      )

  @doc "Read the public activity projection for one project conversation participant."
  @spec project_conversation_participant_status(Project.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def project_conversation_participant_status(
        %Project{salix_group_id: group_id},
        conversation_id,
        participant_id
      ) do
    case Client.impl().get_conversation_participant_status(
           group_id,
           conversation_id,
           participant_id
         ) do
      {:ok, status} when is_map(status) -> {:ok, normalize_participant_status(status)}
      other -> other
    end
  end

  @doc "Read public activity projections for already-loaded participants."
  @spec project_conversation_participant_statuses(Project.t(), String.t(), [map()]) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def project_conversation_participant_statuses(_project, _conversation_id, []), do: {:ok, %{}}

  def project_conversation_participant_statuses(
        %Project{salix_group_id: group_id},
        conversation_id,
        participants
      ),
      do:
        Client.impl().group_conversation_participant_statuses(
          group_id,
          conversation_id,
          participants
        )

  defp normalize_participant_status(status) do
    Map.update(status, "activity", %{"kind" => "unknown"}, &normalize_activity/1)
  end

  defp normalize_activity(activity) when is_map(activity) do
    Map.put(activity, "kind", stable_activity_kind(activity["kind"]))
  end

  defp normalize_activity(_activity), do: %{"kind" => "unknown"}

  defp stable_activity_kind(kind)
       when kind in ["starting", "running", "waiting", "idle", "queued", "failed", "unknown"],
       do: kind

  defp stable_activity_kind(_kind), do: "unknown"

  @doc "Resolve the Salix runtime target for a dashboard/BFT CLI participant trace."
  @spec debug_trace_target(map() | nil, keyword()) ::
          {:ok, %{agent_id: String.t(), session_id: String.t(), participant_id: String.t()}}
          | {:error, :trace_participant_required}
          | {:error, :missing_trace_session}
  def debug_trace_target(conversation, opts \\ []) do
    participant_id = trim(Keyword.get(opts, :participant_id))

    conversation
    |> trace_participant_candidates()
    |> filter_trace_participants(participant_id)
    |> case do
      [%{agent_id: agent_id, session_id: session_id, participant_id: resolved_participant_id}] ->
        {:ok,
         %{
           agent_id: agent_id,
           session_id: session_id,
           participant_id: resolved_participant_id
         }}

      [] ->
        {:error, :missing_trace_session}

      [_ | _] ->
        {:error, :trace_participant_required}
    end
  end

  defp trace_participant_candidates(%{"participants" => participants})
       when is_list(participants) do
    participants
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(trim(&1["actor_type"]) == "agent"))
    |> Enum.map(fn participant ->
      %{
        participant_id: trim(participant["participant_id"]),
        agent_id: trim(participant["agent_id"]),
        session_id: participant_trace_session_id(participant)
      }
    end)
    |> Enum.filter(fn candidate ->
      candidate.agent_id != "" and candidate.session_id != ""
    end)
  end

  defp trace_participant_candidates(_conversation), do: []

  defp filter_trace_participants(candidates, ""), do: candidates

  defp filter_trace_participants(candidates, participant_id) do
    Enum.filter(candidates, &(&1.participant_id == participant_id))
  end

  defp participant_trace_session_id(%{"payload" => %{"session_id" => session_id}}),
    do: trim(session_id)

  defp participant_trace_session_id(_participant), do: ""

  @conversation_create_extra_fields ~w(status activity_status owner_user_id created_by_user_id metadata labels latest_artifact artifact_manifest source_refs)

  defp conversation_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "" -> "user_chat"
      "user_chat" -> "user_chat"
      _work_item -> "agent_task"
    end
  end

  defp conversation_kind(_kind), do: "user_chat"

  defp conversation_create_extras(attrs) do
    Map.take(attrs, @conversation_create_extra_fields)
  end

  defp participants(agent) do
    [
      %{
        "actor_type" => "agent",
        "agent_id" => agent.salix_agent_id,
        "agent_name" => agent.salix["name"],
        "role_label" => agent.role || "agent",
        "state" => "active",
        "notification_filter" => %{"messages" => "all", "statuses" => "none"}
      }
    ]
  end

  defp mutate_project_task_schedule(
         %Project{salix_group_id: group_id} = project,
         conversation_id,
         action,
         attrs,
         opts
       ) do
    opts = Keyword.put_new(opts, :request_id, Ecto.UUID.generate())
    client = Client.impl()

    result =
      with :ok <- authorize_task_schedule_write(project, opts) do
        case action do
          :put ->
            client.update_task_schedule(group_id, conversation_id, attrs)

          :delete ->
            client.update_task_schedule(group_id, conversation_id, nil)
        end
      end

    record_task_schedule_write(project, conversation_id, action, result, opts)
    result
  end

  defp authorize_task_schedule_write(project, opts) do
    case Keyword.get(opts, :actor_user_id) do
      user_id when is_binary(user_id) and user_id != "" ->
        Memberships.authorize(user_id, :write, %{project_id: project.id})

      _internal_call ->
        :ok
    end
  end

  defp record_task_schedule_write(project, conversation_id, action, result, opts) do
    {status, reason, conversation} =
      case result do
        {:ok, conversation} -> {"ok", nil, conversation}
        {:error, :forbidden} -> {"denied", :forbidden, %{}}
        {:error, reason} -> {"failed", reason, %{}}
      end

    schedule = conversation["schedule"] || %{}

    _ =
      Observability.record_write_attempt(%{
        org_id: project.org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: "project_task_schedule.#{action}",
        resource_type: "task_schedule",
        resource_id: conversation_id,
        resource_label: conversation_label(conversation_id),
        result: status,
        reason: reason,
        request_id: Keyword.fetch!(opts, :request_id),
        surface: "task_schedule",
        metadata: %{
          "project_id" => project.id,
          "salix_group_id" => project.salix_group_id,
          "conversation_id" => conversation_id,
          "has_schedule" => is_binary(schedule["schedule_id"]) and schedule["schedule_id"] != ""
        }
      })
  end

  defp record_conversation_event(project, agent, conversation_id, result, reason, opts) do
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

    attrs = %{
      org_id: project.org_id,
      project_id: project.id,
      actor_user_id: Keyword.get(opts, :actor_user_id),
      domain: "conversation",
      source: "bft.dashboard",
      event_type: "conversation.created",
      severity: conversation_event_severity(result),
      status: result,
      reason_class: conversation_reason_class(result, reason),
      summary: conversation_event_summary(result),
      resource_type: "project_conversation",
      resource_id: conversation_id,
      correlation_id: request_id,
      evidence: conversation_metadata(project, agent, conversation_id, request_id)
    }

    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, event_reason} ->
        Logger.warning("conversation_event_failed reason=#{inspect(event_reason)}")
        :ok
    end
  end

  defp maybe_record_conversation_audit(project, agent, conversation_id, opts) do
    if audit_enabled?(opts) do
      request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

      case Observability.record_audit(%{
             org_id: project.org_id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: "project_conversation.created",
             resource_type: "project_conversation",
             resource_id: conversation_id,
             resource_label: conversation_label(conversation_id),
             result: "ok",
             request_id: request_id,
             metadata: conversation_metadata(project, agent, conversation_id, request_id)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, reason} ->
          Logger.warning("conversation_audit_failed reason=#{inspect(reason)}")
          :ok
      end
    end
  end

  defp maybe_record_conversation_write_attempt(
         {:error, reason},
         project,
         agent,
         conversation_id,
         opts
       ) do
    if audit_enabled?(opts) do
      request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

      case Observability.record_write_attempt(%{
             org_id: project.org_id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: "project_conversation.created",
             resource_type: "project_conversation",
             resource_id: conversation_id,
             resource_label: conversation_label(conversation_id),
             result: "failed",
             reason: reason,
             request_id: request_id,
             surface: "conversation",
             metadata: conversation_metadata(project, agent, conversation_id, request_id)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, audit_reason} ->
          Logger.warning(
            "conversation_write_attempt_audit_failed reason=#{inspect(audit_reason)}"
          )

          :ok
      end
    end
  end

  defp record_message_event(project, conversation_id, send_result, result, reason, opts) do
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

    attrs = %{
      org_id: project.org_id,
      project_id: project.id,
      actor_user_id: Keyword.get(opts, :actor_user_id),
      domain: "conversation",
      source: "bft.dashboard",
      event_type: "conversation.message.sent",
      severity: conversation_event_severity(result),
      status: result,
      reason_class: conversation_reason_class(result, reason),
      summary: message_event_summary(result),
      resource_type: "project_conversation",
      resource_id: conversation_id,
      correlation_id: request_id,
      evidence: message_metadata(project, conversation_id, send_result, request_id)
    }

    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, event_reason} ->
        Logger.warning("conversation_message_event_failed reason=#{inspect(event_reason)}")
        :ok
    end
  end

  defp maybe_record_message_audit(project, conversation_id, send_result, opts) do
    if audit_enabled?(opts) do
      request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

      case Observability.record_audit(%{
             org_id: project.org_id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: "project_conversation.message_sent",
             resource_type: "project_conversation",
             resource_id: conversation_id,
             resource_label: conversation_label(conversation_id),
             result: "ok",
             request_id: request_id,
             metadata: message_metadata(project, conversation_id, send_result, request_id)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, reason} ->
          Logger.warning("conversation_message_audit_failed reason=#{inspect(reason)}")
          :ok
      end
    end
  end

  defp maybe_record_message_write_attempt(
         {:error, reason},
         project,
         conversation_id,
         client_request_id,
         opts
       ) do
    if audit_enabled?(opts) do
      request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

      case Observability.record_write_attempt(%{
             org_id: project.org_id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: "project_conversation.message_sent",
             resource_type: "project_conversation",
             resource_id: conversation_id,
             resource_label: conversation_label(conversation_id),
             result: "failed",
             reason: reason,
             request_id: request_id,
             surface: "conversation",
             metadata:
               message_metadata(
                 project,
                 conversation_id,
                 %{"client_request_id" => client_request_id},
                 request_id
               )
           }) do
        {:ok, _audit} ->
          :ok

        {:error, audit_reason} ->
          Logger.warning(
            "conversation_message_write_attempt_audit_failed reason=#{inspect(audit_reason)}"
          )

          :ok
      end
    end
  end

  defp conversation_event_severity("failed"), do: "error"
  defp conversation_event_severity(_result), do: "info"

  defp conversation_reason_class("failed", reason), do: reason_class(reason)
  defp conversation_reason_class(_result, _reason), do: nil

  defp conversation_event_summary("failed"), do: "Project conversation creation failed"
  defp conversation_event_summary(_result), do: "Project conversation created"
  defp message_event_summary("failed"), do: "Project conversation message send failed"
  defp message_event_summary(_result), do: "Project conversation message sent"

  defp conversation_metadata(project, agent, conversation_id, request_id) do
    %{
      "project_id" => project.id,
      "salix_group_id" => project.salix_group_id,
      "conversation_id" => conversation_id,
      "agent_id" => agent.id,
      "salix_agent_id" => agent.salix_agent_id,
      "request_id" => request_id
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp message_metadata(project, conversation_id, send_result, request_id) do
    %{
      "project_id" => project.id,
      "salix_group_id" => project.salix_group_id,
      "conversation_id" => conversation_id,
      "message_id" => safe_result_value(send_result, "message_id"),
      "client_request_id" => safe_result_value(send_result, "client_request_id"),
      "delivery_status" => safe_result_value(send_result, "delivery_status"),
      "inserted" => safe_result_value(send_result, "inserted"),
      "request_id" => request_id
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp safe_result_value(send_result, key) when is_map(send_result) do
    case Map.get(send_result, key) do
      value when is_binary(value) or is_boolean(value) -> value
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp safe_result_value(_send_result, _key), do: nil

  defp dashboard_message_request_id(request_id) when is_binary(request_id) and request_id != "",
    do: "dash-" <> request_id

  defp dashboard_message_request_id(_request_id), do: "dash-" <> Ecto.UUID.generate()

  defp reason_class(reason) when reason in [:not_found, :missing, :unknown_agent], do: "not_found"
  defp reason_class(reason) when reason in [:unauthorized, :forbidden], do: "permission"
  defp reason_class(:unavailable), do: "unavailable"
  defp reason_class({:validation, _reason}), do: "validation"
  defp reason_class(%Ecto.Changeset{}), do: "validation"
  defp reason_class(_reason), do: "runtime"

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp conversation_label(conversation_id), do: "Conversation #{short_id(conversation_id)}"

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id) when is_binary(id) and id != "", do: id
  defp short_id(_id), do: "conversation"

  defp stringify(map) do
    Map.new(map || %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
