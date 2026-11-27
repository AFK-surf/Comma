defmodule SalixIM.StationTaskQuestionSync do
  @moduledoc """
  Deterministic Home card projection and bidirectional sync for station-hosted
  still.fail chats (`station:<station_id>:<thread>`).

  `build_home_notification/2` converts an admitted still.fail stop directly into
  Home message content blocks and server-only `metadata["station_task_question"]`
  binding (no Router LLM involvement):
  - `options` cards (1..6 choices) on CAS-capable stations (`task_say_cas: 1`)
    render as server-marked `independent: true` clickable question cards with
    `skip_behavior: "dismiss"` and persisted `card_seq` / `observation_id`.
  - `options` cards on older stations without `task_say_cas: 1` fail closed to
    a direct link.
  - `text` cards and expiring system cards (`login`, `secret`, `vault`,
    `signin`, `device`, `adb`, `rig`) render as concise direct-link notices.
  - `done` and `failed` stops render from index fields with zero station RPCs.

  When the user answers a bound card in Home, `prepare_user_answer/3` forwards
  the answer straight to the station with `expected_card_seq` CAS (and
  `close_card: true` for `action: "close"` options), rejects stale cards without
  mutating newer questions, and folds dismissed cards locally without hiding
  them from Routine. Conversely, when a stop moves on or leaves in still.fail,
  `resolve_stillfail_answer/3` folds the bound Home card by exact `card_seq`.
  """

  alias SalixIM.{
    ConversationQuestion,
    Conversations,
    GroupDirectory,
    RouterConversationInput
  }

  alias SalixIM.Ports.StationHostedTasks

  @urgent_system_cards ~w(login secret vault signin device adb rig)
  @max_prompt_bytes 1_800
  @max_body_bytes 2_400
  @max_router_excerpt_bytes 1_200

  @doc """
  Builds Home message content blocks and server-only binding metadata for an
  admitted still.fail stop.

  Returns:
  - `{:ok, %{content: list(), metadata: map(), kind: String.t(), card_seq: integer() | nil, router_context: map(), advise_router: boolean()}}`
  - `:already_resolved` when fetched station messages show the card is already
    answered or closed
  """
  @spec build_home_notification(map(), keyword()) ::
          {:ok, map()} | :already_resolved
  def build_home_notification(stop, opts \\ []) when is_map(stop) do
    kind = to_string(stop[:kind] || stop["kind"] || "need")
    card_kind = stop[:card_kind] || stop["card_kind"]
    zh? = zh_locale?(stop[:locale] || stop["locale"])
    attachments = normalize_attachments(Keyword.get(opts, :attachments, []))

    cond do
      kind == "need" and card_kind == "options" ->
        build_options_notification(stop, Keyword.get(opts, :messages, []), attachments, zh?)

      kind == "need" and card_kind == "text" ->
        build_text_card_notification(stop, Keyword.get(opts, :messages, []), attachments, zh?)

      kind == "need" and card_kind in @urgent_system_cards ->
        {:ok, build_system_card_notification(stop, card_kind, zh?)}

      true ->
        {:ok, build_plain_notification(stop, kind, zh?)}
    end
  end

  defp build_options_notification(stop, messages, attachments, zh?) do
    ref = stop[:ref] || stop["ref"]
    obs = stop[:observation] || stop["observation"]
    title = stop[:title] || stop["title"] || ref
    url = stop[:url] || stop["url"]
    note = non_blank(stop[:note] || stop["note"])
    cas_supported? = (stop[:cas_supported?] || stop["cas_supported?"]) == true
    staged_names = staged_file_names(attachments)

    case pending_card_message(messages, "options") do
      :already_resolved ->
        :already_resolved

      {:pending, card_msg, card} ->
        raw_options = List.wrap(card["options"])
        choices = map_stillfail_choices(raw_options)
        prompt = truncate_bytes(note || fixed_line("need", zh?), @max_prompt_bytes)
        body = excerpt_message_body(card_msg["text"], prompt, @max_body_bytes, zh?, staged_names)

        router_context =
          %{
            "prompt" => prompt,
            "choices" => Enum.map(choices, & &1["label"])
          }
          |> maybe_put(
            "excerpt",
            excerpt_message_body(card_msg["text"], nil, @max_router_excerpt_bytes, zh?)
          )
          |> maybe_put("url", non_blank(url))

        if cas_supported? and length(choices) in 1..6 do
          question = %{
            "type" => "question",
            "prompt" => prompt,
            "choices" => choices,
            "multi_select" => false,
            "allow_other" => true,
            "skip_behavior" => "dismiss"
          }

          header_text =
            if is_binary(body),
              do: title_link(title, url) <> "\n\n" <> body,
              else: title_link(title, url)

          header_block = %{"type" => "text", "text" => header_text}

          case ConversationQuestion.normalize_agent_content(
                 [header_block] ++ attachments ++ [question]
               ) do
            {:ok, normalized} ->
              content = ConversationQuestion.mark_independent(normalized)
              close_choice_ids = extract_close_choice_ids(content)

              binding =
                %{
                  "conversation_id" => ref,
                  "close_choice_ids" => close_choice_ids
                }
                |> maybe_put("observation_id", obs)
                |> maybe_put("card_seq", card_msg["seq"])

              {:ok,
               %{
                 content: content,
                 metadata: %{"station_task_question" => binding},
                 kind: "need",
                 card_seq: card_msg["seq"],
                 router_context: router_context,
                 advise_router: true
               }}

            {:error, _} ->
              {:ok,
               build_options_link_only(title, url, note, body, router_context, attachments, zh?)}
          end
        else
          # Un-upgraded station without atomic `task_say_cas: 1` (or invalid options):
          # fail closed to a direct source link instead of emitting an unprotected card.
          {:ok, build_options_link_only(title, url, note, body, router_context, attachments, zh?)}
        end
    end
  end

  defp build_options_link_only(title, url, note, body, router_context, attachments, zh?) do
    summary = note || fixed_line("need", zh?)

    hint =
      if zh?,
        do: "请在 still.fail 中打开并选择。",
        else: "Open in still.fail to choose an option."

    text =
      [title_link(title, url), body, summary, hint]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    %{
      content: [%{"type" => "text", "text" => text}] ++ attachments,
      metadata: %{},
      kind: "need",
      card_seq: nil,
      router_context: router_context,
      advise_router: true
    }
  end

  defp build_text_card_notification(stop, messages, attachments, zh?) do
    title = stop[:title] || stop["title"] || stop[:ref] || stop["ref"]
    url = stop[:url] || stop["url"]
    note = non_blank(stop[:note] || stop["note"])
    staged_names = staged_file_names(attachments)

    case pending_card_message(messages, "text") do
      :already_resolved ->
        :already_resolved

      {:pending, card_msg, card} ->
        placeholder = non_blank(card["placeholder"])
        summary = note || fixed_line("need", zh?)
        body = excerpt_message_body(card_msg["text"], summary, @max_body_bytes, zh?, staged_names)

        hint =
          cond do
            is_binary(placeholder) and zh? ->
              "需要填写：#{placeholder}（请点击上方链接在 still.fail 中填写）"

            is_binary(placeholder) ->
              "Input requested: #{placeholder} (open the link above to fill in still.fail)"

            zh? ->
              "请点击上方链接在 still.fail 中填写。"

            true ->
              "Open the link above to fill in still.fail."
          end

        text =
          [title_link(title, url), body, summary, hint]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n\n")

        router_context =
          %{"prompt" => truncate_bytes(summary, @max_prompt_bytes)}
          |> maybe_put(
            "excerpt",
            excerpt_message_body(card_msg["text"], nil, @max_router_excerpt_bytes, zh?)
          )
          |> maybe_put("placeholder", placeholder)
          |> maybe_put("url", non_blank(url))

        {:ok,
         %{
           content: [%{"type" => "text", "text" => text}] ++ attachments,
           metadata: %{},
           kind: "need",
           card_seq: nil,
           router_context: router_context,
           advise_router: true
         }}
    end
  end

  # Expiring system cards (login, vault/secret, sign-in, device/rig): never copy
  # `note` verbatim in case it includes sensitive codes or prompt text.
  defp build_system_card_notification(stop, card_kind, zh?) do
    title = stop[:title] || stop["title"] || stop[:ref] || stop["ref"]
    url = stop[:url] || stop["url"]
    label = system_card_label(card_kind, zh?)

    body =
      if zh?,
        do: "需要你在 still.fail 中完成「#{label}」，请点击上方链接直接操作。",
        else: "Action required in still.fail (#{label}). Open the link above to complete it."

    text = Enum.join([title_link(title, url), body], "\n")

    router_context =
      %{"card_kind" => card_kind}
      |> maybe_put("url", non_blank(url))

    %{
      content: [%{"type" => "text", "text" => text}],
      metadata: %{},
      kind: "need",
      card_seq: nil,
      router_context: router_context,
      advise_router: false
    }
  end

  defp build_plain_notification(stop, kind, zh?) do
    title = stop[:title] || stop["title"] || stop[:ref] || stop["ref"]
    url = stop[:url] || stop["url"]
    note = non_blank(stop[:note] || stop["note"])
    summary = format_plain_summary(kind, note, zh?)
    text = Enum.join([title_link(title, url), summary], "\n")

    router_context =
      %{"excerpt" => truncate_bytes_with_ellipsis(summary, @max_router_excerpt_bytes)}
      |> maybe_put("url", non_blank(url))

    %{
      content: [%{"type" => "text", "text" => text}],
      metadata: %{},
      kind: kind,
      card_seq: nil,
      router_context: router_context,
      advise_router: false
    }
  end

  defp format_plain_summary("failed", note, zh?), do: sanitize_failed_note(note, zh?)

  defp format_plain_summary("done", note, zh?) do
    prefix = if zh?, do: "已完成：", else: "Completed: "

    case note do
      nil -> fixed_line("done", zh?)
      text -> prefix <> text
    end
  end

  defp format_plain_summary(kind, note, zh?) do
    prefix = if zh?, do: "等待处理：", else: "Waiting for you: "

    case note do
      nil -> fixed_line(kind, zh?)
      text -> prefix <> text
    end
  end

  # Never dump raw OAuth/HTTP/stack error text into Home chat: classify common
  # runtime failures into concise actionable lines and prefix clean notes.
  defp sanitize_failed_note(nil, zh?), do: fixed_line("failed", zh?)

  defp sanitize_failed_note(note, zh?) when is_binary(note) do
    cond do
      Regex.match?(
        ~r/UNAUTHENTICATED|invalid authentication credentials|OAuth\s*2|\bcode\s*40[13]\b|\b401\b|\b403\b|expired token|token expired|login cookie/i,
        note
      ) ->
        if zh?,
          do: "运行中止：账号认证已失效，请点击上方链接在 still.fail 中重新登录或重试。",
          else:
            "Run stopped: authentication expired. Open the link above in still.fail to sign in or retry."

      Regex.match?(
        ~r/ECONNRESET|ETIMEDOUT|ECONNREFUSED|EHOSTUNREACH|Connection dropped|Request timed out|socket hang up/i,
        note
      ) ->
        if zh?,
          do: "运行中断：网络连接异常，请点击上方链接在 still.fail 中重试。",
          else:
            "Run interrupted: network connection failed. Open the link above in still.fail to retry."

      Regex.match?(
        ~r/https?:\/\/|Traceback|\bException\b|\bError:\s|\bstatus\s*5\d\d\b|\bcode\s*5\d\d\b|stack\s*trace/i,
        note
      ) or String.contains?(note, "\n") ->
        if zh?,
          do: "运行失败，请点击上方链接在 still.fail 中查看详情并重试。",
          else: "Run failed. Open the link above in still.fail to view details or retry."

      true ->
        prefix = if zh?, do: "运行失败：", else: "Failed: "
        prefix <> truncate_bytes_with_ellipsis(note, 240)
    end
  end

  @doc false
  def pending_card_message(messages, card_type) when is_list(messages) do
    sorted = Enum.sort_by(messages, &(&1["seq"] || 0), :asc)

    latest =
      sorted
      |> Enum.reverse()
      |> Enum.find(fn m ->
        m["author_kind"] == "agent" and is_map(m["card"]) and m["card"]["type"] == card_type
      end)

    case latest do
      %{"seq" => seq, "card" => card} when is_integer(seq) and is_map(card) ->
        answered_in_card? = card["closed"] == true or is_binary(non_blank(card["choice"]))

        person_after? =
          Enum.any?(sorted, fn m ->
            m["author_kind"] == "person" and (m["seq"] || 0) > seq
          end)

        newer_card? =
          Enum.any?(sorted, fn m ->
            m["author_kind"] == "agent" and (m["seq"] || 0) > seq and is_map(m["card"])
          end)

        if answered_in_card? or person_after? or newer_card?,
          do: :already_resolved,
          else: {:pending, latest, card}

      _ ->
        :already_resolved
    end
  end

  def pending_card_message(_messages, _card_type), do: :already_resolved

  defp map_stillfail_choices(raw_options) do
    raw_options
    |> Enum.take(6)
    |> Enum.flat_map(fn
      %{"label" => label} = opt ->
        case non_blank(label) do
          nil ->
            []

          clean_label ->
            [
              %{"label" => clean_label}
              |> maybe_put("description", non_blank(opt["detail"]))
              |> then(
                &if(opt["recommended"] == true, do: Map.put(&1, "recommended", true), else: &1)
              )
              |> then(&if(opt["action"] == "close", do: Map.put(&1, "action", "close"), else: &1))
            ]
        end

      _ ->
        []
    end)
  end

  defp extract_close_choice_ids(content) do
    case ConversationQuestion.question_block(content) do
      %{"choices" => choices} when is_list(choices) ->
        for %{"id" => id, "action" => "close"} when is_binary(id) <- choices, do: id

      _ ->
        []
    end
  end

  @doc """
  Handles a Home user `question_answer` replying to a still.fail-bound card
  before the message is committed to `ConversationActor`.

  Returns:
  - `:passthrough` when the message is not answering a bound still.fail card
  - `{:handled, sync_info, extra_metadata}` when handled directly without waking
    the Router (dismissed locally, or forwarded cleanly to still.fail)
  - `{:stale_card, ref, question_id, binding}` when the station rejected the
    CAS check (`stale_card`) because the card was already answered or replaced
  - `{:fallback_to_router, extra_metadata}` when forwarding failed (for example,
    the station is offline) so the Router wakes and informs the user
  """
  @spec prepare_user_answer(String.t(), map(), map()) ::
          :passthrough
          | {:handled, term(), map()}
          | {:stale_card, String.t(), String.t(), map()}
          | {:fallback_to_router, map()}
  def prepare_user_answer(group_id, conversation, attrs)
      when is_binary(group_id) and is_map(conversation) and is_map(attrs) do
    with %{} = answer <- ConversationQuestion.answer_block(attrs["content"]),
         false <- get_in(attrs, ["metadata", "resolved_in_stillfail"]) == true,
         question_id when is_binary(question_id) <- answer["question_message_id"],
         {:ok, question_message} <-
           Conversations.get_group_conversation_message(
             group_id,
             conversation["conversation_id"],
             question_id
           ),
         %{"conversation_id" => ref} = binding <-
           get_in(question_message, ["metadata", "station_task_question"]),
         {station_id, thread} <- StationHostedTasks.parse(ref),
         :ok <- ConversationQuestion.admit_answer(answer, question_message) do
      if answer["skipped"] == true do
        {:handled, {:dismissed, ref, question_id}, %{"dismissed_station_task" => ref}}
      else
        forward_answer(
          group_id,
          conversation,
          attrs,
          answer,
          question_message,
          binding,
          ref,
          station_id,
          thread
        )
      end
    else
      _ -> :passthrough
    end
  end

  def prepare_user_answer(_group_id, _conversation, _attrs), do: :passthrough

  @doc """
  Finalizes side effects once a directly handled answer or dismiss commits in
  Home:
  - Forwarded answers close the proactive matter and stage a compact 1-line
    `no_wake` Router context update.
  - Dismissed cards fold only in Home (keeping the stop open in Routine) and
    stage a compact 1-line `no_wake` Router context update.
  """
  @spec after_commit(String.t(), term()) :: :ok
  def after_commit(group_id, {:forwarded, ref, seq, question_id, reply_text})
      when is_binary(group_id) and is_binary(ref) do
    notify_observer(group_id, ref, seq)

    stage_router_context(group_id, "station-ans:" <> question_id, %{
      "event" => "station_card_answered",
      "ref" => ref,
      "msg_id" => question_id,
      "seq" => seq,
      "choice" => String.slice(reply_text || "", 0, 120)
    })

    :ok
  end

  def after_commit(group_id, {:dismissed, ref, question_id})
      when is_binary(group_id) and is_binary(ref) do
    # Dismissing a Home card folds it locally while keeping the still-open
    # still.fail stop visible in Routine.
    stage_router_context(group_id, "station-dis:" <> question_id, %{
      "event" => "station_card_dismissed",
      "ref" => ref,
      "msg_id" => question_id
    })

    :ok
  end

  def after_commit(_group_id, _sync_info), do: :ok

  @doc """
  Folds a Home card whose station CAS check returned `stale_card`, reading the
  station by `card_seq` when reachable and appending a non-waking resolved
  receipt without applying the user's stale click.

  If the Home card already has a committed `question_answer`, returns that
  existing message id without appending a duplicate receipt.
  """
  @spec fold_stale_card(String.t(), String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fold_stale_card(group_id, home_id, user_id, question_id, binding, opts \\ [])
      when is_binary(group_id) and is_binary(home_id) and is_binary(question_id) and
             is_map(binding) do
    ref = binding["conversation_id"]
    card_seq = binding["card_seq"]

    case find_existing_question_answer(group_id, home_id, question_id) do
      {:ok, existing_id} ->
        {:ok, %{"message_id" => existing_id, "inserted" => false}}

      :none ->
        with {:ok, question_message} <-
               Conversations.get_group_conversation_message(group_id, home_id, question_id),
             %{} = question_block <-
               ConversationQuestion.question_block(question_message["content"]),
             {station_id, thread} <- StationHostedTasks.parse(ref),
             {:ok, group} <- GroupDirectory.get_group(group_id) do
          scope = %{tenant_id: group["tenant_id"], group_id: group_id}
          stillfail_messages = read_station_tail_messages(scope, station_id, thread)

          {display_text, answer_block} =
            resolve_stillfail_answer(question_block, stillfail_messages,
              card_seq: card_seq,
              locale: Keyword.get(opts, :locale)
            )

          RouterConversationInput.append_resolved_question_answer(
            group_id,
            user_id,
            question_id,
            display_text,
            answer_block,
            ref
          )
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :stale_card_fold_unavailable}
        end
    end
  rescue
    _ -> {:error, :stale_card_fold_unavailable}
  end

  defp find_existing_question_answer(group_id, home_id, question_id) do
    case Conversations.list_group_conversation_message_page(group_id, home_id, limit: 40) do
      {:ok, %{"messages" => messages}} when is_list(messages) ->
        messages
        |> Enum.find(fn msg ->
          case ConversationQuestion.answer_block(msg["content"]) do
            %{"question_message_id" => ^question_id} -> true
            _ -> false
          end
        end)
        |> case do
          %{"message_id" => id} when is_binary(id) -> {:ok, id}
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp read_station_tail_messages(scope, station_id, thread) do
    limit = 50

    case StationHostedTasks.read(scope, station_id, thread, %{"after" => 0, "limit" => limit}) do
      {:ok, %{"messages" => list} = page} when is_list(list) ->
        through = page["through"]
        last_seq = list |> Enum.map(&(&1["seq"] || 0)) |> Enum.max(fn -> 0 end)

        if is_integer(through) and through > last_seq do
          tail_after = max(through - limit, 0)

          case StationHostedTasks.read(scope, station_id, thread, %{
                 "after" => tail_after,
                 "limit" => limit
               }) do
            {:ok, %{"messages" => tail}} when is_list(tail) -> tail
            _ -> list
          end
        else
          list
        end

      _ ->
        []
    end
  end

  @doc """
  Stages a compact 1-line `no_wake` JSON context entry into the Router session
  so follow-up questions in Home see card notifications, direct answers,
  dismisses, and still.fail resolutions without waking the Router.
  """
  @spec stage_router_context(String.t(), String.t(), map()) :: :ok
  def stage_router_context(group_id, source_id, payload)
      when is_binary(group_id) and is_binary(source_id) and is_map(payload) do
    _ =
      RouterConversationInput.append_provider_input(
        group_id,
        source_id,
        %{
          content: Jason.encode!(payload),
          name: "Comma",
          role: "user",
          no_wake: true
        },
        %{
          "provider" => "comma",
          "context_only" => true,
          "event_type" => payload["event"] || "station_task_context"
        }
      )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Finds an open bound question card in `messages` for `ref` (fallback for
  matters written before `home_message_id` was persisted on `MailInteraction`).
  """
  @spec find_open_question_message([map()], String.t()) :: {:ok, map()} | :none
  def find_open_question_message(messages, ref) when is_list(messages) and is_binary(ref) do
    answered_ids =
      messages
      |> Enum.reduce(MapSet.new(), fn message, acc ->
        case ConversationQuestion.answer_block(message["content"]) do
          %{"question_message_id" => qid} when is_binary(qid) -> MapSet.put(acc, qid)
          _ -> acc
        end
      end)

    messages
    |> Enum.sort_by(&(&1["seq"] || 0), :desc)
    |> Enum.find(fn message ->
      message["actor_type"] == "agent" and
        get_in(message, ["metadata", "station_task_question", "conversation_id"]) == ref and
        not is_nil(ConversationQuestion.question_block(message["content"]))
    end)
    |> case do
      %{"message_id" => id} = msg when is_binary(id) ->
        if MapSet.member?(answered_ids, id), do: :none, else: {:ok, msg}

      _ ->
        :none
    end
  end

  def find_open_question_message(_messages, _ref), do: :none

  @doc """
  Matches what the user chose or replied in `stillfail_messages` against the
  Home `question_block`'s choices and returns `{display_text, answer_block}`
  (without `question_message_id`, which the caller attaches).

  Options:
  - `:card_seq` — exact station message `seq` of the card being folded; when
    provided, only evidence belonging to that card is attributed to it.
  - `:reason` — `:closed` (default) or `:superseded` (when replaced by a newer
    question on the same chat).
  - `:locale` — optional user locale for neutral receipts.
  """
  @spec resolve_stillfail_answer(map(), [map()], keyword()) :: {String.t(), map()}
  def resolve_stillfail_answer(%{} = question_block, stillfail_messages, opts \\ [])
      when is_list(stillfail_messages) do
    card_seq = Keyword.get(opts, :card_seq)
    reason = Keyword.get(opts, :reason, :closed)
    zh? = zh_locale?(Keyword.get(opts, :locale))

    chosen = extract_stillfail_choice(stillfail_messages, card_seq)
    choices = List.wrap(question_block["choices"])

    case match_choice(choices, chosen) do
      %{"id" => id, "label" => label} ->
        {label,
         %{
           "type" => "question_answer",
           "choice_ids" => [id],
           "skipped" => false
         }}

      nil ->
        cond do
          is_binary(chosen) and chosen != "" and question_block["allow_other"] != false ->
            capped = truncate_bytes_with_ellipsis(chosen, 240)

            {capped,
             %{
               "type" => "question_answer",
               "choice_ids" => [],
               "other" => capped,
               "skipped" => false
             }}

          is_binary(chosen) and chosen != "" ->
            capped = truncate_bytes_with_ellipsis(chosen, 240)

            {capped,
             %{
               "type" => "question_answer",
               "choice_ids" => [],
               "skipped" => true
             }}

          reason == :superseded ->
            {if(zh?, do: "已换新题。", else: "Replaced by a newer question."),
             %{
               "type" => "question_answer",
               "choice_ids" => [],
               "skipped" => true
             }}

          true ->
            {if(zh?, do: "已在 still.fail 处理。", else: "Resolved in still.fail."),
             %{
               "type" => "question_answer",
               "choice_ids" => [],
               "skipped" => true
             }}
        end
    end
  end

  @doc false
  @spec answer_to_station_reply(map(), map(), map()) :: {String.t(), boolean()} | :empty
  def answer_to_station_reply(answer, question, binding)
      when is_map(answer) and is_map(question) and is_map(binding) do
    choice_ids = List.wrap(answer["choice_ids"])
    choices = List.wrap(question["choices"])
    picked = Enum.filter(choices, &(&1["id"] in choice_ids))

    picked_text =
      case picked do
        [] -> nil
        [single] -> non_blank(single["reply"]) || non_blank(single["label"])
        many -> Enum.map_join(many, ", ", &String.trim(to_string(&1["label"] || "")))
      end

    other_text = non_blank(answer["other"])

    text =
      [picked_text, other_text]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
      |> String.trim()

    if text == "" do
      :empty
    else
      close_ids = List.wrap(binding["close_choice_ids"])

      close_card? =
        is_nil(other_text) and length(choice_ids) == 1 and hd(choice_ids) in close_ids

      {text, close_card?}
    end
  end

  defp forward_answer(
         group_id,
         conversation,
         attrs,
         answer,
         question_message,
         binding,
         ref,
         station_id,
         thread
       ) do
    question = ConversationQuestion.question_block(question_message["content"]) || %{}
    question_id = answer["question_message_id"]

    with {reply_text, close_card?} <- answer_to_station_reply(answer, question, binding),
         {:ok, group} <- GroupDirectory.get_group(group_id) do
      scope = %{tenant_id: group["tenant_id"], group_id: group_id}
      requester = router_name(conversation["router_agent_id"])
      key = sync_idempotency_key(attrs, question_id, reply_text)

      opts =
        %{}
        |> then(&if(close_card?, do: Map.put(&1, "close_card", true), else: &1))
        |> then(fn map ->
          case binding["card_seq"] do
            seq when is_integer(seq) and seq > 0 -> Map.put(map, "expected_card_seq", seq)
            _ -> map
          end
        end)
        |> then(fn map ->
          case non_blank(attrs["requester_email"]) do
            email when is_binary(email) -> Map.put(map, "requester_email", email)
            _ -> map
          end
        end)

      case StationHostedTasks.say(scope, station_id, thread, reply_text, key, requester, opts) do
        {:ok, %{"seq" => seq}} ->
          {:handled, {:forwarded, ref, seq, question_id, reply_text},
           %{
             "synced_to_stillfail" => %{
               "conversation_id" => ref,
               "seq" => seq,
               "closed_card" => close_card?
             }
           }}

        {:ok, _other} ->
          {:fallback_to_router,
           %{"stillfail_sync_error" => "the station did not take the Message"}}

        {:error, {:station_refused, why}} ->
          if stale_card_error?(why) do
            {:stale_card, ref, question_id, binding}
          else
            {:fallback_to_router,
             %{"stillfail_sync_error" => format_error({:station_refused, why})}}
          end

        {:error, reason} ->
          {:fallback_to_router, %{"stillfail_sync_error" => format_error(reason)}}
      end
    else
      _ -> :passthrough
    end
  end

  defp stale_card_error?(why) when is_binary(why), do: String.contains?(why, "stale_card")
  defp stale_card_error?(why), do: String.contains?(inspect(why), "stale_card")

  defp extract_stillfail_choice(messages, card_seq) when is_integer(card_seq) and card_seq > 0 do
    sorted = Enum.sort_by(messages, &(&1["seq"] || 0), :asc)

    case Enum.find(sorted, &(&1["seq"] == card_seq)) do
      %{"card" => %{"choice" => choice}} when is_binary(choice) ->
        non_blank(choice)

      %{} ->
        next_card_seq =
          sorted
          |> Enum.find_value(fn m ->
            if m["author_kind"] == "agent" and (m["seq"] || 0) > card_seq and is_map(m["card"]),
              do: m["seq"]
          end)

        sorted
        |> Enum.find_value(fn m ->
          seq = m["seq"] || 0

          if m["author_kind"] == "person" and seq > card_seq and
               (is_nil(next_card_seq) or seq < next_card_seq) do
            extract_person_reply_text(m["text"])
          end
        end)

      nil ->
        nil
    end
  end

  defp extract_stillfail_choice(messages, _card_seq) do
    sorted = Enum.sort_by(messages, &(&1["seq"] || 0), :asc)

    latest_options_card =
      sorted
      |> Enum.reverse()
      |> Enum.find(fn m ->
        m["author_kind"] == "agent" and is_map(m["card"]) and m["card"]["type"] == "options"
      end)

    case latest_options_card do
      %{"card" => %{"choice" => choice}} when is_binary(choice) ->
        non_blank(choice)

      %{"seq" => seq} when is_integer(seq) ->
        sorted
        |> Enum.reverse()
        |> Enum.find_value(fn m ->
          if m["author_kind"] == "person" and (m["seq"] || 0) > seq do
            extract_person_reply_text(m["text"])
          end
        end)

      _ ->
        nil
    end
  end

  defp extract_person_reply_text(value) do
    case non_blank(value) do
      nil -> nil
      trimmed -> strip_leading_blockquote(trimmed)
    end
  end

  defp strip_leading_blockquote(text) do
    if String.starts_with?(text, ">") do
      remaining =
        text
        |> String.split(~r/\r?\n/)
        |> Enum.drop_while(fn line ->
          t = String.trim_leading(line)
          t == "" or String.starts_with?(t, ">")
        end)
        |> Enum.join("\n")
        |> String.trim()

      if remaining == "", do: text, else: remaining
    else
      text
    end
  end

  defp match_choice(_choices, nil), do: nil

  defp match_choice(choices, chosen) when is_binary(chosen) do
    trimmed = String.trim(chosen)
    down = String.downcase(trimmed)

    Enum.find(choices, fn choice ->
      is_map(choice) and
        (non_blank(choice["label"]) == trimmed or non_blank(choice["reply"]) == trimmed)
    end) ||
      Enum.find(choices, fn choice ->
        is_map(choice) and
          (downcase_or_nil(choice["label"]) == down or downcase_or_nil(choice["reply"]) == down)
      end)
  end

  defp title_link(title, url) do
    clean_title = non_blank(title) || "still.fail"

    if valid_https_url?(url) do
      safe_title = clean_title |> String.replace("[", "(") |> String.replace("]", ")")
      "[#{safe_title}](#{url})"
    else
      clean_title
    end
  end

  defp valid_https_url?(url) when is_binary(url),
    do: String.starts_with?(url, "https://") and byte_size(url) <= 2_048

  defp valid_https_url?(_url), do: false

  defp fixed_line("need", true), do: "正在等待你的回复。"
  defp fixed_line("need", false), do: "Waiting for your reply."
  defp fixed_line("done", true), do: "任务已完成。"
  defp fixed_line("done", false), do: "Task finished."
  defp fixed_line("failed", true), do: "任务执行失败。"
  defp fixed_line("failed", false), do: "Task failed."
  defp fixed_line(_, true), do: "状态有更新。"
  defp fixed_line(_, false), do: "Status updated."

  defp system_card_label("login", true), do: "CLI 登录"
  defp system_card_label("login", false), do: "CLI login"
  defp system_card_label(k, true) when k in ~w(secret vault), do: "凭据/密钥审批"
  defp system_card_label(k, false) when k in ~w(secret vault), do: "vault approval"
  defp system_card_label("signin", true), do: "浏览器登录"
  defp system_card_label("signin", false), do: "browser sign-in"
  defp system_card_label(k, true) when k in ~w(device adb rig), do: "设备授权"
  defp system_card_label(k, false) when k in ~w(device adb rig), do: "device authorization"
  defp system_card_label(other, _zh?), do: to_string(other)

  defp zh_locale?(locale) when is_binary(locale), do: String.starts_with?(locale, "zh")
  defp zh_locale?(_), do: false

  defp normalize_attachments(list) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp normalize_attachments(_), do: []

  defp staged_file_names(attachments) do
    for %{"file_name" => name} <- attachments,
        is_binary(name),
        trimmed = String.trim(name),
        trimmed != "",
        into: MapSet.new(),
        do: trimmed
  end

  defp excerpt_message_body(raw_text, compare_text, max_bytes, zh?, staged_names \\ MapSet.new()) do
    case non_blank(raw_text) do
      nil ->
        nil

      trimmed ->
        cleaned =
          trimmed
          |> replace_relative_markdown_images(zh?, staged_names)
          |> String.replace(~r/\n{3,}/, "\n\n")
          |> String.trim()

        cond do
          cleaned == "" ->
            nil

          is_binary(compare_text) and String.trim(compare_text) == cleaned ->
            nil

          true ->
            truncate_bytes_with_ellipsis(cleaned, max_bytes)
        end
    end
  end

  defp replace_relative_markdown_images(text, zh?, staged_names) do
    label = if zh?, do: "图片", else: "Image"

    Regex.replace(~r/!\[([^\]]*)\]\(([^)\s]+)\)/u, text, fn full, alt, src ->
      trimmed_src = String.trim(src)

      if remote_or_rooted_image_src?(trimmed_src) do
        full
      else
        base = Path.basename(trimmed_src)

        if MapSet.member?(staged_names, trimmed_src) or MapSet.member?(staged_names, base) do
          ""
        else
          name = non_blank(alt) || base
          "[#{label}: #{name}]"
        end
      end
    end)
  end

  defp remote_or_rooted_image_src?(src) do
    Regex.match?(~r/^(?:https?:\/\/|\/|\.\/|\.\.\/|data:image\/)/i, src)
  end

  defp truncate_bytes_with_ellipsis(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_bytes_with_ellipsis(text, max_bytes) do
    # Reserve 3 bytes for the UTF-8 ellipsis ("…").
    budget = max(max_bytes - 3, 0)
    String.trim_trailing(truncate_bytes(text, budget)) <> "…"
  end

  defp truncate_bytes(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_bytes(text, max_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn g, acc ->
      if byte_size(acc) + byte_size(g) <= max_bytes,
        do: {:cont, acc <> g},
        else: {:halt, acc}
    end)
  end

  defp router_name(agent_id) when is_binary(agent_id) do
    case GroupDirectory.get_agent(agent_id) do
      {:ok, %{"name" => name}} when is_binary(name) and name != "" -> name
      _ -> "Router"
    end
  end

  defp router_name(_), do: "Router"

  defp sync_idempotency_key(attrs, question_id, reply_text) do
    case non_blank(attrs["client_request_id"]) do
      nil ->
        digest =
          :crypto.hash(:sha256, "#{question_id}:#{reply_text}")
          |> Base.encode16(case: :lower)
          |> binary_part(0, 24)

        "comma-card:" <> digest

      req_id ->
        "comma-card:" <> req_id
    end
  end

  defp notify_observer(group_id, ref, seq) do
    if mod = SystemsRuntime.get_env(:salix_im, :station_task_observer) do
      _ = mod.router_replied(group_id, ref, seq)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp non_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_blank(_), do: nil

  defp downcase_or_nil(value) do
    case non_blank(value) do
      nil -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp format_error(:device_offline),
    do: "the station hosting this Task is offline; it can be read and written in once it is back"

  defp format_error(:not_found), do: "unknown station-hosted Task"
  defp format_error({:station_refused, why}), do: "the station refused: " <> to_string(why)
  defp format_error(reason), do: inspect(reason)
end
