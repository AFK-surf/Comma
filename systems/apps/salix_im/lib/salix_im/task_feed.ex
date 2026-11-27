defmodule SalixIM.TaskFeed do
  @moduledoc """
  Incremental Task Feed projection over canonical `agent_task` Conversations
  and their Messages.

  Maintains `salix_task_feed_entries` inside the Conversation source
  transaction (`SalixIM.ConversationPGStore`) with zero cross-conversation
  scans and zero polling:

  - User follow-ups, Router `task_request` messages, and Loop wakes advance the
    Task's active cluster context without inserting empty rows (so idle Loop
    wakes emit zero feed noise).
  - Agent `milestone` blocks upsert the active cluster in-place, deduplicating
    by `(seq, title)` and keeping up to 20 latest milestones plus total count.
  - Standalone milestones are backfilled with `outcome_message_id`,
    `outcome_text`, `media`, and `files` when the Agent's next visible reply
    arrives in the same cluster.
  - Tasks that reach `ready_for_review` or `completed` with a visible Agent
    reply materialize a clean feed entry even if no milestone was recorded.
  - Conversation title, status, archive/unarchive, and soft/hard delete changes
    synchronize in O(k) via `(group_id, conversation_id)`.
  """

  require Logger

  alias SalixIM.{
    ConversationAttachments,
    ConversationMessage,
    ConversationMilestone,
    ConversationPGStore
  }

  alias SalixStore.Repo
  alias SalixStore.TaskFeed, as: Store

  @max_trigger_text 140
  @max_outcome_text 240
  @max_media 4
  @max_files 3
  @backfill_tasks 25
  @backfill_messages 500
  @message_page 100
  @outcome_materializing_statuses ~w(
    ready_for_review needs_review review waiting_for_review escalated
    completed done closed success succeeded terminal
    failed cancelled canceled
  )

  @doc """
  Advances the internal `_task_feed_cluster` context on an `agent_task`
  Conversation record when a Message is appended.
  """
  @spec project_cluster(map(), map()) :: map()
  def project_cluster(%{"kind" => "agent_task"} = conversation, message) when is_map(message) do
    current = current_cluster(conversation)
    seq = message["seq"] || 0

    next =
      cond do
        loop_wake?(message) ->
          %{
            "cluster_key" => "run:#{seq}",
            "trigger_kind" => "run",
            "trigger_text" => nil,
            "is_loop" => true
          }

        seq == 1 ->
          %{
            "cluster_key" => "brief",
            "trigger_kind" => "brief",
            "trigger_text" => nil,
            "is_loop" => current["is_loop"] == true
          }

        follow_up_trigger?(message) ->
          %{
            "cluster_key" => "follow_up:#{message["message_id"]}",
            "trigger_kind" => "follow_up",
            "trigger_text" => extract_trigger_text(message),
            "is_loop" => current["is_loop"] == true
          }

        visible_agent_message?(message) and
            not ConversationMilestone.only_milestones?(message["content"]) ->
          outcome = extract_outcome(message)

          if outcome.has_outcome? do
            Map.put(current, "last_outcome", %{
              "message_id" => outcome.message_id,
              "text" => outcome.text,
              "media" => outcome.media,
              "files" => outcome.files,
              "at" => created_at(message),
              "seq" => seq
            })
          else
            current
          end

        true ->
          current
      end

    Map.put(conversation, "_task_feed_cluster", next)
  end

  def project_cluster(conversation, _message), do: conversation

  @doc """
  Synchronizes `salix_task_feed_entries` inside the Conversation transaction on
  Message append or Conversation metadata update.
  """
  @spec sync!(map(), map() | nil, map(), map() | nil) :: :ok
  def sync!(scope, previous, %{"kind" => "agent_task"} = record, message) do
    if message do
      sync_message!(scope, record, message)
    end

    if previous do
      sync_metadata_change!(scope, previous, record)
    end

    :ok
  end

  def sync!(_scope, _previous, _record, _message), do: :ok

  @doc """
  Replays a page of historical Messages (`seq ASC`) into `salix_task_feed_entries`
  inside the caller's transaction, returning the resulting `_task_feed_cluster`
  map so multi-page backfills preserve cluster context across pages.
  """
  @spec backfill_messages!(map(), map(), [map()], map() | nil) :: map() | nil
  def backfill_messages!(scope, record, messages, initial_cluster \\ nil)

  def backfill_messages!(scope, %{"kind" => "agent_task"} = record, messages, initial_cluster)
      when is_list(messages) do
    seed =
      case initial_cluster do
        cluster when is_map(cluster) -> Map.put(record, "_task_feed_cluster", cluster)
        _nil -> Map.delete(record, "_task_feed_cluster")
      end

    final_record =
      Enum.reduce(messages, seed, fn msg, acc ->
        next = project_cluster(acc, msg)
        sync_message!(scope, next, msg)
        next
      end)

    final_record["_task_feed_cluster"]
  end

  def backfill_messages!(_scope, _record, _messages, _initial_cluster), do: nil

  ## Backfill

  @doc """
  Opens the Task Feed backfill after a successful core rollout, under the marker
  `task_feed_v1` (`salix_cutover_markers`) and the release's `authority`.
  Answers `:opened`, `:indexing` while pages remain, or `:ready`.
  """
  @spec open_after_rollout(String.t()) ::
          {:ok, :opened | :indexing | :ready} | {:error, :invalid | :unavailable}
  def open_after_rollout(authority) when is_binary(authority) and authority != "" do
    %{num_rows: opened} =
      Repo.query!(
        "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, now(), $2) ON CONFLICT (name) DO NOTHING",
        [
          Store.marker(),
          %{"phase" => "running", "position" => nil, "processed" => 0, "authority" => authority}
        ]
      )

    cond do
      opened == 1 -> {:ok, :opened}
      Store.ready?() -> {:ok, :ready}
      true -> {:ok, :indexing}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def open_after_rollout(_authority), do: {:error, :invalid}

  @doc """
  One page of the Task Feed backfill the release opened. Records the position of
  the next page in `task_feed_v1`, carrying the in-flight cluster context when a
  single Task spans pages. Answers `{:ok, :closed}` until opened, `{:ok, :complete}`
  once done, else `{:ok, %{processed: n, done: boolean}}`.
  """
  @spec backfill_page() ::
          {:ok, :closed | :complete | %{processed: non_neg_integer(), done: boolean()}}
          | {:error, term()}
  def backfill_page do
    marker = Store.marker()

    case Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name = $1", [marker]) do
      %{rows: []} ->
        {:ok, :closed}

      %{rows: [[%{"phase" => "complete"}]]} ->
        {:ok, :complete}

      %{rows: [[evidence]]} ->
        with {:ok, %{processed: processed, skipped: skipped, next: next}} <-
               index_page(evidence["position"]) do
          %{num_rows: recorded} =
            Repo.query!(
              "UPDATE salix_cutover_markers SET evidence = $2, completed_at = now() WHERE name = $1 AND evidence = $3",
              [
                marker,
                Map.merge(evidence, %{
                  "phase" => if(is_nil(next), do: "complete", else: "running"),
                  "position" => next,
                  "processed" => (evidence["processed"] || 0) + processed,
                  "skipped" => (evidence["skipped"] || 0) + skipped
                }),
                evidence
              ]
            )

          {:ok, %{processed: processed, done: recorded == 1 and is_nil(next)}}
        end
    end
  end

  defp index_page(position) do
    {from, after_seq, initial_cluster} =
      case position do
        %{"group_id" => group_id, "conversation_id" => conversation_id, "after_seq" => seq} = pos
        when is_integer(seq) ->
          cluster = if is_map(pos["cluster"]), do: pos["cluster"], else: nil
          {{group_id, conversation_id}, seq, cluster}

        nil ->
          {nil, 0, nil}
      end

    {page, following} = from |> tasks_from(@backfill_tasks + 1) |> Enum.split(@backfill_tasks)

    {after_seq, initial_cluster} =
      case page do
        [{group_id, conversation_id, _tail} | _] when {group_id, conversation_id} == from ->
          {after_seq, initial_cluster}

        _other ->
          {0, nil}
      end

    backfill_tasks(page, following, after_seq, initial_cluster, {0, 0})
  end

  defp backfill_tasks([], [], _after_seq, _cluster, {processed, skipped}),
    do: {:ok, %{processed: processed, skipped: skipped, next: nil}}

  defp backfill_tasks(
         [],
         [{group_id, conversation_id, _tail} | _],
         _after_seq,
         _cluster,
         {processed, skipped}
       ),
       do:
         {:ok,
          %{
            processed: processed,
            skipped: skipped,
            next: position(group_id, conversation_id, 0, nil)
          }}

  defp backfill_tasks(
         [{group_id, conversation_id, tail} = task | rest],
         following,
         after_seq,
         cluster,
         {processed, skipped}
       ) do
    room = @backfill_messages - processed - skipped

    if room <= 0 do
      {:ok,
       %{
         processed: processed,
         skipped: skipped,
         next: position(group_id, conversation_id, after_seq, cluster)
       }}
    else
      scope = ConversationPGStore.new(group_id, conversation_id)
      last = min(tail, after_seq + min(room, @message_page))

      with {:ok, messages, lost} <- read_messages(scope, after_seq, last),
           {:ok, next_cluster} <- ConversationPGStore.index_task_feed(scope, messages, cluster) do
        counts = {processed + length(messages), skipped + lost}

        if last < tail,
          do: backfill_tasks([task | rest], following, last, next_cluster, counts),
          else: backfill_tasks(rest, following, 0, nil, counts)
      end
    end
  end

  defp read_messages(_scope, after_seq, last) when last <= after_seq, do: {:ok, [], 0}

  defp read_messages(scope, after_seq, last) do
    case ConversationPGStore.messages(scope, after_seq + 1, last, last - after_seq) do
      {:ok, messages} -> {:ok, messages, 0}
      {:error, :archive_incomplete} -> read_each(scope, after_seq + 1, last)
      {:error, _reason} = error -> error
    end
  end

  defp read_each(scope, first, last) do
    Enum.reduce_while(first..last//1, {:ok, [], 0}, fn seq, {:ok, messages, lost} ->
      case ConversationPGStore.messages(scope, seq, seq, 1) do
        {:ok, read} ->
          {:cont, {:ok, messages ++ read, lost}}

        {:error, :archive_incomplete} ->
          Logger.warning(
            "Task feed backfill skipped a Message whose archived body is gone " <>
              "(#{scope.group_id}/#{scope.conversation_id} seq #{seq})"
          )

          {:cont, {:ok, messages, lost + 1}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp position(group_id, conversation_id, after_seq, cluster) do
    base = %{
      "group_id" => group_id,
      "conversation_id" => conversation_id,
      "after_seq" => after_seq
    }

    if is_map(cluster), do: Map.put(base, "cluster", cluster), else: base
  end

  defp tasks_from(from, limit) do
    {condition, params} =
      case from do
        nil ->
          {"", [limit]}

        {group_id, conversation_id} ->
          {"AND (group_id, conversation_id) >= ($2, $3)", [limit, group_id, conversation_id]}
      end

    %{rows: rows} =
      Repo.query!(
        """
        SELECT group_id, conversation_id, message_tail_seq FROM salix_conversations
        WHERE kind = 'agent_task' AND deleted_at IS NULL #{condition}
        ORDER BY group_id, conversation_id
        LIMIT $1
        """,
        params
      )

    Enum.map(rows, fn [group_id, conversation_id, tail] ->
      {group_id, conversation_id, tail || 0}
    end)
  end

  @doc "Reads one page of a Group's Task Feed and projects it to public JSON maps."
  @spec list_group(String.t(), keyword()) ::
          {:ok, map()} | {:error, :invalid | :unavailable}
  def list_group(group_id, opts \\ []) do
    with {:ok, %{entries: entries, has_more: has_more, next_cursor: next_cursor}} <-
           Store.list_group(group_id, opts) do
      {:ok,
       %{
         "entries" => Enum.map(entries, &public_entry/1),
         "has_more" => has_more,
         "next_cursor" => next_cursor
       }}
    end
  end

  @doc "Derives `loop_kind` from a Loop trigger map."
  @spec loop_kind(map() | nil) :: String.t() | nil
  def loop_kind(%{"every_minutes" => _}), do: "every_minutes"
  def loop_kind(%{"cron" => _}), do: "cron"
  def loop_kind(%{"events" => _}), do: "events"
  def loop_kind(_trigger), do: nil

  @doc "Cleans markdown noise from Agent text and truncates to <= 240 graphemes."
  @spec clean_outcome_text(String.t() | nil) :: String.t() | nil
  def clean_outcome_text(nil), do: nil

  def clean_outcome_text(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/```[^\n]*\n?/u, " ")
      |> String.replace("```", " ")
      |> String.replace(~r/!\[([^\]]*)\]\([^)]+\)/u, "\\1")
      |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/u, "\\1")
      |> String.replace(~r/^\s{0,3}\#{1,6}\s+/um, "")
      |> String.replace(~r/^\s*>\s?/um, "")
      |> String.replace(~r/^\s*[-*+]\s+/um, "")
      |> String.replace(~r/[`*_~]+/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if cleaned == "" do
      nil
    else
      truncate_graphemes(cleaned, @max_outcome_text)
    end
  end

  def clean_outcome_text(_other), do: nil

  @doc "Projects a store entry map into the locked public JSON shape."
  @spec public_entry(map()) :: map()
  def public_entry(entry) when is_map(entry) do
    %{
      "id" => entry.id,
      "conversation_id" => entry.conversation_id,
      "group_id" => entry.group_id,
      "cluster_key" => entry.cluster_key,
      "trigger_kind" => entry.trigger_kind,
      "trigger_text" => entry.trigger_text,
      "task_title" => entry.task_title,
      "task_status" => entry.task_status,
      "task_updated_at" => entry.task_updated_at,
      "review_version" => entry.review_version,
      "origin" => entry.origin,
      "is_loop" => entry.is_loop,
      "loop_kind" => entry.loop_kind,
      "occurred_at" => entry.occurred_at,
      "milestones" => Enum.map(entry.milestones, &public_milestone/1),
      "milestone_count" => entry.milestone_count,
      "outcome_message_id" => entry.outcome_message_id,
      "outcome_text" => entry.outcome_text,
      "media" => entry.media,
      "files" => entry.files,
      "pull_request" => entry.pull_request
    }
  end

  defp public_milestone(milestone) when is_map(milestone) do
    %{
      "title" => milestone["title"],
      "at" => milestone["at"],
      "message_id" => milestone["message_id"]
    }
  end

  defp sync_message!(scope, record, message) do
    if visible_agent_message?(message) do
      only_milestones? = ConversationMilestone.only_milestones?(message["content"])
      cluster = current_cluster(record)
      fallback_message_id = get_in(cluster, ["last_outcome", "message_id"])
      milestones = extract_milestones(message, only_milestones?, fallback_message_id)
      outcome = if only_milestones?, do: empty_outcome(), else: extract_outcome(message)
      seq = message["seq"] || 0

      cond do
        milestones != [] ->
          Store.upsert_entry!(
            entry_attrs(scope, record, cluster, %{
              occurred_at: created_at(message),
              milestones: milestones,
              has_outcome: outcome.has_outcome?,
              outcome_message_id: outcome.message_id,
              outcome_text: outcome.text,
              media: outcome.media,
              files: outcome.files
            })
          )

        outcome.has_outcome? and seq > 1 ->
          Store.upsert_entry!(
            entry_attrs(scope, record, cluster, %{
              occurred_at: created_at(message),
              milestones: [],
              has_outcome: true,
              outcome_message_id: outcome.message_id,
              outcome_text: outcome.text,
              media: outcome.media,
              files: outcome.files
            })
          )

        true ->
          :ok
      end
    end

    :ok
  end

  defp sync_metadata_change!(scope, previous, record) do
    if metadata_changed?(previous, record) do
      Store.sync_conversation!(scope.group_id, scope.conversation_id, conversation_attrs(record))
    end

    if record["status"] in @outcome_materializing_statuses and
         previous["status"] != record["status"] and
         is_nil(record["deleted_at"]) do
      maybe_materialize_status_entry!(scope, record)
    end

    :ok
  end

  defp maybe_materialize_status_entry!(scope, record) do
    cluster = current_cluster(record)
    cluster_key = cluster["cluster_key"]

    if not Store.exists?(scope.group_id, scope.conversation_id, cluster_key) do
      case cluster["last_outcome"] do
        %{"message_id" => msg_id} = last_outcome when is_binary(msg_id) ->
          Store.upsert_entry!(
            entry_attrs(scope, record, cluster, %{
              occurred_at: max(last_outcome["at"] || 0, record["updated_at"] || 0),
              milestones: [],
              has_outcome: true,
              outcome_message_id: msg_id,
              outcome_text: last_outcome["text"],
              media: List.wrap(last_outcome["media"]),
              files: List.wrap(last_outcome["files"])
            })
          )

        _none ->
          :ok
      end
    end
  end

  defp entry_attrs(scope, record, cluster, extra) do
    record
    |> conversation_attrs()
    |> Map.merge(%{
      group_id: scope.group_id,
      conversation_id: scope.conversation_id,
      cluster_key: cluster["cluster_key"],
      trigger_kind: cluster["trigger_kind"],
      trigger_text: cluster["trigger_text"],
      is_loop: cluster["is_loop"] == true
    })
    |> Map.merge(extra)
  end

  defp conversation_attrs(record) do
    status = record["status"] || "unknown"
    updated_at = record["updated_at"] || 0

    %{
      task_title: task_title(record),
      task_status: status,
      task_updated_at: updated_at,
      review_version: review_version(record, status, updated_at),
      origin: task_origin(record),
      archived: status == "archived",
      deleted_at: datetime(record["deleted_at"])
    }
  end

  defp metadata_changed?(previous, record) do
    previous["title"] != record["title"] or
      previous["status"] != record["status"] or
      previous["updated_at"] != record["updated_at"] or
      previous["deleted_at"] != record["deleted_at"] or
      task_origin(previous) != task_origin(record)
  end

  defp current_cluster(%{"_task_feed_cluster" => %{"cluster_key" => key} = cluster})
       when is_binary(key) and key != "" do
    cluster
  end

  defp current_cluster(_record) do
    %{
      "cluster_key" => "brief",
      "trigger_kind" => "brief",
      "trigger_text" => nil,
      "is_loop" => false
    }
  end

  defp loop_wake?(%{"actor_type" => "system", "agent_input" => %{"trusted_origin" => origin}})
       when is_map(origin) do
    origin["provider"] == "loop"
  end

  defp loop_wake?(_message), do: false

  defp follow_up_trigger?(message) do
    cond do
      get_in(message, ["metadata", "task_request"]) == true ->
        true

      message["actor_type"] in ["user", "provider_user"] and
        not ConversationMessage.internal_delivery?(message) and
        get_in(message, ["metadata", "message_type"]) != "task_command" and
          (message["seq"] || 0) > 1 ->
        true

      true ->
        false
    end
  end

  defp visible_agent_message?(%{"actor_type" => "agent"} = message) do
    is_list(message["content"]) and
      message["kind"] in [nil, "message"] and
      not ConversationMessage.internal_delivery?(message) and
      get_in(message, ["metadata", "message_type"]) != "task_command" and
      get_in(message, ["metadata", "task_request"]) != true
  end

  defp visible_agent_message?(_message), do: false

  defp extract_milestones(message, only_milestones?, fallback_message_id) do
    at = created_at(message)
    message_id = if only_milestones?, do: fallback_message_id, else: message["message_id"]
    seq = message["seq"]

    message["content"]
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "milestone", "title" => title} when is_binary(title) ->
        case String.trim(title) do
          "" ->
            []

          trimmed ->
            base = %{"title" => trimmed, "at" => at, "message_id" => message_id, "seq" => seq}

            if only_milestones? do
              [Map.put(base, "pending_reveal", true)]
            else
              [base]
            end
        end

      _other ->
        []
    end)
  end

  defp extract_outcome(message) do
    content = List.wrap(message["content"])
    text = content |> ConversationMessage.text_content() |> clean_outcome_text()
    media = extract_media(content, message["message_id"])
    files = extract_files(content)

    %{
      has_outcome?: not is_nil(text) or media != [] or files != [],
      message_id: message["message_id"],
      text: text,
      media: media,
      files: files
    }
  end

  defp empty_outcome, do: %{has_outcome?: false, message_id: nil, text: nil, media: [], files: []}

  defp extract_media(content, message_id) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"type" => "image"} = block, index} ->
        attachment_id =
          nonempty_string(block["attachment_id"]) ||
            nonempty_string(get_in(block, ["blob_ref", "uuid"])) ||
            "#{message_id}:#{index}"

        [
          %{
            "attachment_id" => attachment_id,
            "mime_type" => nonempty_string(block["mime_type"]) || "image/*",
            "width" => positive_int(block["width"]),
            "height" => positive_int(block["height"]),
            "filename" => nonempty_string(ConversationAttachments.file_name(block))
          }
        ]

      _other ->
        []
    end)
    |> Enum.take(@max_media)
  end

  defp extract_files(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "file"} = block ->
        name = nonempty_string(ConversationAttachments.file_name(block))

        if name do
          [%{"name" => name, "mime_type" => nonempty_string(block["mime_type"])}]
        else
          []
        end

      _other ->
        []
    end)
    |> Enum.take(@max_files)
  end

  defp extract_trigger_text(message) do
    text = ConversationMessage.text_content(message["content"])

    first_line =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.find(&(&1 != ""))

    case first_line do
      nil -> nil
      line -> truncate_graphemes(line, @max_trigger_text)
    end
  end

  defp task_title(%{"title" => title}) when is_binary(title), do: title
  defp task_title(_record), do: ""

  defp review_version(record, "ready_for_review", updated_at)
       when is_integer(updated_at) and updated_at > 0 do
    case get_in(record, ["schedule", "schedule_id"]) do
      id when is_binary(id) -> if String.trim(id) == "", do: updated_at, else: nil
      _none -> updated_at
    end
  end

  defp review_version(_record, _status, _updated_at), do: nil

  defp task_origin(record) do
    case get_in(record, ["metadata", "origin", "provider"]) do
      provider when is_binary(provider) -> nonempty_string(provider)
      _none -> nil
    end
  end

  defp created_at(%{"created_at" => at}) when is_integer(at) and at >= 0, do: at
  defp created_at(_message), do: 0

  defp datetime(nil), do: nil

  defp datetime(ms) when is_integer(ms),
    do: DateTime.from_unix!(ms, :millisecond)

  defp datetime(%DateTime{} = dt), do: dt
  defp datetime(_other), do: nil

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_n), do: nil

  defp nonempty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonempty_string(_value), do: nil

  defp truncate_graphemes(text, max) do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max - 1) <> "…"
    end
  end
end
