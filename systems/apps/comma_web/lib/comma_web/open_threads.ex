defmodule CommaWeb.OpenThreads do
  @moduledoc """
  Finds what the owner left open in their own Slack messages: something they
  promised, a question nobody answered yet, or a problem they raised. The
  notebook lists the open ones; nothing here interrupts the owner, spends the
  automatic message budget or reaches the proactive check.

  At most once a day, beside the portrait, it does two things:

  - Discovery, best effort: of the newest 100 own Slack messages, the
    Router model reads those sent since the source's cursor (the first
    refresh starts a day back), each with the start of the thread it
    answered and the thread's later messages, and the open threads already
    followed, without tools, in batches that each fit (`batches/1`). The
    cursor then moves to the newest message sent. More than 100 messages
    since the last refresh leave the older ones unread. The server keeps a
    thread only when it cites a permalink of those messages, and keys it by
    the Slack thread, so a later message in the same thread updates it
    (`Comma.OpenThreads`).
  - Tracking: for at most 10 open threads, read longest ago first, it reads
    each thread's messages since its last check, one thread at a time, and
    asks the model once which threads they close. A thread without news
    costs no model call; a thread the model did not judge is read again.

  It runs only while the owner has automatic messages on and is the
  Workspace's only member; otherwise it deletes the owner's threads.
  Recording checks again, under the profile lock that source purges take,
  that the read's account is still the source's current account and that
  both conditions still hold, so a read that a rebind, a revocation or a
  setting change overtook writes nothing.
  """
  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 3,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable, :suspended, :completed]
    ]

  require Logger
  alias Comma.Data.{OpenThread, RecommendationProfile}
  alias Comma.Repo
  alias CommaWeb.{Proactive, RecommendationOAuthSource, RecommendationRenderer}
  alias CommaWeb.{RecommendationMemberIdentity, RecommendationMemberRead, RecommendationRuntime}

  @own_limit 60
  @own_bytes 24_000
  @quote_chars 300
  @timeout_ms 60_000

  @doc "Queues the day's open thread refresh; later calls the same day join it."
  def enqueue(%RecommendationProfile{} = profile),
    do: %{"profile_id" => profile.id} |> new() |> then(&Oban.insert(Comma.Oban, &1))

  @impl Oban.Worker
  def timeout(_job), do: 120_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    Logger.metadata(profile_id: profile_id)

    with %RecommendationProfile{} = profile <- Repo.get(RecommendationProfile, profile_id),
         {:ok, workspace} <- owned(profile) do
      if eligible?(workspace, profile),
        do: run(workspace, profile),
        else: Comma.OpenThreads.purge(profile.id)
    else
      _ -> :ok
    end
  end

  defp owned(profile) do
    with {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(profile.user_id),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, %{}, profile.workspace_id),
         true <- workspace["owner_user_id"] == profile.user_id,
         do: {:ok, workspace},
         else: (_ -> :error)
  end

  defp eligible?(workspace, profile),
    do:
      personal?(workspace, profile.user_id) and
        Proactive.automatic?(workspace["default_group_id"], profile.user_id) == {:ok, true}

  defp run(workspace, profile) do
    case refresh(workspace, profile) do
      {:ok, counts} ->
        Logger.info("open_threads refreshed open=#{counts.open}")
        CommaWeb.ProactiveNotebook.enqueue(workspace["default_group_id"], profile.user_id)

      {:error, reason} = error ->
        Logger.warning("open_threads failed reason=#{inspect(reason, limit: 3)}")

        # Without credits a retry fails the same way; the next day tries again.
        case reason do
          :insufficient_credits -> {:cancel, reason}
          {:billing_unavailable, _} -> {:cancel, reason}
          :member_source_changed -> :ok
          _ -> error
        end
    end
  end

  defp personal?(workspace, owner),
    do: Enum.map(workspace["members"] || [], & &1["user_id"]) in [[], [owner]]

  # The first enabled Slack source the owner reads as themselves, as the
  # portrait reads it.
  defp refresh(workspace, profile) do
    case for(%{"enabled" => true, "appId" => "slack"} = s <- profile.sources || [], do: s) do
      [%{"connectionId" => source_id} = source | _] when is_binary(source_id) ->
        with {:ok, identity} <-
               RecommendationMemberIdentity.resolve(workspace, profile.user_id, source),
             {:ok, own, subject} <-
               RecommendationOAuthSource.own_slack_messages(
                 workspace,
                 profile.user_id,
                 source,
                 RecommendationMemberRead.deadline(),
                 replies: true
               ),
             true <- subject["provider_user_id"] == identity["provider_user_id"],
             cursor = Comma.OpenThreads.cursor(profile.id, source_id),
             fresh = fresh(own, cursor, SystemsClock.utc_now()),
             open =
               Enum.filter(
                 Comma.OpenThreads.list(profile.id),
                 &(&1.source_id == source_id and &1.status == "open")
               ),
             {:ok, entries} <- discover(workspace, profile, fresh, open, subject["handle"]) do
          {tracked, checked, closed} = track(workspace, profile, source, source_id)
          gap?(own, cursor) && Logger.info("open_threads skipped messages older than the read")

          Comma.OpenThreads.record(profile.id, source_id, source["toolkit"] || "slack", entries,
            current?: &current?(&1, source_id, identity),
            read_until: newest_ts([cursor | Enum.map(fresh, & &1["ts"])]),
            tracked: tracked,
            checked: checked,
            closed: closed
          )
        else
          false -> {:error, :member_source_changed}
          error -> error
        end

      _ ->
        {:ok, %{open: 0}}
    end
  end

  # The read's account is still the source's account, and the owner still
  # holds a single-member Workspace with automatic messages on.
  defp current?(profile, source_id, identity) do
    RecommendationRuntime.member_subjects_valid?(profile, %{source_id => identity}) and
      case owned(profile) do
        {:ok, workspace} -> eligible?(workspace, profile)
        :error -> false
      end
  end

  # The own messages after the cursor, each judged once. The first refresh
  # starts a day back, so earlier history is not read as news.
  defp fresh(own, nil, now) do
    since = DateTime.to_unix(now) - 86_400
    Enum.filter(own, &(ts_seconds(&1["ts"]) > since))
  end

  defp fresh(own, cursor, _now),
    do: Enum.filter(own, &(ts_seconds(&1["ts"]) > ts_seconds(cursor)))

  defp newest_ts(timestamps) do
    timestamps
    |> Enum.filter(&is_binary/1)
    |> Enum.max_by(&ts_seconds/1, fn -> nil end)
  end

  defp ts_seconds(ts) when is_binary(ts) do
    case Float.parse(ts) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp ts_seconds(_ts), do: 0.0

  # New messages in bounded batches, with the open threads followed.
  defp discover(_workspace, _profile, [], _open, _handle), do: {:ok, []}

  defp discover(workspace, profile, fresh, open, handle) do
    fresh
    |> batches()
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, found} ->
      case extract(workspace, profile, input(batch, open, handle)) do
        {:ok, entries} -> {:cont, {:ok, found ++ entries}}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Splits new messages into model inputs that each fit #{@own_limit} messages
  and #{@own_bytes} bytes, so every message reaches the model. A message too
  large alone loses its replies and is cut to fit.
  """
  def batches(messages) do
    messages
    |> Enum.map(&fit/1)
    |> Enum.chunk_while(
      {[], 0},
      fn message, {batch, bytes} ->
        size = byte_size(Jason.encode!(message))

        if batch != [] and (length(batch) >= @own_limit or bytes + size > @own_bytes),
          do: {:cont, Enum.reverse(batch), {[message], size}},
          else: {:cont, {[message | batch], bytes + size}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {batch, _} -> {:cont, Enum.reverse(batch), {[], 0}}
      end
    )
  end

  # A message too large alone loses its replies, and its thread start and
  # text are cut by encoded bytes, never inside a character, until it fits.
  defp fit(message) do
    if byte_size(Jason.encode!(message)) <= @own_bytes,
      do: message,
      else: shrink(Map.delete(message, "replies"), div(@own_bytes, 2))
  end

  defp shrink(message, limit) do
    cut =
      message
      |> Map.update("text", "", &cut_bytes(&1 || "", limit))
      |> Map.update("thread", nil, &(&1 && cut_bytes(&1, div(limit, 4))))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    if byte_size(Jason.encode!(cut)) <= @own_bytes or limit == 0,
      do: cut,
      else: shrink(message, div(limit, 2))
  end

  defp cut_bytes(text, limit) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, bytes} ->
      size = byte_size(Jason.encode!(grapheme)) - 2

      if bytes + size > limit,
        do: {:halt, {kept, bytes}},
        else: {:cont, {[grapheme | kept], bytes + size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  # The newest 100 own messages reach back past the cursor, or some sent
  # since the last read were never returned.
  defp gap?(_own, nil), do: false
  defp gap?([], _cursor), do: false

  defp gap?(own, cursor),
    do: Enum.all?(own, &(ts_seconds(&1["ts"]) > ts_seconds(cursor))) and length(own) >= 100

  @doc """
  Reads the news of the source's tracked open threads and asks the model
  which are closed. Returns the IDs whose thread was read, the newest ts
  read per thread the model judged, and the closed thread IDs. A thread
  the model did not judge keeps its checked ts, so its news is read again.
  """
  def track(workspace, profile, source, source_id) do
    tracked = Map.new(Comma.OpenThreads.tracked(profile.id, source_id), &{&1.id, &1})

    threads =
      Map.new(
        Enum.flat_map(tracked, fn {id, thread} ->
          case split_key(thread.thread_key) do
            {channel, ts} when is_binary(channel) ->
              [{id, {channel, ts, thread.checked_ts || url_ts(thread.url) || ts}}]

            _ ->
              []
          end
        end)
      )

    with true <- threads != %{},
         {:ok, read} <-
           RecommendationOAuthSource.slack_thread_news(
             workspace,
             profile.user_id,
             source,
             threads
           ) do
      news = Map.reject(read, fn {_id, messages} -> messages == [] end)
      {judged, closed} = closed(workspace, news, tracked)

      checked =
        for {id, messages} <- news, id in judged, into: %{}, do: {id, List.last(messages)["ts"]}

      {Map.keys(read), checked, closed}
    else
      _ -> {[], %{}, []}
    end
  end

  defp closed(_workspace, news, _tracked) when news == %{}, do: {[], []}

  defp closed(workspace, news, tracked) do
    input = %{
      "items" =>
        Enum.map(news, fn {id, messages} ->
          thread = tracked[id]

          %{
            "id" => id,
            "kind" => thread.kind,
            "summary" => thread.summary,
            "quote" => thread.quote,
            "messages" => Enum.map(messages, &Map.take(&1, ~w(from text)))
          }
        end)
    }

    with {:ok, model} <- RecommendationRuntime.model(workspace["router_agent_id"]),
         {:ok, %{"items" => items}} when is_list(items) <-
           RecommendationRenderer.open_threads_check(workspace, model, input, @timeout_ms) do
      judged =
        for %{"id" => id, "open" => open} <- items,
            is_boolean(open) and Map.has_key?(news, id),
            do: {id, open}

      {Enum.map(judged, &elem(&1, 0)), for({id, false} <- judged, do: id)}
    else
      _ -> {[], []}
    end
  end

  defp split_key("slack:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [channel, ts] -> {channel, ts}
      _ -> {nil, nil}
    end
  end

  defp split_key(_key), do: {nil, nil}

  defp url_ts(url) do
    case Regex.run(~r</p(\d{7,})>, url || "") do
      [_, digits] -> String.slice(digits, 0..-7//1) <> "." <> String.slice(digits, -6, 6)
      _ -> nil
    end
  end

  defp extract(workspace, profile, input) do
    with {:ok, model} <- RecommendationRuntime.model(workspace["router_agent_id"]),
         {:ok, answer} <-
           RecommendationRenderer.open_threads(workspace, model, profile, input, @timeout_ms),
         do: build(answer, input)
  end

  @doc """
  The model input: the owner's new own messages (bounded, in the order Slack
  returned them), the open threads already followed, and the owner's handle.
  """
  def input(own_messages, previous, handle) do
    own =
      own_messages
      |> Enum.take(@own_limit)
      |> Enum.reduce_while({[], @own_bytes}, fn message, {kept, budget} ->
        size = byte_size(Jason.encode!(message))

        if size > budget,
          do: {:halt, {kept, budget}},
          else: {:cont, {[message | kept], budget - size}}
      end)
      |> elem(0)
      |> Enum.reverse()

    %{
      "member" => handle,
      "ownMessages" => own,
      "previous" =>
        for(
          %OpenThread{status: status} = thread <- previous,
          status == "open",
          do: %{
            "kind" => thread.kind,
            "status" => status,
            "summary" => thread.summary,
            "evidence" => [thread.url]
          }
        )
    }
  end

  @doc """
  The threads of a model answer that cite at least one permalink of the
  owner's messages in the input, as `Comma.OpenThreads.record/5` entries.
  The first cited message's Slack thread keys the thread; the newest cited
  message of that thread gives its link, quote and evidence time. A due date that is not a date is
  dropped. Returns `{:error, :invalid_open_threads}` for an answer that is not
  a list of threads.
  """
  def build(%{"threads" => threads}, input) when is_list(threads) do
    messages = Map.new(input["ownMessages"] || [], &{&1["permalink"], &1})

    {:ok,
     Enum.flat_map(threads, fn
       %{"kind" => kind, "status" => status, "summary" => summary, "evidence" => evidence} =
           thread
       when is_binary(summary) and summary != "" and is_list(evidence) ->
         cited =
           Enum.flat_map(evidence, fn link ->
             with %{} = message <- messages[link],
                  %DateTime{} = at <- ts_time(message["ts"]),
                  do: [{link, message, at}],
                  else: (_ -> [])
           end)

         with [{first, _, _} | _] <- cited,
              key when is_binary(key) <- thread_key(first) do
           # One thread: evidence from another thread is not this one's.
           cited = Enum.filter(cited, &(thread_key(elem(&1, 0)) == key))
           {url, newest, at} = Enum.max_by(cited, &elem(&1, 2), DateTime)

           [
             %{
               "thread_key" => key,
               "kind" => kind,
               "status" => status,
               "summary" => clean(summary, 200),
               "quote" => clean(newest["text"], @quote_chars) || "",
               "counterpart" => clean(thread["counterpart"], 80),
               "url" => url,
               "due_on" => due(thread["due"]),
               "evidence_at" => at,
               "checked_ts" => newest["ts"]
             }
           ]
         else
           _ -> []
         end

       _ ->
         []
     end)}
  end

  def build(_answer, _input), do: {:error, :invalid_open_threads}

  @doc """
  The Slack thread a permalink belongs to, as `slack:<channel>/<thread ts>`:
  a reply's `thread_ts`, or the message's own ts for a thread start.
  """
  def thread_key(permalink) when is_binary(permalink) do
    with [_, channel, digits] <-
           Regex.run(~r<slack\.com/archives/([A-Z0-9]+)/p(\d{7,})>, permalink),
         uri = URI.parse(permalink),
         query = URI.decode_query(uri.query || "") do
      thread =
        case query["thread_ts"] do
          ts when is_binary(ts) and ts != "" -> ts
          _ -> String.slice(digits, 0..-7//1) <> "." <> String.slice(digits, -6, 6)
        end

      "slack:" <> channel <> "/" <> thread
    else
      _ -> nil
    end
  end

  def thread_key(_permalink), do: nil

  defp ts_time(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {seconds, _rest} when seconds > 0 -> DateTime.from_unix!(seconds * 1_000_000, :microsecond)
      _ -> nil
    end
  end

  defp ts_time(_ts), do: nil

  defp due(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp due(_text), do: nil

  defp clean(text, limit) when is_binary(text) do
    case text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, limit) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp clean(_text, _limit), do: nil
end
