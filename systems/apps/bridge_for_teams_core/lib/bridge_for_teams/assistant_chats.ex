defmodule BridgeForTeams.AssistantChats do
  @moduledoc """
  The "New Home" assistant chat: one durable Salix conversation per user per
  Agent Swarm that backs the dashboard's docked chat panel.

  `ensure_chat/4` resolves the given project's current group router, reuses an
  existing binding or lazily creates a conversation, and remembers it in
  `user_assistant_chats`
  (unique per user + project), so every visit to the same swarm reuses the
  same thread — and different swarms (or the same user in another org) never
  share one. The caller resolves WHICH project the board is bound to
  (`BridgeForTeams.Projects.default_project_for_user/2` plus the user's
  dashboard prefs); this module never falls back to an arbitrary org project.
  The agent on the other end is a real Salix runtime agent — its tools
  (memory, OAuth credentials, task delegation) are what give the chat its
  reach.
  """
  import Ecto.Query
  require Logger

  alias BridgeForTeams.{Agents, Conversations, Observability, Repo}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Agent, Project, UserAssistantChat}

  @invalid_candidate_disposition "replace_invalid_salix_candidate"
  @participant_validation_page_limit 50
  @participant_validation_max_pages 10

  @type chat_context :: %{
          binding: UserAssistantChat.t(),
          project: Project.t(),
          agent: Agent.t() | nil
        }

  @doc "Fetch the user's assistant chat binding for one Agent Swarm."
  @spec get_binding(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, UserAssistantChat.t()} | {:error, :not_found}
  def get_binding(user_id, project_id) do
    case Repo.get_by(UserAssistantChat, user_id: user_id, project_id: project_id) do
      nil -> {:error, :not_found}
      binding -> {:ok, binding}
    end
  end

  @doc """
  Resolve the user's assistant chat for `project`, creating the Salix
  conversation and the (user, project) binding on first use.
  `initial_message` (optional, from opts) is sent right after creation so the
  agent starts with dashboard context.

  Passing `context_digest` (a digest of the context's STABLE instruction
  block) turns the context durable: the binding remembers which digest the
  conversation received, and a later `ensure_chat` whose digest drifted
  re-sends `initial_message` into the existing conversation. Compaction is
  deliberately not a refresh trigger because the Router session is shared
  across the swarm; see `maybe_refresh_context/4`. Refresh is best-effort: a
  failed send leaves the digest untouched so the next visit retries; two
  concurrent mounts can at worst double-send one hidden context message.

  Errors: `{:error, :no_project}` when the caller resolved no board project
  (nil — the dashboard shows its empty state),
  `{:error, :router_not_configured}` when the group's router is missing or
  blank, `{:error, :router_agent_not_found}` when that router has no matching
  active BFT agent, or a tagged Salix group/conversation error (callers degrade
  to an empty-state panel).
  """
  @spec ensure_chat(Ecto.UUID.t(), Ecto.UUID.t() | nil, Project.t() | nil, keyword()) ::
          {:ok, chat_context()} | {:error, term()}
  def ensure_chat(user_id, org_id, project, opts \\ [])

  def ensure_chat(_user_id, _org_id, nil, _opts), do: {:error, :no_project}

  def ensure_chat(user_id, org_id, %Project{} = project, opts) do
    case get_binding(user_id, project.id) do
      {:ok, binding} -> resolve_binding(binding, project, opts)
      {:error, :not_found} -> create_chat(user_id, org_id, project, opts)
    end
  end

  defp resolve_binding(binding, %Project{} = project, opts) do
    with {:ok, agent} <- Agents.current_router(project) do
      case replacement_seed(binding) do
        seed when is_binary(seed) ->
          create_chat_candidate(
            binding.user_id,
            binding.org_id,
            project,
            agent,
            binding,
            seed,
            opts
          )

        nil ->
          case validate_bound_chat(project, binding.conversation_id, agent) do
            :ok ->
              binding = maybe_refresh_context(binding, project, agent, opts)
              {:ok, %{binding: binding, project: project, agent: agent}}

            :stale ->
              create_chat_candidate(
                binding.user_id,
                binding.org_id,
                project,
                agent,
                binding,
                binding.conversation_id,
                opts
              )

            {:error, _reason} = error ->
              error
          end
      end
    end
  end

  defp validate_bound_chat(project, conversation_id, agent) do
    case Conversations.get_project_conversation(project, conversation_id) do
      {:ok, %{"kind" => "user_chat"}} ->
        validate_required_participants(project, conversation_id, agent.salix_agent_id)

      {:ok, conversation} when is_map(conversation) ->
        :stale

      {:error, :not_found} ->
        :stale

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, :invalid_salix_conversation}
    end
  end

  defp validate_required_participants(project, conversation_id, router_agent_id) do
    validate_required_participant_page(
      project,
      conversation_id,
      router_agent_id,
      nil,
      @participant_validation_max_pages,
      %{router?: false, provider?: false}
    )
  end

  defp validate_required_participant_page(
         _project,
         _conversation_id,
         _router_agent_id,
         _cursor,
         0,
         _found
       ),
       do: {:error, :salix_participant_validation_incomplete}

  defp validate_required_participant_page(
         project,
         conversation_id,
         router_agent_id,
         cursor,
         pages_left,
         found
       ) do
    opts =
      [limit: @participant_validation_page_limit]
      |> maybe_put_cursor(cursor)

    case Client.impl().list_group_conversation_participants(
           project.salix_group_id,
           conversation_id,
           opts
         ) do
      {:ok, %{"participants" => participants} = page} when is_list(participants) ->
        found = %{
          router?:
            found.router? or Enum.any?(participants, &router_participant?(&1, router_agent_id)),
          provider?: found.provider? or Enum.any?(participants, &bft_provider_participant?/1)
        }

        cond do
          found.router? and found.provider? ->
            :ok

          page["has_more"] == true ->
            case page["next_cursor"] do
              next_cursor
              when is_binary(next_cursor) and next_cursor != "" and next_cursor != cursor ->
                validate_required_participant_page(
                  project,
                  conversation_id,
                  router_agent_id,
                  next_cursor,
                  pages_left - 1,
                  found
                )

              _invalid_cursor ->
                {:error, :invalid_salix_participant_page}
            end

          true ->
            :stale
        end

      {:error, :not_found} ->
        :stale

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, :invalid_salix_participant_list}
    end
  end

  defp maybe_put_cursor(opts, cursor) when is_binary(cursor) and cursor != "",
    do: Keyword.put(opts, :cursor, cursor)

  defp maybe_put_cursor(opts, _cursor), do: opts

  defp router_participant?(participant, router_agent_id) do
    is_map(participant) and participant["actor_type"] == "agent" and
      participant["agent_id"] == router_agent_id and participant["state"] == "active"
  end

  defp bft_provider_participant?(participant) do
    expected = Conversations.bft_participant_attrs()

    is_map(participant) and participant["actor_type"] == "provider" and
      participant["provider"] == expected["provider"] and
      participant["target_key"] == expected["target_key"] and participant["state"] == "active"
  end

  # Re-send the (UI-hidden) context message only when the instructions
  # changed (digest drift — deploys, user rename). NULL digests
  # (pre-tracking rows) drift by definition, so every legacy binding
  # refreshes once on its next visit.
  #
  # Deliberately NOT a trigger: session compaction. The router session is
  # shared across the swarm's conversations and compacts routinely while
  # workers churn, so a compaction-marker re-send degenerated into "every
  # page refresh appends another 2 KB context message" — feeding the very
  # growth that forces the next compaction. The lossy-summary risk this
  # traded against is covered by the compaction instruction preserving
  # working state, and a digest bump still re-teaches after deploys.
  defp maybe_refresh_context(binding, project, _agent, opts) do
    digest = Keyword.get(opts, :context_digest)
    message = Keyword.get(opts, :initial_message)

    if is_binary(digest) and digest != "" and is_binary(message) and message != "" and
         binding.context_digest != digest do
      refresh_context(binding, project, message, digest)
    else
      binding
    end
  end

  defp refresh_context(binding, project, message, digest) do
    case Conversations.send_project_conversation_message(
           project,
           binding.conversation_id,
           message
         ) do
      {:ok, _result} ->
        binding
        |> UserAssistantChat.changeset(%{context_digest: digest})
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, _changeset} -> binding
        end

      {:error, reason} ->
        Logger.warning("assistant_chat_context_refresh_failed reason=#{inspect(reason)}")
        binding
    end
  end

  defp create_chat(user_id, org_id, %Project{} = project, opts) do
    with {:ok, agent} <- Agents.current_router(project) do
      create_chat_candidate(user_id, org_id, project, agent, nil, nil, opts)
    end
  end

  defp create_chat_candidate(user_id, org_id, project, agent, existing, replacement_seed, opts) do
    title = Keyword.get(opts, :title, "Comma assistant")
    request_id = assistant_chat_request_id(user_id, project.id, replacement_seed)

    with {:ok, conversation} <-
           Conversations.create_project_conversation(
             project,
             agent,
             %{
               "title" => title,
               "kind" => "user_chat",
               "owner_user_id" => user_id,
               "created_by_user_id" => user_id
             },
             actor_user_id: user_id,
             request_id: request_id
           ),
         conversation_id when is_binary(conversation_id) and conversation_id != "" <-
           conversation["conversation_id"],
         {:ok, _provider} <-
           Conversations.ensure_project_bft_participant(project, conversation_id) do
      case validate_bound_chat(project, conversation_id, agent) do
        :ok ->
          maybe_send_initial_message(project, conversation_id, opts, request_id)

          marker =
            Conversations.conversation_compaction_marker(project, agent, conversation_id)

          persist_valid_candidate(
            user_id,
            org_id,
            project,
            agent,
            existing,
            conversation_id,
            marker,
            request_id,
            opts
          )

        :stale ->
          persist_invalid_candidate(
            user_id,
            org_id,
            project,
            agent,
            existing,
            conversation_id,
            request_id,
            opts
          )

        {:error, _reason} = error ->
          error
      end
    else
      nil -> {:error, :invalid_salix_conversation_identity}
      "" -> {:error, :invalid_salix_conversation_identity}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_salix_conversation_identity}
    end
  end

  defp persist_valid_candidate(
         user_id,
         org_id,
         project,
         agent,
         nil,
         conversation_id,
         marker,
         request_id,
         opts
       ) do
    attrs = candidate_binding_attrs(user_id, org_id, project, conversation_id, marker, opts)

    %UserAssistantChat{}
    |> UserAssistantChat.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :project_id])

    case get_binding(user_id, project.id) do
      {:ok, %UserAssistantChat{conversation_id: ^conversation_id, disposition: nil} = binding} ->
        {:ok, %{binding: binding, project: project, agent: agent}}

      {:ok, %UserAssistantChat{disposition: disposition} = binding}
      when is_binary(disposition) ->
        persist_valid_candidate(
          user_id,
          org_id,
          project,
          agent,
          binding,
          conversation_id,
          marker,
          request_id,
          opts
        )

      {:ok, winner} ->
        record_candidate_disposition(
          project,
          user_id,
          conversation_id,
          winner.conversation_id,
          request_id,
          "concurrent_binding_winner"
        )

        resolve_binding(winner, project, opts)

      {:error, :not_found} ->
        {:error, :binding_not_persisted}
    end
  end

  defp persist_valid_candidate(
         user_id,
         _org_id,
         project,
         agent,
         %UserAssistantChat{} = existing,
         conversation_id,
         marker,
         request_id,
         opts
       ) do
    now = DateTime.utc_now()

    updates = [
      conversation_id: conversation_id,
      context_digest: Keyword.get(opts, :context_digest),
      context_summary_seq: marker,
      disposition: nil,
      replacement_seed_conversation_id: nil,
      updated_at: now
    ]

    {updated_count, _rows} =
      UserAssistantChat
      |> where([chat], chat.id == ^existing.id and chat.updated_at == ^existing.updated_at)
      |> Repo.update_all(set: updates)

    case {updated_count, get_binding(user_id, project.id)} do
      {1, {:ok, binding}} ->
        if existing.conversation_id != conversation_id do
          record_candidate_disposition(
            project,
            user_id,
            existing.conversation_id,
            conversation_id,
            request_id,
            "replaced_invalid_binding"
          )
        end

        {:ok, %{binding: binding, project: project, agent: agent}}

      {0,
       {:ok, %UserAssistantChat{conversation_id: ^conversation_id, disposition: nil} = binding}} ->
        {:ok, %{binding: binding, project: project, agent: agent}}

      {0, {:ok, winner}} ->
        record_candidate_disposition(
          project,
          user_id,
          conversation_id,
          winner.conversation_id,
          request_id,
          "concurrent_binding_winner"
        )

        resolve_binding(winner, project, opts)

      {_count, {:error, :not_found}} ->
        {:error, :binding_not_persisted}
    end
  end

  defp persist_invalid_candidate(
         user_id,
         org_id,
         project,
         _agent,
         nil,
         conversation_id,
         request_id,
         opts
       ) do
    attrs =
      candidate_binding_attrs(user_id, org_id, project, conversation_id, 0, opts)
      |> Map.put(:disposition, @invalid_candidate_disposition)
      |> Map.put(:replacement_seed_conversation_id, conversation_id)

    %UserAssistantChat{}
    |> UserAssistantChat.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :project_id])

    case get_binding(user_id, project.id) do
      {:ok, %UserAssistantChat{conversation_id: ^conversation_id} = marker} ->
        record_candidate_disposition(
          project,
          user_id,
          conversation_id,
          nil,
          request_id,
          "invalid_candidate"
        )

        if marker.disposition == @invalid_candidate_disposition,
          do: {:error, :invalid_salix_chat_candidate},
          else: resolve_binding(marker, project, opts)

      {:ok, winner} ->
        record_candidate_disposition(
          project,
          user_id,
          conversation_id,
          winner.conversation_id,
          request_id,
          "concurrent_binding_winner"
        )

        resolve_binding(winner, project, opts)

      {:error, :not_found} ->
        {:error, :binding_not_persisted}
    end
  end

  defp persist_invalid_candidate(
         user_id,
         _org_id,
         project,
         _agent,
         %UserAssistantChat{} = existing,
         conversation_id,
         request_id,
         opts
       ) do
    now = DateTime.utc_now()

    {updated_count, _rows} =
      UserAssistantChat
      |> where([chat], chat.id == ^existing.id and chat.updated_at == ^existing.updated_at)
      |> Repo.update_all(
        set: [
          disposition: @invalid_candidate_disposition,
          replacement_seed_conversation_id: conversation_id,
          updated_at: now
        ]
      )

    case {updated_count, get_binding(user_id, project.id)} do
      {1, {:ok, _marker}} ->
        record_candidate_disposition(
          project,
          user_id,
          conversation_id,
          existing.conversation_id,
          request_id,
          "invalid_replacement_candidate"
        )

        {:error, :invalid_salix_chat_candidate}

      {0, {:ok, winner}} ->
        if winner.conversation_id != conversation_id do
          record_candidate_disposition(
            project,
            user_id,
            conversation_id,
            winner.conversation_id,
            request_id,
            "concurrent_binding_winner"
          )
        end

        resolve_binding(winner, project, opts)

      {_count, {:error, :not_found}} ->
        {:error, :binding_not_persisted}
    end
  end

  defp candidate_binding_attrs(user_id, org_id, project, conversation_id, marker, opts) do
    %{
      user_id: user_id,
      org_id: org_id || project.org_id,
      project_id: project.id,
      conversation_id: conversation_id,
      context_digest: Keyword.get(opts, :context_digest),
      context_summary_seq: marker,
      disposition: nil,
      replacement_seed_conversation_id: nil
    }
  end

  defp replacement_seed(%UserAssistantChat{
         disposition: @invalid_candidate_disposition,
         replacement_seed_conversation_id: seed
       })
       when is_binary(seed) and seed != "",
       do: seed

  defp replacement_seed(_binding), do: nil

  defp assistant_chat_request_id(user_id, project_id, nil),
    do: "bft-assistant-chat:#{project_id}:#{user_id}"

  defp assistant_chat_request_id(user_id, project_id, replacement_seed),
    do: "bft-assistant-chat:#{project_id}:#{user_id}:replace:#{replacement_seed}"

  defp record_candidate_disposition(
         project,
         user_id,
         candidate_conversation_id,
         serving_conversation_id,
         request_id,
         reason_class
       ) do
    attrs = %{
      org_id: project.org_id,
      project_id: project.id,
      actor_user_id: user_id,
      domain: "conversation",
      resource_type: "assistant_chat_candidate",
      resource_id: candidate_conversation_id,
      source: "salix.conversation",
      event_type: "assistant_chat.candidate_orphaned",
      severity: "warning",
      status: "retained_non_serving",
      reason_class: reason_class,
      summary: "Assistant Chat candidate retained outside the serving product binding",
      evidence: %{
        "candidate_conversation_id" => candidate_conversation_id,
        "serving_conversation_id" => serving_conversation_id,
        "request_id" => request_id,
        "disposition" => "retain_non_serving"
      },
      correlation_id: "assistant-chat-candidate:#{candidate_conversation_id}:#{reason_class}",
      occurred_at: DateTime.utc_now()
    }

    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "assistant_chat_candidate_disposition_failed conversation_id=#{candidate_conversation_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_send_initial_message(project, conversation_id, opts, request_id) do
    case Keyword.get(opts, :initial_message) do
      text when is_binary(text) and text != "" ->
        case Conversations.send_project_conversation_message(project, conversation_id, text,
               request_id: request_id <> ":initial"
             ) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Logger.warning("assistant_chat_initial_message_failed reason=#{inspect(reason)}")
            :ok
        end

      _ ->
        :ok
    end
  end

  # What the assistant agent can actually consume, mirrored from the runtime
  # (`SalixAgent.Tools` read_file): images in exactly these formats render as
  # multimodal/vision input (`image_path?/1`); anything that is valid UTF-8
  # text is readable regardless of extension (`binary_content?/1`), so the
  # text list below is a curated picker set, not a hard runtime limit. Other
  # binaries (pdf, docx, zip…) raise "unsupported — add a dedicated reader",
  # so they must NOT be offered for upload.
  @image_upload_extensions ~w(.png .jpg .jpeg .gif .webp)
  @text_upload_extensions ~w(.md .markdown .txt .csv .tsv .json .jsonl .xml .yaml .yml .toml .html .htm .log)

  @doc "Image formats the agent runtime can read as image input."
  @spec image_upload_extensions() :: [String.t()]
  def image_upload_extensions, do: @image_upload_extensions

  @doc "All attachment formats the agent runtime can consume."
  @spec attachment_upload_extensions() :: [String.t()]
  def attachment_upload_extensions, do: @image_upload_extensions ++ @text_upload_extensions

  @doc """
  Store a chat attachment in the assistant agent's workspace VFS (under
  `/uploads/`) so the agent can read it with its file tools. Returns the VFS
  path to reference in the message.
  """
  @spec upload_attachment(Agent.t(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def upload_attachment(%Agent{salix_agent_id: agent_id}, filename, binary)
      when is_binary(agent_id) and is_binary(binary) do
    safe_name =
      filename
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")

    path = "/uploads/#{System.unique_integer([:positive])}-#{safe_name}"

    case BridgeForTeams.Salix.Client.impl().write_agent_file(agent_id, path, binary) do
      {:ok, _result} -> {:ok, path}
      {:error, _reason} = error -> error
    end
  end

  def upload_attachment(_agent, _filename, _binary), do: {:error, :no_agent}
end
