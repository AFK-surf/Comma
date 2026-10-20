defmodule SalixIM.FeishuMessageMirror do
  @moduledoc """
  Seam for mirroring observed Feishu messages into ClickHouse for search.

  The Feishu counterpart of `SalixIM.SlackMessageMirror`, with the same two
  writers and the same acknowledgement rules:

    * **Live.** `observe/2` runs once per verified Feishu callback in
      `SalixIM.ProviderHTTP`, after the app, token and decryption checks and
      before the Router relevance filter. With the "read all group messages"
      scope Feishu delivers all group chatter, most of which the Router
      ignores; the mirror must see it anyway, and it must see recalls, which
      never reach the Router. The callback appends one row to
      `SalixStore.FeishuMirrorOutbox`; a failed insert fails the callback so
      Feishu retries. `OutboxDrainer` moves rows into ClickHouse and deletes
      them only after the insert is acknowledged.

    * **History.** `Backfill` walks each chat the app is in, and each thread
      it finds, newest first through `/im/v1/messages`, and lowers a
      container's watermark only after the page landed.

  Both rely on one property for retry safety: a row's `version` comes from
  the message's own state (`Row`), and the table is a `ReplacingMergeTree` on
  it, so writing a row twice changes nothing.

  Mirroring is off unless `:salix_im, :feishu_message_mirror_mod` names a
  storage adapter (`SalixAnalytics.FeishuMirror` in production); with it off
  `observe/2` builds nothing and the drainer and backfill idle.

  Search reads the mirror through `SalixIM.Provider.Feishu.MessageSearch`.
  Coverage is partial by construction: events Feishu never delivers or stops
  retrying are lost, edits are visible only when a later callback or history
  page observes them, and history is walked down to what the app can read.
  """

  require Logger

  alias SalixIM.FeishuMessageMirror.Row
  alias SalixStore.FeishuMirrorOutbox

  @callback record_batch([map()]) :: :ok | {:error, term()}

  defmodule Noop do
    @moduledoc "Default implementation: mirroring disabled."
    @behaviour SalixIM.FeishuMessageMirror

    # Not `:ok`: a writer that took this as durability would delete an outbox
    # row, or commit a watermark, over rows that went nowhere.
    @impl true
    def record_batch([]), do: :ok
    def record_batch(_rows), do: {:error, :feishu_message_mirror_disabled}
  end

  @doc """
  Records one verified Feishu callback.

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
  Writes a message batch and reports whether it landed. Blocking, by design:
  both writers discard their own record of the rows only on `:ok`.
  """
  @spec write_batch([map()]) :: :ok | {:error, term()}
  def write_batch([]), do: :ok

  def write_batch(rows) when is_list(rows) do
    case impl().record_batch(rows) do
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

  defp persist_failed(detail) do
    Logger.warning("feishu message mirror persist failed: #{detail}")

    SystemsRuntime.Telemetry.execute([:salix, :feishu_mirror, :dropped], %{count: 1}, %{
      reason: :outbox_unavailable
    })

    {:error, :outbox_unavailable}
  rescue
    _exception -> {:error, :outbox_unavailable}
  end

  defp impl, do: SystemsRuntime.get_env(:salix_im, :feishu_message_mirror_mod, Noop)

  defp outbox,
    do: SystemsRuntime.get_env(:salix_im, :feishu_message_mirror_outbox, FeishuMirrorOutbox)
end
