defmodule SalixIM.SlackMessageMirror do
  @moduledoc """
  Seam for mirroring observed Slack messages into ClickHouse.

  `observe/2` is called once per authenticated Slack event, from the single
  point in `SalixIM.ProviderHTTP` every event crosses. It normalizes the event
  into a mirror row and appends it to `SalixStore.SlackMirrorOutbox`; the
  `OutboxDrainer` on each Pod moves rows from there into ClickHouse through
  `write_batch/1` or `write_reaction_batch/1`. Mirroring is off unless
  `:salix_im, :slack_message_mirror_mod` names a storage adapter, and with it
  off `observe/2` builds nothing.

  Two rules this module exists to enforce.

  **A successful Slack ACK means the event is in the outbox.** The webhook
  inserts one PostgreSQL row; PostgreSQL is already on the routing path.
  If that insert fails, `observe/2` returns an error so Slack retries. A
  ClickHouse outage does not fail the callback: the row stays in the outbox
  until the drainer writes it. Events Slack never delivers, or stops retrying,
  remain unrecoverable — history excludes deletes.

  **It is called before the routing relevance filter, not after.**
  `consume_unbound_slack_event/2` admits only subtypes that carry a routable
  body, which correctly drops `message_changed` and `message_deleted`. Slack
  marks both `hidden: true`, and hidden subtypes are excluded from
  `conversations.history` — so an edit or a deletion this side does not see
  here can never be recovered from the API afterwards. Mirroring downstream of
  that filter would build an index that silently keeps deleted messages.

  ## The two writers

  The outbox drainer and `SalixIM.SlackMessageMirror.Backfill` both write
  through the blocking batch seams, which report failure. The drainer deletes
  an outbox row only on `:ok`; the backfill lowers a channel's watermark only
  on `:ok`. Neither ever proceeds on a guess, and both rely on the same fact
  to be safe under retry: a row's `version` comes from the observation's own
  state, so writing it twice changes nothing.
  """

  require Logger

  alias SalixIM.SlackMessageMirror.{MetadataRow, PinRow, ReactionRow, Row}
  alias SalixStore.{SlackMirrorBackfillLedger, SlackMirrorOutbox}

  @callback record_batch([map()]) :: :ok | {:error, term()}
  @callback record_reaction_batch([map()]) :: :ok | {:error, term()}
  @callback record_pin_batch([map()]) :: :ok | {:error, term()}
  @callback record_metadata_batch([map()]) :: :ok | {:error, term()}
  @callback record_event_triggers([map()]) :: :ok | {:error, term()}

  defmodule Noop do
    @moduledoc "Default implementation: mirroring disabled."
    @behaviour SalixIM.SlackMessageMirror

    # Not `:ok`. A writer that took this answer as durability would delete an
    # outbox row, or commit a watermark, over rows that went nowhere.
    @impl true
    def record_batch([]), do: :ok
    def record_batch(_rows), do: {:error, :slack_message_mirror_disabled}

    @impl true
    def record_reaction_batch([]), do: :ok
    def record_reaction_batch(_rows), do: {:error, :slack_message_mirror_disabled}

    @impl true
    def record_pin_batch([]), do: :ok
    def record_pin_batch(_rows), do: {:error, :slack_message_mirror_disabled}

    @impl true
    def record_metadata_batch([]), do: :ok
    def record_metadata_batch(_rows), do: {:error, :slack_message_mirror_disabled}

    @impl true
    def record_event_triggers([]), do: :ok
    def record_event_triggers(_rows), do: {:error, :slack_message_mirror_disabled}
  end

  @doc """
  Records one observed Slack event.

  Returns `:ok` when the event was ignored or durably appended. Returns
  `{:error, :outbox_unavailable}` when the durable insert failed, so the Slack
  callback can fail and Slack can retry. Building the row is skipped entirely
  when no adapter is configured.
  """
  @spec observe(map(), map()) :: :ok | {:error, :outbox_unavailable}
  def observe(connect, envelope) do
    if enabled?() do
      maybe_kick_channel_join(connect, envelope)

      with :ok <- SalixStore.SlackSearchFiles.observe(connect, envelope) do
        case component_row(connect, envelope) do
          {:ok, kind, row} -> append(kind, row, connect)
          :ignore -> :ok
        end
      else
        {:error, reason} -> persist_failed(:outbox_unavailable, inspect(reason))
      end
    else
      :ok
    end
  rescue
    exception ->
      persist_failed(:outbox_unavailable, Exception.message(exception))
  catch
    kind, reason ->
      persist_failed(:outbox_unavailable, inspect({kind, reason}))
  end

  defp component_row(connect, envelope) do
    Enum.find_value(
      [
        {"message", &Row.from_event/2},
        {"reaction", &ReactionRow.from_event/2},
        {"pin", &PinRow.from_event/2},
        {"metadata", &MetadataRow.from_event/2}
      ],
      :ignore,
      fn {kind, fun} ->
        case fun.(connect, envelope) do
          {:ok, row} -> {:ok, kind, row}
          :ignore -> nil
        end
      end
    )
  end

  defp append(kind, row, connect) do
    case outbox().append(row, kind, Map.take(connect, ~w(group_id connect_id connect_generation))) do
      :ok -> :ok
      {:error, reason} -> persist_failed(:outbox_unavailable, inspect(reason))
    end
  end

  defp persist_failed(reason, detail) do
    Logger.warning("slack message mirror persist failed (#{reason}): #{detail}")
    :telemetry.execute([:salix, :slack_mirror, :dropped], %{count: 1}, %{reason: reason})
    {:error, reason}
  rescue
    _exception -> {:error, :outbox_unavailable}
  end

  @doc """
  Writes a message batch and reports whether it landed. Blocking, by design.

  Both durable writers call this before discarding their own record of the
  rows, so an error here has to reach them, and an adapter that raises has to
  become an error rather than an acknowledgement.
  """
  @spec write_batch([map()]) :: :ok | {:error, term()}
  def write_batch([]), do: :ok

  def write_batch(rows) when is_list(rows) do
    if enabled?(), do: write_admitted_batches(rows), else: write(:record_batch, rows)
  end

  defp write_admitted_batches(rows) do
    rows
    |> Enum.chunk_every(200)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      # Drained rows already own a durable admission. A synchronous history or
      # repair batch must gain one before any canonical write is dispatched.
      {admitted, fresh} = Enum.split_with(batch, &is_integer(&1["_mirror_outbox_id"]))

      with :ok <- write(:record_batch, admitted),
           :ok <- write_fresh_messages(fresh) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp write_fresh_messages([]), do: :ok

  defp write_fresh_messages(rows) do
    with {:ok, admitted} <- outbox().admit_messages(rows),
         :ok <- write(:record_batch, admitted) do
      outbox().delete_source_writes(Enum.map(admitted, & &1["_mirror_outbox_id"]))
    end
  end

  @doc """
  Writes a reaction batch and reports whether it landed. Blocking, by design.

  Same acknowledgement rule as `write_batch/1`. Reactions are shared mirrored
  context, never a Triage trigger.
  """
  @spec write_reaction_batch([map()]) :: :ok | {:error, term()}
  def write_reaction_batch(rows), do: write(:record_reaction_batch, rows)

  @spec write_pin_batch([map()]) :: :ok | {:error, term()}
  def write_pin_batch(rows), do: write(:record_pin_batch, rows)

  @spec write_metadata_batch([map()]) :: :ok | {:error, term()}
  def write_metadata_batch(rows), do: write(:record_metadata_batch, rows)

  @doc """
  Records live webhook observations for Triage's change stream.

  Call this only from the outbox drain, after the message batch landed.
  Backfill must not.
  """
  @spec write_event_triggers([map()]) :: :ok | {:error, term()}
  def write_event_triggers(rows), do: write(:record_event_triggers, rows)

  defp write(_function, []), do: :ok

  defp write(function, rows) when is_list(rows) do
    case apply(impl(), function, [rows]) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_mirror_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Is an adapter wired in?"
  @spec enabled?() :: boolean()
  def enabled?, do: impl() != Noop

  # Best-effort. A kick failure must not fail the Slack ACK.
  defp maybe_kick_channel_join(connect, envelope) when is_map(connect) and is_map(envelope) do
    event = envelope["event"]
    bot = trim(connect["bot_user_id"])

    if is_map(event) and event["type"] == "member_joined_channel" and bot != "" and
         trim(event["user"]) == bot do
      _ = SlackMirrorBackfillLedger.kick_connect(connect)

      case Process.whereis(SalixIM.SlackMessageMirror.BackfillRunner) do
        pid when is_pid(pid) -> send(pid, :work_tick)
        nil -> :ok
      end
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp maybe_kick_channel_join(_connect, _envelope), do: :ok

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp impl, do: Application.get_env(:salix_im, :slack_message_mirror_mod, Noop)

  defp outbox, do: Application.get_env(:salix_im, :slack_message_mirror_outbox, SlackMirrorOutbox)
end
