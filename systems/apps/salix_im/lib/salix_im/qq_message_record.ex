defmodule SalixIM.QQMessageRecord do
  @moduledoc """
  The searchable record of QQ group messages.

  QQ has no history API: a bot knows only the messages QQ delivered to it. A
  group delivers every message once a group admin sets the bot's message range
  to all messages, and only mentions otherwise. Each delivered group message,
  and each message the bot sends to a group, becomes one row of the message
  mirror, and `qq.search_messages` reads them back.

  ## Storage

  The record has its own store and its own code: the callback appends a row
  to `SalixStore.QQMirrorOutbox`, and `SalixIM.QQMessageRecord.OutboxDrainer`
  moves it into the ClickHouse table `qq_messages` (`SalixAnalytics.QQMirror`).
  The table identifies a message by `(tenant_id, app_id, chat_id, message_id)`,
  where `app_id` is the bot's AppID.

  The record is off unless `:salix_im, :qq_message_record_mod` names a storage
  adapter; with it off `observe/2` builds nothing and the drainer does not
  start.

  A row's `version` comes from the message's own time, so a callback that QQ
  delivers twice writes the same row. QQ sends no event for a recalled or
  changed message; a row is never replaced by a newer state.

  A member who joined or left, and a request to join, are rows too
  (`observe_event/2`): QQ reports them as events of the group, and the record
  is where the Agent reads what happened in a group. Such a row has
  `message_type` `event` and the actor kind `system`.

  Private chats are not recorded.
  """

  require Logger

  alias SalixStore.QQMirrorOutbox

  @callback record_batch([map()]) :: :ok | {:error, term()}

  defmodule Noop do
    @moduledoc "Default implementation: the record is off."
    @behaviour SalixIM.QQMessageRecord

    # Not `:ok`: a drainer that took this as durability would delete an outbox
    # row over a message that went nowhere.
    @impl true
    def record_batch([]), do: :ok
    def record_batch(_rows), do: {:error, :qq_message_record_disabled}
  end

  @max_text_chars 64_000
  @max_files 20

  @doc "The mirror scope of one QQ connect."
  @spec scope(map()) :: %{String.t() => String.t()}
  def scope(connect) when is_map(connect) do
    %{"tenant_id" => text(connect["tenant_id"]), "app_id" => text(connect["app_id"])}
  end

  @doc "True when group messages are recorded on this node."
  @spec enabled?() :: boolean()
  def enabled?, do: impl() != Noop

  @doc """
  Writes a batch of rows and reports whether it landed. The outbox drainer
  deletes its rows only on `:ok`.
  """
  @spec write_batch([map()]) :: :ok | {:error, term()}
  def write_batch([]), do: :ok

  def write_batch(rows) when is_list(rows) do
    case impl().record_batch(rows) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_record_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "The outbox the record appends to and its drainer drains."
  @spec outbox() :: module()
  def outbox, do: SystemsRuntime.get_env(:salix_im, :qq_message_record_outbox, QQMirrorOutbox)

  @doc "The reader `qq.search_messages` uses, or `nil` when the record is off."
  @spec reader() :: module() | nil
  def reader do
    reader = SystemsRuntime.get_env(:salix_im, :qq_message_record_reader_mod)
    if enabled?() and is_atom(reader), do: reader
  end

  @doc """
  Records one group message QQ delivered. `:ok` when the message was recorded
  or needs no record; `{:error, :outbox_unavailable}` when the durable append
  failed, so that the callback fails and QQ can deliver it again.
  """
  @spec observe(map(), map()) :: :ok | {:error, :outbox_unavailable}
  def observe(connect, event) when is_map(connect) and is_map(event) do
    author = if is_map(event["author"]), do: event["author"], else: %{}
    files = event["attachments"] |> List.wrap() |> Enum.filter(&is_map/1) |> Enum.take(@max_files)

    append(connect, %{
      "chat_id" => "group:" <> text(event["group_openid"]),
      "message_id" => text(event["id"]),
      "create_time_us" => time_us(event["timestamp"]),
      "actor_kind" => if(author["bot"] == true, do: "app", else: "user"),
      "actor_id" => text(author["member_openid"] || author["id"]),
      "actor_label" => text(author["username"]),
      "text" => [event["content"] |> text() |> String.trim() | notes(event)] |> joined(),
      "content" =>
        %{
          "files" =>
            Enum.map(files, fn file ->
              %{
                "name" => text(file["filename"]),
                "type" => text(file["content_type"]),
                "size" => file["size"],
                # QQ's signed download address. `qq.fetch_file` reads it; a
                # search result never shows it.
                "url" => text(file["url"])
              }
            end)
        }
        |> put_present("ref", message_ref(event))
        |> put_present("role", text(author["member_role"])),
      "file_count" => length(files),
      "ingest_source" => "webhook"
    })
  end

  def observe(_connect, _event), do: :ok

  @doc """
  Records one event of a group that is not a message: `GROUP_MEMBER_ADD`,
  `GROUP_MEMBER_REMOVE` or `GROUP_JOIN_REQUEST`. `payload` is the whole
  callback; its `id` names the event, so a second delivery writes the same row.
  """
  @spec observe_event(map(), map()) :: :ok | {:error, :outbox_unavailable}
  def observe_event(connect, %{"t" => type, "d" => %{} = event} = payload) when is_map(connect) do
    member = text(event["member_openid"])
    time_us = event_time_us(event)

    id =
      case text(payload["id"]) do
        "" -> "#{type}:#{member}:#{time_us}"
        id -> id
      end

    append(connect, %{
      "chat_id" => "group:" <> text(event["group_openid"]),
      "message_id" => "event:" <> id,
      "create_time_us" => time_us,
      "actor_kind" => "system",
      "actor_id" => member,
      "actor_label" => text(event["username"]),
      "text" => event_text(type, event),
      "content" => %{"files" => [], "event" => type},
      "file_count" => 0,
      "message_type" => "event",
      "ingest_source" => "webhook"
    })
  end

  def observe_event(_connect, _payload), do: :ok

  defp event_text("GROUP_MEMBER_ADD", _event), do: "[a member joined the group]"
  defp event_text("GROUP_MEMBER_REMOVE", _event), do: "[a member left the group or was removed]"

  defp event_text("GROUP_JOIN_REQUEST", event) do
    verify = if is_map(event["verify_info"]), do: event["verify_info"], else: %{}

    answers =
      verify["review_qa_list"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&"#{text(&1["question"])} #{text(&1["answer"])}")

    [
      if(is_map(event["auto_approved"]),
        do: "[a request to join the group was approved by a join strategy]",
        else: "[a request to join the group]"
      ),
      text(verify["verify_message"])
      | answers
    ]
    |> joined()
  end

  defp event_text(_type, _event), do: ""

  # A member event carries Unix seconds; a join request carries RFC 3339.
  defp event_time_us(%{"timestamp" => seconds}) when is_integer(seconds) and seconds > 0,
    do: seconds * 1_000_000

  defp event_time_us(event), do: time_us(event["apply_at"])

  @doc """
  The index QQ quotes a received message by, or `""`. QQ sends it in the
  message's scene as `msg_idx=<index>`.
  """
  @spec message_ref(map()) :: String.t()
  def message_ref(%{"message_scene" => %{"ext" => ext}}) when is_list(ext) do
    Enum.find_value(ext, "", fn
      "msg_idx=" <> index -> String.trim(index)
      _other -> nil
    end)
  end

  def message_ref(_event), do: ""

  @doc "The index QQ quotes a sent message by, from the answer to the send, or `\"\"`."
  @spec sent_ref(map()) :: String.t()
  def sent_ref(%{"ext_info" => %{"ref_idx" => ref}}) when is_binary(ref), do: String.trim(ref)
  def sent_ref(_sent), do: ""

  @doc "The quote index recorded for a group message, or `nil`."
  @spec quote_index(map(), String.t(), String.t()) :: String.t() | nil
  def quote_index(connect, "group:" <> _openid = chat_id, message_id) when is_map(connect) do
    with reader when not is_nil(reader) <- reader(),
         {:ok, row} <- reader.get_message(scope(connect), chat_id, message_id),
         {:ok, %{"ref" => ref}} when is_binary(ref) and ref != "" <- Jason.decode(row["content"]) do
      ref
    else
      _unknown -> nil
    end
  end

  def quote_index(_connect, _chat_id, _message_id), do: nil

  @doc """
  What a message holds beside its text, as lines a reader understands: QQ's
  transcript of a voice message, and the title and link of a card.
  """
  @spec notes(map()) :: [String.t()]
  def notes(event) when is_map(event) do
    voices =
      event["attachments"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&String.trim(text(&1["asr_refer_text"])))
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&"[voice message; QQ's transcript: #{&1}]")

    voices ++ card(event["ark_data"])
  end

  def notes(_event), do: []

  defp card(%{} = ark) do
    fields = if is_map(ark["fields"]), do: ark["fields"], else: %{}

    parts =
      [
        text(ark["ark_name"]),
        text(fields["title"]),
        text(fields["desc"]),
        text(fields["source"]),
        text(fields["address"]),
        text(fields["jump_url"])
      ]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case parts do
      [] -> if(text(ark["prompt"]) == "", do: [], else: ["[card: #{text(ark["prompt"])}]"])
      parts -> ["[card: #{Enum.join(parts, " | ")}]"]
    end
  end

  defp card(_ark), do: []

  defp joined(lines), do: lines |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")

  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc "True when the message mentions the bot that received it."
  @spec mentions_bot?(map()) :: boolean()
  def mentions_bot?(event) when is_map(event),
    do: event["mentions"] |> List.wrap() |> Enum.any?(&(is_map(&1) and &1["is_you"] == true))

  def mentions_bot?(_event), do: false

  @doc """
  The message text as a person reads it. QQ writes a mention as `<@openid>`:
  the mention of the receiving bot is removed, as QQ itself removes it from a
  mention event, and any other becomes `@name`.
  """
  @spec readable_text(map()) :: String.t()
  def readable_text(event) when is_map(event) do
    event["mentions"]
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(text(event["content"]), fn mention, content ->
      token = "<@" <> text(mention["member_openid"] || mention["id"]) <> ">"

      cond do
        token == "<@>" -> content
        mention["is_you"] == true -> String.replace(content, token, "")
        true -> String.replace(content, token, "@" <> text(mention["username"]))
      end
    end)
    |> String.trim()
  end

  @doc "Records one message the bot sent to a group. Best effort; returns `:ok`."
  @spec observe_sent(map(), String.t(), map(), String.t(), non_neg_integer()) :: :ok
  def observe_sent(connect, "group:" <> _openid = chat_id, sent, text, file_count)
      when is_map(connect) and is_map(sent) do
    _ =
      append(connect, %{
        "chat_id" => chat_id,
        "message_id" => text(sent["id"]),
        "create_time_us" => time_us(sent["timestamp"]),
        "actor_kind" => "app",
        "actor_id" => text(connect["bot_user_id"]),
        "actor_label" => text(connect["bot_username"]),
        "text" => text,
        "content" => put_present(%{"files" => []}, "ref", sent_ref(sent)),
        "file_count" => file_count,
        "ingest_source" => "send"
      })

    :ok
  end

  def observe_sent(_connect, _chat_id, _sent, _text, _file_count), do: :ok

  defp append(connect, attrs) do
    scope = scope(connect)

    cond do
      not enabled?() ->
        :ok

      scope["tenant_id"] == "" or scope["app_id"] == "" or attrs["message_id"] == "" or
        attrs["chat_id"] == "group:" or attrs["create_time_us"] == 0 ->
        :ok

      true ->
        row =
          scope
          |> Map.merge(attrs)
          |> Map.merge(%{
            "version" => attrs["create_time_us"] * 2,
            "deleted" => false,
            "root_id" => "",
            "parent_id" => "",
            "thread_id" => "",
            "chat_type" => "group",
            "message_type" =>
              attrs["message_type"] || if(attrs["file_count"] > 0, do: "file", else: "text"),
            "text" => String.slice(attrs["text"], 0, @max_text_chars),
            "content" => Jason.encode!(attrs["content"]),
            "observed_ts_us" => 0
          })

        case outbox().append(row, "message") do
          :ok -> :ok
          {:error, reason} -> failed(inspect(reason))
        end
    end
  rescue
    exception -> failed(Exception.message(exception))
  catch
    kind, reason -> failed(inspect({kind, reason}))
  end

  defp failed(detail) do
    Logger.warning("qq message record append failed: #{detail}")
    {:error, :outbox_unavailable}
  end

  # QQ gives the send time to the second, as RFC 3339.
  defp time_us(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> max(DateTime.to_unix(datetime, :microsecond), 0)
      _invalid -> 0
    end
  end

  defp time_us(_timestamp), do: 0

  defp impl, do: SystemsRuntime.get_env(:salix_im, :qq_message_record_mod, Noop)

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""
end
