defmodule CommaWeb.ParticipantHistoryStream do
  @moduledoc """
  Authorized, exact-Participant execution-history read stream. It changes no
  Conversation or runtime state. Modeled in tla/session-history/SessionHistoryLive.tla.

  Each backfill reads at most 50 records at a time from one fixed Session, with
  an immutable before cursor. Recent-window batches never enter the manual
  ledger. A checkpoint advances only after the complete catch-up was sent.
  Connections expire after 55 seconds and reauthorize on reconnect. PubSub
  hints wake catch-up; heartbeats do not scan storage. No progress claim is made
  across permanent disconnect, owner loss, or an unbounded producer rate.
  """
  import Plug.Conn
  alias CommaWeb.ParticipantHistory

  def send(conn, context, after_id, window_ms \\ 55_000) do
    topic = CommaWeb.PubSubNotifier.topic(context.agent["agent_id"])
    pubsub = Application.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub)
    :ok = Phoenix.PubSub.subscribe(pubsub, topic)
    deadline = System.monotonic_time(:millisecond) + window_ms

    conn =
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    try do
      with {:ok, conn, recent_head} <- catch_up(conn, context, nil, "recent", deadline),
           {:ok, conn, head} <-
             catch_up(conn, context, after_id || recent_head, "update", deadline) do
        loop(conn, context, head, deadline)
      else
        _ -> conn
      end
    after
      Phoenix.PubSub.unsubscribe(pubsub, topic)
    end
  end

  defp catch_up(conn, context, after_id, phase, deadline) do
    context = with_live(context)

    with {:ok, page} <- ParticipantHistory.page(context.agent, context.session_id, 50, nil) do
      head =
        case List.last(page["records"]) do
          nil -> after_id
          record -> record["id"]
        end

      with {:ok, conn} <- batches(conn, context, page, after_id, phase, deadline) do
        if phase == "update" do
          with {:ok, conn} <- frame(conn, context, [], "checkpoint", head), do: {:ok, conn, head}
        else
          {:ok, conn, head}
        end
      end
    end
  end

  defp batches(conn, context, page, after_id, phase, deadline) do
    cutoff = System.system_time(:millisecond) - 180_000

    records =
      Enum.filter(page["records"], fn record ->
        if phase == "recent" do
          (get_in(record, ["execution", "observed_at_ms"]) || record["timestamp_ms"] || 0) >=
            cutoff
        else
          # Nil means an empty Session was observed: its first committed batch
          # must be sent before advancing the checkpoint. Modeled by CatchUp in
          # SessionHistoryLive.tla (UnsafeEmptyUpdate reproduces the old guard).
          after_id == nil or newer?(record["id"], after_id)
        end
      end)

    continue = page["has_more"] and records != [] and length(records) == length(page["records"])

    with {:ok, conn} <- frame(conn, context, records, phase, nil) do
      cond do
        System.monotonic_time(:millisecond) >= deadline ->
          {:error, :timeout}

        continue ->
          with {:ok, older} <-
                 ParticipantHistory.page(
                   context.agent,
                   context.session_id,
                   50,
                   page["next_before"]
                 ) do
            batches(conn, context, older, after_id, phase, deadline)
          end

        true ->
          {:ok, conn}
      end
    end
  end

  defp loop(conn, context, head, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      conn
    else
      receive do
        {:salix_agent_event, agent_id, {:execution_history_updated, session_id}} ->
          if agent_id == context.agent["agent_id"] and session_id == context.session_id do
            case frame(conn, with_live(context), [], "checkpoint", head) do
              {:ok, conn} -> loop(conn, context, head, deadline)
              _ -> conn
            end
          else
            loop(conn, context, head, deadline)
          end

        {:salix_agent_event, agent_id, event} ->
          if agent_id == context.agent["agent_id"] and session_event?(event, context.session_id) do
            with {:ok, conn, head} <- catch_up(conn, context, head, "update", deadline) do
              loop(conn, context, head, deadline)
            else
              _ -> conn
            end
          else
            loop(conn, context, head, deadline)
          end
      after
        min(5_000, remaining) ->
          case frame(conn, with_live(context), [], "checkpoint", head) do
            {:ok, conn} -> loop(conn, context, head, deadline)
            _ -> conn
          end
      end
    end
  end

  defp session_event?({:session_updated, session_id}, session_id), do: true
  defp session_event?(_, _), do: false

  defp newer?(id, after_id) do
    case {Integer.parse(id), Integer.parse(after_id)} do
      {{a, ""}, {b, ""}} -> a > b
      _ -> id > after_id
    end
  end

  defp with_live(context) do
    live =
      case SalixAgent.AgentActor.execution_history_snapshot(
             context.agent["agent_id"],
             context.session_id
           ) do
        {:ok, records} -> records
        {:error, _} -> []
      end

    Map.put(context, :live_records, live)
  end

  defp frame(conn, context, records, phase, checkpoint) do
    data =
      Map.merge(context.target, %{
        "records" => records,
        "phase" => phase,
        "checkpoint" => checkpoint,
        "live_records" => context.live_records,
        "server_time_ms" => System.system_time(:millisecond)
      })

    chunk(conn, ["event: history\ndata: ", Jason.encode!(data), "\n\n"])
  end
end
