defmodule SalixIM.LarkSuiteTriage do
  @moduledoc """
  Feishu and Lark group triage: the Router of a Group reads the ambient
  messages of the group chats an admin chose and decides, once per debounce
  batch, to stay silent, add a reaction, reply in the message's thread, or
  hand an investigation to a Task.

  Slack triage (`SalixIM.Triage.*`) is a separate implementation with its own
  storage; nothing here is shared with it.

  * `observe_ambient/4` is called by `SalixIM.ProviderHTTP` (Feishu) and
    `SalixIM.LarkInbound` (Lark) for a verified group message that is not for
    the Router: no mention of the bot, not a thread the bot joined, not a
    thread bound to a Task. It only stores the message in its batch
    (`SalixStore.LarkSuiteTriage`); it never changes the webhook answer.
  * `process_batch/2` evaluates one claimed batch and applies the decision.
    A reaction, reply or delegation runs only while the source and chat are
    still enabled and no later batch of the same thread is pending; otherwise
    the batch is `stale` and nothing is written to the chat.

  The evaluator is `SalixIM.Ports.LarkSuiteTriageEvaluator`
  (`:lark_suite_triage_evaluator`); the release binds the model call, which
  passes the batch's archive identity to `SalixAgent.LLM.complete/4`.
  """

  require Logger

  alias SalixIM.{
    FeishuThreadTaskBinding,
    GroupDirectory,
    LarkThreadTaskBinding,
    ProviderConnects
  }

  alias SalixIM.Provider.{Feishu, Lark}
  alias SalixStore.LarkSuiteTriage, as: Store

  @silence_reasons ~w(already_handled no_useful_addition insufficient_evidence ambient_chatter)
  @emoji ~w(THUMBSUP OK DONE SMILE)
  @max_reply_bytes 4_000
  @max_title_bytes 200
  @max_prompt_bytes 8_000
  @max_context_messages 10
  @max_context_text_bytes 500
  @max_interactive_text_bytes 2_000
  @max_team_field_bytes 500

  ## Intake

  @doc """
  Stores one ambient group message for triage when its chat is watched.
  Best effort: always `:ok`, whatever the message or the store does.
  """
  @spec observe_ambient(String.t(), map(), map(), map()) :: :ok
  def observe_ambient(provider, connect, message, sender)
      when provider in ["feishu", "lark"] and is_map(connect) and is_map(message) and
             is_map(sender) do
    chat_id = text(message["chat_id"])
    thread_id = text(message["thread_id"])

    # Without the bot's own ID a mention of the bot cannot be told apart from
    # ambient talk, so such a connect's messages are never triaged.
    with true <- connect["owner_only"] != true,
         true <- text(connect["bot_open_id"]) != "",
         true <- text(message["chat_type"]) == "group",
         true <- text(sender["sender_type"]) == "user",
         tenant_id when tenant_id != "" <- text(connect["tenant_id"]),
         connect_id when connect_id != "" <- text(connect["connect_id"]),
         message_id when message_id != "" <- text(message["message_id"]),
         true <- chat_id != "",
         true <- not bound_thread?(provider, connect, chat_id, thread_id),
         {:ok, %{source: source, chat: chat}} <-
           Store.active_source_for_chat(tenant_id, provider, connect_id, chat_id) do
      _ =
        Store.append_ambient_message(
          %{
            tenant_id: tenant_id,
            provider: provider,
            group_id: source.group_id,
            connect_id: connect_id,
            router_agent_id: source.router_agent_id,
            chat_id: chat_id,
            chat_name: chat.chat_name,
            thread_key: thread_id
          },
          %{
            message_id: message_id,
            sender_id: text(get_in(sender, ["sender_id", "open_id"])),
            sender_name: "",
            text: message_text(message),
            sent_at_ms: sent_at_ms(message)
          }
        )

      :ok
    else
      _not_watched -> :ok
    end
  rescue
    exception ->
      Logger.warning("lark_suite_triage_observe_failed #{inspect(exception.__struct__)}")
      :ok
  catch
    _kind, _reason -> :ok
  end

  def observe_ambient(_provider, _connect, _message, _sender), do: :ok

  defp bound_thread?(_provider, _connect, _chat_id, ""), do: false

  defp bound_thread?("feishu", connect, chat_id, thread_id),
    do: FeishuThreadTaskBinding.active_binding(connect, chat_id, thread_id) != :none

  defp bound_thread?("lark", connect, chat_id, thread_id),
    do: LarkThreadTaskBinding.active_binding(connect, chat_id, thread_id) != :none

  @doc false
  # The readable text of a Feishu or Lark message: text and rich-text (post)
  # content, mention keys replaced by the mentioned names; any other message
  # type is named by its type.
  def message_text(message) do
    mentions =
      for mention <- List.wrap(message["mentions"]),
          is_map(mention),
          key = text(mention["key"]),
          key != "",
          do: {key, "@" <> text(mention["name"])}

    content =
      case Jason.decode(text(message["content"])) do
        {:ok, %{} = content} -> content
        _invalid -> %{}
      end

    body =
      case text(message["message_type"] || message["msg_type"]) do
        "text" -> text(content["text"])
        "post" -> post_text(content)
        "interactive" -> interactive_text(content)
        "" -> text(content["text"])
        type -> "[#{type}]"
      end

    Enum.reduce(mentions, body, fn {key, name}, acc -> String.replace(acc, key, name) end)
  end

  defp interactive_text(content) when is_map(content) do
    title =
      case content do
        %{"header" => %{"title" => title_node}} -> collect_card_text(title_node)
        %{"title" => t} when is_binary(t) -> [String.trim(t)]
        _ -> []
      end

    body =
      content
      |> Map.drop(["header", "title"])
      |> collect_card_text()

    text =
      (title ++ body)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> bounded(@max_interactive_text_bytes)

    if text == "", do: "[interactive]", else: text
  end

  defp collect_card_text(%{"tag" => tag, "content" => value})
       when tag in ["markdown", "lark_md", "plain_text"] and is_binary(value),
       do: [value]

  defp collect_card_text(%{"tag" => tag, "text" => value})
       when tag in ["text", "a", "markdown", "lark_md", "plain_text"] and is_binary(value),
       do: [value]

  defp collect_card_text(%{"tag" => "at", "user_name" => name}) when is_binary(name),
    do: ["@" <> name]

  defp collect_card_text(%{"tag" => "div"} = node) do
    collect_card_text(node["text"]) ++ collect_card_text(node["fields"])
  end

  defp collect_card_text(%{} = node) do
    Enum.flat_map(
      ~w(title header body elements fields columns text content),
      fn key ->
        case Map.get(node, key) do
          value when is_binary(value) and key == "content" -> [value]
          value when is_map(value) or is_list(value) -> collect_card_text(value)
          _ -> []
        end
      end
    )
  end

  defp collect_card_text(list) when is_list(list),
    do: Enum.flat_map(list, &collect_card_text/1)

  defp collect_card_text(_other), do: []

  defp post_text(content) do
    post =
      case content do
        %{"content" => _} -> content
        other -> other |> Map.values() |> Enum.find(%{}, &is_map/1)
      end

    title = text(post["title"])

    lines =
      for line <- List.wrap(post["content"]), is_list(line) do
        Enum.map_join(line, "", fn
          %{"tag" => "text", "text" => value} -> to_string(value)
          %{"tag" => "a", "text" => value} -> to_string(value)
          %{"tag" => "at", "user_name" => name} -> "@" <> to_string(name)
          %{"tag" => "code_block", "text" => value} -> to_string(value)
          _other -> ""
        end)
      end

    [title | lines] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  defp sent_at_ms(message) do
    case Integer.parse(text(message["create_time"])) do
      {ms, ""} when ms > 0 -> ms
      _missing -> SystemsClock.system_time(:millisecond)
    end
  end

  ## Evaluation and effects

  @doc """
  Evaluates one claimed batch and applies its decision. Returns the outcome
  stored with `SalixStore.LarkSuiteTriage.complete_batch/4`. `opts`:
  `:evaluator`, `:task_delegator`, `:provider_call` (tests), `:now`.
  """
  @spec process_batch(map(), keyword()) :: map()
  def process_batch(batch, opts \\ []) do
    with {:ok, connect} <- connect(batch),
         true <- active?(batch) || {:stale, "source_disabled"},
         batch = with_sender_names(batch, connect, opts),
         recent_context = recent_context(batch, connect, opts),
         team_context = team_context(batch),
         {:ok, decision} <- evaluate(batch, recent_context, team_context, opts),
         {:ok, decision} <- validate(decision) do
      apply_decision(batch, connect, decision, opts)
      |> Map.put(:messages_json, batch.messages_json)
    else
      {:stale, reason} -> %{state: "stale", reason_code: reason}
      {:error, code} when is_binary(code) -> %{state: "failed", error_code: code}
    end
  rescue
    exception ->
      Logger.warning("lark_suite_triage_batch_failed #{inspect(exception.__struct__)}")
      %{state: "failed", error_code: "internal_error"}
  end

  defp connect(batch) do
    case ProviderConnects.get_active_connect_by_id(
           batch.group_id,
           batch.connect_id,
           batch.provider
         ) do
      {:ok, %{"tenant_id" => tenant_id} = connect} when tenant_id == batch.tenant_id ->
        {:ok, connect}

      _missing ->
        {:error, "connect_unavailable"}
    end
  end

  defp active?(batch) do
    case Store.active_source_for_chat(
           batch.tenant_id,
           batch.provider,
           batch.connect_id,
           batch.chat_id
         ) do
      {:ok, %{source: %{router_agent_id: router}}} -> router == batch.router_agent_id
      _inactive -> false
    end
  end

  # The evaluator, the timeline and the audited reveal show who wrote each
  # message. At most one directory read per distinct sender of the batch.
  defp with_sender_names(batch, connect, opts) do
    names =
      batch.messages_json
      |> Enum.map(& &1["sender_id"])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Map.new(fn open_id -> {open_id, user_name(batch, connect, open_id, opts)} end)

    messages =
      Enum.map(batch.messages_json, fn message ->
        case names[message["sender_id"]] do
          name when is_binary(name) and name != "" -> Map.put(message, "sender_name", name)
          _unknown -> message
        end
      end)

    %{batch | messages_json: messages}
  end

  defp user_name(batch, connect, open_id, opts) do
    case call(batch, connect, "get_user", %{"user_id" => open_id}, opts) do
      {:ok, %{"user" => %{} = user}} -> text(user["name"])
      _unreadable -> ""
    end
  end

  defp recent_context(batch, connect, opts) do
    raw_messages = fetch_recent_messages(batch, connect, opts)
    batch_ids = MapSet.new(List.wrap(batch.message_ids))

    earliest_ms =
      batch.messages_json
      |> Enum.map(& &1["sent_at_ms"])
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.min(fn -> 0 end)

    raw_messages
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&(&1["deleted"] == true))
    |> Enum.map(&normalize_context_message/1)
    |> Enum.reject(fn msg ->
      msg["message_id"] == "" or
        MapSet.member?(batch_ids, msg["message_id"]) or
        msg["text"] == "" or
        (earliest_ms > 0 and msg["sent_at_ms"] > earliest_ms)
    end)
    |> Enum.sort_by(&{&1["sent_at_ms"], &1["message_id"]})
    |> Enum.take(-@max_context_messages)
  rescue
    _exception -> []
  catch
    _kind, _reason -> []
  end

  defp fetch_recent_messages(batch, connect, opts) do
    page_params = %{"page_size" => 20, "sort_type" => "ByCreateTimeDesc"}

    if batch.thread_key != "" do
      case call(
             batch,
             connect,
             "get_thread_replies",
             Map.put(page_params, "thread_id", batch.thread_key),
             opts
           ) do
        {:ok, %{"messages" => msgs}} when is_list(msgs) and msgs != [] ->
          msgs

        _fallback ->
          fetch_chat_history(batch, connect, page_params, opts)
      end
    else
      fetch_chat_history(batch, connect, page_params, opts)
    end
  end

  defp fetch_chat_history(batch, connect, page_params, opts) do
    case call(
           batch,
           connect,
           "get_chat_history",
           Map.put(page_params, "chat_id", batch.chat_id),
           opts
         ) do
      {:ok, %{"messages" => msgs}} when is_list(msgs) -> msgs
      _unreadable -> []
    end
  end

  defp normalize_context_message(msg) do
    sent_at_ms =
      cond do
        is_integer(msg["sent_at_ms"]) and msg["sent_at_ms"] > 0 ->
          msg["sent_at_ms"]

        true ->
          case Integer.parse(text(msg["create_time"])) do
            {ms, ""} when ms > 0 -> ms
            _ -> 0
          end
      end

    sender_name =
      case text(msg["sender_name"]) do
        "" -> text(get_in(msg, ["sender", "name"]))
        name -> name
      end

    raw_text =
      case text(msg["text"]) do
        "" -> ""
        value -> value |> Store.redact() |> bounded(@max_context_text_bytes)
      end

    %{
      "message_id" => text(msg["message_id"]),
      "sender_name" => sender_name,
      "text" => raw_text,
      "sent_at_ms" => sent_at_ms
    }
  end

  defp team_context(batch) do
    case GroupDirectory.get_group(batch.group_id, batch.tenant_id) do
      {:ok, %{} = group} ->
        ctx =
          %{}
          |> maybe_put_text("name", group["name"], @max_team_field_bytes)
          |> maybe_put_text("description", group["description"], @max_team_field_bytes)

        if map_size(ctx) > 0, do: ctx, else: nil

      _unavailable ->
        nil
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp maybe_put_text(map, key, value, max_bytes) do
    case text(value) do
      "" -> map
      present -> Map.put(map, key, bounded(present, max_bytes))
    end
  end

  defp evaluate(batch, recent_context, team_context, opts) do
    evaluator =
      Keyword.get_lazy(opts, :evaluator, fn ->
        SystemsRuntime.get_env(:salix_im, :lark_suite_triage_evaluator, __MODULE__.Unconfigured)
      end)

    request =
      %{
        "provider" => batch.provider,
        "chat_name" => batch.chat_name,
        "in_thread" => batch.thread_key != "",
        "target_message_id" => batch.target_message_id,
        "recent_context" => recent_context,
        "messages" =>
          Enum.map(
            batch.messages_json,
            &Map.take(&1, ~w(message_id sender_name text sent_at_ms))
          ),
        "allowed_emoji" => @emoji,
        "silence_reasons" => @silence_reasons
      }
      |> then(&if(is_map(team_context), do: Map.put(&1, "team_context", team_context), else: &1))

    case evaluator.evaluate(request, identity(batch)) do
      {:ok, %{} = decision} -> {:ok, decision}
      _error -> {:error, "evaluation_failed"}
    end
  end

  @doc "The archive identity of a batch's model call (`SalixAgent.LLM.complete/4`)."
  @spec identity(map()) :: map()
  def identity(batch),
    do: %{
      tenant_id: batch.tenant_id,
      group_id: batch.group_id,
      agent_id: batch.router_agent_id,
      session_id: "lark_suite_triage:#{batch.connect_id}:#{batch.id}",
      round_id: batch.id
    }

  @doc false
  def validate(%{"kind" => "silence"} = decision) do
    reason = text(decision["reason_code"])

    if reason in @silence_reasons,
      do: {:ok, %{kind: "silence", reason_code: reason}},
      else: {:error, "invalid_decision"}
  end

  def validate(%{"kind" => "reaction"} = decision) do
    emoji = decision["emoji_type"] |> text() |> String.upcase()

    if emoji in @emoji,
      do: {:ok, %{kind: "reaction", emoji_type: emoji}},
      else: {:error, "invalid_decision"}
  end

  def validate(%{"kind" => "reply"} = decision) do
    reply = text(decision["text"])

    if reply != "" and byte_size(reply) <= @max_reply_bytes,
      do: {:ok, %{kind: "reply", text: reply}},
      else: {:error, "invalid_decision"}
  end

  def validate(%{"kind" => "delegate"} = decision) do
    title = text(decision["task_title"])
    prompt = text(decision["task_prompt"])

    if title != "" and prompt != "" and byte_size(title) <= @max_title_bytes and
         byte_size(prompt) <= @max_prompt_bytes,
       do: {:ok, %{kind: "delegate", task_title: title, task_prompt: prompt}},
       else: {:error, "invalid_decision"}
  end

  def validate(_decision), do: {:error, "invalid_decision"}

  defp apply_decision(_batch, _connect, %{kind: "silence", reason_code: reason}, _opts),
    do: %{state: "applied", decision_kind: "silence", reason_code: reason}

  defp apply_decision(batch, connect, decision, opts) do
    if fresh?(batch),
      do: effect(batch, connect, decision, opts),
      else: %{state: "stale", decision_kind: decision.kind, reason_code: "superseded"}
  end

  # A person may have written again, or an admin paused the chat, while the
  # model thought: then nothing is written to the chat.
  defp fresh?(batch), do: active?(batch) and not Store.newer_pending?(batch)

  defp effect(batch, connect, %{kind: "reaction", emoji_type: emoji}, opts) do
    params = %{"message_id" => batch.target_message_id, "emoji_type" => emoji}

    case call(batch, connect, "add_reaction", params, opts) do
      {:ok, _reaction} ->
        %{state: "applied", decision_kind: "reaction", reaction_emoji: emoji}

      {:error, _reason} ->
        %{
          state: "failed",
          decision_kind: "reaction",
          reaction_emoji: emoji,
          error_code: "provider_error"
        }
    end
  end

  defp effect(batch, connect, %{kind: "reply", text: reply}, opts) do
    params = %{
      "chat_id" => batch.chat_id,
      "reply_to" => batch.target_message_id,
      "reply_in_thread" => true,
      "text" => reply
    }

    case call(batch, connect, "send_message", params, opts) do
      {:ok, _sent} ->
        %{state: "applied", decision_kind: "reply", reply_text: reply}

      {:error, _reason} ->
        %{
          state: "failed",
          decision_kind: "reply",
          reply_text: reply,
          error_code: "provider_error"
        }
    end
  end

  defp effect(batch, connect, %{kind: "delegate"} = decision, opts) do
    delegator = Keyword.get(opts, :task_delegator, __MODULE__.TaskDelegator)
    base = %{decision_kind: "delegate", task_title: decision.task_title}

    result =
      if function_exported?(delegator, :delegate, 4),
        do: delegator.delegate(batch, connect, decision, opts),
        else: delegator.delegate(batch, connect, decision)

    case result do
      {:ok, conversation_id} when is_binary(conversation_id) ->
        Map.merge(base, %{state: "applied", task_conversation_id: conversation_id})

      {:error, :worker_unavailable} ->
        Map.merge(base, %{state: "applied", reason_code: "worker_unavailable"})

      _error ->
        Map.merge(base, %{state: "failed", error_code: "delegation_failed"})
    end
  end

  @doc false
  def provider_call(batch, connect, operation, params, opts),
    do: call(batch, connect, operation, params, opts)

  defp call(batch, connect, operation, params, opts) do
    scope = %{tool_call_id: "lark-triage:" <> batch.id}

    case Keyword.get(opts, :provider_call) do
      fun when is_function(fun, 5) ->
        fun.(batch.provider, batch.router_agent_id, connect, operation, params)

      nil ->
        module = if batch.provider == "feishu", do: Feishu, else: Lark

        module.call(
          batch.router_agent_id,
          connect,
          batch.provider <> "." <> operation,
          params,
          scope
        )
    end
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: ""

  defp bounded(value, max) when is_binary(value) do
    if byte_size(value) <= max,
      do: value,
      else: value |> binary_part(0, max) |> String.chunk(:valid) |> hd()
  end

  defp bounded(_value, _max), do: ""

  defmodule Unconfigured do
    @moduledoc false
    def evaluate(_request, _identity), do: {:error, :evaluator_unconfigured}
  end

  defmodule TaskDelegator do
    @moduledoc """
    Hands a triage investigation to the Group's Task agent through
    `SalixIM.TaskPlacement`, at the Group's default place and default Task
    model (no place is named here), then binds the source thread to the Task
    so later replies there reach it. For a top-level message (`thread_key == ""`),
    opens a thread with a brief receipt after Task creation succeeds and binds
    the new thread to the Task. A Group without a Task agent gets no Task and
    no message.
    """

    require Logger

    alias SalixIM.{FeishuThreadTaskBinding, LarkThreadTaskBinding, TaskPlacement}

    @spec delegate(map(), map(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
    def delegate(batch, connect, decision, opts \\ []) do
      attrs = %{
        "title" => decision.task_title,
        "content" => decision.task_prompt <> "\n\n" <> source(batch),
        "client_request_id" => "lark-triage:" <> batch.id,
        "source_refs" => %{"origin_agent_id" => batch.router_agent_id}
      }

      case TaskPlacement.create_task_conversation(batch.group_id, batch.router_agent_id, attrs) do
        {:ok, %{"conversation_id" => conversation_id}} ->
          bind_or_open_thread(batch, connect, conversation_id, opts)
          {:ok, conversation_id}

        {:error, {:task_worker, _reason}} ->
          {:error, :worker_unavailable}

        {:error, _reason} = error ->
          error
      end
    end

    @doc false
    def source(batch) do
      platform = if batch.provider == "feishu", do: "Feishu", else: "Lark"

      [
        "Source: #{platform} group chat",
        if(batch.chat_name != "", do: " \"#{batch.chat_name}\""),
        " (chat_id #{batch.chat_id}, connect_id #{batch.connect_id}),",
        " message #{batch.target_message_id}",
        if(batch.thread_key != "", do: ", thread #{batch.thread_key}"),
        "."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()
    end

    defp bind_or_open_thread(%{thread_key: ""} = batch, connect, conversation_id, opts) do
      params = %{
        "chat_id" => batch.chat_id,
        "reply_to" => batch.target_message_id,
        "reply_in_thread" => true,
        "text" => receipt_text(batch)
      }

      case SalixIM.LarkSuiteTriage.provider_call(batch, connect, "send_message", params, opts) do
        {:ok, %{} = sent} ->
          thread_id = extract_text(get_in(sent, ["message", "thread_id"]) || sent["thread_id"])
          receipt_id = extract_text(get_in(sent, ["message", "message_id"]) || sent["message_id"])

          if thread_id != "" do
            bind_message_id = if(receipt_id != "", do: receipt_id, else: batch.target_message_id)
            bind(batch, connect, conversation_id, thread_id, bind_message_id, opts)
          else
            Logger.warning(
              "lark_suite_triage_delegate_receipt_missing_thread provider=#{batch.provider}"
            )

            :ok
          end

        {:error, _reason} ->
          Logger.warning("lark_suite_triage_delegate_receipt_failed provider=#{batch.provider}")
          :ok
      end
    rescue
      _exception ->
        Logger.warning("lark_suite_triage_delegate_receipt_failed provider=#{batch.provider}")
        :ok
    end

    defp bind_or_open_thread(batch, connect, conversation_id, opts) do
      bind(batch, connect, conversation_id, batch.thread_key, batch.target_message_id, opts)
    end

    defp receipt_text(%{provider: "feishu"}),
      do: "收到，我来跟进排查，进展会同步在这个话题里。"

    defp receipt_text(_batch),
      do: "Got it, I'll look into this and follow up in this thread."

    defp extract_text(value) when is_binary(value), do: String.trim(value)
    defp extract_text(_value), do: ""

    defp bind(batch, connect, conversation_id, thread_id, message_id, opts) do
      scope = %{
        agent: %{"role" => "router"},
        agent_id: batch.router_agent_id,
        tenant_id: batch.tenant_id,
        group_id: batch.group_id
      }

      params = %{
        "conversation_id" => conversation_id,
        "chat_id" => batch.chat_id,
        "thread_id" => thread_id,
        "message_id" => message_id
      }

      case Keyword.get(opts, :thread_binder) do
        fun when is_function(fun, 4) ->
          _ = fun.(batch.provider, scope, connect, params)

        nil ->
          module =
            if batch.provider == "feishu",
              do: FeishuThreadTaskBinding,
              else: LarkThreadTaskBinding

          _ = module.bind_thread_to_task(scope, connect, params)
      end

      :ok
    rescue
      _exception -> :ok
    end
  end
end
