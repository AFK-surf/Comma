defmodule SalixIM.LarkMessageRecord do
  @moduledoc """
  The searchable record of Lark messages.

  Lark delivers a message to the bot as one callback: every message of a
  private chat, and of a group either every message or only mentions, as the
  app's scopes allow. Each delivered message, each recall, and each message
  the bot sends becomes one row, and `lark.search_messages` reads them back.

  ## Storage

  The record has its own store and its own code. `observe/2` runs once per
  verified callback in `SalixIM.LarkInbound`, before the Router relevance
  filter, and appends one row to `SalixStore.LarkMirrorOutbox`; a failed
  append fails the callback so that Lark delivers it again.
  `SalixIM.LarkMessageRecord.OutboxDrainer` moves rows into the ClickHouse
  table `lark_messages` (`SalixAnalytics.LarkMirror`) and deletes them only
  after the insert is acknowledged. The table identifies a message by
  `(tenant_id, app_id, chat_id, message_id)`.

  A row's `version` comes from the message's own state (`Row`), and the table
  is a `ReplacingMergeTree` on it, so writing a row twice changes nothing.

  The record is off unless `:salix_im, :lark_message_record_mod` names a
  storage adapter; with it off `observe/2` builds nothing and the drainer
  and the backfill do not start.

  ## History

  `SalixIM.LarkMessageRecord.Backfill` walks each chat the app is in, and
  each thread it finds, newest first through `/im/v1/messages`, and lowers a
  container's watermark in `SalixStore.LarkMirrorBackfillLedger` only after
  the page landed. `BackfillRunner` schedules the passes.

  Coverage is partial by construction: events Lark never delivers or stops
  retrying are lost, edits are visible only when a later callback or history
  page observes them, and history is walked down to what the app can read.
  `lark.search_messages` says which part of a search is not walked yet.
  """

  require Logger

  alias SalixIM.LarkMessageRecord.Row
  alias SalixStore.LarkMirrorOutbox

  @callback record_batch([map()]) :: :ok | {:error, term()}

  defmodule Noop do
    @moduledoc "Default implementation: mirroring disabled."
    @behaviour SalixIM.LarkMessageRecord

    # Not `:ok`: a writer that took this as durability would delete an outbox
    # row, or commit a watermark, over rows that went nowhere.
    @impl true
    def record_batch([]), do: :ok
    def record_batch(_rows), do: {:error, :lark_message_record_disabled}
  end

  @doc """
  Records one verified Lark callback.

  `:ok` when the event was ignored or durably appended;
  `{:error, :outbox_unavailable}` when the durable insert failed.
  """
  @spec observe(map(), map()) :: :ok | {:error, :outbox_unavailable}
  def observe(connect, envelope) do
    if enabled?() do
      case Row.from_event(connect, envelope) do
        {:ok, row} ->
          case outbox().append(row, "message") do
            :ok -> :ok
            {:error, reason} -> persist_failed(inspect(reason))
          end

        :ignore ->
          :ok
      end
    else
      :ok
    end
  rescue
    exception -> persist_failed(Exception.message(exception))
  catch
    kind, reason -> persist_failed(inspect({kind, reason}))
  end

  @doc """
  Records one message the bot sent, from Lark's answer to the send. Best
  effort; returns `:ok`. `text` is the Markdown the bot wrote.
  """
  @spec observe_sent(map(), map(), String.t()) :: :ok
  def observe_sent(connect, sent, text) when is_map(connect) and is_map(sent) do
    with true <- enabled?(),
         {:ok, row} <- Row.from_sent(connect, sent, text) do
      _ = outbox().append(row, "message")
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def observe_sent(_connect, _sent, _text), do: :ok

  @doc "The reader `lark.search_messages` uses, or `nil` when the record is off."
  @spec reader() :: module() | nil
  def reader do
    reader = SystemsRuntime.get_env(:salix_im, :lark_message_record_reader_mod)
    if enabled?() and is_atom(reader), do: reader
  end

  @doc "The outbox the record appends to and its drainer drains."
  @spec outbox() :: module()
  def outbox,
    do: SystemsRuntime.get_env(:salix_im, :lark_message_record_outbox, LarkMirrorOutbox)

  @doc """
  Writes a message batch and reports whether it landed. Blocking, by design:
  the outbox drainer deletes its rows, and the backfill commits its page,
  only on `:ok`.
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

  @doc "Is an adapter wired in?"
  @spec enabled?() :: boolean()
  def enabled?, do: impl() != Noop

  defp persist_failed(detail) do
    Logger.warning("lark message record append failed: #{detail}")

    SystemsRuntime.Telemetry.execute([:salix, :lark_mirror, :dropped], %{count: 1}, %{
      reason: :outbox_unavailable
    })

    {:error, :outbox_unavailable}
  rescue
    _exception -> {:error, :outbox_unavailable}
  end

  defp impl, do: SystemsRuntime.get_env(:salix_im, :lark_message_record_mod, Noop)
end
