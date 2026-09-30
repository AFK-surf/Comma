defmodule BridgeForTeams.WorkspaceImports do
  @moduledoc """
  Import mock/demo data into a user's "My Space" board.

  External tools generate a JSON document (`format: "bft.myspace.import"`,
  `version: 1`) describing board cards, optional task-chat transcripts, an
  optional assistant-rail transcript, and an optional layout. This context
  validates the whole document up front, then upserts the cards as
  `BridgeForTeams.WorkspaceItems` — per-user `workspace_items` Postgres rows.

  ## The `mock_import` contract

  Every imported card row carries:

    * `external_source: "mock_import"` and `external_id: <document
      external_id>` — the first-class identity columns (unique per
      project + user via `workspace_items_project_external_idx`)
    * `source: "import"` and the legacy stamp
      `source_refs => %{"source" => "mock_import", "import_id" => external_id}`

  That identity is load bearing:

    * Re-imports are idempotent — an incoming `external_id` that matches an
      existing mock-import card updates it; a new one creates a card. Cards
      that are NOT mock imports are never touched.
    * `mode: "replace"` archives previously-imported (mock_import) cards whose
      `external_id` is absent from the new document.
    * `BridgeForTeams.DashboardProjection` skips writing its builder rows
      (metrics/team activity/meeting mirrors) into categories owned by a
      user's live mock-import cards, so projection refreshes never stack a
      live widget next to an imported demo one.

  Transcripts (item `messages` and `assistant_chat`) are written through the
  Salix seed-transcript path (`seed_group_conversation_transcript`), which
  never dispatches deliveries and advances the participants' delivery cursors
  past the seeded tail — imported mock messages NEVER wake the real agent.
  An imported item preallocates a canonical `salix_conversation_id`; seeding
  materializes that conversation with kind `user_chat`, so the task
  drawer renders the transcript while the projection (which only projects
  workspace kinds) never turns it into a duplicate board row.

  Live system-authored widgets hand their category over to an import:
  importing an item in category X archives any live onboarding seed card
  (`workspace_seed`) or projection singleton (`dashboard_projection`, i.e.
  metrics/team activity) in category X (counted in `archived`), and
  `WorkspaceItems.ensure_seeded/4` skips categories that already hold a live
  mock-import card.

  Validation is all-or-nothing: the entire document is validated before any
  write, so a rejected document never leaves partial state behind.
  """

  require Logger

  alias BridgeForTeams.{
    Accounts,
    Agents,
    AssistantChats,
    Conversations,
    Memberships,
    Observability,
    WorkspaceItems
  }

  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Agent, Organization, Project, User}
  alias SalixStore.Ids

  @format "bft.myspace.import"
  @version 1
  @mock_source "mock_import"
  @item_source "import"

  @max_items 100
  @max_payload_bytes 32 * 1024
  @max_messages 50
  @roles ~w(user agent)
  @modes ~w(merge replace)

  @type summary :: %{
          created: non_neg_integer(),
          updated: non_neg_integer(),
          archived: non_neg_integer(),
          messages_appended: non_neg_integer(),
          messages_skipped: non_neg_integer(),
          items: [%{external_id: String.t(), conversation_id: String.t() | nil}]
        }

  @doc """
  Import a My Space document into `target_user`'s board for `project`.

  `actor_user` is who performed the import (audited), `target_user` is whose
  board receives the cards. Returns `{:ok, summary}` or, for a document that
  fails validation, `{:error, {:validation, errors}}` where each error is
  `%{index: non_neg_integer() | nil, external_id: String.t() | nil, errors: [String.t()]}`.
  """
  @spec import_document(User.t(), User.t(), Organization.t(), Project.t(), map(), keyword()) ::
          {:ok, summary()} | {:error, term()}
  def import_document(
        %User{} = actor_user,
        %User{} = target_user,
        %Organization{} = org,
        %Project{} = project,
        doc,
        opts \\ []
      )
      when is_map(doc) do
    with :ok <- validate_document(doc) do
      mode = normalize_mode(doc["mode"])
      items = List.wrap(doc["items"])

      existing =
        WorkspaceItems.list_tasks(target_user.id, project_id: project.id, include_archived: true)

      mock_index = index_mock_imports(existing)
      incoming_ids = MapSet.new(items, & &1["external_id"])

      with {:ok, processed} <- process_items(target_user, org, project, items, mock_index),
           {:ok, replaced} <- maybe_archive_missing(mode, mock_index, incoming_ids),
           {:ok, seed_archived} <- archive_superseded_widgets(existing, items),
           {:ok, chat_counts} <-
             import_assistant_chat(target_user, org, project, doc["assistant_chat"]) do
        apply_layout(target_user, org, project, doc["layout"])

        summary =
          processed
          |> Map.update!(:archived, &(&1 + replaced + seed_archived))
          |> Map.update!(:messages_appended, &(&1 + chat_counts.appended))
          |> Map.update!(:messages_skipped, &(&1 + chat_counts.skipped))

        record_audit(actor_user, target_user, org, project, mode, summary, opts)

        {:ok, summary}
      end
    end
  end

  @doc """
  Resolve the board's target user. Defaults to `actor_user`; when `user_email`
  is given it must resolve to an org member and the actor must be an org
  owner/admin. Returns `{:error, :forbidden}` or `{:error, :not_found}` on
  failure, matching the web layer's error conventions.
  """
  @spec resolve_target_user(User.t(), Organization.t(), String.t() | nil) ::
          {:ok, User.t()} | {:error, :forbidden | :not_found}
  def resolve_target_user(%User{} = actor_user, %Organization{}, email) when email in [nil, ""],
    do: {:ok, actor_user}

  def resolve_target_user(%User{} = actor_user, %Organization{} = org, email)
      when is_binary(email) do
    with :ok <- require_org_admin(actor_user, org),
         {:ok, %User{} = user} <- Accounts.get_user_by_email(String.trim(email)),
         {:ok, _role} <- Memberships.org_role(org.id, user.id) do
      {:ok, user}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _not_a_member -> {:error, :not_found}
    end
  end

  @doc "Whether a workspace item was created by a mock import."
  @spec mock_import_item?(WorkspaceItems.Item.t()) :: boolean()
  def mock_import_item?(%WorkspaceItems.Item{} = item) do
    item.external_source == @mock_source or
      (is_map(item.source_refs) and item.source_refs["source"] == @mock_source)
  end

  def mock_import_item?(_item), do: false

  # ---- item processing -------------------------------------------------------

  defp process_items(target_user, org, project, items, mock_index) do
    # Partition into updates (matched mock_import cards) and creates, keeping
    # document order so the returned `items` list matches the input.
    {creates, updates} =
      items
      |> Enum.with_index()
      |> Enum.split_with(fn {item, _index} ->
        not Map.has_key?(mock_index, item["external_id"])
      end)

    with {:ok, created_results} <- run_creates(target_user, org, project, creates),
         {:ok, updated_results} <- run_updates(updates, mock_index) do
      merged =
        (created_results ++ updated_results)
        |> Enum.sort_by(fn {index, _entry, _counts} -> index end)

      summary =
        Enum.reduce(
          merged,
          %{
            created: 0,
            updated: 0,
            archived: 0,
            messages_appended: 0,
            messages_skipped: 0,
            items: []
          },
          fn {_index, entry, counts}, acc ->
            acc
            |> Map.update!(counts.kind, &(&1 + 1))
            |> Map.update!(:messages_appended, &(&1 + counts.appended))
            |> Map.update!(:messages_skipped, &(&1 + counts.skipped))
            |> Map.update!(:items, &(&1 ++ [entry]))
          end
        )

      {:ok, summary}
    end
  end

  defp run_creates(_target_user, _org, _project, []), do: {:ok, []}

  defp run_creates(target_user, org, project, creates) do
    attrs_list = Enum.map(creates, fn {item, _index} -> create_attrs(item) end)

    case WorkspaceItems.create_tasks(target_user.id, org.id, project.id, attrs_list) do
      {:ok, created_items} ->
        agent = first_agent(project)

        results =
          creates
          |> Enum.zip(created_items)
          |> Enum.map(fn {{item, index}, created} ->
            {appended, skipped} =
              seed_transcript(
                project,
                agent,
                created.salix_conversation_id,
                item["messages"],
                {:item, created.title, target_user.id}
              )

            entry = %{
              external_id: item["external_id"],
              conversation_id: created.salix_conversation_id
            }

            {index, entry, %{kind: :created, appended: appended, skipped: skipped}}
          end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_updates(updates, mock_index) do
    Enum.reduce_while(updates, {:ok, []}, fn {item, index}, {:ok, acc} ->
      existing = Map.fetch!(mock_index, item["external_id"])

      case WorkspaceItems.update_task(existing, update_attrs(item)) do
        {:ok, updated} ->
          # Messages are appended only on create; on update they are skipped so
          # a re-import never duplicates a transcript.
          skipped = length(List.wrap(item["messages"]))

          entry = %{
            external_id: item["external_id"],
            conversation_id: updated.salix_conversation_id
          }

          {:cont, {:ok, [{index, entry, %{kind: :updated, appended: 0, skipped: skipped}} | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_archive_missing("replace", mock_index, incoming_ids) do
    mock_index
    |> Enum.reject(fn {import_id, item} ->
      MapSet.member?(incoming_ids, import_id) or item.status == "archived" or
        not is_nil(item.archived_at)
    end)
    |> Enum.reduce_while({:ok, 0}, fn {_import_id, item}, {:ok, count} ->
      case WorkspaceItems.archive_task(item) do
        {:ok, _archived} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_archive_missing(_mode, _mock_index, _incoming_ids), do: {:ok, 0}

  # A live system-authored widget in a category this document imports would
  # sit on the board next to the mock card as a duplicate: the onboarding seed
  # containers (`source_refs["source"] == "workspace_seed"`) and the dashboard
  # projection's singleton widgets (`external_source == "dashboard_projection"`
  # — metrics/team activity). The import adopts the category and archives
  # them; user- and agent-authored cards (and real projected conversations,
  # meetings, recaps) are never touched.
  defp archive_superseded_widgets(existing, items) do
    categories = MapSet.new(items, & &1["category"])
    seed_source = WorkspaceItems.seed_source()

    existing
    |> Enum.filter(fn item ->
      system_widget? =
        item.external_source == "dashboard_projection" or
          get_in(item.source_refs, ["source"]) == seed_source

      system_widget? and item.status != "archived" and is_nil(item.archived_at) and
        MapSet.member?(categories, item.category)
    end)
    |> Enum.reduce_while({:ok, 0}, fn item, {:ok, count} ->
      case WorkspaceItems.archive_task(item) do
        {:ok, _archived} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Index existing mock-import cards by the first-class identity columns.
  defp index_mock_imports(items) do
    items
    |> Enum.filter(&(&1.external_source == @mock_source))
    |> Enum.reduce(%{}, fn item, acc ->
      case item.external_id do
        id when is_binary(id) and id != "" -> Map.put_new(acc, id, item)
        _ -> acc
      end
    end)
  end

  defp create_attrs(item) do
    %{
      "title" => item["title"],
      "description" => item["description"],
      "category" => item["category"],
      "status" => item["status"] || "in_progress",
      "platform" => item["platform"] || "comma",
      "labels" => item["labels"] || [],
      "payload" => item["payload"] || %{},
      "metadata" => item["metadata"] || %{},
      "source" => @item_source,
      "external_source" => @mock_source,
      "external_id" => item["external_id"],
      "salix_conversation_id" => Ids.new_conversation_id(),
      "source_refs" => %{"source" => @mock_source, "import_id" => item["external_id"]}
    }
  end

  defp update_attrs(item) do
    %{
      "title" => item["title"],
      "description" => item["description"],
      "status" => item["status"] || "in_progress",
      "platform" => item["platform"] || "comma",
      "labels" => item["labels"] || [],
      "payload" => item["payload"] || %{},
      "metadata" => item["metadata"] || %{},
      "source" => @item_source
    }
  end

  # ---- messages --------------------------------------------------------------

  # Mock transcripts go through the Salix seed path
  # (`seed_group_conversation_transcript`) — ONE call per conversation, never
  # the delivery-triggering append path — so the real
  # agent never processes an imported "user" message. The seed also advances
  # the participants' delivery cursors past the seeded tail
  # (`mark_participants_delivered`), so delivery recovery can't replay the
  # transcript into the agent later.
  #
  # `context` picks the conversation attrs:
  #
  #   * `{:item, title, user_id}` — the imported item has preallocated a
  #     `salix_conversation_id`; the seed CREATES it as
  #     kind `user_chat` (the row is the board item, the conversation is only
  #     its chat transcript — and `user_chat` keeps the projection from
  #     re-projecting it into a duplicate row).
  #   * `{:assistant_chat, user_id}` — the rail conversation exists; mirror its
  #     record (the seed upsert merges over it) so title/status stay intact.
  defp seed_transcript(project, agent, conversation_id, messages, context)

  defp seed_transcript(%Project{} = project, agent, conversation_id, messages, context)
       when is_list(messages) or is_nil(messages) do
    messages = messages |> List.wrap() |> Enum.take(@max_messages)

    with {:ok, conversation_attrs} <-
           seed_conversation_attrs(context, project, agent, conversation_id),
         {:ok, seed} <-
           prepare_seed_payload(
             conversation_attrs,
             seed_messages(messages, agent, seed_user_id(context), conversation_id),
             conversation_id
           ),
         {:ok, result} <-
           Client.impl().seed_group_conversation_transcript(
             project.salix_group_id,
             conversation_id,
             seed
           ) do
      appended = seed_appended_count(result, length(messages))
      {appended, length(messages) - appended}
    else
      error ->
        Logger.warning(
          "workspace_import_seed_failed conversation_id=#{conversation_id} reason=#{inspect(error)}"
        )

        {0, length(messages)}
    end
  end

  defp seed_conversation_attrs({:item, title, user_id}, _project, agent, _conversation_id) do
    {:ok,
     %{
       "kind" => "user_chat",
       "title" => title,
       "participants" => item_chat_participants(agent, user_id)
     }}
  end

  defp seed_conversation_attrs({:assistant_chat, _user_id}, project, _agent, conversation_id) do
    with {:ok, _participant} <-
           Conversations.ensure_project_bft_participant(project, conversation_id),
         {:ok, conversation} <- Conversations.get_project_conversation(project, conversation_id) do
      participants =
        case Conversations.list_project_conversation_participants(project, conversation_id) do
          {:ok, participants} -> participants
          {:error, _reason} -> []
        end
        |> ensure_bft_seed_participant()

      {:ok, seed_conversation_mirror(conversation, participants)}
    end
  end

  defp item_chat_participants(agent, _user_id) do
    bft_participant = Conversations.bft_participant_attrs()

    case agent do
      %Agent{} = agent ->
        [
          bft_participant,
          %{
            "actor_type" => "agent",
            "agent_id" => agent.salix_agent_id,
            "agent_name" => agent.salix["name"],
            "role_label" => agent.role || "agent",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]

      _no_agent ->
        [bft_participant]
    end
  end

  defp ensure_bft_seed_participant(participants) do
    participants = List.wrap(participants)

    if Enum.any?(participants, &(&1["actor_type"] == "provider" and &1["provider"] == "bft")),
      do: participants,
      else: [Conversations.bft_participant_attrs() | participants]
  end

  # An existing rail has already consumed its preallocated identity. Mirror the
  # canonical create semantics as well as presentation fields so the owner can
  # verify that the seed is attaching to that exact conversation.
  defp seed_conversation_mirror(conversation, participants) do
    conversation
    |> Map.take(
      ~w(kind title status activity_status created_by_agent_id owner_user_id source_refs schedule created_at updated_at)
    )
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
    |> put_seed_participants(participants)
  end

  defp put_seed_participants(attrs, participants) when is_list(participants) do
    mirrored =
      participants
      |> Enum.filter(&is_map/1)
      |> Enum.map(
        &Map.take(
          &1,
          ~w(participant_id actor_type agent_id agent_name role_label state notification_filter user_id provider target_key payload)
        )
      )
      |> Enum.filter(fn participant ->
        present_string?(participant["actor_type"])
      end)

    if mirrored == [], do: attrs, else: Map.put(attrs, "participants", mirrored)
  end

  defp put_seed_participants(attrs, _participants), do: attrs

  defp seed_user_id({:item, _title, user_id}), do: user_id
  defp seed_user_id({:assistant_chat, user_id}), do: user_id

  defp prepare_seed_payload(conversation, messages, conversation_id) do
    now = System.system_time(:millisecond)

    participants =
      conversation["participants"]
      |> List.wrap()
      |> Enum.map(fn participant ->
        participant
        |> Map.put_new("participant_id", Ids.new_participant_id())
        |> Map.put("conversation_id", conversation_id)
        |> Map.put_new("state", "active")
        |> Map.put_new("notification_filter", %{
          "messages" => "all",
          "statuses" => "none"
        })
        |> Map.put_new("created_at", now)
        |> Map.put_new("updated_at", now)
      end)

    messages =
      Enum.map(messages, fn message ->
        participant =
          Enum.find(participants, fn participant ->
            case message["actor_type"] do
              "agent" ->
                participant["actor_type"] == "agent" and
                  participant["agent_id"] == message["agent_id"]

              "provider_user" ->
                participant["actor_type"] == "provider" and participant["provider"] == "bft"

              _ ->
                false
            end
          end)

        if participant,
          do: Map.put(message, "participant_id", participant["participant_id"]),
          else: message
      end)

    if Enum.all?(messages, &Ids.valid_participant_id?(&1["participant_id"])) do
      {:ok,
       %{
         "conversation" =>
           conversation
           |> Map.put("conversation_id", conversation_id)
           |> Map.put("participants", participants)
           |> Map.put_new("status", "active")
           |> Map.put_new("activity_status", "idle")
           |> Map.put_new("created_at", now)
           |> Map.put_new("updated_at", now),
         "messages" => messages,
         "mark_participants_delivered" => true
       }}
    else
      {:error, :seed_message_participant_not_found}
    end
  end

  defp seed_messages(messages, agent, user_id, conversation_id) do
    base_ms = System.system_time(:millisecond)

    messages
    |> Enum.with_index()
    # Explicit increasing timestamps preserve the document's message order.
    |> Enum.map(fn {message, index} ->
      seed_message(message, agent, user_id, conversation_id, index, base_ms + index)
    end)
  end

  defp seed_message(message, agent, user_id, conversation_id, index, created_at_ms) do
    role = message["role"]
    actor_type = if role == "user", do: "provider_user", else: role
    text = String.trim(to_string(message["text"] || ""))

    %{
      "client_request_id" => "workspace_import:#{conversation_id}:#{index}",
      "kind" => "message",
      "actor_type" => actor_type,
      "content" => [%{"type" => "text", "text" => text}],
      "metadata" => %{"source" => @mock_source},
      "created_at" => created_at_ms
    }
    |> put_user_identity(role, user_id)
    |> put_agent_identity(role, agent)
  end

  defp put_user_identity(payload, "user", user_id) do
    payload
    |> Map.put("provider", "bft")
    |> Map.put("user_id", user_id)
  end

  defp put_user_identity(payload, _role, _user_id), do: payload

  defp put_agent_identity(payload, "agent", %Agent{} = agent) do
    payload
    |> Map.put("agent_id", agent.salix_agent_id)
    |> Map.put("agent_name", agent.salix["name"])
  end

  defp put_agent_identity(payload, _role, _agent), do: payload

  defp seed_appended_count(result, requested) when is_map(result) do
    case result["appended_count"] do
      count when is_integer(count) and count >= 0 -> count
      _other -> requested
    end
  end

  defp seed_appended_count(_result, requested), do: requested

  # ---- assistant chat --------------------------------------------------------

  defp import_assistant_chat(_target_user, _org, _project, nil),
    do: {:ok, %{appended: 0, skipped: 0}}

  defp import_assistant_chat(target_user, org, project, %{"messages" => messages})
       when is_list(messages) and messages != [] do
    with {:ok, %{binding: binding, agent: agent}} <-
           AssistantChats.ensure_chat(target_user.id, org.id, project) do
      conversation_id = binding.conversation_id

      if already_mock_imported?(project, conversation_id) do
        # Append-once: a rail that already carries a mock-import transcript is
        # left as-is so re-imports never stack duplicate assistant chatter.
        {:ok, %{appended: 0, skipped: length(messages)}}
      else
        {appended, skipped} =
          seed_transcript(
            project,
            agent,
            conversation_id,
            messages,
            {:assistant_chat, target_user.id}
          )

        {:ok, %{appended: appended, skipped: skipped}}
      end
    end
  end

  defp import_assistant_chat(_target_user, _org, _project, _assistant_chat),
    do: {:ok, %{appended: 0, skipped: 0}}

  defp already_mock_imported?(%Project{} = project, conversation_id) do
    case Conversations.list_project_conversation_messages(project, conversation_id,
           limit: @max_messages
         ) do
      {:ok, messages} ->
        Enum.any?(messages, fn message ->
          is_map(message) and get_in(message, ["metadata", "source"]) == @mock_source
        end)

      _ ->
        false
    end
  end

  # ---- layout ----------------------------------------------------------------

  # Map the import's optional `layout` onto the existing per-(user, org)
  # dashboard prefs, keyed by this project. `widget_order` maps to the
  # `home_layout` widget order and `sizes` to `widget_sizes`; both prefs are
  # per-project maps, so we merge this project's entry and leave other swarms'
  # saved layouts untouched. Best-effort: a prefs write error never fails the
  # import (the cards are what matter).
  defp apply_layout(_target_user, _org, _project, nil), do: :ok

  defp apply_layout(%User{} = target_user, %Organization{} = org, %Project{} = project, layout)
       when is_map(layout) do
    prefs = BridgeForTeams.DashboardPrefs.get(target_user.id, org.id)

    with order when is_list(order) <- normalize_widget_order(layout["widget_order"]) do
      home_layout = Map.put((prefs && prefs.home_layout) || %{}, project.id, order)
      BridgeForTeams.DashboardPrefs.put_home_layout(target_user.id, org.id, home_layout)
    end

    with sizes when is_map(sizes) <- normalize_widget_sizes(layout["sizes"]) do
      widget_sizes = Map.put((prefs && prefs.widget_sizes) || %{}, project.id, sizes)
      BridgeForTeams.DashboardPrefs.put_widget_sizes(target_user.id, org.id, widget_sizes)
    end

    :ok
  end

  defp apply_layout(_target_user, _org, _project, _layout), do: :ok

  defp normalize_widget_order(order) when is_list(order), do: Enum.filter(order, &is_binary/1)
  defp normalize_widget_order(_order), do: nil

  @widget_sizes ~w(small medium large)

  defp normalize_widget_sizes(sizes) when is_map(sizes) do
    sizes
    |> Enum.filter(fn {category, size} -> is_binary(category) and size in @widget_sizes end)
    |> Map.new()
  end

  defp normalize_widget_sizes(_sizes), do: nil

  # ---- audit -----------------------------------------------------------------

  defp record_audit(actor_user, target_user, org, project, mode, summary, opts) do
    Observability.record_audit(%{
      org_id: org.id,
      actor_user_id: actor_user.id,
      actor_label: actor_label(actor_user),
      action: "dashboard_import.applied",
      resource_type: "dashboard_import",
      resource_id: project.id,
      resource_label: "My Space import (#{mode})",
      result: "ok",
      request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
      metadata: %{
        "target_user_id" => target_user.id,
        "project_id" => project.id,
        "mode" => mode,
        "created" => summary.created,
        "updated" => summary.updated,
        "archived" => summary.archived,
        "messages_appended" => summary.messages_appended,
        "messages_skipped" => summary.messages_skipped
      }
    })
  end

  defp actor_label(%User{email: email}) when is_binary(email) and email != "", do: email
  defp actor_label(%User{name: name}) when is_binary(name) and name != "", do: name
  defp actor_label(%User{id: id}), do: id

  # ---- validation ------------------------------------------------------------

  defp validate_document(doc) do
    doc_errors =
      []
      |> check(doc["format"] == @format, "format must be \"#{@format}\"")
      |> check(doc["version"] == @version, "version must be #{@version}")
      |> check(valid_mode?(doc["mode"]), "mode must be one of #{Enum.join(@modes, ", ")}")
      |> check(is_list(doc["items"]), "items must be a list")
      |> check(items_within_cap?(doc["items"]), "items exceeds the #{@max_items} item cap")

    item_errors = validate_items(doc["items"])
    chat_errors = validate_assistant_chat(doc["assistant_chat"])

    errors =
      []
      |> maybe_doc_error(doc_errors)
      |> Kernel.++(item_errors)
      |> Kernel.++(chat_errors)

    if errors == [], do: :ok, else: {:error, {:validation, errors}}
  end

  defp validate_items(items) when is_list(items) do
    seen = duplicate_ids(items)

    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> validate_item(item, index, seen) end)
  end

  defp validate_items(_items), do: []

  defp validate_item(item, index, duplicate_ids) when is_map(item) do
    external_id = item["external_id"]

    errors =
      []
      |> check(present_string?(external_id), "external_id is required")
      |> check(
        not MapSet.member?(duplicate_ids, external_id),
        "external_id must be unique in the document"
      )
      |> check(present_string?(item["title"]), "title is required")
      |> check(item["category"] in WorkspaceItems.categories(), "category is not allowed")
      |> check(optional_in?(item["status"], WorkspaceItems.statuses()), "status is not allowed")
      |> check(
        optional_in?(item["platform"], WorkspaceItems.platforms()),
        "platform is not allowed"
      )
      |> check(optional_string_list?(item["labels"]), "labels must be a list of strings")
      |> check(optional_map?(item["payload"]), "payload must be an object")
      |> check(payload_within_cap?(item["payload"]), "payload exceeds the 32KB cap")
      |> check(optional_map?(item["metadata"]), "metadata must be an object")
      |> Kernel.++(validate_messages(item["messages"]))

    if errors == [],
      do: [],
      else: [%{index: index, external_id: normalize_external_id(external_id), errors: errors}]
  end

  defp validate_item(_item, index, _duplicate_ids),
    do: [%{index: index, external_id: nil, errors: ["item must be an object"]}]

  defp validate_messages(nil), do: []

  defp validate_messages(messages) when is_list(messages) do
    []
    |> check(
      length(messages) <= @max_messages,
      "messages exceeds the #{@max_messages} message cap"
    )
    |> Kernel.++(Enum.flat_map(messages, &validate_message/1))
  end

  defp validate_messages(_messages), do: ["messages must be a list"]

  defp validate_message(message) when is_map(message) do
    []
    |> check(message["role"] in @roles, "message role must be one of #{Enum.join(@roles, ", ")}")
    |> check(present_string?(message["text"]), "message text is required")
  end

  defp validate_message(_message), do: ["message must be an object"]

  defp validate_assistant_chat(nil), do: []

  defp validate_assistant_chat(%{"messages" => messages}) when is_list(messages) do
    case validate_messages(messages) do
      [] -> []
      errors -> [%{index: nil, external_id: "assistant_chat", errors: errors}]
    end
  end

  defp validate_assistant_chat(%{} = _chat), do: []

  defp validate_assistant_chat(_chat),
    do: [
      %{index: nil, external_id: "assistant_chat", errors: ["assistant_chat must be an object"]}
    ]

  defp duplicate_ids(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(& &1["external_id"])
    |> Enum.filter(&present_string?/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> id end)
    |> MapSet.new()
  end

  defp maybe_doc_error(errors, []), do: errors

  defp maybe_doc_error(errors, doc_errors),
    do: [%{index: nil, external_id: nil, errors: doc_errors} | errors]

  # ---- small helpers ---------------------------------------------------------

  defp check(errors, true, _message), do: errors
  defp check(errors, false, message), do: errors ++ [message]

  defp normalize_mode(mode) when mode in @modes, do: mode
  defp normalize_mode(_mode), do: "merge"

  defp valid_mode?(nil), do: true
  defp valid_mode?(mode), do: mode in @modes

  defp items_within_cap?(items) when is_list(items), do: length(items) <= @max_items
  defp items_within_cap?(_items), do: true

  defp optional_in?(nil, _allowed), do: true
  defp optional_in?(value, allowed), do: value in allowed

  defp optional_map?(nil), do: true
  defp optional_map?(value), do: is_map(value)

  defp optional_string_list?(nil), do: true
  defp optional_string_list?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp optional_string_list?(_value), do: false

  defp payload_within_cap?(nil), do: true

  defp payload_within_cap?(payload) when is_map(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> byte_size(json) <= @max_payload_bytes
      _ -> false
    end
  end

  defp payload_within_cap?(_payload), do: true

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_external_id(value) when is_binary(value), do: value
  defp normalize_external_id(_value), do: nil

  defp require_org_admin(%User{} = user, %Organization{} = org) do
    case Memberships.org_role(org.id, user.id) do
      {:ok, role} when role in ["owner", "admin"] -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp first_agent(%Project{} = project) do
    project.id |> Agents.list_agents() |> List.first()
  end
end
