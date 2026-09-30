defmodule Salix.Bindings.MeetingCopilot do
  @moduledoc false

  @behaviour SalixMeet.Ports.Copilot

  require Logger

  alias SalixMeet.{Runtime, Store}
  alias SalixWeb.LLMProxy

  @max_tokens 300
  @min_new 1
  @prior_actions_kept 8
  @history_chars 40_000

  @system_prompt """
  You are a quiet assistant silently monitoring a live meeting's transcript and chat.

  This runs as an ongoing conversation: each user turn carries only the NEW transcript and
  chat since the previous turn, and your own replies stay in the history — so the whole
  conversation is the meeting so far.

  Default to silence. Prefer saying nothing over interrupting a flowing conversation.

  Speak into the meeting chat only when:
  - a participant explicitly asks the assistant / bot / notetaker to say or share something, or
  - the room clearly assigns an owner + task and a short confirmation adds durable clarity.

  Do NOT speak when:
  - nobody asked for anything,
  - it is vague brainstorming with no owner or task,
  - people merely mention the assistant in the third person,
  - the room is flowing naturally and you would only interrupt,
  - or a similar message is already in "Already sent".

  Do not summarize or recap the discussion unless explicitly asked. When explicitly asked to
  summarize, use the whole conversation so far; if you already gave a summary earlier, cover
  only what happened since then instead of repeating it.

  Reply with ONLY a JSON object: {"say": "<message>"}. Leave "say" empty to stay silent.
  Keep any message to one or two short, factual lines in the language of the meeting.

  Example action-item note: {"say": "📋 已记：负责人跟进首页文案，明天同步。"}
  """

  @impl true
  @spec maybe_speak(String.t()) :: :ok
  def maybe_speak(meeting_id) when is_binary(meeting_id) do
    case Store.get(meeting_id) do
      {:ok, %{"state" => state}, _etag} when is_map(state) -> consider(meeting_id, state)
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("meeting copilot #{meeting_id} crashed: #{inspect(e)}")
      :ok
  end

  defp consider(meeting_id, state) do
    caption_cursor = cursor(state, "caption_cursor")
    chat_cursor = cursor(state, "chat_cursor")
    new_caps = Enum.drop(List.wrap(state["captions"]), caption_cursor)
    new_chats = Enum.drop(List.wrap(state["chats"]), chat_cursor)
    caption_len = caption_cursor + length(new_caps)
    chat_len = chat_cursor + length(new_chats)

    cond do
      trim(state["status"]) != "active" ->
        :ok

      length(new_caps) + length(new_chats) < @min_new ->
        :ok

      true ->
        run_turn(meeting_id, state, new_caps, new_chats, caption_len, chat_len)
    end
  end

  # One copilot turn: append the new delta to the running conversation and ask the LLM.
  # Only a successful call persists the turn + advances the cursors; a failed call consumes
  # nothing, so the same (plus newer) content is retried on the next tick.
  defp run_turn(meeting_id, state, new_caps, new_chats, caption_len, chat_len) do
    agent_id = trim(state["meeting_agent_id"])
    turn = %{"role" => "user", "content" => build_digest(state, new_caps, new_chats)}
    messages = prior_messages(state) ++ [turn]

    case chat(agent_id, messages) do
      {:ok, content} ->
        commit_turn(meeting_id, messages, parse_say(content), caption_len, chat_len)

      _ ->
        :ok
    end
  end

  defp commit_turn(meeting_id, messages, say, caption_len, chat_len) do
    {messages, spoken} = apply_outcome(messages, say, send_say(meeting_id, say))
    advance(meeting_id, messages, caption_len, chat_len, spoken)
  end

  defp send_say(_meeting_id, ""), do: :silent

  defp send_say(meeting_id, say) do
    case Runtime.send_chat(meeting_id, say) do
      {:error, reason} ->
        Logger.warning("meeting copilot #{meeting_id} send failed: #{inspect(reason)}")
        :failed

      _ok ->
        Logger.info("meeting copilot #{meeting_id} spoke: #{truncate(say, 120)}")
        :sent
    end
  end

  # Record into the running conversation only what was actually delivered: a silent
  # turn or a failed send appends no assistant reply, so a later summary/action
  # request never treats the bot as if it already answered.
  @doc false
  def apply_outcome(messages, say, outcome) do
    spoken = if outcome == :sent, do: say, else: ""
    {accumulate(messages, spoken), spoken}
  end

  # Append the assistant's reply to the running conversation (a silent turn keeps just the
  # user delta) and keep it under the character budget. The authoritative full-meeting
  # summary is produced at the end by MeetingSummary, so dropping the oldest turns here only
  # trims context the live copilot no longer needs.
  @doc false
  def accumulate(messages, say) do
    messages
    |> maybe_append_reply(say)
    |> cap_history()
  end

  defp maybe_append_reply(messages, ""), do: messages

  defp maybe_append_reply(messages, say),
    do: messages ++ [%{"role" => "assistant", "content" => say}]

  defp cap_history(messages) do
    messages |> trim_budget() |> drop_leading_assistant()
  end

  # Drop whole oldest turns (a user delta plus its assistant reply, or a lone user)
  # until the conversation fits the budget, but never drop the final turn — so we
  # never orphan an assistant reply from the user it answered.
  defp trim_budget(messages) do
    if history_len(messages) <= @history_chars or length(messages) <= 2 do
      messages
    else
      trim_budget(drop_oldest_turn(messages))
    end
  end

  defp drop_oldest_turn([%{"role" => "user"}, %{"role" => "assistant"} | rest]), do: rest
  defp drop_oldest_turn([_first | rest]), do: rest

  defp drop_leading_assistant([%{"role" => "assistant"} | rest]), do: drop_leading_assistant(rest)
  defp drop_leading_assistant(messages), do: messages

  defp history_len(messages) do
    Enum.reduce(messages, 0, fn m, acc -> acc + String.length(to_string(m["content"])) end)
  end

  defp advance(meeting_id, messages, caption_len, chat_len, spoken) do
    Store.update_state_retrying(meeting_id, fn state ->
      copilot =
        state
        |> Map.get("copilot", %{})
        |> Map.put("caption_cursor", caption_len)
        |> Map.put("chat_cursor", chat_len)
        |> Map.put("messages", messages)
        |> record_spoken(spoken)

      Map.put(state, "copilot", copilot)
    end)

    :ok
  end

  defp record_spoken(copilot, spoken) when spoken in [nil, ""], do: copilot

  defp record_spoken(copilot, say) do
    prior = copilot |> Map.get("prior_actions", []) |> List.wrap()

    copilot
    |> Map.put("last_chat_at", System.system_time(:second))
    |> Map.put("prior_actions", Enum.take([truncate(say, 160) | prior], @prior_actions_kept))
  end

  defp prior_messages(state) do
    state
    |> get_in(["copilot", "messages"])
    |> List.wrap()
    |> Enum.filter(fn m ->
      is_map(m) and is_binary(m["role"]) and is_binary(m["content"]) and m["content"] != ""
    end)
  end

  @doc false
  def build_digest(state, new_caps, new_chats) do
    parts = ["## Meeting: #{blank_default(trim(state["title"]), "Meeting")}"]

    parts =
      case blank_default(trim(state["bot_name"]), default_bot_name()) do
        "" ->
          parts

        name ->
          parts ++
            [
              "You appear in this meeting as \"#{name}\". When a participant writes @#{name} or otherwise addresses #{name}, they are addressing you."
            ]
      end

    parts =
      case cooldown_note(state) do
        "" -> parts
        note -> parts ++ [note]
      end

    parts =
      case transcript_lines(new_caps) do
        "" -> parts
        lines -> parts ++ ["## New transcript\n" <> lines]
      end

    parts =
      case chat_lines(new_chats) do
        "" -> parts
        lines -> parts ++ ["## New in-meeting chat\n" <> lines]
      end

    parts =
      case prior_actions(state) do
        [] ->
          parts

        acts ->
          parts ++
            ["## Already sent (do NOT repeat)\n" <> Enum.map_join(acts, "\n", &("- " <> &1))]
      end

    Enum.join(parts, "\n\n")
  end

  defp cooldown_note(state) do
    case get_in(state, ["copilot", "last_chat_at"]) do
      ts when is_integer(ts) and ts > 0 ->
        "You last spoke #{max(System.system_time(:second) - ts, 0)}s ago. " <>
          "Avoid speaking again unless the new content contains a materially new, explicit request."

      _ ->
        ""
    end
  end

  defp prior_actions(state), do: state |> get_in(["copilot", "prior_actions"]) |> List.wrap()

  defp transcript_lines(caps) do
    caps
    |> Enum.map(fn c -> "#{blank_default(trim(c["speaker"]), "Unknown")}: #{trim(c["text"])}" end)
    |> Enum.reject(&(&1 == ": " or String.ends_with?(&1, ": ")))
    |> Enum.join("\n")
  end

  defp chat_lines(chats) do
    chats
    |> Enum.reject(&(trim(&1["direction"]) == "outgoing"))
    |> Enum.map(fn c -> "#{blank_default(trim(c["sender"]), "Unknown")}: #{trim(c["text"])}" end)
    |> Enum.reject(&String.ends_with?(&1, ": "))
    |> Enum.join("\n")
  end

  defp chat(agent_id, messages) do
    req = %{
      "messages" => [%{"role" => "system", "content" => @system_prompt} | messages],
      "max_tokens" => @max_tokens
    }

    opts = %{
      entrypoint: "meeting_copilot",
      actor_type: "system",
      skip_metering: Application.get_env(:salix_web, :meeting_summary_skip_metering, false)
    }

    with {:ok, llm} when is_map(llm) <- LLMProxy.resolve_llm(agent_id),
         {:ok, resp} <- LLMProxy.complete(agent_id, llm, req, opts),
         content when is_binary(content) <-
           get_in(resp, ["choices", Access.at(0), "message", "content"]) do
      {:ok, content}
    else
      other -> {:error, other}
    end
  end

  @doc false
  def parse_say(content) do
    with [json] <- Regex.run(~r/\{.*\}/s, content),
         {:ok, %{"say" => say}} <- Jason.decode(json),
         true <- is_binary(say) do
      String.trim(say)
    else
      _ -> ""
    end
  end

  defp cursor(state, key) do
    case get_in(state, ["copilot", key]) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp blank_default("", fallback), do: fallback
  defp blank_default(value, _fallback), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp default_bot_name do
    case Application.get_env(:salix_meet, :default_bot_name) do
      value when is_binary(value) and value != "" -> value
      _ -> "Cirno"
    end
  end
end
