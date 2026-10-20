defmodule SalixAnalytics.FeishuMirror do
  @moduledoc """
  Storage adapter for the Feishu message mirror.

  `SalixIM.FeishuMessageMirror` owns the seam and the row shape; this app owns
  the ClickHouse destination, the same split as `SalixAnalytics.SlackMirror`.
  Production wires it in through `:salix_im, :feishu_message_mirror_mod`.

  `record_batch/1` inserts inline and reports whether the insert landed. Both
  callers — the outbox drainer and the history backfill — discard their own
  durable record of the rows on `:ok`, so there is no buffered path here. The
  callback is implemented structurally because this app does not depend on
  `salix_im`.
  """

  alias SalixAnalytics.FeishuMirror.Sink

  @doc "Inserts one message batch synchronously and reports whether it landed."
  @spec record_batch([map()]) :: :ok | {:error, term()}
  def record_batch([]), do: :ok

  def record_batch(rows) when is_list(rows) do
    # The layout probe runs first: an insert that "succeeded" into a table on
    # the wrong key would let the caller discard rows the engine will destroy.
    with :ok <- Sink.readiness() do
      rows
      |> Enum.chunk_every(batch_rows())
      |> Enum.reduce_while(:ok, fn chunk, :ok ->
        case Sink.write(chunk) do
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
    |> SystemsRuntime.get_env(:feishu_mirror, [])
    |> Keyword.get(:batch_size, 200)
  end
end
