defmodule BridgeForTeams.Conversations do
  @moduledoc """
  Conversation read context for project-scoped dashboard surfaces.

  BridgeForTeams stores the project and agent records in Postgres, while
  conversation records live in Salix under the project's group id. This module
  keeps that Salix boundary behind the configured client implementation.
  """

  require Logger

  alias BridgeForTeams.{Accounts, Memberships, Observability, WorkspaceItems}
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

  @doc "Update generic mutable fields on a project conversation."
  @spec update_project_conversation(Project.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def update_project_conversation(
        %Project{salix_group_id: group_id} = project,
        conversation_id,
        attrs
      )
      when is_binary(conversation_id) and is_map(attrs) do
    client = Client.impl()
    attrs = stringify(attrs)

    with {:ok, attrs} <-
           preserve_workspace_presentation_on_update(
             client,
             group_id,
             conversation_id,
             attrs
           ) do
      client.update_group_conversation(group_id, conversation_id, attrs)
      |> project_committed_conversation(project)
    end
  end

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
        %Project{salix_group_id: group_id} = project,
        conversation_id,
        review_version
      )
      when is_binary(conversation_id) and is_integer(review_version) and
             review_version > 0 do
    Client.impl().accept_task_review(group_id, conversation_id, review_version)
    |> project_committed_conversation(project)
  end

  @doc "Synchronously project one committed Conversation onto local workspace rows."
  @spec project_project_conversation(Project.t(), String.t() | map()) ::
          {:ok, [BridgeForTeams.WorkspaceItems.Item.t()]} | {:error, term()}
  def project_project_conversation(%Project{} = project, conversation_id)
      when is_binary(conversation_id) do
    with {:ok, conversation} <- get_project_conversation(project, conversation_id) do
      project_project_conversation(project, conversation)
    end
  end

  def project_project_conversation(%Project{} = project, conversation)
      when is_map(conversation) do
    BridgeForTeams.DashboardProjection.project_conversations(project, [conversation])
  end

  @doc "Apply a user workspace edit to its canonical Conversation, then reread the projection."
  @spec update_workspace_item(Project.t(), WorkspaceItems.Item.t(), map()) ::
          {:ok, WorkspaceItems.Item.t()} | {:error, term()}
  def update_workspace_item(%Project{} = project, %WorkspaceItems.Item{} = item, attrs)
      when is_map(attrs) do
    case item.salix_conversation_id do
      conversation_id when is_binary(conversation_id) and conversation_id != "" ->
        update_canonical_workspace_item(project, item, conversation_id, stringify(attrs))

      _local_only ->
        WorkspaceItems.update_task(item, attrs)
    end
  end

  @doc "Soft-archive a workspace item through its canonical Conversation when linked."
  @spec archive_workspace_item(Project.t(), WorkspaceItems.Item.t()) ::
          {:ok, WorkspaceItems.Item.t()} | {:error, term()}
  def archive_workspace_item(%Project{} = project, %WorkspaceItems.Item{} = item) do
    case item.salix_conversation_id do
      conversation_id when is_binary(conversation_id) and conversation_id != "" ->
        with {:ok, conversation} <- get_project_conversation(project, conversation_id),
             {:ok, archived} <-
               Client.impl().set_task_archived(
                 project.salix_group_id,
                 conversation_id,
                 :archive,
                 conversation["updated_at"]
               ),
             {:ok, _items} <- project_project_conversation(project, archived),
             {:ok, projected} <- reread_workspace_item(item, project, conversation_id) do
          {:ok, projected}
        end

      _local_only ->
        WorkspaceItems.update_task(item, %{
          "status" => "archived",
          "archived_at" => DateTime.utc_now()
        })
    end
  end

  @doc "Accept the exact reviewed Task version and synchronously reread its workspace row."
  @spec accept_workspace_item_review(Project.t(), WorkspaceItems.Item.t()) ::
          {:ok, WorkspaceItems.Item.t()} | {:error, term()}
  def accept_workspace_item_review(
        %Project{} = project,
        %WorkspaceItems.Item{salix_conversation_id: conversation_id} = item
      )
      when is_binary(conversation_id) and conversation_id != "" do
    with {:ok, %{"kind" => "agent_task", "updated_at" => review_version}}
         when is_integer(review_version) and review_version > 0 <-
           get_project_conversation(project, conversation_id),
         {:ok, accepted} <-
           accept_project_task_review(project, conversation_id, review_version),
         {:ok, _items} <- project_project_conversation(project, accepted),
         {:ok, projected} <- reread_workspace_item(item, project, conversation_id) do
      {:ok, projected}
    else
      {:ok, %{"kind" => _other}} -> update_workspace_item(project, item, %{"status" => "done"})
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_response}
    end
  end

  def accept_workspace_item_review(%Project{} = project, %WorkspaceItems.Item{} = item),
    do: update_workspace_item(project, item, %{"status" => "done"})

  defp update_canonical_workspace_item(project, item, conversation_id, attrs) do
    with {:ok, conversation} <- get_project_conversation(project, conversation_id),
         updates <- canonical_workspace_updates(conversation, item, attrs),
         {:ok, updated} <- update_project_conversation(project, conversation_id, updates),
         {:ok, _items} <- project_project_conversation(project, updated),
         {:ok, projected} <- reread_workspace_item(item, project, conversation_id) do
      {:ok, projected}
    end
  end

  defp canonical_workspace_updates(conversation, item, attrs) do
    metadata =
      conversation
      |> Map.get("metadata", %{})
      |> map_value()
      |> put_workspace_metadata("workspace_category", attrs, "category", item.category)
      |> put_workspace_metadata("payload", attrs, "payload", item.payload || %{})
      |> put_workspace_metadata("source", attrs, "source", item.source)
      |> put_workspace_metadata("platform", attrs, "platform", item.platform)
      |> put_workspace_metadata("description", attrs, "description", item.description)
      |> put_workspace_metadata(
        "external_source",
        attrs,
        "external_source",
        item.external_source
      )
      |> put_workspace_metadata("external_id", attrs, "external_id", item.external_id)
      |> put_workspace_metadata(
        "archived_at",
        attrs,
        "archived_at",
        encode_datetime(item.archived_at)
      )
      |> Map.delete("workflow_summary")
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{"metadata" => metadata}
    |> put_if_present("title", attrs, "title")
    |> put_if_present("activity_status", attrs, "activity_status")
    |> put_if_present("labels", attrs, "labels")
    |> put_if_present("latest_artifact", attrs, "latest_artifact")
    |> put_if_present("artifact_manifest", attrs, "artifact_manifest")
    |> put_conversation_status(conversation, attrs)
  end

  defp put_workspace_metadata(metadata, key, attrs, attr_key, fallback) do
    value =
      case Map.fetch(attrs, attr_key) do
        {:ok, value} -> encode_metadata_value(value)
        :error -> Map.get(metadata, key, encode_metadata_value(fallback))
      end

    Map.put(metadata, key, value)
  end

  defp put_conversation_status(updates, conversation, attrs) do
    case Map.fetch(attrs, "status") do
      {:ok, status} ->
        Map.put(updates, "status", conversation_status(conversation["kind"], status))

      :error ->
        updates
    end
  end

  defp conversation_status("agent_task", "done"), do: "completed"

  defp conversation_status("agent_task", status) when status in ["accepted", "in_progress"],
    do: "active"

  defp conversation_status(_kind, status), do: status

  defp put_if_present(result, key, attrs, attr_key) do
    case Map.fetch(attrs, attr_key) do
      {:ok, value} -> Map.put(result, key, value)
      :error -> result
    end
  end

  defp reread_workspace_item(item, project, conversation_id) do
    WorkspaceItems.get_task(item.row_user_id || item.user_id, conversation_id,
      project_id: project.id
    )
  end

  defp encode_metadata_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_metadata_value(value), do: value
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(_value), do: nil
  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}

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

  @doc "List conversations for a project's Salix group."
  @spec list_project_conversations(Project.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_project_conversations(%Project{salix_group_id: group_id} = project, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    result =
      case Client.impl().list_group_conversations(group_id, limit: limit) do
        {:ok, %{"data" => conversations}} when is_list(conversations) -> {:ok, conversations}
        {:ok, conversations} when is_list(conversations) -> {:ok, conversations}
        {:ok, _other} -> {:ok, []}
        {:error, reason} -> {:error, reason}
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

  @doc """
  Create a project conversation bound to an agent participant.

  `attrs["kind"]` keeps the BFT presentation term. `"user_chat"` (the default)
  is written to Salix as `user_chat`; every work-item term is written as the
  canonical `agent_task` kind and, when recognized, retains its dashboard
  category in conversation metadata.
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
      |> put_workspace_presentation(attrs["kind"])

    result =
      Client.impl().create_group_conversation(group_id, conversation_attrs)

    case result do
      {:ok, conversation} ->
        persisted_conversation_id = conversation["conversation_id"]
        record_conversation_event(project, agent, persisted_conversation_id, "ok", nil, opts)
        maybe_record_conversation_audit(project, agent, persisted_conversation_id, opts)
        maybe_project_conversation(project, conversation)
        {:ok, conversation}

      {:error, reason} = err ->
        record_conversation_event(project, agent, nil, "failed", reason, opts)
        maybe_record_conversation_write_attempt(err, project, agent, nil, opts)
        err
    end
  end

  @doc """
  Record a completed BFT work session as a canonical `agent_task` conversation
  containing the agent's execution-log messages. This is how proactively
  finished work (the New Home board) carries a real, inspectable session: the
  dashboard shows the log, and the user reviews the result.

  Participants suppress ordinary message notifications so recording the log
  does not schedule the agent runtime. Returns `{:ok, conversation_id}`.
  """
  @spec record_agent_session(Project.t(), Agent.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def record_agent_session(
        %Project{salix_group_id: group_id},
        %Agent{} = agent,
        title,
        log_messages
      )
      when is_binary(title) and is_list(log_messages) do
    participants =
      participants(agent)
      |> Enum.map(
        &Map.put(
          &1,
          "notification_filter",
          %{"messages" => "none", "statuses" => "none"}
        )
      )

    with {:ok, conversation} <-
           Client.impl().create_group_conversation(group_id, %{
             "title" => title,
             "kind" => "agent_task",
             "participants" => participants
           }) do
      persisted_id = conversation["conversation_id"]

      Enum.each(log_messages, fn text ->
        Client.impl().append_group_conversation_message(group_id, persisted_id, %{
          "client_request_id" => "tasklog-" <> Ecto.UUID.generate(),
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => agent.salix_agent_id,
          "agent_name" => agent.salix["name"],
          "content" => [%{"type" => "text", "text" => text}],
          "metadata" => %{"source" => "bridge_for_teams_dashboard"}
        })
      end)

      {:ok, persisted_id}
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
  The runtime session id under which `agent` runs `conversation_id`'s turns.
  A worker uses its per-conversation session. A router uses the canonical
  session persisted on its Salix agent control record.
  """
  @spec conversation_session_ids(Project.t(), Agent.t() | nil, String.t() | nil) :: [String.t()]
  def conversation_session_ids(
        %Project{} = project,
        %Agent{role: "worker", salix_agent_id: agent_id},
        conversation_id
      )
      when is_binary(conversation_id) and conversation_id != "",
      do: conversation_participant_session_ids(project, conversation_id, agent_id)

  def conversation_session_ids(
        %Project{salix_group_id: group_id},
        %Agent{role: "router", salix_agent_id: agent_id},
        _conversation_id
      )
      when is_binary(group_id) and group_id != "" and is_binary(agent_id) and agent_id != "" do
    with true <- Ids.valid_group_id?(group_id),
         tenant_id <- Ids.tenant_id_from_group!(group_id),
         {:ok, router_agent} <- Client.impl().get_agent_projection(agent_id, tenant_id),
         {:ok, session_id} <-
           SalixStore.RuntimeIds.persisted_router_session_id(router_agent) do
      [session_id]
    else
      _ -> []
    end
  end

  def conversation_session_ids(%Project{} = project, nil, conversation_id)
      when is_binary(conversation_id) and conversation_id != "" do
    conversation_participant_session_ids(project, conversation_id, nil)
  end

  def conversation_session_ids(%Project{}, nil, _conversation_id), do: []

  def conversation_session_ids(%Project{}, _agent, _conversation_id), do: []

  defp conversation_participant_session_ids(project, conversation_id, agent_id) do
    case get_project_conversation(project, conversation_id) do
      {:ok, conversation} ->
        conversation
        |> trace_participant_candidates()
        |> Enum.filter(&(is_nil(agent_id) or &1.agent_id == agent_id))
        |> Enum.map(& &1.session_id)
        |> Enum.uniq()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  The compaction marker for `conversation_id`'s chat: the summed
  `summary_sequence` of the runtime sessions the agent may run it in
  (`conversation_session_ids/3`). It grows whenever one of those sessions
  compacts its transcript, so a caller that wrote durable context into the
  conversation can tell "the transcript was summarized since my last send"
  and re-send. Best-effort: an unreachable runtime (or a scripted test client
  without the read) answers 0.
  """
  @spec conversation_compaction_marker(Project.t(), Agent.t() | nil, String.t() | nil) ::
          non_neg_integer()
  def conversation_compaction_marker(%Project{} = project, agent, conversation_id) do
    impl = Client.impl()

    with %Agent{salix_agent_id: agent_id} when is_binary(agent_id) and agent_id != "" <- agent,
         sessions when sessions != [] <- conversation_session_ids(project, agent, conversation_id),
         true <- Code.ensure_loaded?(impl) and function_exported?(impl, :list_sessions, 2),
         {:ok, listed} when is_list(listed) <- impl.list_sessions(agent_id, include_hidden: true) do
      listed
      |> Enum.filter(&(is_map(&1) and &1["session_id"] in sessions))
      |> Enum.map(fn session ->
        case session["summary_sequence"] do
          seq when is_integer(seq) and seq > 0 -> seq
          _missing -> 0
        end
      end)
      |> Enum.sum()
    else
      _missing_or_error -> 0
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

  def bft_participant_attrs, do: @bft_participant

  def ensure_project_bft_participant(
        %Project{salix_group_id: group_id},
        conversation_id
      ) do
    Client.impl().ensure_group_conversation_provider_participant(
      group_id,
      conversation_id,
      bft_participant_attrs()
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

  defp put_workspace_presentation(conversation_attrs, requested_kind)
       when is_binary(requested_kind) do
    kind = String.trim(requested_kind)

    if kind != "agent_task" and kind in WorkspaceItems.kinds() do
      case Map.get(conversation_attrs, "metadata") do
        nil ->
          Map.put(conversation_attrs, "metadata", %{
            "workspace_category" => WorkspaceItems.category_for_kind(kind)
          })

        metadata when is_map(metadata) ->
          Map.put(
            conversation_attrs,
            "metadata",
            Map.put_new(metadata, "workspace_category", WorkspaceItems.category_for_kind(kind))
          )

        _invalid_metadata ->
          conversation_attrs
      end
    else
      conversation_attrs
    end
  end

  defp put_workspace_presentation(conversation_attrs, _requested_kind),
    do: conversation_attrs

  defp preserve_workspace_presentation_on_update(
         client,
         group_id,
         conversation_id,
         %{"metadata" => metadata} = attrs
       )
       when is_map(metadata) do
    case client.get_group_conversation(group_id, conversation_id) do
      {:ok, %{"metadata" => existing_metadata}} when is_map(existing_metadata) ->
        workspace_category = existing_metadata["workspace_category"]

        if is_binary(workspace_category) and workspace_category != "" do
          {:ok,
           Map.put(
             attrs,
             "metadata",
             Map.put_new(metadata, "workspace_category", workspace_category)
           )}
        else
          {:ok, attrs}
        end

      {:ok, _conversation} ->
        {:ok, attrs}

      {:error, _reason} = error ->
        error
    end
  end

  defp preserve_workspace_presentation_on_update(
         _client,
         _group_id,
         _conversation_id,
         attrs
       ),
       do: {:ok, attrs}

  defp project_committed_conversation({:ok, conversation} = result, project) do
    maybe_project_conversation(project, conversation)
    result
  end

  defp project_committed_conversation(result, _project), do: result

  defp maybe_project_conversation(project, conversation) do
    case BridgeForTeams.DashboardProjection.project_conversations(project, [conversation]) do
      {:ok, _items} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "project_conversation_projection_failed project_id=#{project.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "project_conversation_projection_failed project_id=#{project.id} reason=#{Exception.message(error)}"
      )

      :ok
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
