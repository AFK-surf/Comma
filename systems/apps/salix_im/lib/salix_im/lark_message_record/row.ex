defmodule SalixIM.LarkMessageRecord.Row do
  @moduledoc """
  Pure Lark-event to record-row normalization.

  Everything here is a total function of the event and the connect identity.
  The one clock input is the backfill observation cut supplied by the caller.

  ## Version

      version = observed_state_ts_micros * 2 + (deleted ? 1 : 0)

  `observed_state_ts` is the message's `create_time`, its `update_time` once
  Lark marks it updated, or the recall event's `recall_time`. It is never the
  ingest wall clock, so a replayed callback writes the same row and a history
  page that observed an older state loses to the live tail. The deletion bit
  keeps a recall above every edit sharing its microsecond.

  ## Live and history share one path

  `from_history/3` wraps an `/im/v1/messages` item and runs the same builder
  as a `im.message.receive_v1` callback, so both sources converge on one row.
  `ingest_source` and `actor_label` differ: only history pages carry the
  sender's display name. Neither decides a merge.

  A recall (`im.message.recalled_v1`) carries no create time or content. Its
  row is a tombstone with `create_time_us = 0`; the table is partitioned by
  tenant rather than by month so the tombstone always meets the message it
  replaces.
  """

  alias SalixIM.Provider.Lark.Message

  @max_text_chars 64_000
  @max_content_bytes 262_144

  @doc "Builds the row for one Lark callback, or `:ignore`."
  @spec from_event(map(), map()) :: {:ok, map()} | :ignore
  def from_event(connect, %{"header" => %{"event_type" => type}, "event" => event})
      when is_map(event) do
    with {:ok, identity} <- identity(connect) do
      case type do
        "im.message.receive_v1" ->
          case event["message"] do
            message when is_map(message) ->
              message
              |> Map.put("sender", event["sender"] || %{})
              |> build(identity, "webhook", 0)

            _missing ->
              :ignore
          end

        "im.message.recalled_v1" ->
          tombstone(identity, event)

        _other ->
          :ignore
      end
    end
  end

  def from_event(_connect, _envelope), do: :ignore

  @doc """
  Builds the row for one message the bot sent, from Lark's answer to the
  send, or `:ignore`. `text` is what the bot wrote; the answer holds the
  rendered form.
  """
  @spec from_sent(map(), map(), String.t()) :: {:ok, map()} | :ignore
  def from_sent(connect, message, text) when is_map(message) and is_binary(text) do
    with {:ok, identity} <- identity(connect),
         {:ok, row} <- build(message, identity, "send", 0) do
      {:ok, if(text == "", do: row, else: Map.put(row, "text", bounded_text(text)))}
    end
  end

  def from_sent(_connect, _message, _text), do: :ignore

  @doc "Builds the row for one `/im/v1/messages` item, or `:ignore`."
  @spec from_history(map(), map(), non_neg_integer()) :: {:ok, map()} | :ignore
  def from_history(connect, message, observed_ts_us)
      when is_map(message) and is_integer(observed_ts_us) and observed_ts_us >= 0 do
    with {:ok, identity} <- identity(connect) do
      build(message, identity, "backfill", observed_ts_us)
    end
  end

  def from_history(_connect, _message, _observed_ts_us), do: :ignore

  @doc "Microseconds from a Lark millisecond timestamp string."
  @spec ms_to_us(term()) :: {:ok, pos_integer()} | :error
  def ms_to_us(value) when is_integer(value) and value > 0, do: {:ok, value * 1_000}

  def ms_to_us(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {ms, ""} when ms > 0 -> {:ok, ms * 1_000}
      _invalid -> :error
    end
  end

  def ms_to_us(_value), do: :error

  defp build(message, identity, source, observed_ts_us) do
    normalized = Message.normalize(message)
    deleted = message["deleted"] == true

    with message_id when message_id != "" <- normalized["message_id"],
         chat_id when chat_id != "" <- normalized["chat_id"],
         {:ok, create_us} <- ms_to_us(message["create_time"]) do
      state_us =
        case {message["updated"] == true or deleted, ms_to_us(message["update_time"])} do
          {true, {:ok, update_us}} -> max(create_us, update_us)
          _ -> create_us
        end

      content = raw_content(message)
      content = if byte_size(content) > @max_content_bytes, do: "", else: content
      sender = normalized["sender"] || %{}

      {:ok,
       Map.merge(identity, %{
         "chat_id" => chat_id,
         "message_id" => message_id,
         "create_time_us" => create_us,
         "version" => state_us * 2 + if(deleted, do: 1, else: 0),
         "deleted" => deleted,
         "root_id" => normalized["root_id"],
         "parent_id" => normalized["parent_id"],
         "thread_id" => normalized["thread_id"],
         "chat_type" => str(message["chat_type"]),
         "message_type" => normalized["message_type"],
         "actor_kind" => str(sender["sender_type"]),
         "actor_id" => str(sender["id"]),
         "actor_label" => str(sender["name"]),
         "text" => if(deleted, do: "", else: bounded_text(normalized["text"])),
         "content" => if(deleted, do: "", else: content),
         "file_count" => min(length(normalized["attachments"] || []), 65_535),
         "ingest_source" => source,
         "observed_ts_us" => observed_ts_us
       })}
    else
      _ -> :ignore
    end
  end

  defp tombstone(identity, event) do
    with message_id when message_id != "" <- str(event["message_id"]),
         chat_id when chat_id != "" <- str(event["chat_id"]),
         {:ok, recall_us} <- ms_to_us(event["recall_time"]) do
      {:ok,
       Map.merge(identity, %{
         "chat_id" => chat_id,
         "message_id" => message_id,
         "create_time_us" => 0,
         "version" => recall_us * 2 + 1,
         "deleted" => true,
         "root_id" => "",
         "parent_id" => "",
         "thread_id" => "",
         "chat_type" => "",
         "message_type" => "",
         "actor_kind" => "",
         "actor_id" => "",
         "actor_label" => "",
         "text" => "",
         "content" => "",
         "file_count" => 0,
         "ingest_source" => "webhook",
         "observed_ts_us" => 0
       })}
    else
      _ -> :ignore
    end
  end

  defp identity(connect) when is_map(connect) do
    tenant_id = str(connect["tenant_id"])
    app_id = str(connect["app_id"])

    if tenant_id != "" and app_id != "",
      do: {:ok, %{"tenant_id" => tenant_id, "app_id" => app_id}},
      else: :ignore
  end

  defp identity(_connect), do: :ignore

  defp raw_content(message) do
    body = if is_map(message["body"]), do: message["body"], else: %{}

    case body["content"] || message["content"] do
      value when is_binary(value) -> value
      value when is_map(value) or is_list(value) -> Jason.encode!(value)
      _ -> ""
    end
  end

  defp bounded_text(text) when is_binary(text), do: String.slice(text, 0, @max_text_chars)
  defp bounded_text(_text), do: ""

  defp str(value) when is_binary(value), do: String.trim(value)
  defp str(_value), do: ""
end
