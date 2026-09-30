defmodule Comma.TaskShares do
  @moduledoc """
  Public read-only links to one Comma Task.

  A Task Share is Comma product authorization, not a Task fact: it names one
  `agent_task` Conversation and a Message cutoff (`through_seq`). The canonical
  Salix log stays the only history. A public read resolves the link, re-checks
  that its creator still owns the ready Workspace, and reads canonical Messages
  up to the cutoff through an allowlist projection. Later Messages stay private
  until the owner moves the cutoff.

  Artifacts are the downloadable `file` and `image` blocks of Agent Messages at
  or before the cutoff. The `snapshot` manifest is a disposable projection that
  publish rebuilds; downloads re-read the canonical Message instead of trusting
  it. See `docs/architecture/DOMAIN_CONCEPTS.md` (Task Share).
  """

  import Ecto.Query

  alias Comma.{ConversationAttachments, Conversations, Repo, Workspaces}
  alias Comma.Data.TaskShare

  @token_bytes 32
  @token_pattern ~r/\A[A-Za-z0-9_-]{43}\z/
  @scan_page 1_000
  @scan_message_limit 5_000
  @artifact_limit 500
  @public_page_default 50
  @public_page_max 100
  # One owner page resolves at most 50 Task summaries, one Task read each.
  @owner_page_max 50
  @artifact_types ["file", "image"]
  @context_marker "[[comma-context]]"
  @protocol_marker "[[comma-protocol]]"
  @fence_open "```comma:"
  @fence_close "```"
  @attached_files_header "Attached files in your workspace:\n"
  # Composer mentions (`[title](comma:task/<id>)`) and bare references name
  # another Task. Neither its title nor its ID is part of this share.
  @task_mention_source "\\[[^\\]\\n]*\\]\\(\\s*comma:(?:task|conversation)\\/[^)\\s]*\\s*\\)|comma:(?:task|conversation)\\/[A-Za-z0-9._-]+"
  @task_mention Regex.compile!(@task_mention_source, "u")
  @task_mention_only Regex.compile!("\\A(?:" <> @task_mention_source <> ")\\z", "u")

  ## Owner operations

  @doc "The active share of a Task, or `{:error, :not_found}`."
  def get(user, session, group_id, conversation_id) do
    with {:ok, _workspace, conversation} <-
           authorize_task(user, session, group_id, conversation_id),
         %TaskShare{} = share <- active_share(conversation_id) do
      {:ok, owner_view(share, conversation)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  One page of a Group's active shares, most recently shared first.

  The query reads the share rows of one Workspace through its index, and the
  page resolves at most 50 Task summaries, one Task read each. A share whose
  Task no longer resolves leaves the page, as its public link reads `404`. The
  cursor is the last listed share's `shared_at` and row ID.
  """
  def list(user, session, group_id, opts \\ []) do
    with false <- session["restricted"] == true,
         {:ok, limit} <- owner_page_limit(Keyword.get(opts, :limit)),
         {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {page, rest} =
           Enum.split(active_shares(workspace["id"], group_id, cursor, limit + 1), limit),
         {:ok, conversations} <- share_conversations(user, session, group_id, page) do
      {:ok,
       %{
         "data" =>
           for(
             share <- page,
             conversation <- List.wrap(conversations[share.conversation_id]),
             do: owner_list_view(share, conversation)
           ),
         "has_more" => rest != [],
         "next_cursor" => if(rest != [], do: encode_cursor(List.last(page)))
       }}
    else
      true -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Creates the Task's share, or moves an existing share's cutoff to the current
  Message tail. The token of an existing share does not change.
  """
  def publish(user, session, group_id, conversation_id) do
    with {:ok, workspace, conversation} <-
           authorize_task(user, session, group_id, conversation_id),
         through_seq = tail_seq(conversation),
         {:ok, snapshot} <- build_snapshot(workspace, conversation_id, through_seq) do
      case upsert_share(workspace, user, conversation_id, %{
             through_seq: through_seq,
             snapshot: snapshot
           }) do
        {:ok, share} -> {:ok, owner_view(share, conversation)}
        {:error, _reason} -> {:error, :task_share_unavailable}
      end
    end
  end

  # A concurrent first publish loses the active-share constraint race; it then
  # moves the winner's cutoff instead of failing.
  defp upsert_share(workspace, user, conversation_id, attrs, attempts \\ 2) do
    case active_share(conversation_id) do
      %TaskShare{} = share ->
        share |> Ecto.Changeset.change(attrs) |> Repo.update()

      nil ->
        case insert_share(workspace, user, conversation_id, attrs) do
          {:error, %Ecto.Changeset{}} when attempts > 1 ->
            upsert_share(workspace, user, conversation_id, attrs, attempts - 1)

          result ->
            result
        end
    end
  end

  @doc "Revokes the current link and issues a new one for the same cutoff."
  def reset(user, session, group_id, conversation_id) do
    with {:ok, workspace, conversation} <-
           authorize_task(user, session, group_id, conversation_id) do
      Repo.transaction(fn ->
        case active_share(conversation_id, lock: true) do
          nil ->
            Repo.rollback(:not_found)

          share ->
            {:ok, _revoked} = share |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update()

            case insert_share(workspace, user, conversation_id, %{
                   through_seq: share.through_seq,
                   snapshot: share.snapshot
                 }) do
              {:ok, replacement} -> owner_view(replacement, conversation)
              {:error, _reason} -> Repo.rollback(:task_share_unavailable)
            end
        end
      end)
    end
  end

  @doc "Revokes the Task's share. Revoking an unshared Task succeeds."
  def revoke(user, session, group_id, conversation_id) do
    with {:ok, _workspace, _conversation} <-
           authorize_task(user, session, group_id, conversation_id) do
      from(share in TaskShare,
        where: share.conversation_id == ^conversation_id and is_nil(share.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: now(), updated_at: now()])

      :ok
    end
  end

  @doc "The subset of `conversation_ids` in `group_id` that have an active share."
  def shared_conversation_ids(group_id, conversation_ids)
      when is_binary(group_id) and is_list(conversation_ids) do
    ids = Enum.filter(conversation_ids, &is_binary/1)

    if ids == [] do
      MapSet.new()
    else
      from(share in TaskShare,
        where:
          share.group_id == ^group_id and share.conversation_id in ^ids and
            is_nil(share.revoked_at),
        select: share.conversation_id
      )
      |> Repo.all()
      |> MapSet.new()
    end
  end

  def shared_conversation_ids(_group_id, _conversation_ids), do: MapSet.new()

  ## Public reads

  @doc "Title, share time, and artifact manifest of a public link."
  def public_summary(token) do
    with {:ok, share, _workspace, conversation} <- resolve(token) do
      snapshot = share.snapshot || %{}

      {:ok,
       %{
         "title" => public_title(conversation),
         "shared_at" => unix_time(share.updated_at),
         "message_count" => snapshot["message_count"] || 0,
         "artifacts" => snapshot["artifacts"] || [],
         "artifacts_truncated" => snapshot["artifacts_truncated"] == true
       }}
    end
  end

  @doc """
  One forward page of public Messages after `after_seq`, bounded by the
  cutoff. `next_after_seq` is `nil` on the last page.
  """
  def public_messages(token, after_seq, limit) do
    with {:ok, share, workspace, _conversation} <- resolve(token),
         {:ok, after_seq} <- non_negative(after_seq, 0),
         {:ok, limit} <- page_limit(limit) do
      read_limit = min(limit, share.through_seq - after_seq)

      if read_limit <= 0 do
        {:ok, %{"messages" => [], "next_after_seq" => nil}}
      else
        with {:ok, raw} <-
               read_messages(workspace, share.conversation_id, after_seq, read_limit) do
          raw = Enum.filter(raw, &(is_integer(&1["seq"]) and &1["seq"] <= share.through_seq))
          last_seq = raw |> List.last() |> then(&(&1 && &1["seq"]))

          {:ok,
           %{
             "messages" => Enum.flat_map(raw, &public_message/1),
             "next_after_seq" =>
               if(is_integer(last_seq) and last_seq < share.through_seq, do: last_seq)
           }}
        end
      end
    end
  end

  @doc "Bytes of one shared artifact, addressed by Message sequence and block index."
  def public_attachment(token, seq, index) do
    with {:ok, share, workspace, _conversation} <- resolve(token),
         {:ok, seq} <- positive(seq),
         {:ok, index} <- ConversationAttachments.parse_index(to_string(index)),
         true <- seq <= share.through_seq,
         {:ok, [message | _]} <- read_messages(workspace, share.conversation_id, seq - 1, 1),
         true <- message["seq"] == seq and artifact_message?(message),
         %{"type" => type} when type in @artifact_types <-
           Enum.at(List.wrap(message["content"]), index) do
      ConversationAttachments.fetch_message(workspace, message, index)
    else
      {:error, reason} when reason not in [:not_found] -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc "Whether a string has the shape of a share token. Grants nothing."
  def valid_token?(token) when is_binary(token), do: Regex.match?(@token_pattern, token)
  def valid_token?(_token), do: false

  ## Public projection

  @doc false
  def public_message(message) do
    if public_row?(message) do
      terminals = terminal_markers(message["actor_type"])

      {blocks, _state} =
        message["content"]
        |> content_blocks()
        |> Enum.with_index()
        |> Enum.flat_map_reduce(:visible, &project_block(&1, &2, message, terminals))

      if blocks == [] do
        []
      else
        [
          %{
            "seq" => message["seq"],
            "role" => if(message["actor_type"] == "agent", do: "assistant", else: "user"),
            "created_at" => message["created_at"],
            "content" => blocks
          }
        ]
      end
    else
      []
    end
  end

  defp public_row?(%{"actor_type" => actor_type} = message)
       when actor_type in ["user", "agent"] do
    message["kind"] in [nil, "message"] and
      not SalixIM.ConversationMessage.internal_delivery?(message) and
      not context_message?(message)
  end

  defp public_row?(_message), do: false

  # Clients read a Message's text as every block's `text`, joined by newlines.
  defp context_message?(message) do
    message["content"]
    |> content_blocks()
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("\n")
    |> String.trim_leading()
    |> String.starts_with?(@context_marker)
  end

  defp content_blocks(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp content_blocks(content) when is_list(content), do: content
  defp content_blocks(_content), do: []

  # A user's workspace upload list names private VFS paths, not shared artifacts.
  defp terminal_markers("user"), do: [@protocol_marker, @attached_files_header]
  defp terminal_markers(_actor_type), do: [@protocol_marker]

  # Private markers apply to the Message's whole text, not to one block: text
  # after a protocol marker, or inside a `comma:` fence that later blocks close,
  # stays private. Every block with text advances the scan in order, and
  # attachment blocks keep their original index.
  defp project_block({%{"type" => "text", "text" => text}, _index}, state, _message, terminals)
       when is_binary(text) do
    {visible, state} = scan(text, state, terminals)
    {text_blocks(visible), state}
  end

  defp project_block(
         {%{"type" => type} = block, index},
         state,
         %{"actor_type" => "agent"},
         terminals
       )
       when type in @artifact_types do
    projected =
      if ConversationAttachments.downloadable?(block) do
        [
          block
          |> ConversationAttachments.describe()
          |> Map.merge(%{"type" => type, "index" => index})
        ]
      else
        []
      end

    {projected, advance(block, state, terminals)}
  end

  # Widgets are not rendered publicly; their summary is the Message's prose.
  defp project_block(
         {%{"type" => "dynamic_ui"} = block, _index},
         state,
         %{"actor_type" => "agent"},
         terminals
       ) do
    case block["summary"] || block["text"] do
      summary when is_binary(summary) ->
        {visible, state} = scan(summary, state, terminals)
        {visible |> String.slice(0, 4_000) |> text_blocks(), state}

      _other ->
        {[], state}
    end
  end

  # Another Task is not part of this share; keep only that a reference existed.
  defp project_block(
         {%{"type" => "conversation_ref"} = block, _index},
         state,
         _message,
         terminals
       ),
       do: {[%{"type" => "task_ref"}], advance(block, state, terminals)}

  defp project_block({block, _index}, state, _message, terminals),
    do: {[], advance(block, state, terminals)}

  defp advance(%{"text" => text}, state, terminals) when is_binary(text),
    do: text |> scan(state, terminals) |> elem(1)

  defp advance(_block, state, _terminals), do: state

  defp scan(_text, :closed, _terminals), do: {"", :closed}
  defp scan(text, state, terminals), do: scan(text, state, terminals, [])

  defp scan(text, :visible, terminals, acc) do
    terminal = :binary.match(text, terminals)
    fence = :binary.match(text, @fence_open)

    cond do
      terminal != :nomatch and (fence == :nomatch or elem(terminal, 0) <= elem(fence, 0)) ->
        {IO.iodata_to_binary([acc, binary_part(text, 0, elem(terminal, 0))]), :closed}

      fence != :nomatch ->
        {start, length} = fence
        rest = binary_part(text, start + length, byte_size(text) - start - length)
        scan(rest, :fence, terminals, [acc, binary_part(text, 0, start)])

      true ->
        {IO.iodata_to_binary([acc, text]), :visible}
    end
  end

  # An unclosed fence stays private to the end of the Message. A protocol
  # marker inside a fence still closes the rest of the Message.
  defp scan(text, :fence, terminals, acc) do
    close = :binary.match(text, @fence_close)
    protocol = :binary.match(text, @protocol_marker)

    cond do
      protocol != :nomatch and (close == :nomatch or elem(protocol, 0) < elem(close, 0)) ->
        {IO.iodata_to_binary(acc), :closed}

      close == :nomatch ->
        {IO.iodata_to_binary(acc), :fence}

      true ->
        {start, length} = close
        rest = binary_part(text, start + length, byte_size(text) - start - length)
        scan(rest, :visible, terminals, acc)
    end
  end

  defp text_blocks(text) do
    @task_mention
    |> Regex.split(String.trim(text), include_captures: true, trim: true)
    |> Enum.flat_map(fn piece ->
      cond do
        Regex.match?(@task_mention_only, piece) -> [%{"type" => "task_ref"}]
        String.trim(piece) == "" -> []
        true -> [%{"type" => "text", "text" => String.trim(piece)}]
      end
    end)
  end

  defp artifact_message?(message),
    do: public_row?(message) and message["actor_type"] == "agent"

  ## Snapshot

  defp build_snapshot(workspace, conversation_id, through_seq) do
    scan_snapshot(workspace, conversation_id, through_seq, 0, 0, %{
      "message_count" => 0,
      "artifacts" => [],
      "artifacts_truncated" => false
    })
  end

  defp scan_snapshot(_workspace, _conversation_id, through_seq, after_seq, _scanned, snapshot)
       when after_seq >= through_seq,
       do: {:ok, finish_snapshot(snapshot)}

  defp scan_snapshot(_workspace, _conversation_id, _through_seq, _after_seq, scanned, snapshot)
       when scanned >= @scan_message_limit,
       do: {:ok, snapshot |> Map.put("artifacts_truncated", true) |> finish_snapshot()}

  defp scan_snapshot(workspace, conversation_id, through_seq, after_seq, scanned, snapshot) do
    limit = Enum.min([@scan_page, through_seq - after_seq, @scan_message_limit - scanned])

    case read_messages(workspace, conversation_id, after_seq, limit) do
      {:ok, []} ->
        {:ok, finish_snapshot(snapshot)}

      {:ok, raw} ->
        raw = Enum.filter(raw, &(is_integer(&1["seq"]) and &1["seq"] <= through_seq))
        snapshot = Enum.reduce(raw, snapshot, &add_to_snapshot/2)

        case List.last(raw) do
          %{"seq" => last_seq} when last_seq > after_seq ->
            scan_snapshot(
              workspace,
              conversation_id,
              through_seq,
              last_seq,
              scanned + length(raw),
              snapshot
            )

          _other ->
            {:ok, finish_snapshot(snapshot)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp add_to_snapshot(message, snapshot) do
    case public_message(message) do
      [projected] ->
        artifacts =
          for %{"type" => type} = block when type in @artifact_types <- projected["content"] do
            Map.put(block, "seq", projected["seq"])
          end

        kept = snapshot["artifacts"]
        room = @artifact_limit - length(kept)

        snapshot
        |> Map.update!("message_count", &(&1 + 1))
        |> Map.put("artifacts", Enum.reverse(Enum.take(artifacts, max(room, 0)), kept))
        |> Map.update!("artifacts_truncated", &(&1 or length(artifacts) > room))

      [] ->
        snapshot
    end
  end

  defp finish_snapshot(snapshot), do: Map.update!(snapshot, "artifacts", &Enum.reverse/1)

  ## Resolution and authorization

  defp resolve(token) do
    with true <- valid_token?(token),
         %TaskShare{revoked_at: nil} = share <- Repo.get_by(TaskShare, token: token),
         {:ok, workspace} <-
           Workspaces.authorize_group_owner(share.workspace_id, share.group_id, share.created_by),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"} = conversation} <-
           Comma.Salix.Client.impl().get_group_conversation(workspace, share.conversation_id) do
      {:ok, share, workspace, conversation}
    else
      {:error, reason} when reason != :not_found -> {:error, {:unavailable, reason}}
      _ -> {:error, :not_found}
    end
  end

  defp authorize_task(user, session, group_id, conversation_id) do
    with false <- session["restricted"] == true,
         true <- SalixStore.Ids.valid_conversation_id?(conversation_id),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"} = conversation} <-
           Comma.Salix.Client.impl().get_group_conversation(workspace, conversation_id) do
      {:ok, workspace, conversation}
    else
      true -> {:error, :forbidden}
      false -> {:error, :not_found}
      {:ok, _other_kind} -> {:error, :not_found}
      {:error, _reason} = error -> error
      _other -> {:error, :not_found}
    end
  end

  defp active_share(conversation_id, opts \\ []) do
    query =
      from(share in TaskShare,
        where: share.conversation_id == ^conversation_id and is_nil(share.revoked_at)
      )

    query = if opts[:lock], do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp active_shares(workspace_id, group_id, cursor, limit) do
    query =
      from(share in TaskShare,
        where:
          share.workspace_id == ^workspace_id and share.group_id == ^group_id and
            is_nil(share.revoked_at),
        order_by: [desc: share.updated_at, desc: share.id],
        limit: ^limit
      )

    case cursor do
      nil ->
        Repo.all(query)

      {shared_at, id} ->
        from(share in query,
          where:
            share.updated_at < ^shared_at or
              (share.updated_at == ^shared_at and share.id < ^id)
        )
        |> Repo.all()
    end
  end

  defp share_conversations(_user, _session, _group_id, []), do: {:ok, %{}}

  defp share_conversations(user, session, group_id, shares) do
    ids = Enum.map(shares, & &1.conversation_id)

    with {:ok, %{"data" => summaries}} <-
           Conversations.task_summaries(user, session, group_id, ids) do
      {:ok, Map.new(summaries, &{&1["id"], &1})}
    end
  end

  defp owner_list_view(share, conversation) do
    snapshot = share.snapshot || %{}

    %{
      "token" => share.token,
      "conversation" => conversation,
      "created_at" => unix_time(share.inserted_at),
      "shared_at" => unix_time(share.updated_at),
      "message_count" => snapshot["message_count"] || 0,
      "artifact_count" => length(snapshot["artifacts"] || [])
    }
  end

  defp owner_page_limit(nil), do: {:ok, @owner_page_max}

  defp owner_page_limit(value) do
    case non_negative(value, @owner_page_max) do
      {:ok, limit} when limit in 1..@owner_page_max -> {:ok, limit}
      _other -> {:error, {:bad_request, "limit must be between 1 and 50"}}
    end
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with [micros, id] <- String.split(cursor, "_", parts: 2),
         {micros, ""} <- Integer.parse(micros),
         {:ok, shared_at} <- DateTime.from_unix(micros, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {shared_at, id}}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}

  defp encode_cursor(share),
    do: "#{DateTime.to_unix(share.updated_at, :microsecond)}_#{share.id}"

  defp insert_share(workspace, user, conversation_id, attrs) do
    now = now()

    %TaskShare{
      token: new_token(),
      workspace_id: workspace["id"],
      group_id: workspace["default_group_id"],
      conversation_id: conversation_id,
      created_by: user["id"],
      through_seq: attrs.through_seq,
      snapshot: attrs.snapshot,
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:conversation_id,
      name: :comma_task_shares_active_conversation_index
    )
    |> Repo.insert()
  end

  defp owner_view(share, conversation) do
    snapshot = share.snapshot || %{}

    %{
      "token" => share.token,
      "created_at" => unix_time(share.inserted_at),
      "shared_at" => unix_time(share.updated_at),
      "message_count" => snapshot["message_count"] || 0,
      "artifact_count" => length(snapshot["artifacts"] || []),
      "has_newer_messages" => tail_seq(conversation) > share.through_seq
    }
  end

  defp read_messages(workspace, conversation_id, after_seq, limit) do
    case Comma.Salix.Client.impl().get_group_conversation_with_messages(
           workspace,
           conversation_id,
           after_seq: after_seq,
           limit: limit
         ) do
      {:ok, %{"messages" => messages}} when is_list(messages) -> {:ok, messages}
      {:ok, _invalid} -> {:error, :invalid_salix_conversation}
      {:error, _reason} = error -> error
    end
  end

  defp tail_seq(conversation) do
    case conversation["message_tail_seq"] || conversation["message_count"] do
      seq when is_integer(seq) and seq > 0 -> seq
      _other -> 0
    end
  end

  defp public_title(conversation) do
    case conversation["title"] do
      title when is_binary(title) and title != "" -> title
      _other -> "Task"
    end
  end

  defp page_limit(nil), do: {:ok, @public_page_default}

  defp page_limit(value) do
    case non_negative(value, @public_page_default) do
      {:ok, limit} when limit > 0 -> {:ok, min(limit, @public_page_max)}
      _other -> {:error, :invalid_page}
    end
  end

  defp non_negative(nil, default), do: {:ok, default}
  defp non_negative(value, _default) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _other -> {:error, :invalid_page}
    end
  end

  defp non_negative(_value, _default), do: {:error, :invalid_page}

  defp positive(value) do
    case non_negative(value, nil) do
      {:ok, parsed} when is_integer(parsed) and parsed > 0 -> {:ok, parsed}
      _other -> {:error, :not_found}
    end
  end

  defp new_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp now, do: DateTime.utc_now()

  defp unix_time(%DateTime{} = value), do: DateTime.to_unix(value)
  defp unix_time(_value), do: nil
end
