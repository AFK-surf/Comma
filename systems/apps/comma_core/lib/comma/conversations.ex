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

  alias Comma.{AgentPolicies, Workspaces}
  alias SalixStore.SearchDocumentEnvelope

  @transcript_limit 1000
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
                 limit: limit,
                 cursor: Keyword.get(opts, :cursor)
               ) do
          conversations =
            Enum.map(page["data"] || [], &present_canonical(workspace, &1, user))
            |> filter_archived(archive)

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

  @doc "List the authorized canonical Tasks pinned in a Group."
  def list_pinned_tasks(user, session, group_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"data" => pins}} when is_list(pins) <-
           salix_list_group_conversation_pins(workspace) do
      data =
        Enum.flat_map(pins, fn pin ->
          with conversation_id when is_binary(conversation_id) <- pin["conversation_id"],
               :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
               {:ok, %{"kind" => "agent_task"} = binding} <-
                 authorized_binding(user, workspace, conversation_id),
               false <- binding["status"] == "archived",
               pinned_at when is_integer(pinned_at) <- pin["pinned_at"] do
            [
              %{
                "conversation" => public_summary(binding),
                "pinned_at" => pinned_at
              }
            ]
          else
            _not_visible_or_not_a_task -> []
          end
        end)

      {:ok, %{"data" => data}}
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
         pinned_at when is_integer(pinned_at) <- pin["pinned_at"] do
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
      {:ok,
       %{
         group_id: group_id,
         kind: "agent_task",
         owner_pid: subscription["owner_pid"],
         resync_required: true,
         version: version,
         workspace: workspace,
         conversation_id: conversation_id,
         task_participants: subscribe_task_participants(workspace, conversation_id)
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_salix_conversation_list_subscription}
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
               self()
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

  def task_participant_statuses(stream_context) do
    bound_worker =
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
              |> Map.delete("type")
              |> Map.put("name", participant.name)
              |> put_optional("actor_id", participant.actor_id)
              |> put_optional("actor_role", participant.actor_role)
            ]
        end
      end)

    %{
      "type" => "task_participant_statuses",
      "group_id" => stream_context.group_id,
      "conversation_id" => stream_context.conversation_id,
      "bound_worker" => bound_worker,
      "participants" => participants
    }
  end

  defp list_scoped_conversation_page(user, workspace, conversation_id) do
    data =
      case authorized_binding(user, workspace, conversation_id) do
        {:ok, binding} ->
          [binding |> conversation_summary() |> projected_summary() |> public_summary()]

        {:error, _reason} ->
          []
      end

    {:ok, %{"data" => data, "has_more" => false, "next_cursor" => nil}}
  end

  def get(user, session, group_id, conversation_id, opts \\ []) do
    with {:ok, workspace, binding} <-
           authorize_conversation_read(user, session, group_id, conversation_id) do
      read_conversation(workspace, binding, opts)
    end
  end

  # The Conversation snapshot and the Message page read share this check.
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

      {:ok,
       if(Keyword.get(opts, :include_worker, false),
         do: Map.put(preview, "bound_worker", task_preview_worker(workspace, salix_conversation)),
         else: preview
       )}
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
           salix_update_group_conversation(workspace, conversation_id, update) do
      {:ok, present_canonical(workspace, salix_conversation, user)}
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
           Comma.Salix.Client.impl().set_task_archived(workspace, conversation_id, action, version) do
      {:ok, present_canonical(workspace, conversation, user)}
    else
      {:error, _} = error -> error
      _ -> {:error, {:bad_request, "Task and positive expected_updated_at are required"}}
    end
  end

  # At most 50 exact summary reads; no transcript hydration, Group scan or per-child RPC.
  def task_summaries(user, session, group_id, ids) when is_list(ids) and length(ids) <= 50 do
    with true <- Enum.all?(ids, &is_binary/1),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace) do
      Enum.reduce_while(Enum.uniq(ids), {:ok, []}, fn id, {:ok, summaries} ->
        with :ok <- Workspaces.group_session_scope(session, group_id, id),
             {:ok, %{"kind" => "agent_task"} = binding} <- authorized_binding(user, workspace, id) do
          {:cont, {:ok, [public_summary(binding) | summaries]}}
        else
          {:error, :not_found} -> {:cont, {:ok, summaries}}
          {:ok, _} -> {:cont, {:ok, summaries}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, summaries} -> {:ok, %{"data" => Enum.reverse(summaries)}}
        error -> error
      end
    else
      false -> {:error, {:bad_request, "ids must contain strings"}}
      error -> error
    end
  end

  def task_summaries(_, _, _, _), do: {:error, {:bad_request, "At most 50 ids are allowed"}}

  defp archive_filter(nil), do: {:ok, "exclude"}
  defp archive_filter(value) when value in ["exclude", "only", "include"], do: {:ok, value}
  defp archive_filter(_), do: {:error, {:bad_request, "Invalid archive filter"}}
  defp filter_archived(data, "include"), do: data

  defp filter_archived(data, mode),
    do: Enum.filter(data, &(&1["status"] == "archived" == (mode == "only")))

  def accept_task_review(user, session, group_id, conversation_id, attrs) do
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
      read_task_conversation(workspace, binding)
    else
      {:ok, %{"kind" => kind}} -> {:error, {:unsupported_for_kind, kind, "accept"}}
      {:error, _} = error -> error
    end
  end

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
  `SalixIM.Conversations.list_group_conversation_message_page/3`.
  """
  def message_page(user, session, group_id, conversation_id, opts) do
    with {:ok, workspace, binding} <-
           authorize_conversation_read(user, session, group_id, conversation_id) do
      client = Comma.Salix.Client.impl()

      if callback_exported?(client, :list_group_conversation_message_page, 3) do
        client.list_group_conversation_message_page(
          workspace,
          salix_conversation_id(binding),
          opts
        )
      else
        {:error, :salix_conversation_read_not_supported}
      end
    end
  end

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
         {:ok, conversation} <- read_conversation(workspace, binding) do
      {:ok,
       %{
         agent_id: workspace["router_agent_id"],
         billing_context: billing_context(workspace, binding["id"], user["id"]),
         messages: conversation["messages"] || []
       }}
    end
  end

  def send_message(user, session, group_id, conversation_id, attrs) do
    attrs = stringify(attrs)

    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, binding} <- authorized_binding(user, workspace, conversation_id) do
      request_id =
        normalize_request_id(attrs["client_request_id"]) ||
          new_request_id()

      send_salix_message(user, session, workspace, binding, attrs, request_id)
    end
  end

  @doc """
  Subscribe-before-snapshot for the user Chat invalidation stream.

  The returned snapshot is canonical Salix state. Subsequent notifications are
  hints only; no Salix sequence or durable Comma cursor is exposed.
  """
  def events(user, session, group_id, conversation_id, _opts \\ []) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, binding} <- authorized_binding(user, workspace, conversation_id),
         :ok <- ensure_events_kind(binding),
         {:ok, subscription} <- subscribe_user_chat(workspace, binding),
         {:ok, conversation} <- read_user_chat_conversation(workspace, binding) do
      stream_context =
        %{
          conversation_id: binding["id"],
          owner_pid: subscription["owner_pid"],
          source_conversation_id: salix_conversation_id(binding),
          workspace: workspace
        }
        |> maybe_put_participant_stream(workspace, binding)

      {:ok, Map.put(conversation, "type", "snapshot"), [], stream_context}
    end
  end

  def public(binding), do: Map.drop(binding, ["internal"])

  @doc false
  def present_canonical(workspace, salix_conversation, user \\ nil)
      when is_map(workspace) and is_map(salix_conversation) do
    workspace
    |> canonical_binding(salix_conversation, user)
    |> projected_summary()
    |> public_summary()
  end

  defp canonical_binding(workspace, salix_conversation, user) do
    conversation_id = salix_conversation["conversation_id"]
    now = now()

    %{
      "id" => conversation_id,
      "group_id" => workspace["default_group_id"],
      "kind" => salix_conversation["kind"],
      "title" => salix_conversation["title"] || default_title(salix_conversation),
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
    |> maybe_put_task_schedule(salix_conversation)
    |> put_archive_fields(salix_conversation)
    |> put_task_origin_fields(salix_conversation)
    |> put_meeting_fields(salix_conversation)
  end

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
        }
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
    |> put_public_working_provider(activity)
    |> put_public_loop_wake(activity)
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
    {:ok, "generic", Map.drop(activity, ["action", "summary", "goal", "tool_name"])}
  end

  defp public_activity_payload(
         %{"summary_class" => "generic", "phase" => phase, "status" => "running"} = activity
       )
       when phase in ["thinking", "messaging"] do
    copy = if phase == "thinking", do: "Thinking", else: "Typing"

    {:ok, "generic",
     activity
     |> Map.drop(["goal", "tool_name"])
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
         optional_public_activity_prose?(activity["tool_name"]) do
      {:ok, "public", activity}
    else
      :error
    end
  end

  defp public_activity_payload(
         %{"summary_class" => "none", "phase" => "idle", "status" => "idle"} = activity
       ) do
    {:ok, "none", Map.drop(activity, ["action", "summary", "goal", "tool_name"])}
  end

  defp public_activity_payload(_activity), do: :error

  defp public_activity_prose?(value) when is_binary(value) do
    value != "" and String.trim(value) != "" and
      length(String.codepoints(value)) <= @public_activity_prose_max_codepoints
  end

  defp public_activity_prose?(_value), do: false

  defp optional_public_activity_prose?(nil), do: true
  defp optional_public_activity_prose?(value), do: public_activity_prose?(value)

  defp read_conversation(workspace, binding, opts \\ [])

  defp read_conversation(workspace, %{"kind" => "user_chat"} = binding, opts),
    do: read_user_chat_conversation(workspace, binding, opts)

  defp read_conversation(workspace, %{"kind" => "agent_task"} = binding, opts),
    do: read_task_conversation(workspace, binding, opts)

  defp read_conversation(_workspace, _binding, _opts), do: {:error, :not_found}

  defp read_user_chat_conversation(workspace, binding, opts \\ []) do
    with {:ok, %{"conversation" => salix_conversation, "messages" => messages}} <-
           salix_get_group_conversation_with_messages(
             workspace,
             salix_conversation_id(binding),
             tail:
               min(
                 max(Keyword.get(opts, :message_limit, @transcript_limit), 1),
                 @transcript_limit
               )
           ),
         true <- salix_conversation["kind"] == "user_chat",
         {:ok, refreshed} <- project_binding_from_salix(binding, salix_conversation) do
      {:ok,
       refreshed
       |> public_summary()
       |> Map.put("title", salix_conversation["title"] || refreshed["title"] || "聊天")
       |> Map.put("status", salix_conversation["status"] || "active")
       |> Map.put("message_count", salix_conversation["message_count"] || length(messages))
       |> Map.put("messages", messages)
       |> Map.put("final_message_id", final_message_id(messages))}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp read_task_conversation(workspace, binding, opts \\ []) do
    with {:ok, %{"conversation" => salix_conversation, "messages" => messages}} <-
           salix_get_group_conversation_with_messages(
             workspace,
             salix_conversation_id(binding),
             tail:
               min(
                 max(Keyword.get(opts, :message_limit, @transcript_limit), 1),
                 @transcript_limit
               )
           ),
         true <- salix_conversation["kind"] == "agent_task",
         {:ok, refreshed} <- project_binding_from_salix(binding, salix_conversation) do
      {:ok,
       refreshed
       |> public_summary()
       |> Map.put("title", salix_conversation["title"] || refreshed["title"] || "Task")
       |> Map.put("status", conversation_status(salix_conversation))
       |> Map.put("activity_status", salix_conversation["activity_status"] || "idle")
       |> Map.put("message_count", salix_conversation["message_count"] || length(messages))
       |> put_optional("review_version", task_review_version(salix_conversation))
       |> put_optional("schedule", public_task_schedule(salix_conversation["schedule"]))
       |> Map.put("messages", messages)}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp send_salix_message(user, session, workspace, binding, attrs, request_id) do
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
        message_client_metadata(session, workspace, attrs),
        attrs["reply_to_message_id"]
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
         reply_to_message_id
       ) do
    with true <- salix_id == workspace["router_conversation_id"],
         {:ok, result} <-
           append_router_conversation_message(
             workspace,
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
      read_conversation(workspace, binding)
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_salix_message_identity}
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
         reply_to_message_id
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
      read_conversation(workspace, binding)
    else
      false -> {:error, :invalid_salix_message_identity}
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_salix_message_identity}
    end
  end

  defp send_authorized_salix_message(
         _user,
         _workspace,
         binding,
         _content,
         _request_id,
         _salix_id,
         _client_metadata,
         _reply_to_message_id
       ),
       do: {:error, {:unsupported_for_kind, binding["kind"], "message"}}

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

  # Display-only source context for this Message. The caller cannot use it
  # to select operation authority or expand the workspace boundary.
  defp message_client_metadata(session, workspace, attrs) do
    metadata = session_client_metadata(session)
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
  end

  defp session_client_metadata(_session), do: %{}

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
         salix_conversation["title"] || binding["title"] || default_title(binding)
       )
       |> Map.put("status", projected_status(binding, salix_conversation))
       |> put_optional("activity_status", salix_conversation["activity_status"])
       |> Map.put("message_count", salix_conversation["message_count"] || 0)
       |> maybe_put_task_schedule(salix_conversation)
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

  defp maybe_put_task_schedule(%{"kind" => "agent_task"} = binding, salix_conversation),
    do: put_optional(binding, "schedule", public_task_schedule(salix_conversation["schedule"]))

  defp maybe_put_task_schedule(binding, _salix_conversation), do: Map.delete(binding, "schedule")

  defp default_title(%{"kind" => "agent_task"}), do: "Task"
  defp default_title(_binding), do: "聊天"
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
      "schedule",
      "freshness",
      "created_by",
      "labels",
      "origin",
      "meeting",
      "client_platform",
      "created_at",
      "updated_at"
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp public_summary(binding) do
    binding
    |> public()
    |> Map.update("schedule", nil, &public_task_schedule/1)
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

  defp authorized_canonical_conversation?(workspace, %{
         "kind" => "user_chat",
         "conversation_id" => conversation_id
       }),
       do: conversation_id == workspace["router_conversation_id"]

  defp authorized_canonical_conversation?(_workspace, _conversation), do: false

  defp workspace_group_binding_revision(workspace),
    do: Workspaces.group_binding_revision(workspace)

  defp ensure_events_kind(%{"kind" => "user_chat"}), do: :ok

  defp ensure_events_kind(%{"kind" => kind}),
    do: {:error, {:unsupported_for_kind, kind, "events"}}

  defp subscribe_task_list(workspace) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :subscribe_group_conversation_list, 3) do
      client.subscribe_group_conversation_list(workspace, "agent_task", self())
    else
      {:error, :salix_conversation_list_subscription_not_supported}
    end
  end

  defp subscribe_user_chat(workspace, binding) do
    client = Comma.Salix.Client.impl()

    if callback_exported?(client, :subscribe_group_conversation, 3) do
      client.subscribe_group_conversation(workspace, salix_conversation_id(binding), self())
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
        self()
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

  defp public_content_match(%{"snippet" => snippet, "highlights" => highlights})
       when is_binary(snippet) and is_list(highlights) do
    with true <- String.valid?(snippet),
         true <- byte_size(snippet) <= SearchDocumentEnvelope.max_bytes(:message),
         {:ok, ranges} <- public_highlights(highlights, snippet) do
      {:ok, %{"snippet" => snippet, "highlights" => ranges}}
    else
      false -> :error
      :error -> :error
    end
  end

  defp public_content_match(_content_match), do: :error

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

  defp public_task_schedule(schedule) when is_map(schedule) do
    schedule
    |> Map.drop(["schedule_id", "conversation_id", "group_id", "tenant_id"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp public_task_schedule(_schedule), do: nil

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
    do: "req_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp now, do: System.system_time(:second)

  defp stringify(attrs) when is_map(attrs),
    do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp stringify(_attrs), do: %{}

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
    local_files = local_file_content_blocks(message)

    case local_files do
      [] ->
        text

      blocks ->
        if text == "", do: blocks, else: [%{"type" => "text", "text" => text} | blocks]
    end
  end

  defp local_file_content_blocks(%{"content" => content}) when is_list(content),
    do: Enum.filter(content, &match?(%{"type" => "local_file"}, &1))

  defp local_file_content_blocks(_message), do: []
end
