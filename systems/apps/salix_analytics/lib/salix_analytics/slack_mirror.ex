defmodule SalixAnalytics.SlackMirror do
  @moduledoc """
  Storage adapter for the Slack message mirror.

  `SalixIM.SlackMessageMirror` owns the seam and the row shape; this app owns
  the ClickHouse destination, the same way `SalixAgent.EventArchive` and
  `SalixAnalytics.EventArchive` split. Production wires it in through
  `:salix_im, :slack_message_mirror_mod`.

  `record_batch/1` and `record_reaction_batch/1` insert inline and report
  whether the insert landed. Both of their callers — the outbox drainer and
  the history backfill — discard their own durable record of the rows on
  `:ok`, so an answer that meant "queued" where they need "durable" would
  lose messages silently. There is no buffered path here any more; the
  webhook's buffer is the PostgreSQL outbox.

  `SalixIM.SlackMessageMirror`'s `@callback` is implemented structurally rather
  than with `@behaviour`: this app does not depend on `salix_im`, which is what
  keeps the seam one-directional. `SalixAnalytics.EventArchive` is wired the
  same way.
  """

  alias SalixAnalytics.SlackMirror.{ReactionSink, Sink}

  @doc "Inserts one message batch synchronously and reports whether it landed."
  @spec record_batch([map()]) :: :ok | {:error, term()}
  def record_batch(rows) do
    canonical = Enum.map(rows, &Map.drop(&1, ["_semantic_context", "_mirror_outbox_id"]))

    with :ok <- write_kind(canonical, &Sink.readiness/0, &Sink.write/1),
         :ok <- write_kind(payload_rows(rows), &Sink.payloads_readiness/0, &Sink.write_payloads/1) do
      # Optional local metadata only. A dead/full semantic queue cannot change
      # the durable mirror acknowledgment or make this caller wait for GPU IO.
      SalixAnalytics.SlackSemanticQueue.offer_live(rows)
      :ok
    end
  end

  @doc "Inserts one reaction batch synchronously and reports whether it landed."
  @spec record_reaction_batch([map()]) :: :ok | {:error, term()}
  def record_reaction_batch(rows),
    do: write_kind(rows, &ReactionSink.readiness/0, &ReactionSink.write/1)

  @spec record_pin_batch([map()]) :: :ok | {:error, term()}
  def record_pin_batch(rows),
    do: write_kind(rows, &Sink.pins_readiness/0, &Sink.write_pins/1)

  @spec record_metadata_batch([map()]) :: :ok | {:error, term()}
  def record_metadata_batch(rows),
    do: write_kind(rows, &Sink.metadata_readiness/0, &Sink.write_metadata/1)

  @doc """
  Records that the live webhook path observed these messages.

  History backfill must not call this. Patrol's change stream is this table,
  not `ingest_source` on the reconstructed message row.
  """
  @spec record_event_triggers([map()]) :: :ok | {:error, term()}
  def record_event_triggers(rows),
    do: write_kind(rows, &Sink.event_triggers_readiness/0, &Sink.write_event_triggers/1)

  defp payload_rows(rows) do
    Enum.flat_map(rows, fn row ->
      case row["payload"] do
        payload when is_binary(payload) and payload != "" ->
          [
            Map.take(row, [
              "event_date",
              "tenant_id",
              "workspace_id",
              "channel_id",
              "message_ts_us",
              "version",
              "payload",
              "text",
              "body_text",
              "observed_ts_us",
              "source_write_id"
            ])
          ]

        _missing ->
          []
      end
    end)
  end

  defp write_kind([], _ready, _write), do: :ok

  defp write_kind(rows, ready, write) when is_list(rows) do
    # The layout probe runs first: a ReplacingMergeTree on the wrong key merges
    # away rows it believes are duplicates. An insert that "succeeded" into
    # such a table would let a caller discard rows the engine is about to
    # destroy. An unreachable server is a retryable outage, not a mismatch, and
    # stays distinguishable in the reason.
    with :ok <- ready.() do
      rows
      |> Enum.chunk_every(batch_rows())
      |> Enum.reduce_while(:ok, fn chunk, :ok ->
        case write.(chunk) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp batch_rows do
    :salix_analytics
    |> Application.get_env(:slack_mirror, [])
    |> Keyword.get(:batch_size, 200)
  end
end
