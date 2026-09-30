defmodule SalixIM.SlackMessageMirror.Row do
  @moduledoc """
  Pure Slack-event to mirror-row normalization.

  Everything here is a total function of the event and the connect identity —
  no store, no provider call. Versioning uses Slack's own timestamps, never
  the wall clock, so a replayed delivery produces the same merge order. The
  one clock input is a backfill observation cut supplied by the caller:
  Slack history has no snapshot timestamp, so the backfill stamps Pod now
  immediately before the HTTP request.

  ## Version

      version = observed_state_ts_micros * 2 + (deleted ? 1 : 0)

  `observed_state_ts` is the message's own `ts`, its `edited.ts` once edited,
  or the `message_deleted` event's `event_ts`. It is never the wall clock at
  ingest: a backfill page that observed an older state must LOSE to the live
  tail that already saw a newer one, and ingest time would invert exactly that
  case.

  The deletion bit makes a tombstone outrank every live observation sharing
  its microsecond, which is the property the mirror's deletion semantics rest
  on. Nothing else is encoded. Two rows with the same version describe the
  same observed state; ClickHouse keeps the most recently inserted one among
  them, which is the documented ReplacingMergeTree rule for equal versions and
  is what lets a re-walk populate a derived column on rows already written.
  `SalixAnalytics`'s ClickHouse test pins that rule.

  ## Canonical payload

  `payload` is the stable Slack message object. Searchable `text` / `body_text`
  and actor/file projections are derived from it. A field is omitted only when
  it is demonstrably expiring and recoverable from a retained stable id
  (`url_private` via `file.id`). Semantic Block Kit fields stay.

  History items are not filtered through a body-subtype allowlist: anything
  Slack returns with a channel and a sortable `ts` is stored. Mutation
  envelopes (`message_changed` / `message_deleted`) are the only special case.

  ## Backfill shares this code, deliberately

  `from_history/3` exists so a `conversations.history` message and the webhook
  callback for the same message produce the SAME row. A Slack history object
  and the `event` inside a message callback are the same shape apart from the
  channel, which history carries in the request instead of the payload, so
  backfill wraps one into the other and runs the identical path. That is what
  makes the two sources converge in ClickHouse instead of merely resembling
  each other: same version derivation, same text and file bounds, same ignore
  rules. Only `ingest_source` differs. Merge and search/history reads do not
  depend on it; Triage's ambient ETL does — `list_changes` admits `"webhook"`
  only, so a history reconstruction cannot create a new Triage subject.

  `reply_count` is the one field the two sources can disagree on at equal
  version. A post callback observes zero replies and a history page observes
  the thread's current count, and neither changes `edited.ts`, so the merge
  between them is arbitrary. It is kept as an observation, not a fact: a
  reader that needs a reply count must count rows sharing a `thread_ts`.
  """

  alias SalixIM.SlackMessageMirror.{BlockPayload, BlockText}
  alias SalixIM.Triage.CanonicalJSON

  # `payload` is the source of truth; `blocks` is the same object for the
  # search/index path. Truncated JSON is not JSON, and an empty payload would
  # make a later Slack-substituting read impossible, so both are stored in
  # full. Slack's own event/history envelope bounds the object.

  # Slack's ceiling is 40,000 CHARACTERS, and the difference matters here
  # because this corpus is bilingual: 40,000 CJK characters is 120,000 UTF-8
  # bytes, so a byte limit set from the character number silently rejects
  # legitimate messages at the top of Slack's own range. Dropping a post would
  # be bad enough; dropping a `message_changed` is worse, because it leaves the
  # PREVIOUS text standing in the index as though the edit never happened.
  #
  # The bound is therefore in characters, above Slack's limit so a platform
  # change does not start silently dropping. The byte figure is only a cheap
  # pre-guard so a hostile payload cannot make `String.length/1` walk an
  # unbounded binary; at UTF-8's 4-bytes-per-character worst case it cannot
  # reject anything the character bound would accept.
  @max_text_chars 64_000
  @max_text_bytes 4 * @max_text_chars
  @max_files 50

  @type row :: %{optional(String.t()) => term()}

  @doc """
  Builds the mirror row for one Slack event, or `:ignore`.

  `:ignore` is the normal outcome for most events; it is not an error and must
  not be logged as one.
  """
  @spec from_event(map(), map()) :: {:ok, row()} | :ignore
  def from_event(connect, envelope), do: from_envelope(connect, envelope, "webhook")

  @doc """
  Builds the mirror row for one `conversations.history` or
  `conversations.replies` message, or `:ignore`.

  The channel is a request parameter on those methods rather than a field on
  the message, so it is put back before the shared path runs.
  """
  @spec from_history(map(), String.t(), map(), non_neg_integer()) :: {:ok, row()} | :ignore
  def from_history(connect, channel_id, message, observed_ts_us \\ 0)

  def from_history(connect, channel_id, message, observed_ts_us)
      when is_binary(channel_id) and is_map(message) and is_integer(observed_ts_us) and
             observed_ts_us >= 0 do
    from_envelope(
      connect,
      %{"event" => Map.put(message, "channel", channel_id)},
      "backfill",
      observed_ts_us
    )
  end

  def from_history(_connect, _channel_id, _message, _observed_ts_us), do: :ignore

  defp from_envelope(connect, envelope, source, observed_ts_us \\ 0)

  defp from_envelope(connect, envelope, source, observed_ts_us)
       when is_map(connect) and is_map(envelope) do
    with {:ok, identity} <- identity(connect),
         event when is_map(event) <- envelope["event"],
         {:ok, observation} <- observation(event) do
      build(
        identity,
        observation
        |> Map.put(:source, source)
        |> Map.put(:observed_ts_us, observed_ts_us)
      )
    else
      _ -> :ignore
    end
  end

  defp from_envelope(_connect, _envelope, _source, _observed_ts_us), do: :ignore

  defp identity(connect) do
    tenant_id = trim(connect["tenant_id"])
    workspace_id = trim(connect["workspace_id"])

    if tenant_id != "" and workspace_id != "",
      do: {:ok, %{tenant_id: tenant_id, workspace_id: workspace_id}},
      else: :ignore
  end

  # An edit and a delete are the only way this side ever learns that a message
  # changed: Slack marks both `hidden: true`, and hidden subtypes are excluded
  # from `conversations.history`. A mirror that filters them the way the
  # routing path does can never repair the difference from the API later.
  defp observation(%{"type" => "message", "subtype" => "message_changed"} = event) do
    message = event["message"]

    if is_map(message) do
      {:ok,
       %{
         event: event,
         message: message,
         channel_id: trim(event["channel"]),
         message_ts: trim(message["ts"]),
         state_ts: first_present([edited_ts(message), trim(event["event_ts"])]),
         deleted?: false
       }}
    else
      :ignore
    end
  end

  defp observation(%{"type" => "message", "subtype" => "message_deleted"} = event) do
    {:ok,
     %{
       event: event,
       message: previous_message(event),
       channel_id: trim(event["channel"]),
       message_ts: trim(event["deleted_ts"]),
       state_ts: trim(event["event_ts"]),
       deleted?: true
     }}
  end

  defp observation(%{"type" => "message"} = event), do: accept_message(event, event)

  # History objects are the same shape as a message event except `type` is
  # sometimes omitted. Anything with a sortable `ts` is stored; a subtype
  # Slack adds tomorrow must not require a code release to be mirrored.
  defp observation(%{"type" => type}) when is_binary(type) and type != "message", do: :ignore

  defp observation(event) when is_map(event), do: accept_message(event, event)

  defp accept_message(event, message) do
    ts = trim(message["ts"])

    if ts != "" do
      {:ok,
       %{
         event: event,
         message: message,
         channel_id: trim(event["channel"]),
         message_ts: ts,
         state_ts: first_present([edited_ts(message), ts]),
         deleted?: false
       }}
    else
      :ignore
    end
  end

  # A deletion event may or may not carry the message it removed. When it does
  # not, the tombstone still has to win the merge, so the row is built from the
  # identity alone and every content column stays empty.
  defp previous_message(event) do
    case event["previous_message"] do
      message when is_map(message) -> message
      _ -> %{}
    end
  end

  defp build(identity, observation) do
    with true <- observation.channel_id != "",
         {:ok, message_ts_us} <- slack_ts_micros(observation.message_ts),
         {:ok, state_ts_us} <- slack_ts_micros(observation.state_ts),
         {:ok, text} <- text(observation),
         {:ok, files} <- files(observation.message) do
      {:ok,
       %{
         "event_date" => event_date(message_ts_us),
         "tenant_id" => identity.tenant_id,
         "workspace_id" => identity.workspace_id,
         "channel_id" => observation.channel_id,
         "message_ts_us" => message_ts_us,
         "message_ts" => observation.message_ts,
         "thread_ts" => trim(observation.message["thread_ts"]),
         "version" => version(state_ts_us, observation.deleted?),
         "deleted" => observation.deleted?,
         "actor_kind" => actor_kind(observation.message),
         "actor_id" => actor_id(observation.message),
         "actor_label" => actor_label(observation.message),
         "subtype" => trim(observation.message["subtype"]),
         "text" => text,
         "body_text" => body_text(observation, text),
         "blocks" => blocks(observation),
         "payload" => payload(observation),
         "files" => CanonicalJSON.encode!(files),
         "file_count" => length(files),
         "reply_count" => reply_count(observation.message["reply_count"]),
         "edited_ts" => edited_ts(observation.message),
         "ingest_source" => observation.source,
         "observed_ts_us" => observed_ts_us(observation, state_ts_us)
       }}
    else
      _ -> :ignore
    end
  end

  @doc "The merge-ordering value for one observed state."
  @spec version(non_neg_integer(), boolean()) :: non_neg_integer()
  def version(state_ts_us, deleted?) when is_integer(state_ts_us) and state_ts_us >= 0,
    do: state_ts_us * 2 + if(deleted?, do: 1, else: 0)

  # Webhook payloads are Slack's state as of `event_ts`. Backfill is Slack's
  # state at request start: history has no snapshot timestamp, so the caller
  # stamps Pod now immediately before the HTTP call (live writer starts first;
  # same clock assumption as `indexed_to`). Zero means "cut unknown, apply all".
  defp observed_ts_us(%{source: "backfill", observed_ts_us: cut}, _state_ts_us)
       when is_integer(cut) and cut > 0,
       do: cut

  defp observed_ts_us(%{source: "backfill"}, _state_ts_us), do: 0
  defp observed_ts_us(_observation, state_ts_us), do: state_ts_us

  @doc """
  Parses a Slack timestamp into microseconds.

  Slack writes `SECONDS.MICROS`, and the fractional half is not always six
  digits, so it is right-padded rather than parsed as an integer directly:
  `"1710000000.1"` is 100000 microseconds, not 1.
  """
  @spec slack_ts_micros(term()) :: {:ok, non_neg_integer()} | :error
  def slack_ts_micros(value) when is_binary(value) do
    with [seconds, micros] <- String.split(value, ".", parts: 2),
         true <- byte_size(micros) in 1..6,
         {seconds, ""} when seconds >= 0 <- Integer.parse(seconds),
         {micros, ""} when micros >= 0 <-
           micros |> String.pad_trailing(6, "0") |> Integer.parse() do
      {:ok, seconds * 1_000_000 + micros}
    else
      _ -> :error
    end
  end

  def slack_ts_micros(_value), do: :error

  defp event_date(message_ts_us) do
    message_ts_us
    |> div(1_000_000)
    |> DateTime.from_unix!()
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp text(%{deleted?: true}), do: {:ok, ""}

  defp text(%{message: message}) do
    case message["text"] do
      text when is_binary(text) -> {:ok, clamp_text(text)}
      _absent_or_invalid -> {:ok, ""}
    end
  end

  # Hostile or future-larger payloads must not drop the row. The identity and
  # version still have to land so an edit/delete of this message can win.
  defp clamp_text(text) when byte_size(text) > @max_text_bytes do
    case :unicode.characters_to_binary(binary_part(text, 0, @max_text_bytes)) do
      bin when is_binary(bin) -> clamp_chars(bin)
      _invalid -> ""
    end
  end

  defp clamp_text(text), do: clamp_chars(text)

  defp clamp_chars(text) do
    if String.valid?(text) do
      if String.length(text) <= @max_text_chars,
        do: text,
        else: String.slice(text, 0, @max_text_chars)
    else
      ""
    end
  end

  defp body_text(%{deleted?: true}, _text), do: ""

  defp body_text(%{message: message}, text),
    do: BlockText.flatten(message, dedupe_against: text)

  defp blocks(%{deleted?: true}), do: ""

  defp blocks(%{message: message}) do
    case message["blocks"] do
      blocks when is_list(blocks) and blocks != [] ->
        blocks |> BlockPayload.sanitize() |> CanonicalJSON.encode!()

      _absent ->
        ""
    end
  end

  defp payload(%{deleted?: true}), do: ""

  defp payload(%{message: message}),
    do: message |> BlockPayload.sanitize() |> CanonicalJSON.encode!()

  defp files(message) do
    files =
      message
      |> Map.get("files")
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_files)

    {:ok, Enum.map(files, &file_metadata/1)}
  end

  defp file_metadata(file) do
    %{
      "id" => trim(file["id"]),
      "name" => trim(file["name"]),
      "mimetype" => trim(file["mimetype"]),
      "size" => if(is_integer(file["size"]) and file["size"] >= 0, do: file["size"], else: 0)
    }
  end

  defp actor_kind(message) do
    cond do
      trim(message["bot_id"]) != "" -> "bot"
      trim(message["app_id"]) != "" -> "app"
      trim(message["user"]) != "" -> "user"
      true -> "unknown"
    end
  end

  defp actor_id(message) do
    # Slack bot posts commonly carry both the stable bot-user id (`user`) and
    # app-local attribution ids. Keep the stable user id as the principal while
    # `actor_kind/1` still classifies the row as non-human.
    first_present([trim(message["user"]), trim(message["bot_id"]), trim(message["app_id"])])
  end

  defp actor_label(message) do
    profile = if is_map(message["bot_profile"]), do: message["bot_profile"], else: %{}

    label =
      first_present([
        trim(profile["name"]),
        trim(profile["display_name"]),
        trim(message["username"])
      ])

    if String.length(label) <= 256, do: label, else: ""
  end

  defp edited_ts(message) do
    case message["edited"] do
      %{"ts" => ts} -> trim(ts)
      _ -> ""
    end
  end

  defp reply_count(value) when is_integer(value) and value >= 0, do: value
  defp reply_count(_value), do: 0

  defp first_present(values), do: Enum.find(values, "", &(&1 != ""))

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
