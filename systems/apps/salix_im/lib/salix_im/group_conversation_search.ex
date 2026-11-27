defmodule SalixIM.GroupConversationSearch do
  @moduledoc """
  Cross-Group conversation search and read within one Salix Tenant.

  Authorization comes exclusively from the caller Group's control record
  (`search_group_ids`, validated and bounded by `Salix.Control.Groups`).
  Every target Group must belong to the caller's Tenant and remain visible.
  A target Group with information-flow control on is authorized only for a
  caller Group that also has it on: results carry the caller Group's own
  audience, which would otherwise drop the target's labels.

  Privacy and information-flow boundaries enforced at the source before any hit
  or message reaches the calling Agent:
    * private chats (`user_chat`, Slack `D*` and `G*`, Feishu/Lark `p2p`, QQ
      `c2c`/`private`, voice and iMessage, IFC `direct` scopes) are excluded;
    * a Task is excluded when it, or any Task or Conversation it was created
      from, came from such a chat, from a `sealed`, members-only or tagged
      scope, or from a source whose label cannot be read;
    * scopes marked `sealed`, members-only or carrying classification `tags`
      in the target Group's `SalixStore.IFC` policy are excluded, and so are
      Slack rooms that are not public channels when the target Group has
      information-flow control on;
    * Agent execution transcripts (`SessionHistory`) are never searched or read.

  Groups that share a Slack workspace or a Feishu/Lark/QQ app share one mirror
  index: one search sends each distinct mirror query once and returns a shared
  message once, for the lowest authorized `group_id` that admits it. Feishu and
  Lark chat and message ids are the same for every app of one provider tenant,
  so when Groups connect different Feishu/Lark bot apps that are all in one
  group chat, a message of that chat is also returned once, for the lowest
  authorized `group_id` that admits it.
  """

  alias SalixIFC.Codec
  alias SalixIM.{Conversations, FeishuMessageMirror, GroupDirectory, LarkMessageRecord}
  alias SalixIM.{ProviderConnects, QQMessageRecord, SlackMessageMirror}
  alias SalixIM.IFC.{Ingress, Projection}
  alias SalixIM.Provider.Slack.SearchQuery
  alias SalixIM.Triage.ClickHouseReader
  alias SalixStore.{ConversationSearch, Ids}
  alias SalixStore.IFC, as: IFCStore

  @hit_prefix "ghit1."
  @default_limit 20
  @max_limit 50
  @default_read_limit 30
  @max_read_limit 50
  @max_query_bytes 500
  @search_deadline_ms 8_000
  @mirror_concurrency 8
  @max_mirror_rows 100
  @max_lineage_depth 8
  # A Feishu/Lark/QQ read anchored on a hit also takes the replies of the
  # minute after it.
  @read_after_hit_us 60_000_000
  @private_chat_types ["p2p", "c2c", "direct", "private"]
  @private_origin_chat_types ["im", "mpim", "p2p", "c2c", "direct", "private"]
  @private_providers ["voice", "imessage"]

  @doc """
  Authorized target Groups for `caller_group_id`, ordered by `group_id`. A
  target with information-flow control on is left out unless the caller has it
  on too; `ifc` says whether the target has it on.
  """
  @spec authorized_groups(String.t()) ::
          {:ok,
           %{
             tenant_id: String.t(),
             groups: [%{group_id: String.t(), name: String.t(), ifc: boolean()}]
           }}
          | {:error, term()}
  def authorized_groups(caller_group_id) when is_binary(caller_group_id) do
    with {:ok, caller} <- GroupDirectory.get_group(String.trim(caller_group_id)) do
      tenant_id = text(caller["tenant_id"])
      caller_ifc? = Ingress.enabled?(caller)

      groups =
        caller["search_group_ids"]
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or &1 == caller["group_id"]))
        |> Enum.uniq()
        |> Enum.filter(&Ids.valid_group_id_for_tenant?(&1, tenant_id))
        |> Enum.flat_map(fn target_id ->
          case GroupDirectory.get_group(target_id, tenant_id) do
            {:ok, target} ->
              ifc? = Ingress.enabled?(target)

              if ifc? and not caller_ifc?,
                do: [],
                else: [%{group_id: target_id, name: group_name(target), ifc: ifc?}]

            _unavailable ->
              []
          end
        end)
        |> Enum.sort_by(& &1.group_id)

      {:ok, %{tenant_id: tenant_id, groups: groups}}
    end
  end

  def authorized_groups(_caller_group_id), do: {:error, :invalid_group_id}

  @doc "Search authorized target Groups' Task conversations and public/room IM mirrors."
  @spec search(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def search(caller_group_id, args) when is_binary(caller_group_id) and is_map(args) do
    with {:ok, query} <- validate_query(args),
         {:ok, limit} <- validate_limit(args, @default_limit, @max_limit),
         {:ok, %{tenant_id: tenant_id, groups: authorized}} <- authorized_groups(caller_group_id),
         :ok <- ensure_configured(authorized),
         {:ok, selected} <- select_groups(authorized, args),
         {:ok, hits} <- run_search(tenant_id, selected, query, limit) do
      {:ok,
       %{
         "query" => query,
         "groups" => Enum.map(selected, &%{"group_id" => &1.group_id, "group_name" => &1.name}),
         "hits" => hits
       }}
    end
  end

  def search(_caller_group_id, _args), do: {:error, :invalid_arguments}

  @doc "Read bounded context for one `hit_id` returned by `search/2`, re-checking authorization."
  @spec read(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def read(caller_group_id, args) when is_binary(caller_group_id) and is_map(args) do
    with {:ok, locator} <- decode_hit_id(value(args, "hit_id")),
         {:ok, limit} <- validate_limit(args, @default_read_limit, @max_read_limit),
         {:ok, %{tenant_id: tenant_id, groups: authorized}} <- authorized_groups(caller_group_id),
         :ok <- ensure_configured(authorized),
         {:ok, target} <- find_authorized_group(authorized, locator["g"]) do
      read_located(tenant_id, target, locator, limit)
    end
  end

  def read(_caller_group_id, _args), do: {:error, :invalid_arguments}

  # ---------------------------------------------------------------------------
  # Search execution
  # ---------------------------------------------------------------------------

  # Task conversations and IM mirrors are searched at once under one deadline.
  # A source that misses it is left out; the search fails only when both do.
  defp run_search(tenant_id, selected, query, limit) do
    deadline = SystemsClock.monotonic_time(:millisecond) + @search_deadline_ms

    tasks =
      SystemsRuntime.Task.async(fn ->
        search_task_conversations(tenant_id, selected, query, limit)
      end)

    mirrors =
      SystemsRuntime.Task.async(fn ->
        search_im_mirrors(tenant_id, selected, query, limit, deadline)
      end)

    case {await_by(tasks, deadline), await_by(mirrors, deadline)} do
      {:timeout, :timeout} ->
        {:error, :search_timeout}

      {task_hits, im_hits} ->
        hits =
          (List.wrap(found(task_hits)) ++ List.wrap(found(im_hits)))
          |> Enum.sort_by(&hit_sort_key/1, :desc)
          |> Enum.take(limit)
          |> Enum.map(&Map.drop(&1, ["__sort_us__", "__message__"]))

        {:ok, hits}
    end
  end

  defp await_by(task, deadline) do
    case SystemsClock.yield(task, remaining_ms(deadline)) ||
           SystemsRuntime.Task.shutdown(task, :brutal_kill) do
      {:ok, hits} -> {:ok, hits}
      _missed -> :timeout
    end
  end

  defp found({:ok, hits}), do: hits
  defp found(:timeout), do: []

  defp remaining_ms(deadline), do: max(deadline - SystemsClock.monotonic_time(:millisecond), 1)

  defp search_task_conversations(tenant_id, selected, query, limit) do
    group_ids = Enum.map(selected, & &1.group_id)
    by_id = Map.new(selected, &{&1.group_id, &1})

    raw_hits =
      if ConversationSearch.configured?() and ConversationSearch.ready?() do
        case ConversationSearch.search_groups(group_ids, query, limit: limit) do
          {:ok, rows} -> rows
          {:error, _} -> []
        end
      else
        Enum.flat_map(group_ids, fn group_id ->
          case Conversations.search_group_conversations_by_keywords(group_id, query, limit: limit) do
            {:ok, rows} -> Enum.map(rows, &Map.put(&1, "group_id", group_id))
            {:error, _} -> []
          end
        end)
      end

    Enum.flat_map(raw_hits, fn hit ->
      group_id = text(hit["group_id"])
      conv_id = text(hit["conversation_id"])

      with %{} = target <- Map.get(by_id, group_id),
           {:ok, record} <- admissible_task_conversation(tenant_id, target, conv_id) do
        updated_us = conversation_timestamp_us(record, hit)

        locator =
          %{"k" => "conversation", "g" => group_id, "c" => conv_id}
          |> put_positive("seq", hit["message_seq"])

        [
          %{
            "hit_id" => encode_hit_id(locator),
            "group_id" => group_id,
            "group_name" => target.name,
            "source" => "task_conversation",
            "conversation_id" => conv_id,
            "title" => non_empty(record["title"], text(hit["title"])),
            "snippet" => task_hit_snippet(hit),
            "timestamp" => iso8601_from_us(updated_us),
            "__sort_us__" => updated_us
          }
        ]
      else
        _excluded -> []
      end
    end)
  end

  # A Task is admissible when neither it nor anything it was created from is
  # private. Its lineage (`parent_conversation_id`,
  # `origin_task_conversation_id`, and Tasks its IFC provenance names) is read
  # in the same Group, at most `@max_lineage_depth` levels up; a parent that
  # is not a Task, cannot be read, or lies deeper excludes it.
  defp admissible_task_conversation(tenant_id, target, conv_id) do
    with {:ok, record} <- Conversations.get_group_conversation_record(target.group_id, conv_id),
         true <- task_record?(record),
         :ok <- admissible_lineage(tenant_id, target, record) do
      {:ok, record}
    else
      _ -> :excluded
    end
  end

  defp task_record?(record),
    do: (record["kind"] || record["conversation_kind"]) == "agent_task"

  defp admissible_lineage(tenant_id, target, record) do
    own_id = text(record["conversation_id"])

    case task_origin(tenant_id, target, record) do
      {:ok, next} ->
        walk_lineage(
          tenant_id,
          target,
          Enum.map(next, &{&1, 1}),
          MapSet.new([own_id])
        )

      :restricted ->
        :restricted
    end
  end

  defp walk_lineage(_tenant_id, _target, [], _visited), do: :ok

  defp walk_lineage(tenant_id, target, [{conv_id, depth} | rest], visited) do
    cond do
      MapSet.member?(visited, conv_id) ->
        walk_lineage(tenant_id, target, rest, visited)

      depth > @max_lineage_depth ->
        :restricted

      true ->
        with {:ok, record} <-
               Conversations.get_group_conversation_record(target.group_id, conv_id),
             true <- task_record?(record),
             {:ok, next} <- task_origin(tenant_id, target, record) do
          walk_lineage(
            tenant_id,
            target,
            rest ++ Enum.map(next, &{&1, depth + 1}),
            MapSet.put(visited, conv_id)
          )
        else
          _private_or_unreadable -> :restricted
        end
    end
  end

  # `{:ok, conversations it was created from}`, or `:restricted` when the
  # record's own origin is private.
  defp task_origin(tenant_id, target, record) do
    refs =
      case record["source_refs"] do
        %{} = refs -> refs
        _none -> %{}
      end

    case restricted_task_origin?(tenant_id, target, refs) do
      {false, provenance_tasks} ->
        parents =
          [refs["parent_conversation_id"], refs["origin_task_conversation_id"]]
          |> Enum.map(&text/1)
          |> Kernel.++(provenance_tasks)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        {:ok, parents}

      true ->
        :restricted
    end
  end

  # `true` when a Task's recorded origin is private, else `{false, ids}` with
  # the Tasks its IFC provenance names.
  defp restricted_task_origin?(tenant_id, target, refs) do
    with false <- restricted_origin_chat?(tenant_id, target, origin_chat(refs)),
         false <- restricted_reply_source?(tenant_id, target, refs["task_reply_source"]),
         false <- restricted_ifc_return?(tenant_id, target, refs["ifc_return"]) do
      provenance_atoms(tenant_id, target, refs["ifc_provenance"])
    end
  end

  # The server-sealed `origin_chat`, or, for a Task written before it, the
  # chat facts some creators kept at the top level of `source_refs`.
  defp origin_chat(%{"origin_chat" => %{} = chat}), do: chat

  defp origin_chat(refs) do
    %{
      "provider" => refs["provider"],
      "conversation_kind" => refs["conversation_kind"],
      "connect_id" => refs["connect_id"],
      "scope_id" =>
        non_empty(
          text(refs["channel_id"]),
          non_empty(text(refs["channel"]), text(refs["chat_id"]))
        ),
      "chat_type" => non_empty(text(refs["chat_type"]), text(refs["channel_type"]))
    }
  end

  defp restricted_origin_chat?(tenant_id, target, chat) do
    provider = String.downcase(text(chat["provider"]))
    connect_id = text(chat["connect_id"])
    scope_id = text(chat["scope_id"])

    text(chat["conversation_kind"]) == "user_chat" or provider in @private_providers or
      String.downcase(text(chat["chat_type"])) in @private_origin_chat_types or
      private_scope_id?(scope_id) or
      (connect_id != "" and scope_id != "" and
         restricted_scope?(tenant_id, target, provider, connect_id, scope_id))
  end

  defp restricted_reply_source?(tenant_id, target, %{"chat_id" => _} = source) do
    connect_id = text(source["connect_id"])
    chat = text(source["chat_id"])

    private_scope_id?(chat) or
      (connect_id != "" and chat != "" and
         restricted_scope?(tenant_id, target, text(source["provider"]), connect_id, chat))
  end

  defp restricted_reply_source?(tenant_id, target, %{} = source) do
    connect_id = text(source["connect_id"])
    channel = text(source["channel"])

    slack_private_channel?(channel) or
      (connect_id != "" and channel != "" and
         restricted_scope?(tenant_id, target, "slack", connect_id, channel))
  end

  defp restricted_reply_source?(_tenant_id, _target, _source), do: false

  defp restricted_ifc_return?(tenant_id, target, %{} = ifc_return) do
    return_target =
      case ifc_return["target"] do
        %{} = return_target -> return_target
        _ -> %{}
      end

    connect_id = text(return_target["connect_id"])
    channel = non_empty(text(return_target["channel"]), text(return_target["chat_id"]))

    private_scope_id?(channel) or
      (connect_id != "" and channel != "" and
         restricted_scope?(tenant_id, target, nil, connect_id, channel)) or
      provenance_atoms(tenant_id, target, ifc_return["source_scope"]) == true
  end

  defp restricted_ifc_return?(_tenant_id, _target, _ifc_return), do: false

  # `true` when an encoded label names a private source or cannot be read,
  # else `{false, ids}` of the Tasks it names.
  defp provenance_atoms(tenant_id, target, encoded) do
    encoded
    |> List.wrap()
    |> Enum.reduce_while({false, []}, fn atom, {false, tasks} ->
      case provenance_atom(tenant_id, target, atom) do
        :ok -> {:cont, {false, tasks}}
        {:task, id} -> {:cont, {false, [id | tasks]}}
        :restricted -> {:halt, true}
      end
    end)
    |> case do
      {false, tasks} -> {false, tasks |> Enum.reverse() |> Enum.uniq()}
      true -> true
    end
  end

  defp provenance_atom(tenant_id, target, encoded) do
    case Codec.decode_atom(encoded) do
      {:ok, {:task, id}} ->
        {:task, text(id)}

      {:ok, {:scope, connect_id, scope_id}} ->
        if private_scope_id?(scope_id) or
             restricted_scope?(tenant_id, target, nil, connect_id, scope_id),
           do: :restricted,
           else: :ok

      {:ok, atom} when atom == :public ->
        :ok

      {:ok, {kind, _id}} when kind in [:space, :group] ->
        :ok

      # `:agent_private`, `{:tag, _}`, `{:conversation, _}` (a Conversation
      # that is not a Task, such as a `user_chat`), and anything unreadable.
      _private ->
        :restricted
    end
  end

  defp private_scope_id?(scope_id) do
    slack_private_channel?(scope_id) or String.starts_with?(scope_id, "c2c:") or
      String.starts_with?(scope_id, "user:") or Projection.direct_scope_id?(scope_id)
  end

  # Slack DMs (`D*`) and multi-person DMs or legacy private groups (`G*`).
  defp slack_private_channel?(channel),
    do: String.starts_with?(channel, "D") or String.starts_with?(channel, "G")

  # ---------------------------------------------------------------------------
  # IM Mirror search (Slack, Feishu, Lark, QQ)
  # ---------------------------------------------------------------------------

  # Groups of one Tenant can share a Slack workspace or a Feishu/Lark/QQ app,
  # whose mirror is one index. Each distinct reader query runs once; its rows
  # are then filtered per Group and connect, and a message more than one Group
  # admits is kept for the lowest `group_id`. Each query asks for more rows
  # than the search returns, since private and classified rows are dropped
  # afterwards.
  defp search_im_mirrors(tenant_id, selected, query, limit, deadline) do
    reader_limit = min(limit * 3, @max_mirror_rows)

    selected
    |> active_group_connects(deadline)
    |> Enum.flat_map(fn {group, connect} ->
      case mirror_query(tenant_id, connect, query, reader_limit) do
        {:ok, key, run} -> [{key, run, group, connect}]
        :skip -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
    |> SystemsClock.async_stream(
      fn {_key, [{_key2, run, _group, _connect} | _] = entries} ->
        case run.() do
          {:ok, page} -> mirror_hits(tenant_id, entries, List.wrap(page.messages))
          _unavailable -> []
        end
      end,
      max_concurrency: @mirror_concurrency,
      timeout: remaining_ms(deadline),
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, hits} -> hits
      {:exit, _reason} -> []
    end)
    |> Enum.sort_by(&{&1["group_id"], &1["hit_id"]})
    |> Enum.uniq_by(& &1["__message__"])
  end

  # Every selected Group's active IM connects, read at once; a QQ connect is
  # read in full here, since its mirror scope needs fields the public record
  # omits.
  defp active_group_connects(selected, deadline) do
    selected
    |> SystemsClock.async_stream(
      fn group ->
        case ProviderConnects.list_group_im_connects(group.group_id) do
          {:ok, connects} ->
            connects
            |> Enum.filter(&active_connect?/1)
            |> Enum.flat_map(&full_connect(group.group_id, &1))
            |> Enum.map(&{group, &1})

          _unavailable ->
            []
        end
      end,
      max_concurrency: @mirror_concurrency,
      timeout: remaining_ms(deadline),
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, pairs} -> pairs
      {:exit, _reason} -> []
    end)
  end

  defp full_connect(group_id, %{"provider" => "qq"} = connect) do
    case ProviderConnects.get_active_connect_by_id(group_id, text(connect["connect_id"]), "qq") do
      {:ok, full} -> [full]
      _gone -> []
    end
  end

  defp full_connect(_group_id, connect), do: [connect]

  defp active_connect?(connect) when is_map(connect) do
    is_nil(connect["disabled_at"]) and text(connect["connect_id"]) != ""
  end

  defp active_connect?(_connect), do: false

  # The reader query a connect needs, keyed by everything that query depends
  # on, so connects sharing one key share one call.
  defp mirror_query(tenant_id, %{"provider" => "slack"} = connect, query, limit) do
    reader = ClickHouseReader.impl()
    workspace_id = text(connect["workspace_id"])

    with true <- SlackMessageMirror.enabled?() and is_atom(reader) and workspace_id != "",
         _ <- Code.ensure_loaded(reader),
         true <- function_exported?(reader, :search, 2),
         {:ok, parsed} <- SearchQuery.parse(query) do
      opts = slack_reader_opts(connect, parsed, limit)
      scope = %{"tenant_id" => tenant_id, "workspace_id" => workspace_id}
      {:ok, {:slack, workspace_id, opts[:channel_id]}, fn -> reader.search(scope, opts) end}
    else
      _ -> :skip
    end
  end

  defp mirror_query(tenant_id, %{"provider" => provider} = connect, query, limit)
       when provider in ["feishu", "lark"] do
    app_id = text(connect["app_id"])

    with {:ok, reader} <- feishu_or_lark_reader(provider),
         true <- app_id != "",
         {:ok, parsed} <- SearchQuery.parse(query, :feishu),
         opts = feishu_reader_opts(parsed, limit),
         true <- filtered?(parsed, opts) do
      scope = %{"tenant_id" => tenant_id, "app_id" => app_id}
      {:ok, {provider, app_id}, fn -> reader.search(scope, opts) end}
    else
      _ -> :skip
    end
  end

  defp mirror_query(_tenant_id, %{"provider" => "qq"} = connect, query, limit) do
    reader = SystemsRuntime.get_env(:salix_im, :qq_message_record_reader_mod)

    with true <- QQMessageRecord.enabled?() and is_atom(reader) and not is_nil(reader),
         {:ok, parsed} <- SearchQuery.parse(query, :feishu),
         opts = feishu_reader_opts(parsed, limit),
         true <- filtered?(parsed, opts) do
      scope = QQMessageRecord.scope(connect)
      {:ok, {:qq, scope}, fn -> reader.search(scope, opts) end}
    else
      _ -> :skip
    end
  end

  defp mirror_query(_tenant_id, _connect, _query, _limit), do: :skip

  # One query grammar for every IM mirror (`SearchQuery`, Feishu dialect for
  # Feishu, Lark and QQ). A query with no words and no filter would read the
  # newest messages of every chat.
  defp filtered?(parsed, opts) do
    parsed.clauses != [] or
      Enum.any?(
        [:chat_id, :actor_id, :after_us, :before_us, :has_file],
        &Keyword.has_key?(opts, &1)
      )
  end

  defp feishu_reader_opts(parsed, limit) do
    [
      limit: limit,
      patterns: slack_patterns(parsed.clauses),
      exclude_patterns: Enum.map(parsed.exclude_terms, &like_pattern/1),
      actor_id: parsed.actor_id,
      chat_id: parsed.channel_id,
      after_us: date_us(parsed.after_date),
      before_us: date_us(parsed.before_date),
      has_file: parsed.has_file,
      sort_dir: :desc
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, false, "", []] end)
  end

  defp date_us(nil), do: nil

  defp date_us(%Date{} = date),
    do: (Date.to_gregorian_days(date) - Date.to_gregorian_days(~D[1970-01-01])) * 86_400_000_000

  # The rows of one reader query, filtered for each Group and connect that
  # shares it, in `group_id` order.
  defp mirror_hits(tenant_id, entries, messages) do
    entries
    |> Enum.sort_by(fn {_key, _run, group, connect} ->
      {group.group_id, text(connect["connect_id"])}
    end)
    |> Enum.flat_map(fn {key, _run, group, connect} ->
      connect_hits(tenant_id, key, group, connect, messages)
    end)
  end

  defp connect_hits(tenant_id, {:slack, workspace_id, _channel}, group, connect, messages) do
    connect_id = text(connect["connect_id"])

    allowed =
      allowed_scope_ids(
        tenant_id,
        group,
        "slack",
        connect_id,
        Enum.map(messages, &text(&1["channel"]))
      )

    messages
    |> Enum.filter(fn msg ->
      ch = text(msg["channel"])

      ch != "" and not slack_private_channel?(ch) and MapSet.member?(allowed, ch) and
        routed_slack_channel?(connect, ch)
    end)
    |> Enum.map(fn msg ->
      ch = text(msg["channel"])
      ts = text(msg["ts"])
      thread_ts = non_empty(text(msg["thread_ts"]), ts)
      ts_us = slack_ts_to_us(ts)

      %{
        "hit_id" =>
          encode_hit_id(%{
            "k" => "slack",
            "g" => group.group_id,
            "cn" => connect_id,
            "ch" => ch,
            "th" => thread_ts
          }),
        "group_id" => group.group_id,
        "group_name" => group.name,
        "source" => "slack",
        "channel_id" => ch,
        "snippet" => truncate_snippet(text(msg["text"])),
        "timestamp" => iso8601_from_us(ts_us),
        "__sort_us__" => ts_us,
        "__message__" => {:slack, workspace_id, ch, ts}
      }
    end)
  end

  defp connect_hits(tenant_id, {provider, _app_id}, group, connect, rows)
       when provider in ["feishu", "lark"] do
    connect_id = text(connect["connect_id"])

    allowed =
      allowed_scope_ids(
        tenant_id,
        group,
        provider,
        connect_id,
        Enum.map(rows, &text(&1["chat_id"]))
      )

    rows
    |> Enum.filter(fn row ->
      chat_id = text(row["chat_id"])
      chat_id != "" and not private_chat_row?(row) and MapSet.member?(allowed, chat_id)
    end)
    |> Enum.map(fn row ->
      chat_id = text(row["chat_id"])
      ts_us = int_or_zero(row["create_time_us"])

      %{
        "hit_id" =>
          %{
            "k" => provider,
            "g" => group.group_id,
            "cn" => connect_id,
            "ch" => chat_id,
            "th" => text(row["thread_id"])
          }
          |> put_positive("t", ts_us)
          |> encode_hit_id(),
        "group_id" => group.group_id,
        "group_name" => group.name,
        "source" => provider,
        "chat_id" => chat_id,
        "snippet" => truncate_snippet(text(row["text"])),
        "timestamp" => iso8601_from_us(ts_us),
        "__sort_us__" => ts_us,
        "__message__" => {provider, chat_id, message_identity(row, ts_us)}
      }
    end)
  end

  defp connect_hits(tenant_id, {:qq, scope}, group, connect, rows) do
    connect_id = text(connect["connect_id"])

    allowed =
      allowed_scope_ids(
        tenant_id,
        group,
        "qq",
        connect_id,
        Enum.map(rows, &text(&1["chat_id"]))
      )

    rows
    |> Enum.filter(fn row ->
      chat_id = text(row["chat_id"])
      chat_id != "" and not private_chat_row?(row) and MapSet.member?(allowed, chat_id)
    end)
    |> Enum.map(fn row ->
      chat_id = text(row["chat_id"])
      ts_us = int_or_zero(row["create_time_us"])

      %{
        "hit_id" =>
          %{"k" => "qq", "g" => group.group_id, "cn" => connect_id, "ch" => chat_id}
          |> put_positive("t", ts_us)
          |> encode_hit_id(),
        "group_id" => group.group_id,
        "group_name" => group.name,
        "source" => "qq",
        "chat_id" => chat_id,
        "snippet" => truncate_snippet(text(row["text"])),
        "timestamp" => iso8601_from_us(ts_us),
        "__sort_us__" => ts_us,
        "__message__" => {:qq, scope, chat_id, message_identity(row, ts_us)}
      }
    end)
  end

  defp message_identity(row, ts_us), do: non_empty(text(row["message_id"]), ts_us)

  # A 1:1 chat by the provider's own chat type (Feishu/Lark `p2p`, QQ `c2c`)
  # or by an IFC direct scope id.
  defp private_chat_row?(row) do
    String.downcase(text(row["chat_type"])) in @private_chat_types or
      Projection.direct_scope_id?(text(row["chat_id"]))
  end

  # ---------------------------------------------------------------------------
  # Read execution (live re-authorization + non-sealed/non-DM re-check)
  # ---------------------------------------------------------------------------

  defp read_located(tenant_id, target, %{"k" => "conversation", "c" => conv_id} = loc, limit) do
    with {:ok, record} <- admissible_task_conversation(tenant_id, target, conv_id),
         {:ok, raw_messages} <- read_task_messages(target.group_id, conv_id, loc["seq"], limit) do
      messages =
        raw_messages
        |> List.wrap()
        |> Enum.map(fn msg ->
          %{
            "message_id" => msg["message_id"] || msg["id"],
            "seq" => msg["seq"],
            "sender" => msg["role_label"] || msg["sender_name"] || msg["actor_id"] || msg["role"],
            "text" => SalixIM.ConversationMessage.visible_text(msg),
            "created_at" => msg["created_at"]
          }
        end)

      {:ok,
       %{
         "group_id" => target.group_id,
         "group_name" => target.name,
         "source" => "task_conversation",
         "conversation_id" => conv_id,
         "title" => record["title"],
         "status" => record["status"],
         "messages" => messages
       }}
    else
      _ -> {:error, :conversation_not_accessible}
    end
  end

  defp read_located(
         tenant_id,
         target,
         %{"k" => "slack", "cn" => connect_id, "ch" => channel} = loc,
         limit
       ) do
    reader = ClickHouseReader.impl()
    thread_ts = text(loc["th"])

    with false <- slack_private_channel?(channel),
         false <- restricted_scope?(tenant_id, target, "slack", connect_id, channel),
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(target.group_id, connect_id, "slack"),
         true <- routed_slack_channel?(connect, channel),
         true <- SlackMessageMirror.enabled?() and is_atom(reader),
         _ <- Code.ensure_loaded(reader),
         {:ok, page} <- read_slack_mirror(reader, tenant_id, connect, channel, thread_ts, limit) do
      messages =
        page.messages
        |> List.wrap()
        |> Enum.map(fn msg ->
          %{
            "ts" => msg["ts"],
            "user" => msg["user"],
            "text" => msg["text"]
          }
        end)

      {:ok,
       %{
         "group_id" => target.group_id,
         "group_name" => target.name,
         "source" => "slack",
         "channel_id" => channel,
         "thread_ts" => if(thread_ts == "", do: nil, else: thread_ts),
         "messages" => messages
       }}
    else
      _ -> {:error, :conversation_not_accessible}
    end
  end

  defp read_located(
         tenant_id,
         target,
         %{"k" => provider, "cn" => connect_id, "ch" => chat_id} = loc,
         limit
       )
       when provider in ["feishu", "lark"] do
    thread_id = text(loc["th"])

    with false <- Projection.direct_scope_id?(chat_id),
         false <- restricted_scope?(tenant_id, target, provider, connect_id, chat_id),
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(target.group_id, connect_id, provider),
         {:ok, reader} <- feishu_or_lark_reader(provider),
         app_id = text(connect["app_id"]),
         true <- app_id != "",
         {opts, newest_first?} = chat_window(chat_id, thread_id, loc["t"], limit),
         {:ok, page} <- reader.search(%{"tenant_id" => tenant_id, "app_id" => app_id}, opts) do
      rows =
        if newest_first?,
          do: Enum.reverse(List.wrap(page.messages)),
          else: List.wrap(page.messages)

      if Enum.any?(rows, &private_chat_row?/1) do
        {:error, :conversation_not_accessible}
      else
        messages =
          Enum.map(rows, fn row ->
            %{
              "message_id" => row["message_id"],
              "sender" => non_empty(text(row["actor_label"]), text(row["actor_id"])),
              "text" => row["text"],
              "timestamp" => iso8601_from_us(int_or_zero(row["create_time_us"]))
            }
          end)

        {:ok,
         %{
           "group_id" => target.group_id,
           "group_name" => target.name,
           "source" => provider,
           "chat_id" => chat_id,
           "messages" => messages
         }}
      end
    else
      _ -> {:error, :conversation_not_accessible}
    end
  end

  defp read_located(
         tenant_id,
         target,
         %{"k" => "qq", "cn" => connect_id, "ch" => chat_id} = loc,
         limit
       ) do
    reader = SystemsRuntime.get_env(:salix_im, :qq_message_record_reader_mod)

    with false <- Projection.direct_scope_id?(chat_id),
         false <- restricted_scope?(tenant_id, target, "qq", connect_id, chat_id),
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(target.group_id, connect_id, "qq"),
         true <- QQMessageRecord.enabled?() and is_atom(reader) and not is_nil(reader),
         {opts, _newest_first} = chat_window(chat_id, "", loc["t"], limit),
         {:ok, page} <- reader.search(QQMessageRecord.scope(connect), opts),
         rows = List.wrap(page.messages),
         false <- Enum.any?(rows, &private_chat_row?/1) do
      messages =
        rows
        |> Enum.reverse()
        |> Enum.map(fn row ->
          %{
            "message_id" => row["message_id"],
            "sender" => non_empty(text(row["actor_label"]), text(row["actor_id"])),
            "text" => row["text"],
            "timestamp" => iso8601_from_us(int_or_zero(row["create_time_us"]))
          }
        end)

      {:ok,
       %{
         "group_id" => target.group_id,
         "group_name" => target.name,
         "source" => "qq",
         "chat_id" => chat_id,
         "messages" => messages
       }}
    else
      _ -> {:error, :conversation_not_accessible}
    end
  end

  defp read_located(_tenant_id, _target, _locator, _limit), do: {:error, :invalid_hit_id}

  # A Task hit on a Message reads the page around it; a title hit reads the
  # newest Messages.
  defp read_task_messages(group_id, conv_id, seq, limit) when is_integer(seq) and seq > 0 do
    case Conversations.list_group_conversation_message_page(group_id, conv_id,
           around: seq,
           limit: limit
         ) do
      {:ok, %{"messages" => messages}} -> {:ok, messages}
      {:error, :not_found} -> read_task_messages(group_id, conv_id, nil, limit)
      {:error, _} = error -> error
    end
  end

  defp read_task_messages(group_id, conv_id, _seq, limit),
    do: Conversations.list_group_conversation_messages(group_id, conv_id, tail: limit)

  # The reader options for a Feishu/Lark/QQ chat read and whether the reader
  # returns them newest first. A thread reads from its start. In a whole chat a
  # hit's time anchors the window on it, with the minute after it; without one
  # the chat reads its newest messages.
  defp chat_window(chat_id, thread_id, anchor_us, limit) do
    cond do
      thread_id != "" ->
        {[limit: limit, chat_id: chat_id, thread_id: thread_id, sort_dir: :asc], false}

      is_integer(anchor_us) and anchor_us > 0 ->
        {[
           limit: limit,
           chat_id: chat_id,
           before_us: anchor_us + @read_after_hit_us,
           sort_dir: :desc
         ], true}

      true ->
        {[limit: limit, chat_id: chat_id, sort_dir: :desc], true}
    end
  end

  defp read_slack_mirror(reader, tenant_id, connect, channel, thread_ts, limit) do
    scope = %{
      "tenant_id" => tenant_id,
      "workspace_id" => text(connect["workspace_id"]),
      "channel_id" => channel
    }

    cond do
      thread_ts != "" and function_exported?(reader, :replies, 3) ->
        reader.replies(scope, thread_ts, limit: limit)

      function_exported?(reader, :history, 2) ->
        reader.history(scope, limit: limit)

      true ->
        {:error, :search_unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # Scope classification & routing filters
  # ---------------------------------------------------------------------------

  # The scope ids of one connect a search may return for `target`: not direct,
  # sealed, members-only or tagged (on the scope or its canonical scope), and,
  # where the target Group has information-flow control on, no Slack room that
  # is not a public channel. Without the target's IFC rows only a Group with
  # information-flow control off admits a scope.
  defp allowed_scope_ids(_tenant_id, _target, _provider, _connect_id, []), do: MapSet.new()

  defp allowed_scope_ids(tenant_id, target, provider, connect_id, raw_ids) do
    ids =
      raw_ids
      |> Enum.map(&text/1)
      |> Enum.reject(&(&1 == "" or Projection.direct_scope_id?(&1)))
      |> Enum.uniq()

    room_blocked? = provider == "slack" and target.ifc == true

    if ids == [] do
      MapSet.new()
    else
      case IFCStore.scopes(tenant_id, target.group_id, connect_id, ids) do
        {:ok, stored} ->
          canonicals =
            stored
            |> Map.values()
            |> Enum.map(& &1.canonical_scope_id)
            |> Enum.filter(&(is_binary(&1) and &1 != "" and not Map.has_key?(stored, &1)))
            |> Enum.uniq()

          canonical_rows =
            case canonicals do
              [] ->
                {:ok, %{}}

              list ->
                IFCStore.scopes(tenant_id, target.group_id, connect_id, list)
            end

          case canonical_rows do
            {:ok, canonical_rows} ->
              all_rows = Map.merge(stored, canonical_rows)

              ids
              |> Enum.reject(&scope_row_restricted?(&1, all_rows, room_blocked?))
              |> MapSet.new()

            {:error, _reason} ->
              unavailable_scopes(target, ids)
          end

        {:error, _reason} ->
          unavailable_scopes(target, ids)
      end
    end
  end

  defp unavailable_scopes(%{ifc: true}, _ids), do: MapSet.new()
  defp unavailable_scopes(_target, ids), do: MapSet.new(ids)

  defp restricted_scope?(tenant_id, target, provider, connect_id, scope_id) do
    not MapSet.member?(
      allowed_scope_ids(tenant_id, target, provider, connect_id, [scope_id]),
      scope_id
    )
  end

  defp scope_row_restricted?(scope_id, rows, room_blocked?) do
    row = Map.get(rows, scope_id)
    canonical_id = row && row.canonical_scope_id

    canonical =
      if is_binary(canonical_id) and canonical_id != "",
        do: Map.get(rows, canonical_id),
        else: nil

    Projection.direct_scope_id?(scope_id) or
      (is_binary(canonical_id) and Projection.direct_scope_id?(canonical_id)) or
      row_blocked?(row, room_blocked?) or
      row_blocked?(canonical, room_blocked?)
  end

  defp row_blocked?(nil, _room_blocked?), do: false

  defp row_blocked?(row, room_blocked?) do
    row.kind == "direct" or row.sealed == true or row.audience_mode == "members" or
      List.wrap(row.tags) != [] or (room_blocked? and row.kind == "room")
  end

  defp routed_slack_channel?(connect, channel_id) do
    approved = text(connect["approved_channel_id"])
    approved == "" or approved == channel_id
  end

  defp slack_reader_opts(connect, parsed, limit) do
    channel_id = non_empty(text(parsed.channel_id), text(connect["approved_channel_id"]))

    [
      limit: limit,
      patterns: slack_patterns(parsed.clauses),
      exclude_patterns: Enum.map(parsed.exclude_terms, &like_pattern/1),
      channel_id: if(channel_id == "", do: nil, else: channel_id),
      sort_dir: :desc
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, [], ""] end)
  end

  defp slack_patterns([terms]), do: Enum.map(terms, &like_pattern/1)

  defp slack_patterns(clauses),
    do: Enum.map(clauses, fn terms -> Enum.map(terms, &like_pattern/1) end)

  defp feishu_or_lark_reader("feishu") do
    reader = SystemsRuntime.get_env(:salix_im, :feishu_mirror_reader_mod)

    if FeishuMessageMirror.enabled?() and is_atom(reader) and not is_nil(reader),
      do: {:ok, reader},
      else: {:error, :unavailable}
  end

  defp feishu_or_lark_reader("lark") do
    case LarkMessageRecord.reader() do
      nil -> {:error, :unavailable}
      reader -> {:ok, reader}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation & formatting helpers
  # ---------------------------------------------------------------------------

  defp ensure_configured([]), do: {:error, :no_authorized_groups}
  defp ensure_configured(_groups), do: :ok

  defp select_groups(authorized, args) do
    case value(args, "group_ids") do
      nil ->
        {:ok, authorized}

      [] ->
        {:ok, authorized}

      ids when is_list(ids) ->
        wanted =
          ids
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        by_id = Map.new(authorized, &{&1.group_id, &1})

        if wanted != [] and length(wanted) == length(ids) and
             Enum.all?(wanted, &Map.has_key?(by_id, &1)) do
          {:ok, Enum.map(wanted, &Map.fetch!(by_id, &1))}
        else
          {:error, :unauthorized_group}
        end

      _invalid ->
        {:error, :invalid_group_ids}
    end
  end

  defp find_authorized_group(authorized, group_id) when is_binary(group_id) do
    case Enum.find(authorized, &(&1.group_id == group_id)) do
      %{} = group -> {:ok, group}
      nil -> {:error, :unauthorized_group}
    end
  end

  defp find_authorized_group(_authorized, _group_id), do: {:error, :unauthorized_group}

  defp validate_query(args) do
    q = text(value(args, "query"))

    cond do
      q == "" -> {:error, :query_required}
      byte_size(q) > @max_query_bytes -> {:error, :query_too_long}
      true -> {:ok, q}
    end
  end

  defp validate_limit(args, default, max_val) do
    case value(args, "limit") do
      nil -> {:ok, default}
      n when is_integer(n) and n > 0 -> {:ok, min(n, max_val)}
      _invalid -> {:error, :invalid_limit}
    end
  end

  @doc false
  def encode_hit_id(map) when is_map(map) do
    @hit_prefix <> Base.url_encode64(Jason.encode!(map), padding: false)
  end

  @doc false
  def decode_hit_id(@hit_prefix <> encoded) do
    with {:ok, raw} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"k" => kind, "g" => group_id} = map}
         when is_binary(kind) and is_binary(group_id) <- Jason.decode(raw) do
      {:ok, map}
    else
      _ -> {:error, :invalid_hit_id}
    end
  end

  def decode_hit_id(_other), do: {:error, :invalid_hit_id}

  defp like_pattern(term) do
    "%" <>
      (term
       |> String.replace("\\", "\\\\")
       |> String.replace("%", "\\%")
       |> String.replace("_", "\\_")) <> "%"
  end

  defp group_name(group) do
    non_empty(text(group["name"]), text(group["group_id"]))
  end

  defp task_hit_snippet(hit) do
    content_snippet = get_in(hit, ["content_match", "snippet"])

    truncate_snippet(
      non_empty(text(content_snippet), text(hit["snippet"] || hit["matched_text"]))
    )
  end

  defp truncate_snippet(str) when byte_size(str) <= 320, do: str
  defp truncate_snippet(str), do: String.slice(str, 0, 240) <> "…"

  defp conversation_timestamp_us(record, hit) do
    cond do
      is_integer(record["updated_at"]) and record["updated_at"] > 10_000_000_000_000 ->
        record["updated_at"]

      is_integer(record["updated_at"]) and record["updated_at"] > 1_000_000_000_000 ->
        record["updated_at"] * 1_000

      is_integer(record["updated_at"]) and record["updated_at"] > 0 ->
        record["updated_at"] * 1_000_000

      is_integer(hit["updated_at_us"]) and hit["updated_at_us"] > 0 ->
        hit["updated_at_us"]

      true ->
        0
    end
  end

  defp slack_ts_to_us(ts) do
    case SalixIM.SlackMessageMirror.Row.slack_ts_micros(ts) do
      {:ok, us} -> us
      _ -> 0
    end
  end

  defp iso8601_from_us(us) when is_integer(us) and us > 0 do
    case DateTime.from_unix(us, :microsecond) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp iso8601_from_us(_), do: nil

  defp hit_sort_key(hit), do: {int_or_zero(hit["__sort_us__"]), text(hit["hit_id"])}

  defp put_positive(map, key, value) when is_integer(value) and value > 0,
    do: Map.put(map, key, value)

  defp put_positive(map, _key, _value), do: map

  defp int_or_zero(n) when is_integer(n) and n >= 0, do: n
  defp int_or_zero(_), do: 0

  defp value(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp non_empty("", fallback), do: fallback
  defp non_empty(val, _fallback), do: val

  defp text(nil), do: ""
  defp text(val) when is_binary(val), do: String.trim(val)
  defp text(val), do: val |> to_string() |> String.trim()
end
