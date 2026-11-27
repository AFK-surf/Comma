defmodule SalixStore.TaskFeed do
  @moduledoc """
  Postgres access for the read-only Task Feed projection (`salix_task_feed_entries`).

  Each row represents one progression cluster (brief, follow-up, or Loop run) of
  an `agent_task` Conversation. It is a projection of canonical `Conversation`
  and `Message` facts, never a second lifecycle authority.

  Writes (`upsert_entry!/2`, `sync_conversation!/3`, `delete_conversation!/2`)
  run on the caller's connection inside the Conversation's source transaction
  (`SalixIM.ConversationPGStore`). Reads (`list_group/2`) use indexed keyset
  pagination bounded by statement timeout and page size.
  """

  alias SalixStore.Repo

  @marker "task_feed_v1"
  @default_limit 25
  @max_limit 50
  @max_milestones 20
  @statement_timeout_ms 500
  @database_timeout_ms 1_000

  @columns """
  e.id, e.conversation_id, e.group_id, e.cluster_key, e.trigger_kind, e.trigger_text,
  e.task_title, e.task_status, e.task_updated_at, e.review_version, e.origin,
  e.is_loop, e.loop_kind, e.occurred_at, e.milestones, e.milestone_count,
  e.outcome_message_id, e.outcome_text, e.media, e.files, e.pull_request
  """

  @attention_statuses ~w(ready_for_review escalated failed)

  @doc "The marker the backfill completes."
  def marker, do: @marker

  @doc "True once the backfill has projected every Task an earlier release created."
  @spec ready?() :: boolean()
  def ready? do
    case Repo.query(
           "SELECT 1 FROM salix_cutover_markers WHERE name = $1 AND evidence->>'phase' = 'complete'",
           [@marker]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      _other -> false
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  @doc "Default page size for feed reads."
  def default_limit, do: @default_limit

  @doc "Maximum page size for feed reads."
  def max_limit, do: @max_limit

  @doc "Deterministic stable entry ID for a `(group_id, conversation_id, cluster_key)` cluster."
  @spec entry_id(String.t(), String.t(), String.t()) :: String.t()
  def entry_id(group_id, conversation_id, cluster_key)
      when is_binary(group_id) and is_binary(conversation_id) and is_binary(cluster_key) do
    digest =
      :crypto.hash(:sha256, [group_id, 0, conversation_id, 0, cluster_key])
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 24)

    "tfe_" <> digest
  end

  @doc "Returns true if a feed entry already exists for this cluster."
  @spec exists?(String.t(), String.t(), String.t()) :: boolean()
  def exists?(group_id, conversation_id, cluster_key) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT 1 FROM salix_task_feed_entries
        WHERE group_id = $1 AND conversation_id = $2 AND cluster_key = $3
        LIMIT 1
        """,
        [group_id, conversation_id, cluster_key]
      )

    rows != []
  end

  @doc """
  Upserts a Task Feed cluster entry in-place.

  Milestones are merged and deduplicated by `(seq, title)`, keeping up to
  #{@max_milestones} latest milestones while tracking the full deduplicated
  `milestone_count`. Outcome fields (`outcome_message_id`, `outcome_text`,
  `media`, `files`) are updated when supplied by the incoming write and
  preserved otherwise (so standalone milestones retain any prior or later
  outcome cleanly).
  """
  @spec upsert_entry!(map()) :: :ok
  def upsert_entry!(attrs) when is_map(attrs) do
    group_id = Map.fetch!(attrs, :group_id)
    conversation_id = Map.fetch!(attrs, :conversation_id)
    cluster_key = Map.fetch!(attrs, :cluster_key)
    id = Map.get(attrs, :id) || entry_id(group_id, conversation_id, cluster_key)

    existing =
      case Repo.query!(
             """
             SELECT id, milestones, milestone_count, occurred_at,
                    outcome_message_id, outcome_text, media, files,
                    is_loop, loop_kind, pull_request
             FROM salix_task_feed_entries
             WHERE group_id = $1 AND conversation_id = $2 AND cluster_key = $3
             FOR UPDATE
             """,
             [group_id, conversation_id, cluster_key]
           ) do
        %{rows: [row]} -> row
        %{rows: []} -> nil
      end

    incoming_milestones = List.wrap(Map.get(attrs, :milestones, []))
    incoming_occurred_at = Map.fetch!(attrs, :occurred_at)
    has_outcome? = Map.get(attrs, :has_outcome, false)

    {final_id, merged_milestones, merged_count, final_occurred_at, outcome_message_id,
     outcome_text, media, files, is_loop, loop_kind, pull_request} =
      case existing do
        nil ->
          deduped = dedupe_milestones(incoming_milestones)
          outcome_msg_id = Map.get(attrs, :outcome_message_id)

          final_milestones =
            deduped
            |> Enum.take(-@max_milestones)
            |> maybe_reveal_milestones(has_outcome?, outcome_msg_id)

          {
            id,
            final_milestones,
            length(deduped),
            incoming_occurred_at,
            outcome_msg_id,
            Map.get(attrs, :outcome_text),
            List.wrap(Map.get(attrs, :media, [])),
            List.wrap(Map.get(attrs, :files, [])),
            Map.get(attrs, :is_loop, false) == true,
            Map.get(attrs, :loop_kind),
            Map.get(attrs, :pull_request)
          }

        [
          existing_id,
          existing_milestones,
          existing_count,
          existing_occurred_at,
          existing_outcome_msg_id,
          existing_outcome_text,
          existing_media,
          existing_files,
          existing_is_loop,
          existing_loop_kind,
          existing_pr
        ] ->
          {next_milestones, next_count} =
            merge_milestones(
              List.wrap(existing_milestones),
              existing_count || 0,
              incoming_milestones
            )

          next_outcome_msg_id =
            if has_outcome?,
              do: Map.get(attrs, :outcome_message_id),
              else: existing_outcome_msg_id

          next_milestones =
            maybe_reveal_milestones(next_milestones, has_outcome?, next_outcome_msg_id)

          next_outcome_text =
            if has_outcome?, do: Map.get(attrs, :outcome_text), else: existing_outcome_text

          next_media =
            if has_outcome?,
              do: List.wrap(Map.get(attrs, :media, [])),
              else: List.wrap(existing_media)

          next_files =
            if has_outcome?,
              do: List.wrap(Map.get(attrs, :files, [])),
              else: List.wrap(existing_files)

          {
            existing_id,
            next_milestones,
            next_count,
            max(existing_occurred_at || 0, incoming_occurred_at),
            next_outcome_msg_id,
            next_outcome_text,
            next_media,
            next_files,
            existing_is_loop == true or Map.get(attrs, :is_loop, false) == true,
            Map.get(attrs, :loop_kind) || existing_loop_kind,
            Map.get(attrs, :pull_request) || existing_pr
          }
      end

    Repo.query!(
      """
      INSERT INTO salix_task_feed_entries (
        id, group_id, conversation_id, cluster_key, trigger_kind, trigger_text,
        task_title, task_status, task_updated_at, review_version, origin,
        is_loop, loop_kind, occurred_at, milestones, milestone_count,
        outcome_message_id, outcome_text, media, files, pull_request,
        archived, deleted_at
      )
      VALUES (
        $1, $2, $3, $4, $5, $6,
        $7, $8, $9, $10, $11,
        $12, $13, $14, $15, $16,
        $17, $18, $19, $20, $21,
        $22, $23
      )
      ON CONFLICT (group_id, conversation_id, cluster_key) DO UPDATE SET
        trigger_kind = EXCLUDED.trigger_kind,
        trigger_text = COALESCE(EXCLUDED.trigger_text, salix_task_feed_entries.trigger_text),
        task_title = EXCLUDED.task_title,
        task_status = EXCLUDED.task_status,
        task_updated_at = EXCLUDED.task_updated_at,
        review_version = EXCLUDED.review_version,
        origin = COALESCE(EXCLUDED.origin, salix_task_feed_entries.origin),
        is_loop = EXCLUDED.is_loop,
        loop_kind = EXCLUDED.loop_kind,
        occurred_at = EXCLUDED.occurred_at,
        milestones = EXCLUDED.milestones,
        milestone_count = EXCLUDED.milestone_count,
        outcome_message_id = EXCLUDED.outcome_message_id,
        outcome_text = EXCLUDED.outcome_text,
        media = EXCLUDED.media,
        files = EXCLUDED.files,
        pull_request = EXCLUDED.pull_request,
        archived = EXCLUDED.archived,
        deleted_at = EXCLUDED.deleted_at
      """,
      [
        final_id,
        group_id,
        conversation_id,
        cluster_key,
        Map.fetch!(attrs, :trigger_kind),
        Map.get(attrs, :trigger_text),
        Map.get(attrs, :task_title, ""),
        Map.get(attrs, :task_status, "active"),
        Map.get(attrs, :task_updated_at, 0),
        Map.get(attrs, :review_version),
        Map.get(attrs, :origin),
        is_loop,
        loop_kind,
        final_occurred_at,
        merged_milestones,
        merged_count,
        outcome_message_id,
        outcome_text,
        media,
        files,
        pull_request,
        Map.get(attrs, :archived, false) == true,
        Map.get(attrs, :deleted_at)
      ]
    )

    :ok
  end

  @doc """
  Synchronizes Conversation metadata (title, status, updated_at, review_version,
  origin, archived, deleted_at) across all feed entries of one Task using the
  `(group_id, conversation_id)` index.
  """
  @spec sync_conversation!(String.t(), String.t(), map()) :: :ok
  def sync_conversation!(group_id, conversation_id, attrs) when is_map(attrs) do
    Repo.query!(
      """
      UPDATE salix_task_feed_entries
      SET task_title = $3,
          task_status = $4,
          task_updated_at = $5,
          review_version = $6,
          origin = COALESCE($7, origin),
          archived = $8,
          deleted_at = $9
      WHERE group_id = $1 AND conversation_id = $2
      """,
      [
        group_id,
        conversation_id,
        Map.get(attrs, :task_title, ""),
        Map.get(attrs, :task_status, "active"),
        Map.get(attrs, :task_updated_at, 0),
        Map.get(attrs, :review_version),
        Map.get(attrs, :origin),
        Map.get(attrs, :archived, false) == true,
        Map.get(attrs, :deleted_at)
      ]
    )

    :ok
  end

  @doc """
  Synchronizes Loop metadata (`is_loop`, `loop_kind`) for a Task's existing
  feed entries.
  """
  @spec sync_loop!(String.t(), String.t(), String.t() | nil) :: :ok
  def sync_loop!(group_id, conversation_id, loop_kind)
      when is_binary(group_id) and is_binary(conversation_id) do
    Repo.query!(
      """
      UPDATE salix_task_feed_entries
      SET is_loop = true,
          loop_kind = COALESCE($3, loop_kind)
      WHERE group_id = $1 AND conversation_id = $2
      """,
      [group_id, conversation_id, loop_kind]
    )

    :ok
  end

  @doc "Removes all feed entries of one Task on final deletion."
  @spec delete_conversation!(String.t(), String.t()) :: :ok
  def delete_conversation!(group_id, conversation_id) do
    Repo.query!(
      "DELETE FROM salix_task_feed_entries WHERE group_id = $1 AND conversation_id = $2",
      [group_id, conversation_id]
    )

    :ok
  end

  @doc """
  Reads one keyset-paginated page of a Group's Task Feed, newest first.
  Lists only the newest visible cluster of each Task; older clusters stay stored.

  Options:
  - `:limit` — integer in `1..#{@max_limit}` (default #{@default_limit})
  - `:cursor` — opaque base64url keyset cursor
  - `:attention` — boolean; when true, returns only entries whose `task_status`
    requires attention (`ready_for_review`, `escalated`, `failed`) or whose
    bound Loop is in `failed` status.
  - `:conversation_id` — optional Conversation ID for restricted single-Task sessions.
  """
  @spec list_group(String.t(), keyword()) ::
          {:ok, %{entries: [map()], has_more: boolean(), next_cursor: String.t() | nil}}
          | {:error, :invalid | :unavailable}
  def list_group(group_id, opts \\ []) when is_binary(group_id) and is_list(opts) do
    with {:ok, limit} <- parse_limit(Keyword.get(opts, :limit, @default_limit)),
         {:ok, after_key} <- decode_cursor(Keyword.get(opts, :cursor)) do
      attention? = Keyword.get(opts, :attention, false) == true
      conversation_id = Keyword.get(opts, :conversation_id)

      {conditions, params} =
        build_conditions(group_id, limit + 1, after_key, attention?, conversation_id)

      # One card per Task: an entry is listed only while no newer visible cluster of
      # its conversation exists. The scan walks `group_feed_idx` in feed order and
      # stops at the page limit; each probe uses `conversation_idx`.
      sql = """
      SELECT #{@columns}
      FROM salix_task_feed_entries e
      WHERE #{Enum.join(conditions, " AND ")}
        AND NOT EXISTS (
          SELECT 1 FROM salix_task_feed_entries n
          WHERE n.group_id = e.group_id
            AND n.conversation_id = e.conversation_id
            AND n.archived = false
            AND n.deleted_at IS NULL
            AND (n.occurred_at, n.id) > (e.occurred_at, e.id)
        )
      ORDER BY e.occurred_at DESC, e.id DESC
      LIMIT $2
      """

      read(sql, params, limit)
    end
  end

  @doc "Encodes a keyset cursor from `{occurred_at, id}`."
  @spec encode_cursor(integer(), String.t()) :: String.t()
  def encode_cursor(occurred_at, id) when is_integer(occurred_at) and is_binary(id) do
    [occurred_at, id] |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  @doc "Decodes a keyset cursor into `[occurred_at, id]`."
  @spec decode_cursor(String.t() | nil) :: {:ok, [term()] | nil} | {:error, :invalid}
  def decode_cursor(nil), do: {:ok, nil}
  def decode_cursor(""), do: {:ok, nil}

  def decode_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 1_024 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [occurred_at, id]} <- Jason.decode(json),
         true <- is_integer(occurred_at) and occurred_at >= 0 and is_binary(id) and id != "" do
      {:ok, [occurred_at, id]}
    else
      _invalid -> {:error, :invalid}
    end
  end

  def decode_cursor(_cursor), do: {:error, :invalid}

  defp build_conditions(group_id, fetch_limit, after_key, attention?, conversation_id) do
    conditions = [
      "e.group_id = $1",
      "e.archived = false",
      "e.deleted_at IS NULL"
    ]

    params = [group_id, fetch_limit]

    {conditions, params} =
      if attention? do
        idx = length(params) + 1

        cond_sql =
          "(e.task_status = ANY($#{idx}::text[]) OR (e.is_loop = true AND EXISTS (SELECT 1 FROM agent_loops l WHERE l.group_id = e.group_id AND l.task_conversation_id = e.conversation_id AND l.status = 'failed')))"

        {conditions ++ [cond_sql], params ++ [@attention_statuses]}
      else
        {conditions, params}
      end

    {conditions, params} =
      if is_binary(conversation_id) and conversation_id != "" do
        idx = length(params) + 1
        {conditions ++ ["e.conversation_id = $#{idx}"], params ++ [conversation_id]}
      else
        {conditions, params}
      end

    case after_key do
      nil ->
        {conditions, params}

      [occurred_at, id] ->
        idx1 = length(params) + 1
        idx2 = idx1 + 1

        {conditions ++ ["(e.occurred_at, e.id) < ($#{idx1}, $#{idx2})"],
         params ++ [occurred_at, id]}
    end
  end

  defp read(sql, params, limit) do
    Repo.transaction(
      fn ->
        with {:ok, _timeout} <-
               Repo.query("SELECT set_config('statement_timeout', $1, true)", [
                 Integer.to_string(@statement_timeout_ms) <> "ms"
               ]),
             {:ok, %{rows: rows}} <- Repo.query(sql, params, timeout: @database_timeout_ms) do
          rows
        else
          _other -> Repo.rollback(:unavailable)
        end
      end,
      timeout: @database_timeout_ms
    )
    |> case do
      {:ok, rows} -> {:ok, paginate(Enum.map(rows, &decode_row/1), limit)}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp paginate(entries, limit) do
    {shown, rest} = Enum.split(entries, limit)
    has_more = rest != []

    next_cursor =
      case {has_more, List.last(shown)} do
        {true, %{occurred_at: occurred_at, id: id}} -> encode_cursor(occurred_at, id)
        _done -> nil
      end

    %{entries: shown, has_more: has_more, next_cursor: next_cursor}
  end

  defp decode_row([
         id,
         conversation_id,
         group_id,
         cluster_key,
         trigger_kind,
         trigger_text,
         task_title,
         task_status,
         task_updated_at,
         review_version,
         origin,
         is_loop,
         loop_kind,
         occurred_at,
         milestones,
         milestone_count,
         outcome_message_id,
         outcome_text,
         media,
         files,
         pull_request
       ]) do
    %{
      id: id,
      conversation_id: conversation_id,
      group_id: group_id,
      cluster_key: cluster_key,
      trigger_kind: trigger_kind,
      trigger_text: trigger_text,
      task_title: task_title || "",
      task_status: task_status || "unknown",
      task_updated_at: task_updated_at || 0,
      review_version: review_version,
      origin: origin,
      is_loop: is_loop == true,
      loop_kind: loop_kind,
      occurred_at: occurred_at || 0,
      milestones: List.wrap(milestones),
      milestone_count: milestone_count || 0,
      outcome_message_id: outcome_message_id,
      outcome_text: outcome_text,
      media: List.wrap(media),
      files: List.wrap(files),
      pull_request: pull_request
    }
  end

  defp parse_limit(limit) when is_integer(limit) and limit >= 1 and limit <= @max_limit,
    do: {:ok, limit}

  defp parse_limit(_limit), do: {:error, :invalid}

  defp merge_milestones(existing, existing_count, []),
    do: {existing, max(existing_count, length(existing))}

  defp merge_milestones(existing, existing_count, incoming) do
    existing_keys = MapSet.new(existing, &milestone_key/1)

    min_kept_seq =
      if existing_count > length(existing) do
        existing
        |> Enum.map(&milestone_seq/1)
        |> Enum.filter(&is_integer/1)
        |> case do
          [] -> nil
          seqs -> Enum.min(seqs)
        end
      else
        nil
      end

    {added, _seen} =
      Enum.reduce(incoming, {[], existing_keys}, fn item, {acc, seen} ->
        key = milestone_key(item)
        seq = milestone_seq(item)

        cond do
          is_integer(min_kept_seq) and is_integer(seq) and seq < min_kept_seq ->
            {acc, seen}

          MapSet.member?(seen, key) ->
            {acc, seen}

          true ->
            {[item | acc], MapSet.put(seen, key)}
        end
      end)

    added = Enum.reverse(added)
    combined = Enum.take(existing ++ added, -@max_milestones)
    next_count = max(existing_count, length(existing)) + length(added)
    {combined, next_count}
  end

  defp milestone_seq(item) when is_map(item), do: item["seq"] || item[:seq]
  defp milestone_seq(_item), do: nil

  defp dedupe_milestones(items) do
    items
    |> Enum.reduce({[], MapSet.new()}, fn item, {acc, seen} ->
      key = milestone_key(item)
      if MapSet.member?(seen, key), do: {acc, seen}, else: {[item | acc], MapSet.put(seen, key)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp maybe_reveal_milestones(milestones, true, outcome_message_id)
       when is_binary(outcome_message_id) and outcome_message_id != "" do
    Enum.map(milestones, fn
      %{"pending_reveal" => true} = item ->
        item
        |> Map.put("message_id", outcome_message_id)
        |> Map.delete("pending_reveal")

      item ->
        item
    end)
  end

  defp maybe_reveal_milestones(milestones, _has_outcome?, _outcome_message_id), do: milestones

  defp milestone_key(item) when is_map(item) do
    {item["seq"] || item[:seq], item["title"] || item[:title]}
  end
end
