defmodule Comma.DocumentShares do
  @moduledoc """
  Public read-only links to one document an Agent sent in a Comma Task.

  A Document Share names one Markdown file of one `agent_task` Conversation:
  the `file` block at `block_index` of the Agent Message `message_id`. A
  document is its Task and its file name, so a Task has at most one active
  share for a name, and publishing a later version of the document moves the
  share to that Message and keeps the link.

  A share discloses that one file and nothing else of the Task: no Message, no
  other artifact. It discloses no more than a Task Share of the same Task
  could (`Comma.TaskShares`), and every public read applies the same checks:
  the creator still owns the ready Workspace, the Conversation still resolves
  as an `agent_task`, and the Message still shows that file as a public
  artifact. See `docs/architecture/DOMAIN_CONCEPTS.md` (Document Share).

  A Task a station hosts has no artifacts, so it has no Document Share.
  """

  import Ecto.Query

  alias Comma.{ConversationAttachments, Conversations, Repo, TaskShares, Workspaces}
  alias Comma.Data.DocumentShare
  alias SalixIM.Ports.StationHostedTasks

  @token_bytes 32
  # One owner page resolves at most 50 Task summaries, one Task read each.
  @owner_page_max 50
  @max_file_name_bytes 1_024
  @document_extensions [".md", ".markdown"]

  ## Owner operations

  @doc "The active share of a Task's document, or `{:error, :not_found}`."
  def get(user, session, group_id, conversation_id, file_name) do
    with {:ok, file_name} <- document_name(file_name),
         {:ok, _workspace} <- authorize_task(user, session, group_id, conversation_id),
         %DocumentShare{} = share <- active_share(conversation_id, file_name) do
      {:ok, owner_view(share)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Shares the document that the `file` block at `index` of Agent Message
  `message_id` holds, or moves the document's existing share to that Message.
  The token of an existing share does not change.
  """
  def publish(user, session, group_id, conversation_id, message_id, index) do
    with {:ok, index} <- block_index(index),
         true <- is_binary(message_id) and message_id != "",
         {:ok, workspace} <- authorize_task(user, session, group_id, conversation_id),
         {:ok, message} <- read_message(workspace, conversation_id, message_id),
         {:ok, artifact} <- document_artifact(message, index) do
      case upsert_share(workspace, user, conversation_id, artifact["file_name"], %{
             message_id: message_id,
             block_index: index
           }) do
        {:ok, share} -> {:ok, owner_view(share)}
        {:error, _reason} -> {:error, :task_share_unavailable}
      end
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # A concurrent first publish loses the active-share constraint race; it then
  # moves the winner's share instead of failing.
  defp upsert_share(workspace, user, conversation_id, file_name, attrs, attempts \\ 2) do
    case active_share(conversation_id, file_name) do
      %DocumentShare{} = share ->
        share |> Ecto.Changeset.change(attrs) |> Repo.update()

      nil ->
        case insert_share(workspace, user, conversation_id, file_name, attrs) do
          {:error, %Ecto.Changeset{}} when attempts > 1 ->
            upsert_share(workspace, user, conversation_id, file_name, attrs, attempts - 1)

          result ->
            result
        end
    end
  end

  @doc "Revokes the current link and issues a new one for the same version."
  def reset(user, session, group_id, conversation_id, file_name) do
    with {:ok, file_name} <- document_name(file_name),
         {:ok, workspace} <- authorize_task(user, session, group_id, conversation_id) do
      Repo.transaction(fn ->
        case active_share(conversation_id, file_name, lock: true) do
          nil ->
            Repo.rollback(:not_found)

          share ->
            {:ok, _revoked} = share |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update()

            case insert_share(workspace, user, conversation_id, file_name, %{
                   message_id: share.message_id,
                   block_index: share.block_index
                 }) do
              {:ok, replacement} -> owner_view(replacement)
              {:error, _reason} -> Repo.rollback(:task_share_unavailable)
            end
        end
      end)
    end
  end

  @doc "Revokes the document's share. Revoking an unshared document succeeds."
  def revoke(user, session, group_id, conversation_id, file_name) do
    with {:ok, file_name} <- document_name(file_name),
         {:ok, _workspace} <- authorize_task(user, session, group_id, conversation_id) do
      from(share in DocumentShare,
        where:
          share.conversation_id == ^conversation_id and share.file_name == ^file_name and
            is_nil(share.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: now(), updated_at: now()])

      :ok
    end
  end

  @doc """
  One page of a Group's active document shares, most recently shared first.

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
             do: Map.put(owner_view(share), "conversation", conversation)
           ),
         "has_more" => rest != [],
         "next_cursor" => if(rest != [], do: encode_cursor(List.last(page)))
       }}
    else
      true -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  ## Public reads

  @doc "File name, size and share time of a public document link."
  def public_summary(token) do
    with {:ok, share, _workspace, _message, artifact} <- resolve(token) do
      {:ok,
       %{
         "kind" => "document",
         "file_name" => artifact["file_name"],
         "size" => artifact["size"],
         "shared_at" => unix_time(share.updated_at)
       }}
    end
  end

  @doc "The shared document, opened for `Comma.ConversationAttachments.stream/2`."
  def public_file(token) do
    with {:ok, share, workspace, message, _artifact} <- resolve(token) do
      ConversationAttachments.open_message(workspace, message, share.block_index)
    end
  end

  ## Resolution and authorization

  defp resolve(token) do
    with true <- TaskShares.valid_token?(token),
         %DocumentShare{revoked_at: nil} = share <- Repo.get_by(DocumentShare, token: token),
         {:ok, workspace} <-
           Workspaces.authorize_group_owner(share.workspace_id, share.group_id, share.created_by),
         {:ok, workspace} <- shared_task(workspace, share.conversation_id),
         {:ok, message} <- read_message(workspace, share.conversation_id, share.message_id),
         {:ok, %{"file_name" => file_name} = artifact} <-
           document_artifact(message, share.block_index),
         true <- file_name == share.file_name do
      {:ok, share, workspace, message, artifact}
    else
      {:error, reason} when reason != :not_found ->
        {:error, {:unavailable, reason}}

      _ ->
        {:error, :not_found}
    end
  end

  # The document's Task as a read resolves it: a Salix `agent_task` Conversation of the Group.
  defp shared_task(workspace, conversation_id) do
    with :error <- StationHostedTasks.parse(conversation_id),
         true <- SalixStore.Ids.valid_conversation_id?(conversation_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"}} <-
           Comma.Salix.Client.impl().get_group_conversation(workspace, conversation_id) do
      {:ok, workspace}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :not_found}
    end
  end

  defp authorize_task(user, session, group_id, conversation_id) do
    with false <- session["restricted"] == true,
         {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- shared_task(workspace, conversation_id) do
      {:ok, workspace}
    else
      true -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp read_message(workspace, conversation_id, message_id) do
    case Comma.Salix.Client.get_group_conversation_message(workspace, conversation_id, message_id) do
      {:ok, %{"message_id" => ^message_id} = message} -> {:ok, message}
      {:ok, _other} -> {:error, :not_found}
      {:error, {:bad_request, _reason}} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # The Markdown file a public reader of the Task would see at `index` of the Message: the Task Share projection
  # decides what of a Message is public, so a document is shared under the same rules as a Task's artifacts.
  defp document_artifact(message, index) do
    with [%{"content" => blocks}] <- TaskShares.public_message(message),
         %{"file_name" => file_name} = artifact when is_binary(file_name) <-
           Enum.find(blocks, &match?(%{"type" => "file", "index" => ^index}, &1)),
         {:ok, _file_name} <- document_name(file_name) do
      {:ok, artifact}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :not_found}
    end
  end

  defp document_name(file_name)
       when is_binary(file_name) and file_name != "" and
              byte_size(file_name) <= @max_file_name_bytes do
    # Any other file is no document: it has no share, as a name that is not there has none.
    if String.ends_with?(String.downcase(file_name), @document_extensions),
      do: {:ok, file_name},
      else: {:error, :not_found}
  end

  defp document_name(_file_name), do: {:error, :not_found}

  defp block_index(index) when is_integer(index) and index >= 0, do: {:ok, index}
  defp block_index(index) when is_binary(index), do: ConversationAttachments.parse_index(index)
  defp block_index(_index), do: {:error, :not_found}

  defp active_share(conversation_id, file_name, opts \\ []) do
    query =
      from(share in DocumentShare,
        where:
          share.conversation_id == ^conversation_id and share.file_name == ^file_name and
            is_nil(share.revoked_at)
      )

    query = if opts[:lock], do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp active_shares(workspace_id, group_id, cursor, limit) do
    query =
      from(share in DocumentShare,
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
    ids = shares |> Enum.map(& &1.conversation_id) |> Enum.uniq()

    with {:ok, %{"data" => summaries}} <-
           Conversations.task_summaries(user, session, group_id, ids) do
      {:ok, Map.new(summaries, &{&1["id"], &1})}
    end
  end

  defp insert_share(workspace, user, conversation_id, file_name, attrs) do
    now = now()

    %DocumentShare{
      token: new_token(),
      workspace_id: workspace["id"],
      group_id: workspace["default_group_id"],
      conversation_id: conversation_id,
      created_by: user["id"],
      file_name: file_name,
      message_id: attrs.message_id,
      block_index: attrs.block_index,
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:conversation_id,
      name: :comma_document_shares_active_document_index
    )
    |> Repo.insert()
  end

  defp owner_view(share) do
    %{
      "token" => share.token,
      "file_name" => share.file_name,
      "conversation_id" => share.conversation_id,
      "message_id" => share.message_id,
      "index" => share.block_index,
      "created_at" => unix_time(share.inserted_at),
      "shared_at" => unix_time(share.updated_at)
    }
  end

  defp owner_page_limit(nil), do: {:ok, @owner_page_max}

  defp owner_page_limit(value) do
    case parse_limit(value) do
      {:ok, limit} when limit in 1..@owner_page_max -> {:ok, limit}
      _other -> {:error, {:bad_request, "limit must be between 1 and 50"}}
    end
  end

  defp parse_limit(value) when is_integer(value), do: {:ok, value}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _other -> :error
    end
  end

  defp parse_limit(_value), do: :error

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

  defp new_token do
    @token_bytes |> SystemsRuntime.Proc.random_bytes() |> Base.url_encode64(padding: false)
  end

  defp now, do: SystemsClock.utc_now()

  defp unix_time(%DateTime{} = value), do: DateTime.to_unix(value)
  defp unix_time(_value), do: nil
end
