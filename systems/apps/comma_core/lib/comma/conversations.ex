defmodule Comma.Conversations do
  @moduledoc """
  Group-addressed Comma product facade over Salix Conversations.

  Salix owns canonical Chat and Task identity, metadata, messages,
  participants, idempotency, delivery, and runtime state. Comma authorizes the
  exact Group through its account context and returns canonical Messages to the
  client unchanged. Comma stores no Conversation binding, Message DTO, or Task
  list projection.

  Comma's send-time policy for an explicitly reassigned Group Router is modeled
  in `tla/salix/CommaAssistantRouterReassignment.tla`.

  Exact Participant status ownership and explicit Message egress are specified
  by
  `docs/salix/conversation-owner-actor.md`.
  The client-side Activity v2 identity reducer remains modeled in
  `tla/salix/ActivityPresentation.tla`; Participant routing and subscription
  are enforced by the SalixIM owner tests. Summary-class admission and egress
  sanitization are modeled in `tla/salix/ActivitySummaryAuthority.tla`.
  """

  require SystemsRuntime.Proc

  alias Comma.{AgentPolicies, Workspaces}
  alias SalixStore.SearchDocumentEnvelope

  @transcript_limit 1000
  @suggestion_page_limit 50
  @suggestion_max_pages 20
  @task_order_bucket_name_limit 64
  @task_order_id_limit 500
  @conversation_page_default 50
  @conversation_page_max 50

  @public_activity_keys [
    "phase",
    "status",
    "action",
    "summary",
    "summary_class",
    "goal",
    "target",
    "tool_name",
    "display_strength",
    "display_priority",
    "display_hold_ms",
    "producer_epoch",
    "response_key",
    "sequence",
    "source_message_ids",
    "updated_at"
  ]
  @public_activity_prose_max_codepoints 512

  def list(user, session, group_id) do
    with {:ok, page} <- list_page(user, session, group_id, []) do
      {:ok, page["data"]}
    end
  end

  def list_page(user, session, group_id, opts) when is_list(opts) do
    with {:ok, archive} <- archive_filter(Keyword.get(opts, :archive)),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace) do
      scoped_conversation_id = session["conversation_id"]
      limit = conversation_page_limit(Keyword.get(opts, :limit))

      if is_binary(scoped_conversation_id) do
        with {:ok, page} <- list_scoped_conversation_page(user, workspace, scoped_conversation_id),
             do: {:ok, Map.update!(page, "data", &filter_archived(&1, archive))}
      else
        with {:ok, page} <-
               salix_list_group_conversations(workspace,
                 kind: "agent_task",
                 archive: archive,
                 limit: limit,
                 cursor: Keyword.get(opts, :cursor)
               ),
             {:ok, conversations} <- present_tasks(workspace, page["data"] || [], user, archive) do
          conversations =
            if is_nil(Keyword.get(opts, :cursor)) and is_nil(workspace["home_group_id"]) do
              collab_tasks =
                hosted_collaboration_tasks(workspace, user, archive, limit)

              (conversations ++ collab_tasks)
              |> Enum.uniq_by(& &1["id"])
              |> Enum.sort_by(&(&1["updated_at"] || 0), :desc)
              |> Enum.take(limit)
            else
              conversations
            end

          {:ok,
           %{
             "data" => conversations,
             "has_more" => page["has_more"] == true,
             "next_cursor" => page["next_cursor"]
           }}
        end
      end
    end
  end

  @doc """
  Search authorized canonical Tasks by title and plain Message text.

  Restricted sessions push their exact Conversation scope into the indexed
  query, before ranking and limit, so a Group-wide result set is never exposed
  or filtered after the fact.
  """
  def search(user, session, group_id, query, opts \\ []) when is_list(opts) do
    scoped_conversation_id = session["conversation_id"]

    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, hits} <-
           salix_search_group_tasks(
             workspace,
             query,
             [limit: Keyword.get(opts, :limit)]
             |> maybe_put_keyword(:conversation_id, scoped_conversation_id)
           ),
         {:ok, data} <- public_search_results(hits) do
      {:ok, %{"data" => data}}
    end
  end

  @doc """
  The Messages of one Task whose text matches `query`, oldest first, each as
  its id and `seq`: a client steps through them in the Task. A session scoped
  to another Task finds none.
  """
  def search_task_messages(user, session, group_id, conversation_id, query) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, matches} <-
           salix_task_message_matches(
             workspace,
             session["conversation_id"],
             conversation_id,
             to_string(query || "")
           ),
         {:ok, data} <- public_message_matches(matches) do
      {:ok, %{"data" => data}}
    end
  end

  @doc """
  One page of the files Agents attached to a Group's Tasks, newest first
  (`SalixIM.TaskFiles`). `"conversation_id"` keeps one Task's files and `"q"`
  finds files whose name contains it; a search answers one page. A session
  scoped to one Task sees only that Task's files. Each file names its Task,
  Message and block index, which the attachment routes read.
  """
  def list_task_files(user, session, group_id, params) when is_map(params) do
    with {:ok, opts} <- task_files_options(params),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, opts} <- task_files_scope(session, group_id, opts),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"files" => files} = page} <- salix_list_task_files(workspace, opts) do
      {:ok, %{"data" => files, "next_cursor" => page["next_cursor"]}}
    else
      {:error, :indexing} -> {:error, :task_files_indexing}
      {:error, :invalid} -> {:error, :invalid_task_files_query}
      {:error, :unavailable} -> {:error, :salix_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @task_files_max_query 128

  defp task_files_options(params) do
    query = params |> Map.get("q") |> to_string() |> String.trim()
    conversation_id = Map.get(params, "conversation_id")
    cursor = Map.get(params, "cursor")
    {default_limit, max_limit} = if query == "", do: {50, 200}, else: {20, 50}

    with {:ok, limit} <- task_files_limit(Map.get(params, "limit"), default_limit, max_limit),
         true <-
           String.length(query) <= @task_files_max_query and not String.contains?(query, <<0>>),
         true <- is_nil(cursor) or (is_binary(cursor) and byte_size(cursor) in 1..1_024),
         true <-
           conversation_id in [nil, ""] or SalixStore.Ids.valid_conversation_id?(conversation_id) do
      {:ok,
       [limit: limit]
       |> maybe_put_keyword(:query, if(query == "", do: nil, else: query))
       |> maybe_put_keyword(:cursor, cursor)
       |> maybe_put_keyword(
         :conversation_id,
         if(conversation_id == "", do: nil, else: conversation_id)
       )}
    else
      _invalid -> {:error, :invalid_task_files_query}
    end
  end

  defp task_files_limit(nil, default, _max), do: {:ok, default}

  defp task_files_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} -> task_files_limit(limit, default, max)
      _invalid -> {:error, :invalid_task_files_query}
    end
  end

  defp task_files_limit(limit, _default, max)
       when is_integer(limit) and limit >= 1 and limit <= max,
       do: {:ok, limit}

  defp task_files_limit(_limit, _default, _max), do: {:error, :invalid_task_files_query}

  # A session scoped to one Task reads only that Task's files.
  defp task_files_scope(session, group_id, opts) do
    case Keyword.get(opts, :conversation_id) || session["conversation_id"] do
      nil ->
        {:ok, opts}

      conversation_id ->
        with :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
             do: {:ok, Keyword.put(opts, :conversation_id, conversation_id)}
    end
  end

  defp salix_list_task_files(workspace, opts) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :list_task_files, 2) do
      client.list_task_files(workspace, opts)
    else
      {:error, :salix_conversation_read_not_supported}
    end
  end

  @doc "List the authorized canonical Tasks pinned in a Group."
  def list_pinned_tasks(user, session, group_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"data" => pins}} when is_list(pins) <-
           salix_list_group_conversation_pins(workspace) do
      pinned =
        Enum.flat_map(pins, fn pin ->
          with conversation_id when is_binary(conversation_id) <- pin["conversation_id"],
               :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
               {:ok, %{"kind" => "agent_task"} = binding} <-
                 authorized_binding(user, workspace, conversation_id),
               false <- binding["status"] == "archived",
               pinned_at when is_integer(pinned_at) <- pin["pinned_at"] do
            [{binding, pinned_at}]
          else
            _not_visible_or_not_a_task -> []
          end
        end)

      with {:ok, bindings} <- put_task_loops(Enum.map(pinned, &elem(&1, 0)), workspace) do
        data =
          Enum.zip_with(bindings, pinned, fn binding, {_binding, pinned_at} ->
            %{"conversation" => public_summary(binding), "pinned_at" => pinned_at}
          end)

        {:ok, %{"data" => data}}
      end
    else
      {:error, _reason} = error -> error
      _invalid_pin_list -> {:error, :invalid_salix_conversation_list}
    end
  end

  @doc "Pin one authorized canonical Task through its Group collection owner."
  def pin_task(user, session, group_id, conversation_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"} = binding} <-
           authorized_binding(user, workspace, conversation_id),
         {:ok, pin} <- salix_pin_group_conversation(workspace, conversation_id),
         pinned_at when is_integer(pinned_at) <- pin["pinned_at"],
         {:ok, [binding]} <- put_task_loops([binding], workspace) do
      {:ok,
       %{
         "conversation" => public_summary(binding),
         "pinned_at" => pinned_at
       }}
    else
      {:ok, %{"kind" => kind}} -> {:error, {:unsupported_for_kind, kind, "pin"}}
      {:error, _reason} = error -> error
      _invalid_pin -> {:error, :invalid_salix_conversation_pin}
    end
  end

  @doc "Unpin one authorized canonical Task through its Group collection owner."
  def unpin_task(user, session, group_id, conversation_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"}} <-
           authorized_binding(user, workspace, conversation_id),
         :ok <- salix_unpin_group_conversation(workspace, conversation_id) do
      :ok
    else
      {:ok, %{"kind" => kind}} -> {:error, {:unsupported_for_kind, kind, "unpin"}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Read the Group's stored Task-board arrangement: the per-bucket id order its
  members dragged cards into. Buckets are client vocabulary and ids may point
  at Tasks that have moved on — clients layer the order over the live list. An
  exact Conversation-scoped session receives only its authorized id.
  """
  def get_task_order(user, session, group_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, nil),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"orders" => orders}} when is_map(orders) <-
           Comma.Salix.Client.impl().get_group_task_order(workspace) do
      {:ok, %{"orders" => scoped_task_orders(orders, session, group_id)}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_salix_task_order}
    end
  end

  @doc "Replace one bucket's stored Task order for the Group-scoped caller."
  def put_task_order(user, session, group_id, bucket, conversation_ids) do
    with :ok <- validate_task_order_request(bucket, conversation_ids),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- task_order_write_scope(session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"orders" => orders}} when is_map(orders) <-
           Comma.Salix.Client.impl().put_group_task_order(workspace, bucket, conversation_ids) do
      {:ok, %{"orders" => orders}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_salix_task_order}
    end
  end

  defp validate_task_order_request(bucket, conversation_ids) do
    cond do
      not (is_binary(bucket) and bucket != "" and
               byte_size(bucket) <= @task_order_bucket_name_limit) ->
        {:error, :invalid_task_order_bucket}

      not (is_list(conversation_ids) and
             length(conversation_ids) <= @task_order_id_limit and
               Enum.all?(conversation_ids, &is_binary/1)) ->
        {:error, :invalid_task_order}

      true ->
        :ok
    end
  end

  defp scoped_task_orders(orders, %{"restricted" => true} = session, group_id) do
    Enum.reduce(orders, %{}, fn {bucket, conversation_ids}, scoped ->
      visible_ids =
        Enum.filter(conversation_ids, fn conversation_id ->
          Workspaces.group_session_scope(session, group_id, conversation_id) == :ok
        end)

      if visible_ids == [], do: scoped, else: Map.put(scoped, bucket, visible_ids)
    end)
  end

  defp scoped_task_orders(orders, _session, _group_id), do: orders

  # Replacing one bucket is a Group-wide mutation: even an ids list containing
  # only the scoped Conversation would delete every hidden member of that
  # bucket. Exact Conversation-scoped sessions therefore remain read-only for
  # this aggregate; Group-scoped restricted sessions retain Group authority.
  defp task_order_write_scope(session, group_id) do
    with :ok <- Workspaces.group_session_scope(session, group_id, nil) do
      case session do
        %{"restricted" => true, "conversation_id" => conversation_id}
        when not is_nil(conversation_id) ->
          {:error, :forbidden}

        _unrestricted_or_group_scoped ->
          :ok
      end
    end
  end

  @doc "Subscribe to opaque invalidations for the canonical Group Task list."
  def list_events(user, session, group_id, conversation_id \\ nil) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         :ok <- authorize_task_status(user, workspace, conversation_id),
         {:ok, subscription} <- subscribe_task_list(workspace),
         true <- subscription["resync_required"] == true,
         version when is_binary(version) and version != "" <- subscription["version"] do
      task_participants = subscribe_task_participants(workspace, conversation_id)

      {worker_sessions, worker_roster_sync_pending, worker_roster_sync_halted} =
        subscribe_task_worker_sessions(workspace, conversation_id, task_participants)

      {:ok,
       %{
         group_id: group_id,
         kind: "agent_task",
         owner_pid: subscription["owner_pid"],
         resync_required: true,
         version: version,
         workspace: workspace,
         conversation_id: conversation_id,
         task_participants: task_participants,
         worker_sessions: worker_sessions,
         worker_roster_sync_pending: worker_roster_sync_pending,
         worker_roster_sync_halted: worker_roster_sync_halted,
         task_run: subscribed_task_run(workspace, conversation_id)
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_salix_conversation_list_subscription}
    end
  end

  @doc """
  The Tasks the Group's stations host, as the stations last sent them
  (`SalixWeb.StationTaskIndex`), the latest activity first: each one's
  station, Device, thread, title, status, creator, times, runtime and model,
  never its messages. Of a still.fail station only the chats Comma's Router
  wrote in, each with `url`, its page in still.fail, where a client opens it
  (null for any other station's). A session restricted to one conversation
  sees none.
  """
  def station_tasks(user, session, group_id) do
    client = Comma.Salix.Client.impl()

    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, nil),
         {:ok, rows} <- fetch_station_tasks(client, workspace, user) do
      {:ok, %{"tasks" => Enum.map(rows, &public_station_task/1)}}
    end
  end

  defp fetch_station_tasks(client, workspace, user) do
    cond do
      callback_exported?(client, :list_station_tasks, 2) ->
        member_scope = %{
          email: resolve_station_member_email(user),
          is_owner: is_binary(user["id"]) and workspace["owner_user_id"] == user["id"]
        }

        client.list_station_tasks(workspace, member_scope)

      callback_exported?(client, :list_station_tasks, 1) ->
        client.list_station_tasks(workspace)

      true ->
        {:error, :station_tasks_not_supported}
    end
  end

  defp resolve_station_member_email(%{"email" => email}) when is_binary(email) and email != "",
    do: email |> String.trim() |> String.downcase()

  defp resolve_station_member_email(%{"id" => user_id}) when is_binary(user_id) do
    case Comma.Accounts.get_user(user_id) do
      {:ok, %{"email" => email}} when is_binary(email) and email != "" ->
        email |> String.trim() |> String.downcase()

      _ ->
        nil
    end
  end

  defp resolve_station_member_email(_user), do: nil

  defp public_station_task(row) do
    ~w(station_id device_id thread task title status created_by created_at last_activity_at runtime model url rev)a
    |> Map.new(&{Atom.to_string(&1), Map.get(row, &1)})
    |> Map.put("labels", Map.get(row, :labels) || [])
  end

  @doc """
  Sends the calling process `{:station_tasks_invalidated, group_id}` each
  time a station of the Group changes its Tasks (`station_tasks/3`).
  """
  def subscribe_station_tasks(workspace) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :subscribe_station_tasks, 2),
      do: client.subscribe_station_tasks(workspace, SystemsRuntime.Proc.self()),
      else: {:error, :station_tasks_not_supported}
  end

  @doc """
  Subscribe to every change of the Group's conversations this session may see:
  each `agent_task`, the Workspace's Router chat, and only the scoped
  conversation for a session restricted to one. A client keeps its copies in
  sync from these and resyncs on every (re)connect: versions are hints, not a
  replayable log.
  """
  def change_events(user, session, group_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, nil),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, subscription} <- subscribe_group_changes(workspace),
         version when is_binary(version) and version != "" <- subscription["version"] do
      {:ok,
       %{
         group_id: group_id,
         owner_pid: subscription["owner_pid"],
         version: version,
         router_conversation_id: workspace["router_conversation_id"],
         scoped_conversation_id: scoped_conversation_id(session)
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_salix_conversation_list_subscription}
    end
  end

  @doc """
  The `conversation_changed` frame for a Group mutation, or nil when this
  session may not see the conversation. A conversation that left what the
  session may see (its kind changed) reads as deleted.
  """
  def change_frame(context, %{event: event, conversation_id: conversation_id} = mutation, version)
      when is_binary(version) do
    kind = mutation[:kind]
    previous_kind = mutation[:previous_kind]

    cond do
      not in_change_scope?(context, conversation_id) ->
        nil

      visible_kind?(context, conversation_id, kind) ->
        change_json(context, conversation_id, kind, change_name(event), mutation[:seq], version)

      visible_kind?(context, conversation_id, previous_kind) ->
        change_json(context, conversation_id, previous_kind, "delete", nil, version)

      true ->
        nil
    end
  end

  def change_frame(_context, _mutation, _version), do: nil

  defp in_change_scope?(%{scoped_conversation_id: nil}, conversation_id),
    do: is_binary(conversation_id)

  defp in_change_scope?(%{scoped_conversation_id: scoped}, conversation_id),
    do: conversation_id == scoped

  defp visible_kind?(_context, _conversation_id, "agent_task"), do: true

  defp visible_kind?(%{router_conversation_id: router}, conversation_id, "user_chat"),
    do: is_binary(router) and conversation_id == router

  defp visible_kind?(_context, _conversation_id, _kind), do: false

  defp change_name(:message_created), do: "message"
  defp change_name(:conversation_delete), do: "delete"
  defp change_name(_upsert), do: "upsert"

  defp change_json(context, conversation_id, kind, change, seq, version) do
    frame = %{
      "type" => "conversation_changed",
      "group_id" => context.group_id,
      "conversation_id" => conversation_id,
      "kind" => kind,
      "change" => change,
      "version" => version
    }

    if change == "message" and is_integer(seq), do: Map.put(frame, "seq", seq), else: frame
  end

  defp scoped_conversation_id(%{"restricted" => true, "conversation_id" => id})
       when is_binary(id) and id != "",
       do: id

  defp scoped_conversation_id(_session), do: nil

  defp subscribe_group_changes(workspace) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :subscribe_group_conversation_mutations, 2) do
      client.subscribe_group_conversation_mutations(workspace, SystemsRuntime.Proc.self())
    else
      {:error, :salix_conversation_list_subscription_not_supported}
    end
  end

  defp authorize_task_status(_user, _workspace, nil), do: :ok

  defp authorize_task_status(user, workspace, conversation_id) do
    case authorized_binding(user, workspace, conversation_id) do
      {:ok, %{"kind" => "agent_task"}} -> :ok
      {:ok, _} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # Where the Task runs and its model change only when a member switches them
  # (`set_task_run/6`), which changes the Task, so each stream reads them once:
  # clients open the stream again after reading a changed Task. Nil when they
  # cannot be read: Task panels then show neither.
  # The exception: what a coding Task's sandbox says of itself (what it
  # serves, what is on its display) changes with no change of the Task. A
  # stream of a Task hears when it does (`subscribed_task_run/2`) and
  # reads the run again (`refresh_task_run/1`): one read for each change, of
  # which a sandbox's connection has one as it connects and one each time a
  # Session's browser opens or goes.
  defp task_run(_workspace, nil), do: nil

  defp task_run(workspace, conversation_id) do
    client = Comma.Salix.Client.impl()

    with true <- callback_exported?(client, :task_run, 2),
         {:ok, run} <- client.task_run(workspace, conversation_id) do
      run
    else
      _ -> nil
    end
  end

  # Subscribed before the read, so a change between the two is not missed. A
  # Task that runs on no sandbox is never told anything.
  defp subscribed_task_run(_workspace, nil), do: nil

  defp subscribed_task_run(workspace, conversation_id) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :subscribe_task_run, 3),
      do: client.subscribe_task_run(workspace, conversation_id, SystemsRuntime.Proc.self())

    task_run(workspace, conversation_id)
  end

  @doc """
  A Task stream's context with its Task's run read again, for a stream told
  that the Task's sandbox said something new (`{:coding_sandbox_said, id}`).
  """
  def refresh_task_run(%{workspace: workspace, conversation_id: conversation_id} = context)
      when is_binary(conversation_id),
      do: %{context | task_run: task_run(workspace, conversation_id)}

  def refresh_task_run(context), do: context

  defp subscribe_task_participants(_workspace, nil), do: %{}

  # Modeled in tla/salix/TaskParticipantStatus.tla. The canonical Task stream
  # stays available when either independent Participant status read fails.
  defp subscribe_task_participants(workspace, conversation_id) do
    client = Comma.Salix.Client.impl()

    with true <- callback_exported?(client, :task_activity_participants, 2),
         {:ok, participants} <- client.task_activity_participants(workspace, conversation_id) do
      participants
      |> Enum.take(2)
      |> Enum.reduce(%{}, fn participant, acc ->
        participant_id = participant["participant_id"]

        context = %{
          workspace: workspace,
          conversation_id: conversation_id,
          source_conversation_id: conversation_id,
          participant_id: participant_id,
          actor_id:
            public_actor_id(
              %{"actor_type" => "agent", "agent_id" => participant["agent_id"]},
              %{"kind" => "agent_task"}
            ),
          actor_role:
            if(is_binary(participant["agent_id"]),
              do: actor_role_from_workspace(participant["agent_id"], workspace)
            ),
          name: participant["name"] || "Agent"
        }

        case client.subscribe_group_conversation_participant(
               workspace,
               conversation_id,
               participant_id,
               SystemsRuntime.Proc.self()
             ) do
          {:ok, %{"owner_pid" => owner, "status" => status}} ->
            Map.put(acc, participant_id, Map.merge(context, %{owner_pid: owner, status: status}))

          {:error, _} ->
            acc
        end
      end)
    else
      _ -> %{}
    end
  end

  defp public_actor_id(
         %{"actor_type" => "agent", "agent_id" => agent_id},
         %{"kind" => "agent_task"}
       )
       when is_binary(agent_id) and agent_id != "" do
    digest =
      :crypto.hash(:sha256, agent_id)
      |> Base.url_encode64(padding: false)

    "actor_" <> digest
  end

  defp public_actor_id(_message, _binding), do: nil

  defp actor_role_from_workspace(agent_id, workspace) do
    if agent_id == workspace["router_agent_id"], do: "router", else: "worker"
  end

  defp subscribe_task_worker_sessions(_workspace, nil, _task_participants), do: {[], false, false}

  defp subscribe_task_worker_sessions(workspace, conversation_id, task_participants) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :task_worker_sessions, 2) do
      case client.task_worker_sessions(workspace, conversation_id) do
        {:ok, sessions} when is_list(sessions) ->
          entries =
            sessions
            |> Enum.take(6)
            |> Enum.map(
              &build_worker_session_entry(&1, workspace, conversation_id, task_participants, %{})
            )

          {entries, false, false}

        {:error, reason} when reason in [:not_found, :forbidden, :unauthorized] ->
          {[], false, true}

        _error ->
          {[], true, false}
      end
    else
      {[], false, false}
    end
  end

  @doc """
  Re-reads the Task's active worker session roster (max 6) and reconciles
  subscriptions on an already-open SSE stream (`task.add_session`, `:DOWN`
  recovery, or roster removals).
  Returns `{next_context, changed?, new_entries, removed_refs}` where
  `new_entries` are newly subscribed (or recovered) entries whose `owner_pid`
  must be monitored by the stream process, and `removed_refs` are monitor refs
  of entries removed from the roster to demonitor.
  """
  def sync_task_worker_sessions(
        %{workspace: workspace, conversation_id: conversation_id} = context
      )
      when is_binary(conversation_id) do
    client = Comma.Salix.Client.impl()
    existing_list = Map.get(context, :worker_sessions, [])
    existing_by_id = Map.new(existing_list, &{&1.participant_id, &1})
    task_participants = Map.get(context, :task_participants, %{})

    if callback_exported?(client, :task_worker_sessions, 2) do
      case client.task_worker_sessions(workspace, conversation_id) do
        {:ok, sessions} when is_list(sessions) ->
          next_list =
            sessions
            |> Enum.take(6)
            |> Enum.map(
              &build_worker_session_entry(
                &1,
                workspace,
                conversation_id,
                task_participants,
                existing_by_id
              )
            )

          next_ids = MapSet.new(next_list, & &1.participant_id)

          new_entries =
            Enum.filter(next_list, fn entry ->
              entry.owner_ref == nil and
                not match?(
                  %{owner_pid: pid} when pid != nil,
                  task_participants[entry.participant_id]
                ) and
                SystemsRuntime.Proc.is_process(entry.owner_pid)
            end)

          removed_refs =
            existing_list
            |> Enum.reject(fn entry ->
              MapSet.member?(next_ids, entry.participant_id) or
                Map.has_key?(task_participants, entry.participant_id)
            end)
            |> Enum.map(& &1.owner_ref)
            |> Enum.filter(&is_reference/1)

          changed? =
            worker_session_roster_signature(existing_list) !=
              worker_session_roster_signature(next_list)

          next_context =
            context
            |> Map.put(:worker_sessions, next_list)
            |> Map.put(:worker_roster_sync_pending, false)
            |> Map.put(:worker_roster_sync_halted, false)

          {next_context, changed?, new_entries, removed_refs}

        {:error, reason} when reason in [:not_found, :forbidden, :unauthorized] ->
          next_context =
            context
            |> Map.put(:worker_roster_sync_pending, false)
            |> Map.put(:worker_roster_sync_halted, true)

          {next_context, false, [], []}

        _error ->
          next_context =
            context
            |> Map.put(:worker_roster_sync_pending, true)
            |> Map.put(:worker_roster_sync_halted, false)

          {next_context, false, [], []}
      end
    else
      next_context =
        context
        |> Map.put(:worker_roster_sync_pending, false)
        |> Map.put(:worker_roster_sync_halted, false)

      {next_context, false, [], []}
    end
  end

  def sync_task_worker_sessions(context), do: {context, false, [], []}

  defp worker_session_roster_signature(sessions) do
    Enum.map(sessions, fn s ->
      {s.participant_id, s.slot, s.label, s.model, s.runtime, s.is_primary, s.owner_pid != nil,
       s.status}
    end)
  end

  defp build_worker_session_entry(
         session,
         workspace,
         conversation_id,
         task_participants,
         existing_by_id
       ) do
    participant_id = session["participant_id"]
    agent_id = session["agent_id"]

    base = %{
      workspace: workspace,
      conversation_id: conversation_id,
      source_conversation_id: conversation_id,
      participant_id: participant_id,
      agent_id: agent_id,
      actor_id:
        public_actor_id(
          %{"actor_type" => "agent", "agent_id" => agent_id},
          %{"kind" => "agent_task"}
        ),
      actor_role: "worker",
      name: session["name"] || session["label"] || "Agent",
      slot: session["slot"] || "lead",
      label: session["label"] || session["name"] || "Agent",
      model: session["model"],
      runtime: session["runtime"],
      is_primary: session["is_primary"] == true,
      owner_pid: nil,
      owner_ref: nil,
      status: nil
    }

    cond do
      match?(%{owner_pid: pid} when pid != nil, existing_by_id[participant_id]) ->
        existing = existing_by_id[participant_id]

        Map.merge(base, %{
          owner_pid: existing.owner_pid,
          owner_ref: existing.owner_ref,
          status: existing.status
        })

      match?(%{owner_pid: pid} when pid != nil, task_participants[participant_id]) ->
        tp = task_participants[participant_id]

        Map.merge(base, %{
          owner_pid: tp[:owner_pid],
          owner_ref: tp[:owner_ref],
          status: tp[:status]
        })

      true ->
        client = Comma.Salix.Client.impl()

        case client.subscribe_group_conversation_participant(
               workspace,
               conversation_id,
               participant_id,
               SystemsRuntime.Proc.self()
             ) do
          {:ok, %{"owner_pid" => owner, "status" => status}} ->
            Map.merge(base, %{owner_pid: owner, status: status})

          {:error, _} ->
            base
        end
    end
  end

  def task_participant_statuses(stream_context) do
    worker_sessions_entries = Map.get(stream_context, :worker_sessions, [])

    bound_worker =
      Enum.find_value(worker_sessions_entries, fn session ->
        if session.is_primary do
          %{"participant_id" => session.participant_id, "name" => session.name}
          |> put_optional("actor_id", session.actor_id)
        end
      end) ||
        Enum.find_value(stream_context.task_participants, fn {id, participant} ->
          if participant.actor_role == "worker" do
            %{"participant_id" => id, "name" => participant.name}
            |> put_optional("actor_id", participant.actor_id)
          end
        end)

    participants =
      stream_context.task_participants
      |> Enum.sort_by(fn {id, _} -> id end)
      # Waiting remains active in the runtime, but is not typing in Task UI.
      # Use the Participant's structured wait, never its display-text status.
      |> Enum.reject(fn {_id, participant} ->
        match?(%{"activity" => %{"state" => "active"}, "wait" => %{}}, participant.status)
      end)
      |> Enum.flat_map(fn {_id, participant} ->
        case public_participant_status(participant.status["activity"], participant) do
          nil ->
            []

          status ->
            [
              status
              |> Map.drop([
                "type",
                "working_conversation_ids",
                "waiting",
                "wait_tool",
                "wait_started_at"
              ])
              |> Map.put("name", participant.name)
              |> put_optional("actor_id", participant.actor_id)
              |> put_optional("actor_role", participant.actor_role)
            ]
        end
      end)
      |> Enum.take(2)

    worker_sessions =
      worker_sessions_entries
      |> Enum.take(6)
      |> Enum.map(&public_worker_session/1)

    %{
      "type" => "task_participant_statuses",
      "group_id" => stream_context.group_id,
      "conversation_id" => stream_context.conversation_id,
      "bound_worker" => bound_worker,
      "participants" => participants
    }
    |> then(fn payload ->
      if worker_sessions == [],
        do: payload,
        else: Map.put(payload, "worker_sessions", worker_sessions)
    end)
    |> put_optional("run", stream_context[:task_run])
  end

  defp public_worker_session(session) do
    waiting? = match?(%{"activity" => %{"state" => "active"}, "wait" => %{}}, session.status)

    activity_status =
      if is_map(session.status) do
        public_participant_status(session.status["activity"], session)
      end

    base =
      %{
        "participant_id" => session.participant_id,
        "slot" => session.slot,
        "label" => session.label,
        "is_primary" => session.is_primary,
        "subscribed" => session.owner_pid != nil
      }
      |> put_optional("actor_id", session.actor_id)
      |> put_optional("model", session.model)
      |> put_optional("runtime", session.runtime)

    case activity_status do
      %{"state" => state, "status" => status, "updated_at" => updated_at} = st ->
        projected_state = if waiting? and state == "active", do: "waiting", else: state

        base
        |> Map.put("state", projected_state)
        |> Map.put("status", status)
        |> Map.put("updated_at", updated_at)
        |> put_optional("issue", st["issue"])
        |> put_optional("issue_detail", st["issue_detail"])

      _ ->
        base
        |> Map.put("state", "stopped")
        |> Map.put("status", "")
    end
  end

  defp list_scoped_conversation_page(user, workspace, conversation_id) do
    bindings =
      case authorized_binding(user, workspace, conversation_id) do
        {:ok, binding} -> [binding]
        {:error, _reason} -> []
      end

    with {:ok, bindings} <- put_task_loops(bindings, workspace) do
      data =
        Enum.map(
          bindings,
          &(&1 |> conversation_summary() |> projected_summary() |> public_summary())
        )

      {:ok, %{"data" => data, "has_more" => false, "next_cursor" => nil}}
    end
  end

  @doc """
  A Conversation with its newest Messages. With `after_seq` (the newest seq
  the client holds) it carries only the Messages after it, as `events/5` does.
  """
  def get(user, session, group_id, conversation_id, opts \\ []) do
    with {:ok, workspace, binding} <-
           authorize_conversation_read(user, session, group_id, conversation_id),
         {:ok, conversation} <- read_conversation(workspace, binding, opts) do
      {:ok, messages_after(conversation, Keyword.get(opts, :after_seq))}
    end
  end

  # The Conversation snapshot and the Message page read share this check.
  @doc """
  The Workspace of a Conversation the member may read, for a resource that
  belongs to it and is stored with its Group (an Agent's request card).
  """
  def authorize_read(user, session, group_id, conversation_id) do
    with {:ok, workspace, _binding} <-
           authorize_conversation_read(user, session, group_id, conversation_id),
         do: {:ok, workspace}
  end

  defp authorize_conversation_read(user, session, group_id, conversation_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, binding} <- authorized_binding(user, workspace, conversation_id),
         :ok <- channel_panel_task_kind(session, binding) do
      {:ok, workspace, binding}
    end
  end

  defp channel_panel_task_kind(%{"session_source" => "channel_task_panel"}, %{
         "kind" => "agent_task"
       }),
       do: :ok

  defp channel_panel_task_kind(%{"session_source" => "channel_task_panel"}, _binding),
    do: {:error, :not_found}

  defp channel_panel_task_kind(_session, _binding), do: :ok

  @doc "Read one bounded page of the exact Participant's execution history."
  def participant_history(user, session, group_id, conversation_id, participant_id, opts) do
    with false <- session["restricted"] == true,
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, _binding} <- authorized_binding(user, workspace, conversation_id) do
      Comma.Salix.Client.impl().get_group_conversation_participant_history(
        workspace,
        conversation_id,
        participant_id,
        opts
      )
    else
      true -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  @doc """
  Read the current canonical Task summary without loading its transcript.

  This endpoint follows Task detail's Group/session authorization. By default it
  reads one exact Salix Conversation. `include_worker` also uses the existing
  two-role identity lookup. Neither path adopts a Conversation or persists a
  projection refresh.
  """
  def preview(user, session, group_id, conversation_id, opts \\ []) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         true <- SalixStore.Ids.valid_conversation_id?(conversation_id),
         {:ok, %{"kind" => "agent_task"} = salix_conversation} <-
           salix_get_group_conversation(workspace, conversation_id),
         binding <- canonical_binding(workspace, salix_conversation, user) do
      preview = public_task_preview(workspace, binding, salix_conversation)

      if Keyword.get(opts, :include_worker, false) do
        # The chat-hosted panel reads only this: a Loop Task's Loop comes with it.
        with {:ok, [looped]} <- put_task_loops([binding], workspace) do
          {:ok,
           preview
           |> Map.put("bound_worker", task_preview_worker(workspace, salix_conversation))
           |> put_optional(
             "worker_sessions",
             task_preview_worker_sessions(workspace, salix_conversation)
           )
           |> put_optional("run", task_run(workspace, conversation_id))
           |> put_optional("loop", looped["loop"])}
        end
      else
        {:ok, preview}
      end
    else
      false -> {:error, :not_found}
      {:ok, _unsupported_conversation} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def update(user, session, group_id, conversation_id, attrs) do
    attrs = stringify(attrs)

    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"}} <-
           authorized_binding(user, workspace, conversation_id),
         {:ok, update} <- requested_task_update(workspace, attrs),
         {:ok, salix_conversation} <-
           salix_update_group_conversation(workspace, conversation_id, update),
         {:ok, [task]} <- present_tasks(workspace, [salix_conversation], user) do
      {:ok, task}
    else
      {:ok, %{"kind" => kind}} -> {:error, {:unsupported_for_kind, kind, "patch"}}
      {:error, _reason} = error -> error
    end
  end

  def cancel(user, session, group_id, conversation_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, binding} <- authorized_binding(user, workspace, conversation_id) do
      {:error, {:unsupported_for_kind, binding["kind"], "cancel"}}
    end
  end

  def set_task_archived(user, session, group_id, conversation_id, action, attrs) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"}} <- authorized_binding(user, workspace, conversation_id),
         version when is_integer(version) and version > 0 <- attrs["expected_updated_at"],
         {:ok, conversation} <-
           Comma.Salix.Client.impl().set_task_archived(
             workspace,
             conversation_id,
             action,
             version
           ),
         {:ok, [task]} <- present_tasks(workspace, [conversation], user) do
      {:ok, task}
    else
      {:error, _} = error -> error
      _ -> {:error, {:bad_request, "Task and positive expected_updated_at are required"}}
    end
  end

  # At most 50 exact summary reads and one read of their Loops' live facts; no
  # transcript hydration, Group scan or per-child RPC.
  def task_summaries(user, session, group_id, ids) when is_list(ids) and length(ids) <= 50 do
    with true <- Enum.all?(ids, &is_binary/1),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace) do
      unique_ids = Enum.uniq(ids)
      collab_groups = hosted_collaboration_group_map(workspace, user, unique_ids)

      Enum.reduce_while(unique_ids, {:ok, []}, fn id, {:ok, bindings} ->
        target_workspace =
          case Map.get(collab_groups, id) do
            nil ->
              workspace

            collab_group_id ->
              workspace
              |> Map.put("default_group_id", collab_group_id)
              |> Map.put("home_group_id", workspace["default_group_id"])
          end

        with :ok <- Workspaces.group_session_scope(session, group_id, id),
             {:ok, %{"kind" => "agent_task"} = binding} <-
               authorized_binding(user, target_workspace, id) do
          {:cont, {:ok, [binding | bindings]}}
        else
          {:error, :not_found} -> {:cont, {:ok, bindings}}
          {:ok, _} -> {:cont, {:ok, bindings}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, bindings} ->
          with {:ok, bindings} <- put_task_loops(Enum.reverse(bindings), workspace),
               do: {:ok, %{"data" => Enum.map(bindings, &public_summary/1)}}

        error ->
          error
      end
    else
      false -> {:error, {:bad_request, "ids must contain strings"}}
      error -> error
    end
  end

  def task_summaries(_, _, _, _), do: {:error, {:bad_request, "At most 50 ids are allowed"}}

  def activity_tasks(user, session, group_id) do
    client = Comma.Salix.Client.impl()

    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- client.resolve_workspace_scope(workspace),
         true <- callback_exported?(client, :list_group_activity_tasks, 1),
         {:ok, %{"data" => conversations}}
         when is_list(conversations) and length(conversations) <= 2 <-
           client.list_group_activity_tasks(workspace),
         # Restricted bearer scopes remain exact; Group activity never widens one.
         {:ok, data} <-
           conversations
           |> Enum.filter(fn conversation ->
             Workspaces.group_session_scope(session, group_id, conversation["conversation_id"]) ==
               :ok and
               authorized_canonical_conversation?(workspace, conversation)
           end)
           |> then(&present_tasks(workspace, &1, user)) do
      {:ok, %{"data" => data}}
    else
      false -> {:error, :salix_conversation_list_not_supported}
      {:error, _} = error -> error
      _ -> {:error, :invalid_salix_task_activity_projection}
    end
  end

  defp hosted_collaboration_tasks(workspace, %{"id" => user_id} = user, archive, limit)
       when is_binary(user_id) do
    import Ecto.Query

    default_group_id = workspace["default_group_id"]

    pairs =
      from(c in Comma.Data.TaskCollaborator,
        where:
          c.workspace_id == ^workspace["id"] and c.host_user_id == ^user_id and
            c.group_id != ^default_group_id,
        group_by: [c.group_id, c.conversation_id],
        order_by: [desc: max(c.inserted_at)],
        limit: ^limit,
        select: {c.group_id, c.conversation_id}
      )
      |> Comma.Repo.all()

    Enum.flat_map(pairs, fn {collab_group_id, conversation_id} ->
      collab_ws =
        workspace
        |> Map.put("default_group_id", collab_group_id)
        |> Map.put("home_group_id", default_group_id)

      with {:ok, resolved} <- Comma.Salix.Client.impl().resolve_workspace_scope(collab_ws),
           {:ok, %{"kind" => "agent_task"} = salix_conv} <-
             Comma.Salix.Client.impl().get_group_conversation(resolved, conversation_id),
           {:ok, [presented]} <- present_tasks(resolved, [salix_conv], user, archive) do
        [presented]
      else
        _ -> []
      end
    end)
  end

  defp hosted_collaboration_tasks(_workspace, _user, _archive, _limit), do: []

  defp hosted_collaboration_group_map(workspace, %{"id" => user_id}, ids)
       when is_binary(user_id) and is_list(ids) and ids != [] do
    import Ecto.Query

    default_group_id = workspace["default_group_id"]

    from(c in Comma.Data.TaskCollaborator,
      where:
        c.workspace_id == ^workspace["id"] and c.host_user_id == ^user_id and
          c.group_id != ^default_group_id and c.conversation_id in ^ids,
      distinct: c.conversation_id,
      select: {c.conversation_id, c.group_id}
    )
    |> Comma.Repo.all()
    |> Map.new()
  end

  defp hosted_collaboration_group_map(_workspace, _user, _ids), do: %{}

  defp archive_filter(nil), do: {:ok, "exclude"}
  defp archive_filter(value) when value in ["exclude", "only", "include"], do: {:ok, value}
  defp archive_filter(_), do: {:error, {:bad_request, "Invalid archive filter"}}
  defp filter_archived(data, mode), do: Enum.filter(data, &archive_kept?(&1, mode))

  defp archive_kept?(_conversation, "include"), do: true

  defp archive_kept?(conversation, mode),
    do: conversation["status"] == "archived" == (mode == "only")

  def accept_task_review(user, session, group_id, conversation_id, attrs, opts \\ []) do
    attrs = stringify(attrs)

    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"} = binding} <-
           authorized_binding(user, workspace, conversation_id),
         {:ok, review_version} <- requested_review_version(attrs),
         {:ok, _accepted_snapshot} <-
           Comma.Salix.Client.impl().accept_task_review(
             workspace,
             salix_conversation_id(binding),
             review_version
           ) do
      Comma.Analytics.capture(
        user["id"],
        "comma_task_review_accepted",
        "#{conversation_id}:#{review_version}",
        %{
          "workspace_id" => workspace["id"],
          "conversation_id" => conversation_id,
          "initiator_kind" => Keyword.get(opts, :initiator_kind, "human")
        }
      )

      read_task_conversation(workspace, binding, opts)
    else
      {:ok, %{"kind" => kind}} -> {:error, {:unsupported_for_kind, kind, "accept"}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Ends an in-progress or in-review Task by hand as `completed` or `cancelled`.
  The Salix Conversation owner checks `expected_updated_at` and tells the
  Task's Agents.
  """
  def set_task_status(user, session, group_id, conversation_id, attrs, opts \\ []) do
    attrs = stringify(attrs)

    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"} = binding} <-
           authorized_binding(user, workspace, conversation_id),
         {:ok, status, version} <- requested_task_status(attrs),
         {:ok, ended} <-
           Comma.Salix.Client.impl().set_task_status(
             workspace,
             salix_conversation_id(binding),
             status,
             version,
             user["id"]
           ) do
      if status == "completed" and
           get_in(ended, ["manual_status_change", "from_status"]) == "ready_for_review" do
        Comma.Analytics.capture(
          user["id"],
          "comma_task_review_accepted",
          "#{conversation_id}:#{version}",
          %{
            "workspace_id" => workspace["id"],
            "conversation_id" => conversation_id,
            "initiator_kind" => "human"
          }
        )
      end

      read_task_conversation(workspace, binding, opts)
    else
      {:ok, %{"kind" => kind}} -> {:error, {:unsupported_for_kind, kind, "status"}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Runs a Task on another model, and so perhaps in another place
  (`SalixIM.TaskRun`): `attrs` names `runs_on` (`{kind: salix}`,
  `{kind: cloud_vm}` or `{kind: station, device_id}`; `{kind: sandbox}` for a
  sandbox Task without a repository, which stays on its sandbox) and `model`
  (a Model Choice, or null for the place's default). Whoever may set the
  Task's status may. The Task as read after.
  """
  def set_task_run(user, session, group_id, conversation_id, attrs, opts \\ []) do
    attrs = stringify(attrs)
    client = Comma.Salix.Client.impl()

    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- client.resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"} = binding} <-
           authorized_binding(user, workspace, conversation_id),
         {:ok, run} <- requested_task_run(attrs),
         true <- callback_exported?(client, :switch_task_run, 4) || {:error, :not_found},
         {:ok, _record} <-
           client.switch_task_run(workspace, salix_conversation_id(binding), run, user["id"]) do
      read_task_conversation(workspace, binding, opts)
    else
      {:ok, %{"kind" => kind}} -> {:error, {:unsupported_for_kind, kind, "run"}}
      {:error, _} = error -> error
    end
  end

  defp requested_task_run(%{"runs_on" => %{} = runs_on} = attrs) do
    model = attrs["model"]

    if Map.keys(attrs) -- ["runs_on", "model"] == [] and (is_map(model) or is_nil(model)),
      do: {:ok, %{"runs_on" => runs_on, "model" => model}},
      else: {:error, {:bad_request, "runs_on is required"}}
  end

  defp requested_task_run(_attrs), do: {:error, {:bad_request, "runs_on is required"}}

  def messages(user, session, group_id, conversation_id) do
    with {:ok, conversation} <- get(user, session, group_id, conversation_id) do
      {:ok, conversation["messages"] || []}
    end
  end

  @doc """
  One bounded page of the canonical transcript, positioned by a Message `seq`.

  The authorization is the same as for `get/5`, and the read does not enter a
  Conversation owner. `opts` accepts `before`, `after`, `around` (at most
  one), and `limit`; see
  `SalixIM.Conversations.list_group_conversation_message_page/3`. `view:
  "activity"` cuts each Message down to what a Task's Activity reads
  (`Comma.TaskActivityMessages`).
  """
  def message_page(user, session, group_id, conversation_id, opts) do
    {view, opts} = Keyword.pop(opts, :view)

    with {:ok, slim} <- page_view(view),
         {:ok, workspace, binding} <-
           authorize_conversation_read(user, session, group_id, conversation_id) do
      client = Comma.Salix.Client.impl()

      if callback_exported?(client, :list_group_conversation_message_page, 3) do
        with {:ok, page} <-
               client.list_group_conversation_message_page(
                 workspace,
                 salix_conversation_id(binding),
                 opts
               ) do
          {:ok, if(slim, do: Map.update(page, "messages", [], &Enum.map(&1, slim)), else: page)}
        end
      else
        {:error, :salix_conversation_read_not_supported}
      end
    end
  end

  ## A Collaborative Task's member (`Comma.Collaborations`)
  #
  # A member is not a member of the host's Workspace: their one authority is
  # their active Task Collaborator row for this Task. These read, write and
  # follow that one Task, and nothing else of the host's Group.

  @doc "The Task a member of it reads: as `get/5`, for the Task alone."
  def member_get(user, session, group_id, conversation_id, opts \\ []) do
    with {:ok, workspace, binding} <- authorize_member(user, session, group_id, conversation_id),
         {:ok, conversation} <- read_conversation(workspace, binding, opts) do
      {:ok, messages_after(conversation, Keyword.get(opts, :after_seq))}
    end
  end

  @doc "One page of the Task's transcript for a member: as `message_page/5`."
  def member_message_page(user, session, group_id, conversation_id, opts) do
    {view, opts} = Keyword.pop(opts, :view)

    with {:ok, slim} <- page_view(view),
         {:ok, workspace, binding} <- authorize_member(user, session, group_id, conversation_id),
         {:ok, page} <-
           Comma.Salix.Client.impl().list_group_conversation_message_page(
             workspace,
             salix_conversation_id(binding),
             opts
           ) do
      {:ok, if(slim, do: Map.update(page, "messages", [], &Enum.map(&1, slim)), else: page)}
    end
  end

  @doc """
  A member writes in the Task, as themselves: words alone. Nothing of the
  host's Workspace comes with them: no skill, device, message type or local
  file, which `send_message/6` resolves in the Workspace for its owner.
  """
  def member_send_message(user, session, group_id, conversation_id, attrs, opts \\ []) do
    with {:ok, attrs} <- member_message_attrs(stringify(attrs)),
         {:ok, workspace, binding} <- authorize_member(user, session, group_id, conversation_id),
         :ok <- validate_message_source(attrs, workspace, binding) do
      request_id = normalize_request_id(attrs["client_request_id"]) || new_request_id()
      send_salix_message(user, session, workspace, binding, attrs, request_id, opts)
    end
  end

  @doc """
  The change stream of a member's one Task: as `list_events/4` with that Task
  named. It ends once their membership does (`member?/1` on each change of
  their memberships).
  """
  def member_list_events(user, session, group_id, conversation_id) do
    # Subscribed before the membership is checked: a removal between the two
    # still ends the stream.
    with :ok <- Comma.Collaborations.subscribe(user),
         {:ok, workspace, _binding} <- authorize_member(user, session, group_id, conversation_id),
         {:ok, subscription} <- subscribe_task_list(workspace),
         true <- subscription["resync_required"] == true,
         version when is_binary(version) and version != "" <- subscription["version"] do
      {:ok,
       %{
         group_id: group_id,
         kind: "agent_task",
         owner_pid: subscription["owner_pid"],
         resync_required: true,
         version: version,
         workspace: workspace,
         conversation_id: conversation_id,
         member: %{user: user, session: session, group_id: group_id, task_id: conversation_id},
         task_participants: subscribe_task_participants(workspace, conversation_id),
         task_run: subscribed_task_run(workspace, conversation_id)
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_salix_conversation_list_subscription}
    end
  end

  @doc "Whether a member still reaches their Task."
  def member?(%{user: user, session: session, group_id: group_id, task_id: task_id}),
    do: match?({:ok, _}, Comma.Collaborations.authorize_member(user, session, group_id, task_id))

  # A member sends what the app sends to any Task (`message`, as text or as
  # content blocks), or bare `content` text. Only its text and an answer to an
  # Agent's question card pass: no skills, device, message type or local
  # files of the host's.
  defp member_message_attrs(attrs) do
    message =
      case attrs["message"] do
        %{} = message -> message
        _ -> %{"content" => attrs["content"]}
      end

    text = text_content(message)

    answers =
      case message["content"] do
        content when is_list(content) ->
          Enum.filter(content, &(is_map(&1) and &1["type"] == "question_answer"))

        _ ->
          []
      end

    content =
      if(is_binary(text) and String.trim(text) != "",
        do: [%{"type" => "text", "text" => text}],
        else: []
      ) ++ answers

    if content == [],
      do: {:error, {:bad_request, "message is required"}},
      else:
        {:ok,
         %{"message" => %{"content" => content}}
         |> put_optional("client_request_id", attrs["client_request_id"])}
  end

  defp authorize_member(user, session, group_id, conversation_id) do
    with {:ok, workspace} <-
           Comma.Collaborations.authorize_member(user, session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"} = binding} <-
           authorized_binding(user, workspace, conversation_id) do
      {:ok, workspace, binding}
    else
      {:ok, _other_kind} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp page_view(nil), do: {:ok, nil}
  defp page_view("activity"), do: {:ok, &Comma.TaskActivityMessages.slim/1}
  defp page_view(_view), do: {:error, {:bad_request, "view must be activity"}}

  def message_context(user, session, group_id, conversation_id, message_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, binding} <- authorized_binding(user, workspace, conversation_id),
         {:ok, %{"messages" => messages}} <-
           salix_get_group_conversation_with_messages(
             workspace,
             salix_conversation_id(binding),
             through_id: message_id,
             limit: 17
           ) do
      {:ok, messages}
    end
  end

  @doc """
  One authorized read for auxiliary work that needs the transcript *and* the
  Workspace facts that go with it (`Comma.ChatSuggestions`).

  `messages/4` alone is not enough: an auxiliary LLM call has to resolve the
  Group Router's model and attribute its own cost. Those facts do not belong in
  the canonical Message resource returned to the client.
  """
  @spec suggestion_source(map(), map(), String.t(), String.t()) ::
          {:ok, %{agent_id: String.t() | nil, billing_context: map(), messages: [map()]}}
          | {:error, term()}
  def suggestion_source(user, session, group_id, conversation_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, binding} <- authorized_binding(user, workspace, conversation_id),
         {:ok, messages} <- read_suggestion_messages(workspace, binding) do
      {:ok,
       %{
         agent_id: workspace["router_agent_id"],
         billing_context: billing_context(workspace, binding["id"], user["id"]),
         messages: messages
       }}
    end
  end

  defp read_suggestion_messages(workspace, %{"kind" => kind} = binding)
       when kind in ["user_chat", "agent_task"] do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :list_group_conversation_message_page, 3) do
      collect_suggestion_pages(
        client,
        workspace,
        salix_conversation_id(binding),
        nil,
        [],
        @suggestion_max_pages
      )
    else
      with {:ok, conversation} <-
             read_conversation(workspace, binding, message_limit: @suggestion_page_limit) do
        {:ok, conversation["messages"] || []}
      end
    end
  end

  defp read_suggestion_messages(_workspace, _binding), do: {:error, :not_found}

  defp collect_suggestion_pages(_client, _workspace, _salix_id, _before, acc, 0), do: {:ok, acc}

  defp collect_suggestion_pages(client, workspace, salix_id, before_seq, acc, pages_left) do
    opts =
      if is_integer(before_seq),
        do: [before: before_seq, limit: @suggestion_page_limit],
        else: [limit: @suggestion_page_limit]

    with {:ok, page} <- client.list_group_conversation_message_page(workspace, salix_id, opts) do
      page_messages = page["messages"] || []
      combined = page_messages ++ acc
      first_seq = get_in(page, ["covered", "first_seq"])

      cond do
        Comma.ChatSuggestions.sufficient_context?(combined) ->
          {:ok, combined}

        page["has_older"] != true ->
          {:ok, combined}

        not is_integer(first_seq) or first_seq <= 1 ->
          {:ok, combined}

        is_integer(before_seq) and first_seq >= before_seq ->
          {:ok, combined}

        true ->
          collect_suggestion_pages(
            client,
            workspace,
            salix_id,
            first_seq,
            combined,
            pages_left - 1
          )
      end
    end
  end

  def send_message(user, session, group_id, conversation_id, attrs, opts \\ []) do
    attrs = stringify(attrs)

    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, binding} <- authorized_binding(user, workspace, conversation_id),
         :ok <- validate_message_source(attrs, workspace, binding) do
      request_id =
        normalize_request_id(attrs["client_request_id"]) ||
          new_request_id()

      send_salix_message(user, session, workspace, binding, attrs, request_id, opts)
    end
  end

  @doc """
  Subscribe-before-snapshot for the user Chat invalidation stream.

  The returned snapshot is canonical Salix state. Subsequent notifications are
  hints only; no Salix sequence or durable Comma cursor is exposed.

  `after_seq` is the newest Message seq the client already holds: the snapshot
  then carries only the Messages after it (and says `after_seq`), as Messages
  never change once written. A stream opens again every window and on each
  invalidation, so without it every open sent the whole tail again.
  """
  def events(user, session, group_id, conversation_id, opts \\ []) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, binding} <- authorized_binding(user, workspace, conversation_id),
         :ok <- ensure_events_kind(binding),
         {:ok, subscription} <- subscribe_user_chat(workspace, binding),
         {:ok, conversation} <- read_user_chat_conversation(workspace, binding, opts) do
      stream_context =
        %{
          conversation_id: binding["id"],
          owner_pid: subscription["owner_pid"],
          source_conversation_id: salix_conversation_id(binding),
          workspace: workspace
        }
        |> maybe_put_participant_stream(workspace, binding)

      {:ok,
       conversation
       |> Map.put("type", "snapshot")
       |> messages_after(Keyword.get(opts, :after_seq)), [], stream_context}
    end
  end

  defp messages_after(snapshot, nil), do: snapshot

  defp messages_after(snapshot, after_seq) do
    snapshot
    |> Map.update!("messages", fn messages ->
      Enum.filter(messages, &(is_integer(&1["seq"]) and &1["seq"] > after_seq))
    end)
    |> Map.put("after_seq", after_seq)
  end

  def public(binding), do: Map.drop(binding, ["internal"])

  @doc """
  The public form of one canonical Salix Conversation, such as the Router
  Chat. It carries no Loop Task `loop`: Comma presents Tasks together with the
  live facts of their Loops.
  """
  def present_canonical(workspace, salix_conversation, user \\ nil)
      when is_map(workspace) and is_map(salix_conversation) do
    workspace
    |> canonical_binding(salix_conversation, user)
    |> present_binding(salix_conversation)
  end

  # The public forms of canonical Salix Tasks in the `archive` filter, each
  # Loop Task with its `loop`.
  defp present_tasks(workspace, salix_conversations, user, archive \\ "include") do
    presented =
      for conversation <- salix_conversations,
          binding = canonical_binding(workspace, conversation, user),
          archive_kept?(binding, archive),
          do: {binding, conversation}

    with {:ok, bindings} <- put_task_loops(Enum.map(presented, &elem(&1, 0)), workspace) do
      {:ok,
       Enum.zip_with(bindings, presented, fn binding, {_binding, conversation} ->
         present_binding(binding, conversation)
       end)}
    end
  end

  defp present_binding(binding, salix_conversation) do
    summary = binding |> projected_summary() |> public_summary()

    case salix_conversation["messages"] do
      messages when is_list(messages) ->
        summary
        |> Map.put("messages", messages)
        |> Map.put("final_message_id", final_message_id(messages))

      _ ->
        summary
    end
  end

  defp canonical_binding(workspace, salix_conversation, user) do
    conversation_id = salix_conversation["conversation_id"]
    now = now()

    %{
      "id" => conversation_id,
      "group_id" => workspace["default_group_id"],
      "kind" => salix_conversation["kind"],
      "title" =>
        normalize_user_chat_title(
          salix_conversation["kind"],
          salix_conversation["title"] || default_title(salix_conversation)
        ),
      "status" =>
        if(salix_conversation["kind"] == "agent_task",
          do: conversation_status(salix_conversation),
          else: salix_conversation["status"] || "active"
        ),
      "activity_status" => salix_conversation["activity_status"],
      "message_count" => salix_conversation["message_count"] || 0,
      "freshness" => %{"state" => "fresh", "refreshed_at" => now},
      "created_by" => if(is_map(user), do: user["id"]),
      "internal" => %{
        "binding_version" => 1,
        "salix_group_id" => workspace["default_group_id"],
        "salix_conversation_id" => conversation_id,
        "group_binding_revision" => workspace_group_binding_revision(workspace)
      },
      "created_at" => salix_conversation["created_at"] || now,
      "updated_at" => salix_conversation["updated_at"] || now
    }
    |> put_archive_fields(salix_conversation)
    |> put_task_origin_fields(salix_conversation)
    |> put_meeting_fields(salix_conversation)
    |> put_run_started_at(salix_conversation)
  end

  # When the Task's latest run started (Unix milliseconds): clients show a Task
  # cleared from their chat Task panel again only after it.
  defp put_run_started_at(binding, %{"kind" => "agent_task", "run_started_at" => at})
       when is_integer(at) and at > 0,
       do: Map.put(binding, "run_started_at", at)

  defp put_run_started_at(binding, _salix_conversation), do: binding

  def public_activity(activity, %{
        participant_id: participant_id,
        conversation_id: conversation_id,
        source_conversation_id: source_conversation_id
      })
      when is_map(activity) and is_binary(participant_id) and
             is_binary(conversation_id) and is_binary(source_conversation_id) do
    with response_key when is_binary(response_key) <-
           visible_reply_response_identity(activity["response_key"]),
         {:ok, source_identities} <- ordered_nonempty_strings(activity["source_message_ids"]),
         source_message_ids <-
           canonical_source_message_ids(source_identities, %{
             conversation_id: conversation_id,
             source_conversation_id: source_conversation_id
           }),
         true <- length(source_message_ids) == length(source_identities),
         {:ok, _source_message_ids} <- ordered_nonempty_strings(source_message_ids),
         producer_epoch when is_binary(producer_epoch) and byte_size(producer_epoch) <= 128 <-
           nonempty_string(activity["producer_epoch"]),
         sequence when is_integer(sequence) and sequence > 0 <- activity["sequence"],
         {:ok, summary_class, public_activity} <- public_activity_payload(activity) do
      public_activity
      |> Map.take(@public_activity_keys)
      |> Map.merge(%{
        "type" => "activity",
        "conversation_id" => conversation_id,
        "producer_epoch" => producer_epoch,
        "response_key" => response_key,
        "sequence" => sequence,
        "summary_class" => summary_class,
        "source_message_ids" => source_message_ids
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    else
      _ -> nil
    end
  end

  def public_activity(_activity, _stream_context), do: nil

  def public_participant_status(
        %{
          "state" => state,
          "status" => status,
          "updated_at" => updated_at
        } = activity,
        %{
          participant_id: participant_id,
          conversation_id: conversation_id
        } = stream_context
      )
      when state in ["active", "error", "stopped"] and is_binary(status) and
             is_number(updated_at) and is_binary(participant_id) and
             is_binary(conversation_id) do
    %{
      "type" => "participant_status",
      "conversation_id" => conversation_id,
      "participant_id" => participant_id,
      "state" => state,
      "status" => status,
      "updated_at" => updated_at
    }
    |> put_public_participant_issue(activity)
    |> put_public_issue_detail(activity)
    |> put_public_working_provider(activity)
    |> put_public_loop_wake(activity)
    |> put_public_waiting(activity)
    |> put_public_wait_tool(activity)
    |> put_public_wait_started_at(activity)
    |> put_public_working_conversations(activity, stream_context)
  end

  def public_participant_status(_activity, _stream_context), do: nil

  defp put_public_working_provider(%{"state" => "active"} = public, %{
         "working_provider" => provider
       })
       when provider in ["wechat", "telegram", "signal"],
       do: Map.put(public, "working_provider", provider)

  defp put_public_working_provider(public, _activity), do: public

  defp put_public_loop_wake(%{"state" => "active"} = public, %{"loop_wake" => true}),
    do: Map.put(public, "loop_wake", true)

  defp put_public_loop_wake(public, _activity), do: public

  defp put_public_waiting(%{"state" => "active"} = public, %{"waiting" => true}),
    do: Map.put(public, "waiting", true)

  defp put_public_waiting(public, _activity), do: public

  # The canonical name of the tool whose call the Participant waits on, as
  # Activity frames already publish it. Clients word it; it is never copy.
  @max_public_wait_tool_bytes 128
  defp put_public_wait_tool(%{"state" => "active"} = public, %{"wait_tool" => tool})
       when is_binary(tool) and byte_size(tool) <= @max_public_wait_tool_bytes,
       do: Map.put(public, "wait_tool", tool)

  defp put_public_wait_tool(public, _activity), do: public

  defp put_public_wait_started_at(%{"state" => "active"} = public, %{
         "wait_started_at" => started
       })
       when is_integer(started) and started > 0 do
    if public["waiting"] == true or is_binary(public["wait_tool"]),
      do: Map.put(public, "wait_started_at", started),
      else: public
  end

  defp put_public_wait_started_at(public, _activity), do: public

  # Home names the Tasks its Router is following up on. The client shows a
  # title only after the authorized Task summary read resolves the ID.
  @max_public_working_conversations 8
  defp put_public_working_conversations(
         %{"state" => "active"} = public,
         %{"working_conversation_ids" => ids},
         stream_context
       )
       when is_list(ids) do
    source = Map.get(stream_context, :source_conversation_id)

    ids
    |> Enum.filter(
      &(is_binary(&1) and SalixStore.Ids.valid_conversation_id?(&1) and &1 != source)
    )
    |> Enum.uniq()
    |> Enum.take(@max_public_working_conversations)
    |> case do
      [] -> public
      public_ids -> Map.put(public, "working_conversation_ids", public_ids)
    end
  end

  defp put_public_working_conversations(public, _activity, _stream_context), do: public

  # The agent runtime's stable reason code for an error activity. Clients key
  # localized copy off it, so it is published only for the error state and only
  # as a bounded code — never as free text a provider could have influenced.
  defp put_public_participant_issue(%{"state" => "error"} = public, %{} = activity) do
    case activity["issue"] do
      issue when is_binary(issue) and byte_size(issue) in 1..64 ->
        if String.match?(issue, ~r/\A[a-z0-9_]+\z/),
          do: Map.put(public, "issue", issue),
          else: public

      _absent ->
        public
    end
  end

  defp put_public_participant_issue(public, _activity), do: public

  # What a member can fix after a funding stop: the catalog source and the
  # Profile they named for their own key, or when their own subscription
  # resets. Each field is bounded; provider error text never crosses.
  @funding_issues ~w(provider_quota_exhausted quota_exhausted rate_limited)
  defp put_public_issue_detail(%{"issue" => issue} = public, %{"issue_detail" => %{} = detail})
       when issue in @funding_issues do
    %{
      "source" => public_code(detail["source"]),
      "profile_id" => public_profile_id(detail["profile_id"]),
      "profile_name" => public_profile_name(detail["profile_name"]),
      "reset_at" => public_reset_at(detail["reset_at"]),
      "credits" => if(detail["credits"] == true, do: true)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> public
      detail -> Map.put(public, "issue_detail", detail)
    end
  end

  # What started the round of a failed model request, from a closed set.
  defp put_public_issue_detail(
         %{"issue" => "model_connection_failed"} = public,
         %{"issue_detail" => %{"trigger" => trigger}}
       )
       when trigger in ["voice_call", "background"],
       do: Map.put(public, "issue_detail", %{"trigger" => trigger})

  defp put_public_issue_detail(public, _activity), do: public

  defp public_code(value) when is_binary(value) and byte_size(value) in 1..64,
    do: if(String.match?(value, ~r/\A[a-z0-9][a-z0-9_.-]*\z/), do: value)

  defp public_code(_value), do: nil

  defp public_profile_id(value) when is_binary(value) and byte_size(value) in 1..128,
    do: if(String.match?(value, ~r/\A[A-Za-z0-9_-]+\z/), do: value)

  defp public_profile_id(_value), do: nil

  defp public_profile_name(value) when is_binary(value) and byte_size(value) in 1..200,
    do: if(String.valid?(value) and not String.match?(value, ~r/[\x00-\x1F\x7F]/u), do: value)

  defp public_profile_name(_value), do: nil

  defp public_reset_at(value) when is_integer(value) and value > 0 and value <= 253_402_300_799,
    do: value

  defp public_reset_at(_value), do: nil

  defp ordered_nonempty_strings(values) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) and Enum.uniq(values) == values,
      do: {:ok, values},
      else: :error
  end

  defp ordered_nonempty_strings(_values), do: :error

  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_value), do: nil

  # `summary_class` is egress authority, not a descriptive label. Generic
  # frames may carry only phase-local product copy, `none` carries no prose,
  # and producer-designated public prose must be present and bounded. Keeping
  # this refinement at Comma's projection boundary prevents a contradictory or
  # forged class/payload pair from reaching any client.
  defp public_activity_payload(
         %{"summary_class" => "generic", "phase" => "thinking", "status" => "failed"} =
           activity
       ) do
    {:ok, "generic", Map.drop(activity, ["action", "summary", "goal", "target", "tool_name"])}
  end

  defp public_activity_payload(
         %{"summary_class" => "generic", "phase" => phase, "status" => "running"} = activity
       )
       when phase in ["thinking", "messaging"] do
    copy = if phase == "thinking", do: "Thinking", else: "Typing"

    {:ok, "generic",
     activity
     |> Map.drop(["goal", "target", "tool_name"])
     |> Map.merge(%{"action" => copy, "summary" => copy})}
  end

  defp public_activity_payload(
         %{"summary_class" => "public", "phase" => phase, "status" => status} = activity
       )
       when (phase == "thinking" and status == "running") or
              (phase == "execution" and status in ["running", "failed"]) do
    if public_activity_prose?(activity["summary"]) and
         optional_public_activity_prose?(activity["action"]) and
         optional_public_activity_prose?(activity["goal"]) and
         optional_public_activity_prose?(activity["target"]) and
         optional_public_activity_prose?(activity["tool_name"]) do
      {:ok, "public", activity}
    else
      :error
    end
  end

  defp public_activity_payload(
         %{"summary_class" => "none", "phase" => "idle", "status" => "idle"} = activity
       ) do
    {:ok, "none", Map.drop(activity, ["action", "summary", "goal", "target", "tool_name"])}
  end

  defp public_activity_payload(_activity), do: :error

  defp public_activity_prose?(value) when is_binary(value) do
    value != "" and String.trim(value) != "" and
      length(String.codepoints(value)) <= @public_activity_prose_max_codepoints
  end

  defp public_activity_prose?(_value), do: false

  defp optional_public_activity_prose?(nil), do: true
  defp optional_public_activity_prose?(value), do: public_activity_prose?(value)

  defp read_conversation(workspace, %{"kind" => "user_chat"} = binding, opts),
    do: read_user_chat_conversation(workspace, binding, opts)

  defp read_conversation(workspace, %{"kind" => "agent_task"} = binding, opts),
    do: read_task_conversation(workspace, binding, opts)

  defp read_conversation(_workspace, _binding, _opts), do: {:error, :not_found}

  defp read_user_chat_conversation(workspace, binding, opts) do
    with {:ok, %{"conversation" => salix_conversation, "messages" => messages} = result} <-
           salix_get_group_conversation_with_messages(
             workspace,
             salix_conversation_id(binding),
             snapshot_read_opts(opts)
           ),
         true <- salix_conversation["kind"] == "user_chat",
         {:ok, refreshed} <- project_binding_from_salix(binding, salix_conversation) do
      {:ok,
       refreshed
       |> public_summary()
       |> Map.put(
         "title",
         normalize_user_chat_title("user_chat", salix_conversation["title"] || refreshed["title"]) ||
           "聊天"
       )
       |> Map.put("status", salix_conversation["status"] || "active")
       |> Map.put("message_count", salix_conversation["message_count"] || length(messages))
       |> Map.put("messages", messages)
       |> Map.put("final_message_id", result["final_message_id"] || final_message_id(messages))}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp read_task_conversation(workspace, binding, opts) do
    with {:ok, %{"conversation" => salix_conversation, "messages" => messages}} <-
           salix_get_group_conversation_with_messages(
             workspace,
             salix_conversation_id(binding),
             snapshot_read_opts(opts)
           ),
         true <- salix_conversation["kind"] == "agent_task",
         {:ok, refreshed} <- project_binding_from_salix(binding, salix_conversation),
         {:ok, [refreshed]} <- put_task_loops([refreshed], workspace) do
      {:ok,
       refreshed
       |> public_summary()
       |> Map.put("title", salix_conversation["title"] || refreshed["title"] || "Task")
       |> Map.put("status", conversation_status(salix_conversation))
       |> Map.put("activity_status", salix_conversation["activity_status"] || "idle")
       |> Map.put("message_count", salix_conversation["message_count"] || length(messages))
       |> put_optional("review_version", task_review_version(salix_conversation))
       |> put_task_run(workspace, binding, salix_conversation)
       |> Map.put("messages", messages)}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp snapshot_read_opts(opts) do
    tail =
      min(
        max(Keyword.get(opts, :message_limit, @transcript_limit), 1),
        @transcript_limit
      )

    case Keyword.get(opts, :after_seq) do
      after_seq when is_integer(after_seq) and after_seq >= 0 ->
        [tail: tail, after_seq: after_seq]

      _ ->
        [tail: tail]
    end
  end

  # A coding Task's detail carries its run (the sandbox and its model), so a client opening the Task shows its
  # sandbox with the transcript, before the status stream's first frame. Other Tasks' runs come with that frame.
  defp put_task_run(detail, workspace, binding, %{"runs_on" => %{"kind" => "sandbox"}}) do
    case task_run(workspace, salix_conversation_id(binding)) do
      nil -> detail
      run -> Map.put(detail, "run", run)
    end
  end

  defp put_task_run(detail, _workspace, _binding, _salix_conversation), do: detail

  defp send_salix_message(user, session, workspace, binding, attrs, request_id, opts) do
    content = salix_user_content(attrs["message"] || attrs, workspace, attrs["skills"])

    policy_binding =
      put_in(
        binding,
        ["internal", "billing_context"],
        billing_context(workspace, binding["id"], user["id"])
      )

    salix_id = salix_conversation_id(binding)

    with {:ok, _policy} <-
           AgentPolicies.authorize_send(
             workspace,
             policy_binding,
             session,
             Map.put(attrs, "client_request_id", request_id)
           ) do
      send_authorized_salix_message(
        user,
        workspace,
        binding,
        content,
        request_id,
        salix_id,
        session
        |> message_client_metadata(workspace, attrs)
        |> put_optional("locale", user["locale"]),
        attrs["reply_to_message_id"],
        opts
      )
    end
  end

  defp send_authorized_salix_message(
         user,
         workspace,
         %{"kind" => "user_chat"} = binding,
         content,
         request_id,
         salix_id,
         client_metadata,
         reply_to_message_id,
         opts
       ) do
    if salix_id == workspace["router_conversation_id"] do
      with {:ok, result} <-
             append_router_conversation_message(
               workspace,
               user_salix_message_attrs(
                 user,
                 content,
                 request_id,
                 client_metadata,
                 reply_to_message_id
               )
               |> put_server_requester_email(user)
             ),
           message_id when is_binary(message_id) <- result["message_id"],
           true <- SalixStore.Ids.valid_message_id?(message_id) do
        Comma.Analytics.message_committed(user, workspace, binding, result)
        accepted_message(read_conversation(workspace, binding, opts), message_id)
      else
        {:error, _} = error -> error
        _invalid -> {:error, :invalid_salix_message_identity}
      end
    else
      # A Linear session's chat (see `linear_session_chat?/2`): the owner writes as its own
      # user Participant, like in a Task.
      send_as_user_participant(
        user,
        workspace,
        binding,
        content,
        request_id,
        salix_id,
        client_metadata,
        reply_to_message_id,
        opts
      )
    end
  end

  defp send_authorized_salix_message(
         user,
         workspace,
         %{"kind" => "agent_task"} = binding,
         content,
         request_id,
         salix_id,
         client_metadata,
         reply_to_message_id,
         opts
       ) do
    send_as_user_participant(
      user,
      workspace,
      binding,
      content,
      request_id,
      salix_id,
      client_metadata,
      reply_to_message_id,
      opts
    )
  end

  defp send_authorized_salix_message(
         _user,
         _workspace,
         binding,
         _content,
         _request_id,
         _salix_id,
         _client_metadata,
         _reply_to_message_id,
         _opts
       ),
       do: {:error, {:unsupported_for_kind, binding["kind"], "message"}}

  defp send_as_user_participant(
         user,
         workspace,
         binding,
         content,
         request_id,
         salix_id,
         client_metadata,
         reply_to_message_id,
         opts
       ) do
    with {:ok, _participant} <-
           salix_ensure_user_participant(workspace, salix_id, user["id"]),
         {:ok, result} <-
           Comma.Salix.Client.impl().append_group_conversation_message(
             workspace,
             salix_id,
             user_salix_message_attrs(
               user,
               content,
               request_id,
               client_metadata,
               reply_to_message_id
             )
           ),
         message_id when is_binary(message_id) <- result["message_id"],
         true <- SalixStore.Ids.valid_message_id?(message_id) do
      Comma.Analytics.message_committed(user, workspace, binding, result)
      accepted_message(read_conversation(workspace, binding, opts), message_id)
    else
      false -> {:error, :invalid_salix_message_identity}
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_salix_message_identity}
    end
  end

  defp user_salix_message_attrs(user, content, request_id, client_metadata, reply_to_message_id) do
    %{
      "client_request_id" => request_id,
      "reply_to_message_id" => reply_to_message_id,
      "actor_type" => "user",
      "user_id" => user["id"],
      "content" => content
    }
    |> put_message_client_metadata(client_metadata)
  end

  # Server-trusted sender email for Home card answers forwarded to stations.
  # Always overwrites/strips any pre-existing key so clients cannot spoof it.
  defp put_server_requester_email(attrs, %{"email" => email}) when is_binary(email) do
    case String.trim(email) do
      "" -> Map.delete(attrs, "requester_email")
      trimmed -> Map.put(attrs, "requester_email", trimmed)
    end
  end

  defp put_server_requester_email(attrs, _user), do: Map.delete(attrs, "requester_email")

  # The append receipt identifies this send even if another Message reached
  # the tail before the following read. A retry returns the original receipt.
  defp accepted_message({:ok, conversation}, message_id),
    do: {:ok, Map.put(conversation, "accepted_message_id", message_id)}

  defp accepted_message(error, _message_id), do: error

  # Quick Chat is an input source on Home, not a Task-creation instruction.
  # Keep its bounded text/id contract; arbitrary client metadata is ignored.
  defp validate_message_source(%{"message_type" => "quick_chat"} = attrs, workspace, binding) do
    message = attrs["message"] || attrs
    text = text_content(message)
    request = attrs["client_request_id"]

    if binding["kind"] == "user_chat" and binding["id"] == workspace["router_conversation_id"] and
         is_binary(request) and Regex.match?(~r/\A[A-Za-z0-9_-]{16,64}\z/u, request) and
         is_binary(text) and byte_size(text) in 1..16_000 and String.trim(text) != "" and
         structured_content_blocks(message) == [] do
      :ok
    else
      {:error, {:bad_request, "Invalid quick chat message"}}
    end
  end

  defp validate_message_source(attrs, _workspace, _binding) do
    if is_nil(attrs["message_type"]),
      do: :ok,
      else: {:error, {:bad_request, "Unknown message type"}}
  end

  # Display-only source context for this Message. The caller cannot use it
  # to select operation authority or expand the workspace boundary.
  defp message_client_metadata(session, workspace, attrs) do
    metadata =
      session
      |> session_client_metadata()
      |> put_optional("client_timezone", client_timezone(attrs["client_timezone"]))
      |> put_optional("client_location", client_location(attrs["client_location"]))
      |> put_optional("message_type", attrs["message_type"])
      |> put_optional("client_entry", client_entry(attrs["client_entry"]))

    device_id = attrs["client_device_id"]

    # A client-reported source hint, not permission or execution authority.
    # Resolve one record in the already-authorized workspace; never infer a
    # sender from the group's other connected devices.
    with true <- is_binary(device_id) and byte_size(device_id) in 1..256,
         {:ok, device} <-
           SalixEnv.Control.get_environment(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ) do
      Map.put(metadata, "client_device", %{
        "device_id" => device["device_id"],
        "name" => device["name"]
      })
    else
      _ -> metadata
    end
  end

  defp session_client_metadata(session) when is_map(session) do
    %{}
    |> put_optional("client_kind", nonempty_string(session["client_kind"]))
    |> put_optional("client_platform", nonempty_string(session["client_platform"]))
    # A restricted session (an ops support or Mini App panel session) may post
    # in Home but acts for nobody: Salix sends no Task request for it
    # (`SalixIM.RouterConversationInput`).
    |> put_optional("restricted_session", if(session["restricted"] == true, do: true))
  end

  defp session_client_metadata(_session), do: %{}

  # Where the person wrote this Message when it was not the sending app: the
  # Raycast extension put the words in the app's draft. A client-reported
  # display hint with a closed set of values, never authority.
  defp client_entry("raycast"), do: "raycast"
  defp client_entry(_entry), do: nil

  # The sending device's IANA timezone, so the Agent can write local times.
  # Like the device, it is a display hint, never authority.
  defp client_timezone(zone) when is_binary(zone) and byte_size(zone) in 1..64 do
    case DateTime.shift_zone(SystemsClock.utc_now(), zone) do
      {:ok, _} -> zone
      _ -> nil
    end
  end

  defp client_timezone(_zone), do: nil

  # The sending phone's position, given only while its person shares it
  # (Settings on the phone). Like the timezone, a hint for the Agent's answer,
  # never authority; `read_at` says when the phone read it.
  defp client_location(%{"latitude" => lat, "longitude" => lon, "read_at" => read_at} = location)
       when is_number(lat) and lat >= -90 and lat <= 90 and is_number(lon) and lon >= -180 and
              lon <= 180 and is_binary(read_at) and byte_size(read_at) <= 64 do
    with {:ok, read_at, _offset} <- DateTime.from_iso8601(read_at) do
      %{
        "latitude" => lat,
        "longitude" => lon,
        "read_at" => DateTime.to_iso8601(read_at)
      }
      |> put_optional("accuracy_m", location_accuracy(location["accuracy_m"]))
    else
      _ -> nil
    end
  end

  defp client_location(_location), do: nil

  defp location_accuracy(metres) when is_number(metres) and metres >= 0, do: metres
  defp location_accuracy(_metres), do: nil

  defp put_message_client_metadata(attrs, client_metadata)
       when is_map(client_metadata) and map_size(client_metadata) > 0,
       do: Map.put(attrs, "metadata", client_metadata)

  defp put_message_client_metadata(attrs, _client_metadata), do: attrs

  defp append_router_conversation_message(workspace, attrs) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :append_group_router_conversation_message, 2) do
      client.append_group_router_conversation_message(workspace, attrs)
    else
      {:error, :salix_router_conversation_not_supported}
    end
  end

  defp activity_stream_context(workspace, binding) do
    source_conversation_id = salix_conversation_id(binding)

    with {:ok, context} <-
           Comma.Salix.Client.impl().conversation_activity_context(
             workspace,
             source_conversation_id
           ) do
      {:ok,
       Map.merge(context, %{
         conversation_id: binding["id"],
         source_conversation_id: source_conversation_id
       })}
    end
  end

  def canonical_source_message_ids(source_identities, %{
        source_conversation_id: source_conversation_id
      }) do
    SalixIM.ConversationSourceIdentity.message_ids(source_identities, source_conversation_id)
  end

  def canonical_source_message_ids(_source_identities, _stream_context), do: []

  @doc """
  Validates the opaque response identity minted by Salix for one exact source
  activation. Comma only projects this value; it never derives or replaces it.
  """
  def visible_reply_response_identity(<<"rsp_", encoded::binary-size(24)>> = identity) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 18 -> identity
      _ -> nil
    end
  end

  def visible_reply_response_identity(_identity), do: nil

  defp project_binding_from_salix(binding, salix_conversation) do
    if salix_conversation["kind"] == binding["kind"] do
      refreshed_at = now()

      {:ok,
       binding
       |> Map.put(
         "title",
         normalize_user_chat_title(
           binding["kind"],
           salix_conversation["title"] || binding["title"] || default_title(binding)
         )
       )
       |> Map.put("status", projected_status(binding, salix_conversation))
       |> put_optional("activity_status", salix_conversation["activity_status"])
       |> Map.put("message_count", salix_conversation["message_count"] || 0)
       |> put_archive_fields(salix_conversation)
       |> put_task_origin_fields(salix_conversation)
       |> put_meeting_fields(salix_conversation)
       |> put_in(["internal", "binding_version"], 1)
       |> Map.put("freshness", %{"state" => "fresh", "refreshed_at" => refreshed_at})
       |> Map.put("updated_at", salix_conversation["updated_at"] || refreshed_at)}
    else
      {:error, :not_found}
    end
  end

  defp put_archive_fields(binding, conversation) do
    Map.merge(
      binding,
      Map.take(conversation, ~w(archived_at archived_from_status archive_availability))
    )
  end

  defp default_title(%{"kind" => "agent_task"}), do: "Task"
  defp default_title(_binding), do: "聊天"

  defp normalize_user_chat_title("user_chat", title) when is_binary(title) do
    if String.downcase(String.trim(title)) == "bridge chat", do: "Comma", else: title
  end

  defp normalize_user_chat_title(_kind, title), do: title
  defp default_status(%{"kind" => "agent_task"}), do: "unknown"
  defp default_status(_binding), do: "active"

  defp projected_status(%{"kind" => "agent_task"}, salix_conversation),
    do: conversation_status(salix_conversation)

  defp projected_status(binding, salix_conversation),
    do: salix_conversation["status"] || default_status(binding)

  defp conversation_status(salix_conversation) do
    salix_conversation["status"] || "unknown"
  end

  defp task_review_version(%{"kind" => "agent_task", "status" => "ready_for_review"} = task) do
    case task["updated_at"] do
      review_version when is_integer(review_version) and review_version > 0 ->
        if not scheduled_task?(task), do: review_version

      _other ->
        nil
    end
  end

  defp task_review_version(_task), do: nil

  defp scheduled_task?(task) do
    case get_in(task, ["schedule", "schedule_id"]) do
      schedule_id when is_binary(schedule_id) -> String.trim(schedule_id) != ""
      _ -> false
    end
  end

  defp requested_review_version(%{"review_version" => review_version})
       when is_integer(review_version) and review_version > 0,
       do: {:ok, review_version}

  defp requested_review_version(_attrs), do: {:error, :invalid_review_version}

  defp requested_task_status(%{"status" => status, "expected_updated_at" => version})
       when status in ["completed", "cancelled"] and is_integer(version) and version > 0,
       do: {:ok, status, version}

  defp requested_task_status(_attrs), do: {:error, :invalid_task_status}

  defp requested_task_title(%{"title" => title} = attrs)
       when map_size(attrs) == 1 and is_binary(title) do
    case String.trim(title) do
      "" -> {:error, :invalid_conversation_title}
      trimmed -> {:ok, trimmed}
    end
  end

  defp requested_task_title(_attrs), do: {:error, :invalid_conversation_title}

  # PATCH accepts a title, a label list, or both — nothing else. Label ids
  # must exist in the Group catalog so a Task never binds to a phantom label.
  defp requested_task_update(workspace, attrs) when is_map(attrs) do
    keys = Map.keys(attrs)

    cond do
      keys == [] or Enum.any?(keys, &(&1 not in ["title", "labels"])) ->
        {:error, :invalid_conversation_title}

      true ->
        with {:ok, update} <- requested_update_title(%{}, attrs),
             {:ok, update} <- requested_update_labels(update, workspace, attrs) do
          {:ok, update}
        end
    end
  end

  defp requested_update_title(update, %{"title" => _} = attrs) do
    with {:ok, title} <- requested_task_title(Map.take(attrs, ["title"])) do
      {:ok, Map.put(update, "title", title)}
    end
  end

  defp requested_update_title(update, _attrs), do: {:ok, update}

  defp requested_update_labels(update, workspace, %{"labels" => labels}) do
    with true <- is_list(labels) and Enum.all?(labels, &SalixStore.Ids.valid_task_label_id?/1),
         labels <- Enum.uniq(labels),
         {:ok, %{"labels" => catalog}} <- Comma.Salix.Client.list_group_task_labels(workspace),
         known <- MapSet.new(catalog, & &1["id"]),
         true <- Enum.all?(labels, &MapSet.member?(known, &1)) do
      {:ok, Map.put(update, "labels", labels)}
    else
      false -> {:error, :invalid_task_labels}
      {:error, _} = error -> error
    end
  end

  defp requested_update_labels(update, _workspace, _attrs), do: {:ok, update}

  # Where the Task was asked for, as stamped by `SalixIM.Provider.Internal`
  # when the Router created it: a provider name for IM inbound, or `comma` plus
  # the client platform for a Comma client request.
  defp put_meeting_fields(binding, conversation) do
    case get_in(conversation, ["metadata", "desktop_meeting"]) do
      meeting when is_map(meeting) ->
        Map.put(
          binding,
          "meeting",
          Map.take(meeting, ~w(name archive_date started_at phase version))
        )

      _ ->
        binding
    end
  end

  defp put_task_origin_fields(binding, %{"kind" => "agent_task"} = salix_conversation) do
    origin = get_in(salix_conversation, ["metadata", "origin"]) || %{}
    origin = if is_map(origin), do: origin, else: %{}

    provider =
      case nonempty_string(origin["provider"]) do
        nil ->
          if nonempty_string(
               get_in(salix_conversation, ["source_refs", "parent_conversation_id"])
             ),
             do: "comma"

        provider ->
          provider
      end

    labels =
      case salix_conversation["labels"] do
        labels when is_list(labels) -> Enum.filter(labels, &is_binary/1)
        _other -> []
      end

    binding
    |> put_optional("origin", provider)
    |> put_optional("client_platform", nonempty_string(origin["client_platform"]))
    # Who sent the Task Request this Task was accepted from
    # (`Comma.TaskRequests`). A display fact; it grants nothing.
    |> put_optional(
      "requested_by",
      nonempty_string(get_in(salix_conversation, ["metadata", "task_request", "sender_name"]))
    )
    # The sender's User id: a client groups Tasks by who asked for them, and
    # two senders with the same name stay apart.
    |> put_optional(
      "requested_by_id",
      nonempty_string(get_in(salix_conversation, ["metadata", "task_request", "sender_user_id"]))
    )
    # The sender's avatar as the Task's owner reads it
    # (`Comma.TaskRequests.sender_avatar/5`): the request and the revision
    # the Task was made with.
    |> put_optional("requested_by_avatar", requested_by_avatar(salix_conversation))
    # A Task together: the User ids of the people it was started with
    # (`Comma.Collaborations`), fixed then. A card shows their faces; it
    # grants nothing.
    |> put_optional("together", together(salix_conversation))
    # The Message the Task was created from, such as the person's Home request
    # that the Router answered with this Task. A client reads it to show that
    # request becoming the Task; it grants nothing.
    |> put_optional(
      "parent_message_id",
      nonempty_string(get_in(salix_conversation, ["source_refs", "parent_message_id"]))
    )
    |> Map.put("labels", labels)
  end

  defp put_task_origin_fields(binding, _salix_conversation), do: binding

  defp projected_summary(summary) do
    state =
      case get_in(summary, ["freshness", "state"]) do
        "fresh" -> "fresh"
        "stale" -> "stale"
        _ -> "unknown"
      end

    summary
    |> Map.put("status", summary["status"] || default_status(summary))
    |> Map.put("freshness", Map.put(summary["freshness"] || %{}, "state", state))
  end

  defp conversation_summary(binding) do
    binding
    |> Map.take([
      "id",
      "group_id",
      "title",
      "status",
      "kind",
      "activity_status",
      "message_count",
      "archive_availability",
      "archived_at",
      "archived_from_status",
      "freshness",
      "created_by",
      "labels",
      "origin",
      "meeting",
      "client_platform",
      "requested_by",
      "requested_by_id",
      "requested_by_avatar",
      "together",
      "parent_message_id",
      "loop",
      "pull_request",
      "created_at",
      "updated_at"
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp public_summary(binding) do
    binding
    |> public()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp conversation_page_limit(nil), do: @conversation_page_default

  defp conversation_page_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@conversation_page_max)

  defp conversation_page_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> conversation_page_limit(parsed)
      _ -> @conversation_page_default
    end
  end

  defp conversation_page_limit(_limit), do: @conversation_page_default

  defp authorized_binding(user, workspace, conversation_id) do
    with true <- SalixStore.Ids.valid_conversation_id?(conversation_id),
         {:ok, conversation} <- salix_get_group_conversation(workspace, conversation_id),
         true <- authorized_canonical_conversation?(workspace, conversation) do
      {:ok, canonical_binding(workspace, conversation, user)}
    else
      false -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :not_found}
    end
  end

  defp authorized_canonical_conversation?(_workspace, %{"kind" => "agent_task"}), do: true

  defp authorized_canonical_conversation?(
         workspace,
         %{"kind" => "user_chat", "conversation_id" => conversation_id} = conversation
       ),
       do:
         conversation_id == workspace["router_conversation_id"] or
           linear_session_chat?(workspace, conversation)

  defp authorized_canonical_conversation?(_workspace, _conversation), do: false

  # A chat a provider opened with the Router for the Workspace owner (a Linear
  # agent session's chat): the owner reads and writes it like the Workspace
  # chat. Nothing else outside Tasks and that chat is visible.
  defp linear_session_chat?(workspace, conversation) do
    owner = workspace["owner_user_id"]

    is_binary(owner) and owner != "" and conversation["owner_user_id"] == owner and
      is_map(get_in(conversation, ["source_refs", "linear"]))
  end

  defp workspace_group_binding_revision(workspace),
    do: Workspaces.group_binding_revision(workspace)

  defp ensure_events_kind(%{"kind" => "user_chat"}), do: :ok

  defp ensure_events_kind(%{"kind" => kind}),
    do: {:error, {:unsupported_for_kind, kind, "events"}}

  defp subscribe_task_list(workspace) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :subscribe_group_conversation_list, 3) do
      client.subscribe_group_conversation_list(
        workspace,
        "agent_task",
        SystemsRuntime.Proc.self()
      )
    else
      {:error, :salix_conversation_list_subscription_not_supported}
    end
  end

  defp subscribe_user_chat(workspace, binding) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :subscribe_group_conversation, 3) do
      client.subscribe_group_conversation(
        workspace,
        salix_conversation_id(binding),
        SystemsRuntime.Proc.self()
      )
    else
      {:error, :salix_conversation_subscription_not_supported}
    end
  end

  defp subscribe_user_chat_participant(workspace, stream_context) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :subscribe_group_conversation_participant, 4) do
      client.subscribe_group_conversation_participant(
        workspace,
        stream_context.source_conversation_id,
        stream_context.participant_id,
        SystemsRuntime.Proc.self()
      )
    else
      {:error, :salix_participant_subscription_not_supported}
    end
  end

  defp maybe_put_participant_stream(stream_context, workspace, binding) do
    with {:ok, participant_context} <- activity_stream_context(workspace, binding),
         {:ok, participant_subscription} <-
           subscribe_user_chat_participant(workspace, participant_context),
         {:ok, participant_status} <- participant_subscription_status(participant_subscription) do
      stream_context
      |> Map.merge(participant_context)
      |> Map.put(:participant_status, participant_status)
      |> Map.put(:participant_owner_pid, participant_subscription["owner_pid"])
    else
      {:error, _reason} -> stream_context
      _invalid -> stream_context
    end
  end

  def participant_status(%{
        workspace: workspace,
        source_conversation_id: source_conversation_id,
        participant_id: participant_id
      }) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :get_group_conversation_participant_status, 3) do
      client.get_group_conversation_participant_status(
        workspace,
        source_conversation_id,
        participant_id
      )
    else
      {:error, :salix_participant_status_not_supported}
    end
  end

  def participant_status(_stream_context), do: {:error, :invalid_participant_context}

  defp participant_subscription_status(%{"status" => status}) when is_map(status),
    do: {:ok, status}

  defp participant_subscription_status(_subscription),
    do: {:error, :invalid_participant_subscription}

  defp salix_get_group_conversation(workspace, salix_id) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :get_group_conversation, 2) do
      client.get_group_conversation(workspace, salix_id)
    else
      {:error, :salix_conversation_read_not_supported}
    end
  end

  defp salix_list_group_conversation_pins(workspace) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :list_group_conversation_pins, 1) do
      client.list_group_conversation_pins(workspace)
    else
      {:error, :salix_conversation_read_not_supported}
    end
  end

  defp salix_pin_group_conversation(workspace, conversation_id) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :pin_group_conversation, 2) do
      client.pin_group_conversation(workspace, conversation_id)
    else
      {:error, :salix_conversation_write_not_supported}
    end
  end

  defp salix_unpin_group_conversation(workspace, conversation_id) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :unpin_group_conversation, 2) do
      client.unpin_group_conversation(workspace, conversation_id)
    else
      {:error, :salix_conversation_write_not_supported}
    end
  end

  defp salix_update_group_conversation(workspace, conversation_id, attrs) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :update_group_conversation, 3) do
      client.update_group_conversation(workspace, conversation_id, attrs)
    else
      {:error, :salix_conversation_write_not_supported}
    end
  end

  defp salix_list_group_conversations(workspace, opts) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :list_group_conversations, 2) do
      client.list_group_conversations(workspace, opts)
    else
      {:error, :salix_conversation_list_not_supported}
    end
  end

  defp salix_search_group_tasks(workspace, query, opts) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :search_group_tasks, 3) do
      client.search_group_tasks(workspace, to_string(query || ""), opts)
    else
      {:error, :salix_conversation_search_not_supported}
    end
  end

  defp salix_task_message_matches(_workspace, scoped_conversation_id, conversation_id, _query)
       when is_binary(scoped_conversation_id) and scoped_conversation_id != conversation_id,
       do: {:ok, []}

  defp salix_task_message_matches(workspace, _scoped_conversation_id, conversation_id, query) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :task_message_matches, 3) do
      client.task_message_matches(workspace, conversation_id, query)
    else
      {:error, :salix_conversation_search_not_supported}
    end
  end

  defp public_message_matches(matches) when is_list(matches) do
    public = Enum.map(matches, &put_message_position(%{}, &1))

    if Enum.all?(public, &(map_size(&1) == 2)),
      do: {:ok, public},
      else: {:error, :invalid_salix_conversation_search}
  end

  defp public_message_matches(_matches), do: {:error, :invalid_salix_conversation_search}

  defp public_search_results(results) when is_list(results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case public_search_result(result) do
        {:ok, public} -> {:cont, {:ok, [public | acc]}}
        :error -> {:halt, {:error, :invalid_salix_conversation_search}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp public_search_results(_results), do: {:error, :invalid_salix_conversation_search}

  @doc false
  def validate_search_results_for_test(results), do: public_search_results(results)

  defp public_search_result(
         %{
           "conversation_id" => conversation_id,
           "title" => title,
           "snippet" => snippet,
           "matched_field" => matched_field,
           "highlights" => highlights
         } = result
       )
       when is_binary(title) and is_binary(snippet) and matched_field in ["title", "content"] and
              is_list(highlights) do
    updated_at = Map.get(result, "updated_at")

    with true <- is_nil(updated_at) or (is_integer(updated_at) and updated_at >= 0),
         true <- SalixStore.Ids.valid_conversation_id?(conversation_id),
         true <- String.valid?(title) and String.valid?(snippet),
         true <- byte_size(title) <= SearchDocumentEnvelope.max_bytes(:title),
         true <- valid_search_snippet_size?(matched_field, snippet),
         {:ok, ranges} <- public_highlights(highlights, snippet),
         {:ok, content_match} <- public_content_match(Map.get(result, "content_match")) do
      public =
        %{
          "conversation_id" => conversation_id,
          "title" => title,
          "snippet" => snippet,
          "matched_field" => matched_field,
          "highlights" => ranges
        }
        |> put_optional("updated_at", updated_at)
        |> put_message_position(result)

      {:ok, maybe_put_content_match(public, content_match)}
    else
      false -> :error
      :error -> :error
    end
  end

  defp public_search_result(_result), do: :error

  defp valid_search_snippet_size?("title", snippet),
    do: byte_size(snippet) <= SearchDocumentEnvelope.max_bytes(:title)

  defp valid_search_snippet_size?("content", snippet),
    do: byte_size(snippet) <= SearchDocumentEnvelope.max_bytes(:message)

  defp public_content_match(nil), do: {:ok, nil}

  defp public_content_match(%{"snippet" => snippet, "highlights" => highlights} = content_match)
       when is_binary(snippet) and is_list(highlights) do
    with true <- String.valid?(snippet),
         true <- byte_size(snippet) <= SearchDocumentEnvelope.max_bytes(:message),
         {:ok, ranges} <- public_highlights(highlights, snippet) do
      {:ok, put_message_position(%{"snippet" => snippet, "highlights" => ranges}, content_match)}
    else
      false -> :error
      :error -> :error
    end
  end

  defp public_content_match(_content_match), do: :error

  # The matched Message's id and `seq`, so a client reads the page around it
  # (`around`) instead of the history before it. A position Salix did not give
  # in full is left out; the match itself still shows.
  defp put_message_position(match, %{"message_id" => message_id, "message_seq" => seq})
       when is_binary(message_id) and is_integer(seq) and seq > 0 do
    if SalixStore.Ids.valid_message_id?(message_id),
      do: Map.merge(match, %{"message_id" => message_id, "message_seq" => seq}),
      else: match
  end

  defp put_message_position(match, _source), do: match

  defp maybe_put_content_match(result, nil), do: result

  defp maybe_put_content_match(result, content_match),
    do: Map.put(result, "content_match", content_match)

  defp public_highlights([%{"start" => start, "end" => finish}], snippet)
       when is_integer(start) and is_integer(finish) and start >= 0 and finish > start do
    if finish <= utf16_length(snippet),
      do: {:ok, [%{"start" => start, "end" => finish}]},
      else: :error
  end

  defp public_highlights(_highlights, _snippet), do: :error

  defp utf16_length(value) do
    value
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp maybe_put_keyword(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp salix_get_group_conversation_with_messages(workspace, salix_id, opts) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :get_group_conversation_with_messages, 3) do
      client.get_group_conversation_with_messages(workspace, salix_id, opts)
    else
      {:error, :salix_conversation_read_not_supported}
    end
  end

  defp salix_ensure_user_participant(workspace, salix_id, user_id) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :ensure_group_conversation_user_participant, 3) do
      client.ensure_group_conversation_user_participant(workspace, salix_id, user_id)
    else
      {:error, :salix_user_participant_not_supported}
    end
  end

  defp callback_exported?(client, function, arity) do
    Code.ensure_loaded?(client) and function_exported?(client, function, arity)
  end

  defp salix_conversation_id(%{"internal" => %{"salix_conversation_id" => id}}), do: id
  defp salix_conversation_id(_binding), do: nil

  @doc false
  def billing_context(workspace, conversation_id, actor_user_id) do
    %{
      "billing_account_id" => workspace["billing_account_id"],
      "surface" => "comma",
      "product_owner_type" => "workspace",
      "product_owner_id" => workspace["id"],
      "salix_tenant_id" => workspace["salix_tenant_id"],
      "salix_group_id" => workspace["default_group_id"],
      "salix_agent_id" => workspace["router_agent_id"],
      "charge_policy" => "platform_paid",
      "entrypoint" => "conversation_send",
      "actor_type" => "user",
      "actor_user_id" => actor_user_id,
      "conversation_id" => conversation_id
    }
  end

  defp final_message_id(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"actor_type" => actor_type, "message_id" => id}
      when actor_type in ["agent", "system"] ->
        id

      _ ->
        nil
    end)
  end

  # ---- Loop Tasks ----------------------------------------------------------
  #
  # A Loop Task is a Task that shows one Background Loop (`SalixIM.TaskLoop`).
  # The Loop row holds every fact of it (`SalixAgent.Loops`); its public
  # `loop` is the Loop's state:
  #
  #   * `pending` until the Task's Worker gives the Loop its program;
  #   * `active`;
  #   * `paused` with the reason it paused for (a failed Loop pauses for
  #     `failed`; a user or archive pause has no reason);
  #   * `ended` with the reason it ended.
  #
  # The Loops come from one indexed read per 50 Tasks of a response
  # (`Comma.Salix.Client.task_loops/2`: a list page, the summaries and one
  # Task are one read; the at most 200 pins at most four). Loop ids, config,
  # program paths, webhooks and failure text stay inside Salix. A Task that
  # requested no Loop carries no `loop`.

  @task_loops_batch 50
  @task_loop_cadence_keys ~w(every_minutes cron timezone events)
  @task_loop_pause_reasons %{
    "budget" => "budget",
    "exited" => "exited",
    "quota" => "quota",
    "undeliverable" => "undeliverable"
  }

  # What the list adds to each Task beside its Salix row: its Loop and its pull request.
  defp put_task_loops(bindings, workspace) do
    ids = for %{"kind" => "agent_task", "id" => id} <- bindings, uniq: true, do: id

    with {:ok, loops} <- task_loops(workspace, ids) do
      pull_requests = task_pull_requests(workspace, ids)

      {:ok,
       Enum.map(bindings, fn binding ->
         binding
         |> put_public_task_loop(loops[binding["id"]])
         |> put_optional("pull_request", pull_requests[binding["id"]])
       end)}
    end
  end

  defp task_pull_requests(workspace, ids) do
    ids
    |> Enum.chunk_every(@task_loops_batch)
    |> Enum.reduce(%{}, fn batch, pull_requests ->
      {:ok, read} = Comma.Salix.Client.task_pull_requests(workspace, batch)
      Map.merge(pull_requests, read)
    end)
  end

  defp task_loops(_workspace, []), do: {:ok, %{}}

  defp task_loops(workspace, ids) do
    ids
    |> Enum.chunk_every(@task_loops_batch)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, loops} ->
      case Comma.Salix.Client.task_loops(workspace, batch) do
        {:ok, %{} = read} -> {:cont, {:ok, Map.merge(loops, read)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_public_task_loop(binding, %{"trigger" => %{} = cadence} = loop) do
    {state, reason} = task_loop_state(loop)

    next_run_at =
      if state == "active" and not Map.has_key?(cadence, "events"), do: loop["next_run_at"]

    public =
      %{"state" => state, "cadence" => Map.take(cadence, @task_loop_cadence_keys)}
      |> put_optional("reason", reason)
      |> put_optional("max_runs", loop["max_runs"])
      |> put_optional("ends_at", loop["ends_at"])
      |> put_optional("until", loop["stop_condition"])
      |> put_optional("started_at", loop["started_at"])
      |> put_optional("wake_count", loop["run_count"])
      |> put_optional("last_wake_at", loop["last_run_at"])
      |> put_optional("next_run_at", next_run_at)
      |> put_optional("ended_at", if(state == "ended", do: loop["ended_at"]))

    Map.put(binding, "loop", public)
  end

  defp put_public_task_loop(binding, _loop), do: Map.delete(binding, "loop")

  defp task_loop_state(%{"status" => "ended"} = loop), do: {"ended", loop["ended_reason"]}
  defp task_loop_state(%{"status" => "pending"}), do: {"pending", nil}
  defp task_loop_state(%{"status" => "active"}), do: {"active", nil}
  defp task_loop_state(%{"status" => "failed"}), do: {"paused", "failed"}

  defp task_loop_state(%{"status" => "paused"} = loop),
    do: {"paused", @task_loop_pause_reasons[loop["paused_by"]]}

  defp public_task_preview(workspace, binding, salix_conversation) do
    refreshed_at = now()

    %{
      "id" => binding["id"],
      "group_id" => workspace["default_group_id"],
      "kind" => "agent_task",
      "title" => salix_conversation["title"] || "Task",
      "status" => conversation_status(salix_conversation),
      "activity_status" => salix_conversation["activity_status"] || "idle",
      "freshness" => %{"state" => "fresh", "refreshed_at" => refreshed_at},
      "updated_at" => salix_conversation["updated_at"] || 0
    }
    |> Map.merge(Map.take(binding, ["labels", "origin"]))
  end

  # Opt-in for one open panel. The existing role lookup reads at most the
  # creator and bound Worker; it does not load messages or subscribe to Sessions.
  defp task_preview_worker_sessions(workspace, conversation) do
    client = Comma.Salix.Client.impl()
    conversation_id = conversation["conversation_id"]

    with true <- is_binary(conversation_id) and conversation_id != "",
         true <- callback_exported?(client, :task_worker_sessions, 2),
         {:ok, sessions} when is_list(sessions) and sessions != [] <-
           client.task_worker_sessions(workspace, conversation_id) do
      sessions
      |> Enum.take(6)
      |> Enum.map(fn session ->
        slot = session["slot"] || "lead"

        %{
          "participant_id" => session["participant_id"],
          "slot" => slot,
          "label" => session["label"] || slot,
          "is_primary" => session["is_primary"] == true,
          "subscribed" => false,
          "state" => "stopped",
          "status" => ""
        }
        |> put_optional("actor_id", session["actor_id"])
        |> put_optional("model", session["model"])
        |> put_optional("runtime", session["runtime"])
      end)
    else
      _ -> nil
    end
  end

  defp task_preview_worker(workspace, conversation) do
    client = Comma.Salix.Client.impl()
    worker_id = conversation["task_worker_agent_id"]

    with true <- is_binary(worker_id) and worker_id != "",
         true <- callback_exported?(client, :task_activity_participants, 2),
         {:ok, participants} <-
           client.task_activity_participants(workspace, conversation["conversation_id"]) do
      Enum.find_value(participants, fn participant ->
        if participant["agent_id"] == worker_id do
          %{
            "participant_id" => participant["participant_id"],
            "name" => participant["name"] || "Worker",
            "actor_id" =>
              public_actor_id(%{"actor_type" => "agent", "agent_id" => worker_id}, conversation)
          }
        end
      end)
    else
      _ -> nil
    end
  end

  defp normalize_request_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_request_id(_value), do: nil

  defp new_request_id,
    do: "req_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)

  defp now, do: SystemsClock.system_time(:second)

  defp stringify(attrs) when is_map(attrs),
    do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp stringify(_attrs), do: %{}

  defp together(salix_conversation) do
    # Its host first, then everyone it was started with (none on Comma yet
    # when it went to addresses alone: then its host alone).
    case get_in(salix_conversation, ["metadata", "collaboration"]) do
      %{"host_user_id" => host} = collaboration when is_binary(host) ->
        [host | List.wrap(collaboration["members"])]
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.take(8)

      _other ->
        nil
    end
  end

  defp requested_by_avatar(salix_conversation) do
    case get_in(salix_conversation, ["metadata", "task_request"]) do
      %{"id" => request, "sender_avatar_id" => revision, "workspace_id" => workspace}
      when is_binary(request) and is_binary(revision) and revision != "" and
             is_binary(workspace) ->
        %{"workspace" => workspace, "request" => request, "revision" => revision}

      _other ->
        nil
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp text_content(%{"content" => content}) when is_binary(content), do: content
  defp text_content(%{"content" => [%{"type" => "text", "text" => text} | _]}), do: text
  defp text_content(%{"content" => [%{type: "text", text: text} | _]}), do: text
  defp text_content(%{"text" => text}) when is_binary(text), do: text
  defp text_content(%{content: content}) when is_binary(content), do: content
  defp text_content(%{text: text}) when is_binary(text), do: text
  defp text_content(_attrs), do: ""

  defp salix_user_content(message, workspace, skills) do
    text = message |> text_content() |> Comma.SkillMentions.compose(workspace, skills)

    case structured_content_blocks(message) do
      [] ->
        text

      blocks ->
        if text == "", do: blocks, else: [%{"type" => "text", "text" => text} | blocks]
    end
  end

  # Besides its text, a client sends local files and the answer to an Agent's
  # question card. The Conversation owner validates both.
  defp structured_content_blocks(%{"content" => content}) when is_list(content),
    do: Enum.filter(content, &(is_map(&1) and &1["type"] in ["local_file", "question_answer"]))

  defp structured_content_blocks(_message), do: []
end
