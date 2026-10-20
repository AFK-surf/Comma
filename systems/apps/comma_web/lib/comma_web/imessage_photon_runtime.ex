defmodule CommaWeb.IMessagePhotonRuntime do
  @moduledoc """
  Receiver for Comma iMessage over Photon shared lines.

  Photon lists received Messages through its REST API. A pass reads the
  Messages created since the saved cursor, oldest first, and hands each one to
  `CommaWeb.IMessageIntegration.handle_event/1`. A verified webhook wakes the
  receiver at once. A timer runs a pass every minute, which recovers webhooks
  that did not arrive.

  Photon lists are eventually consistent, so each pass re-reads a two-minute
  overlap. The cursor keeps the IDs handled in that overlap and skips them.
  The canonical Session also deduplicates stable source IDs. A Message that
  becomes visible after the overlap has passed is not received.

  PostgreSQL session ownership serializes passes across Pods. Each pass also
  releases line assignments that no binding or open attempt uses.
  """
  use SystemsRuntime.Server
  require Logger

  alias Comma.{IMessageLinks, Repo}
  alias SalixIM.PhotonIMessage

  @poll_ms 60_000
  @busy_retry_ms 2_000
  @busy_retries 15
  @max_failures 3
  @overlap_seconds 120
  @max_pages 5
  @max_seen 1_000
  @quiet_ms 2_000
  @max_wait_ms 10_000
  # An assignment younger than this can belong to an attempt that is still
  # being created, so the reconcile leaves it.
  @assignment_grace_seconds 15 * 60

  def child_specs, do: if(PhotonIMessage.configured?(), do: [__MODULE__], else: [])

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Wakes the local receiver. Returns `:ok` also when this Pod runs none."
  def poke do
    case SystemsRuntime.Proc.whereis(__MODULE__) do
      nil -> :ok
      pid -> SystemsRuntime.Proc.send(pid, :poke)
    end

    :ok
  end

  @impl true
  def init(_opts) do
    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :poll)
    {:ok, %{task: nil, kind: nil, failures: 0, again: false, busy: 0, timer: nil}}
  end

  @impl true
  # A webhook runs a pass also after failures: it is new evidence that Photon
  # is reachable. The timer stops after three failed passes in a row.
  def handle_info(:poke, %{task: nil} = state), do: {:noreply, start(state, :poke)}
  def handle_info(:poke, state), do: {:noreply, %{state | again: true}}

  def handle_info(:poll, %{task: nil, failures: failures} = state)
      when failures < @max_failures,
      do: {:noreply, start(state, :poll)}

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])

    {failures, busy} =
      case result do
        :ok -> {0, 0}
        {:hold, _ms} -> {0, 0}
        :standby -> {state.failures, state.busy + 1}
        {:error, _} -> {state.failures + 1, 0}
      end

    state = %{state | task: nil, failures: failures, busy: busy}

    cond do
      state.again ->
        {:noreply, start(%{state | again: false}, :poke)}

      # Another Pod holds the pass. A webhook must not wait for the next poll:
      # the holder can have read the list before this Message arrived.
      result == :standby and state.kind == :poke and busy <= @busy_retries ->
        SystemsClock.send_after(SystemsRuntime.Proc.self(), :poke, @busy_retry_ms)
        {:noreply, state}

      # A burst waits for its quiet window: run again when it is due.
      match?({:hold, _}, result) ->
        {:hold, ms} = result
        SystemsClock.send_after(SystemsRuntime.Proc.self(), :poke, ms + 1)
        {:noreply, schedule(state)}

      failures >= @max_failures ->
        Logger.error(
          "Photon iMessage receiver paused after three failed passes; a webhook or a restart resumes it"
        )

        {:noreply, state}

      true ->
        {:noreply, schedule(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start(state, kind) do
    task = SystemsRuntime.Task.async(fn -> run_once(reconcile_assignments: kind == :poll) end)
    %{state | task: task, kind: kind}
  end

  defp schedule(state) do
    SystemsClock.cancel_timer(state.timer)
    %{state | timer: SystemsClock.send_after(SystemsRuntime.Proc.self(), :poll, @poll_ms)}
  end

  @doc """
  Runs one pass when no other Pod holds it. Timer passes also reconcile line
  assignments, so a burst of webhooks adds no assignment reads.
  """
  def run_once(opts \\ []) do
    Repo.checkout(
      fn ->
        case Repo.query!("SELECT pg_try_advisory_lock(4412741, 21578)").rows do
          [[true]] ->
            try do
              receive_pass(opts)
            after
              Repo.query!("SELECT pg_advisory_unlock(4412741, 21578)")
            end

          [[false]] ->
            :standby
        end
      end,
      timeout: 120_000
    )
  rescue
    _ -> {:error, :imessage_receive_unavailable}
  catch
    :exit, _ -> {:error, :imessage_receive_unavailable}
  end

  defp receive_pass(opts) do
    IMessageLinks.prune_expired_claims()
    if Keyword.get(opts, :reconcile_assignments, false), do: release_unused_assignments()

    with {:ok, cursor} <- cursor() do
      drain(cursor, nil, @max_pages)
    end
  end

  # Reads every page first, so a burst that spans two pages stays one burst.
  defp drain(cursor, page_token, pages, acc \\ []) do
    since = DateTime.add(cursor.since, -@overlap_seconds, :second)

    with {:ok, items, next} <- PhotonIMessage.list_received(since, page_token) do
      acc = acc ++ items

      if is_binary(next) and next != "" and pages > 1,
        do: drain(cursor, next, pages - 1, acc),
        else: handle_items(acc, cursor)
    end
  end

  # iOS sends an image with its text as two Messages. A bound person's
  # Messages that follow each other within @quiet_ms form one burst and one
  # Router input. A burst waits until @quiet_ms passed since this receiver
  # first saw its latest Message, or @max_wait_ms since it saw its first one.
  # Quiet time uses local first-seen times, so Photon's clock does not matter.
  # A waiting burst is not checkpointed: a crash replays it; it never drops.
  defp handle_items(items, cursor) do
    now = SystemsClock.utc_now()

    {ready, bursts, cursor} =
      items
      |> Enum.flat_map(fn item ->
        with id when is_binary(id) <- item["id"],
             %DateTime{} = at <- created_at(item),
             false <- Map.has_key?(cursor.seen, id) do
          [{id, at, PhotonIMessage.to_event(item)}]
        else
          _ -> []
        end
      end)
      |> Enum.sort_by(fn {_id, at, _event} -> at end, DateTime)
      |> Enum.reduce({[], %{}, cursor}, fn
        {id, at, :ignore}, {ready, bursts, cursor} ->
          {ready ++ [{:ignore, id, at}], bursts, cursor}

        {id, at, {:ok, event}}, {ready, bursts, cursor} ->
          cursor = %{cursor | held: Map.put_new(cursor.held, id, now)}

          case burst_key(event) do
            nil ->
              {ready ++ [{:events, [{id, at, event}]}], bursts, cursor}

            key ->
              case bursts[key] do
                [{_, last_at, _} | _] = burst ->
                  if DateTime.diff(at, last_at, :millisecond) <= @quiet_ms,
                    do: {ready, Map.put(bursts, key, [{id, at, event} | burst]), cursor},
                    else:
                      {ready ++ [{:events, Enum.reverse(burst)}],
                       Map.put(bursts, key, [{id, at, event}]), cursor}

                nil ->
                  {ready, Map.put(bursts, key, [{id, at, event}]), cursor}
              end
          end
      end)

    {due, waiting} =
      bursts
      |> Map.values()
      |> Enum.map(&Enum.reverse/1)
      |> Enum.split_with(&(wait_ms(&1, cursor, now) == 0))

    work = ready ++ Enum.map(due, &{:events, &1})

    case handle_work(work, cursor) do
      {:ok, cursor} ->
        save_cursor(cursor)

        case Enum.map(waiting, &wait_ms(&1, cursor, now)) do
          [] -> :ok
          waits -> {:hold, Enum.min(waits)}
        end

      {:error, _} = error ->
        error
    end
  end

  defp handle_work([], cursor), do: {:ok, cursor}

  defp handle_work([{:ignore, id, at} | rest], cursor),
    do: handle_work(rest, checkpoint(cursor, id, at))

  defp handle_work([{:events, events} | rest], cursor) do
    case CommaWeb.IMessageIntegration.handle_event(merge(events)) do
      :ok ->
        cursor = Enum.reduce(events, cursor, fn {id, at, _}, c -> checkpoint(c, id, at) end)
        handle_work(rest, cursor)

      {:error, _} = error ->
        save_cursor(cursor)
        error
    end
  end

  # Only Messages that go to the Agent wait: a bound person's private chat.
  # Connection codes and other commands are handled one by one at once.
  defp burst_key(%{"message" => %{"sender_handle" => sender, "chat_guid" => chat} = message}) do
    text = String.trim(message["text"] || "")

    with false <- String.starts_with?(text, "bridgebot"),
         false <- IMessageLinks.photon_claim_code?(sender, text),
         %{transport: "photon", chat_guid: ^chat} <- IMessageLinks.get_link_by_sender(sender) do
      {sender, chat}
    else
      _ -> nil
    end
  end

  defp burst_key(_event), do: nil

  defp wait_ms([{first, _, _} | _] = burst, cursor, now) do
    {last, _, _} = List.last(burst)
    seen = fn id -> Map.get(cursor.held, id, now) end
    quiet = @quiet_ms - DateTime.diff(now, seen.(last), :millisecond)
    max = @max_wait_ms - DateTime.diff(now, seen.(first), :millisecond)
    max(min(quiet, max), 0)
  end

  @doc false
  # One event for a burst, in order: texts joined by new lines, attachments in
  # order. Its source ID names every Message, so a burst that later grows
  # (a Message that became visible late) is a new input, never a dropped one.
  def merge([{_id, _at, event}]), do: event

  def merge([{_, _, first} | _] = events) do
    messages = Enum.map(events, fn {_, _, event} -> event["message"] end)
    {last_id, _, _} = List.last(events)
    ids = Enum.map(events, fn {id, _, _} -> id end)
    digest = :crypto.hash(:sha256, Enum.join(ids, ",")) |> Base.url_encode64(padding: false)

    texts =
      messages |> Enum.map(&(&1["text"] || "")) |> Enum.reject(&(String.trim(&1) == ""))

    message =
      first["message"]
      |> Map.merge(%{
        "receipt_id" => "burst:" <> binary_part(digest, 0, 22),
        "text" => if(texts == [], do: nil, else: Enum.join(texts, "\n")),
        "attachments" => Enum.flat_map(messages, &List.wrap(&1["attachments"])),
        "reply_to_message_id" => Enum.find_value(messages, & &1["reply_to_message_id"]),
        "source_message_ids" => ids
      })

    %{first | "event_id" => last_id, "message" => message}
  end

  defp checkpoint(cursor, id, created_at) do
    since =
      if DateTime.compare(created_at, cursor.since) == :gt, do: created_at, else: cursor.since

    floor = DateTime.add(since, -@overlap_seconds, :second)

    seen =
      cursor.seen
      |> Map.put(id, created_at)
      |> Enum.reject(fn {_id, at} -> DateTime.compare(at, floor) == :lt end)
      |> Enum.sort_by(fn {_id, at} -> at end, {:desc, DateTime})
      |> Enum.take(@max_seen)
      |> Map.new()

    %{cursor | since: since, seen: seen, held: Map.delete(cursor.held, id)}
  end

  defp created_at(%{"createdAt" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp created_at(_item), do: nil

  # A fresh cursor starts now: the receiver does not replay older history.
  defp cursor do
    case Repo.query!("SELECT event_id FROM comma_imessage_relay_cursors WHERE relay_id = $1", [
           PhotonIMessage.relay_id()
         ]).rows do
      [[value]] ->
        decode_cursor(value)

      [] ->
        cursor = %{since: SystemsClock.utc_now(), seen: %{}, held: %{}}

        Repo.query!(
          "INSERT INTO comma_imessage_relay_cursors (relay_id, event_id, inserted_at, updated_at) VALUES ($1, $2, timezone('utc', now()), timestamp '1970-01-01 00:00:00')",
          [PhotonIMessage.relay_id(), encode_cursor(cursor)]
        )

        {:ok, cursor}
    end
  end

  defp decode_cursor(value) do
    with {:ok, %{"since" => since, "seen" => seen} = raw} when is_map(seen) <- Jason.decode(value),
         {:ok, since, _offset} <- DateTime.from_iso8601(since) do
      times = fn map ->
        for {id, at} <- map, {:ok, at, _} <- [DateTime.from_iso8601(at)], into: %{}, do: {id, at}
      end

      {:ok, %{since: since, seen: times.(seen), held: times.(raw["held"] || %{})}}
    else
      _ -> {:error, :imessage_cursor_invalid}
    end
  end

  defp encode_cursor(cursor) do
    Jason.encode!(%{
      "since" => DateTime.to_iso8601(cursor.since),
      "seen" => Map.new(cursor.seen, fn {id, at} -> {id, DateTime.to_iso8601(at)} end),
      # First-seen times of Messages in a burst that still waits (bounded by bursts).
      "held" =>
        cursor.held
        |> Enum.sort_by(fn {_id, at} -> at end, {:desc, DateTime})
        |> Enum.take(@max_seen)
        |> Map.new(fn {id, at} -> {id, DateTime.to_iso8601(at)} end)
    })
  end

  defp save_cursor(cursor) do
    Repo.query!(
      "UPDATE comma_imessage_relay_cursors SET event_id = $2, updated_at = timezone('utc', now()) WHERE relay_id = $1",
      [PhotonIMessage.relay_id(), encode_cursor(cursor)]
    )

    :ok
  end

  # Free plans have few seats. A seat that no binding or open attempt uses is
  # released: after a cancel, an expiry, a replaced attempt or a failed release.
  # The Photon project must serve only this Comma deployment.
  defp release_unused_assignments do
    with {:ok, assignments} <- PhotonIMessage.list_assignments(1) do
      in_use = IMessageLinks.photon_handles_in_use()
      cutoff = DateTime.add(SystemsClock.utc_now(), -@assignment_grace_seconds, :second)

      for %{"assignmentId" => id} = assignment <- assignments,
          is_nil(assignment["releasedAt"]),
          not MapSet.member?(in_use, PhotonIMessage.normalize_handle(assignment["handle"])),
          older?(assignment["createdAt"], cutoff) do
        PhotonIMessage.release_assignment(id)
      end
    end

    :ok
  end

  defp older?(value, cutoff) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.compare(at, cutoff) == :lt
      _ -> false
    end
  end

  defp older?(_value, _cutoff), do: false

  def online? do
    PhotonIMessage.configured?() and
      case Repo.query(
             "SELECT updated_at > timezone('utc', now()) - interval '150 seconds' FROM comma_imessage_relay_cursors WHERE relay_id = $1",
             [PhotonIMessage.relay_id()]
           ) do
        {:ok, %{rows: [[true]]}} -> true
        _ -> false
      end
  end
end
