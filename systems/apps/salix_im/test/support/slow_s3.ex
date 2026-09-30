defmodule SalixIM.TestSupport.SlowS3 do
  @moduledoc """
  `SalixStore.S3.Fake` behind a fixed per-operation delay and an operation log.

  Latency tests use it to make every object-store round trip cost real wall
  time, so a path that serializes N round trips takes at least N × delay.
  The log records `{operation, key, pid, monotonic_ms, caller}` for attribution.
  """

  @behaviour SalixStore.S3

  @fake SalixStore.S3.Fake
  @log __MODULE__.Log

  def start_link(_ \\ []), do: @fake.start_link()

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def delay_ms, do: Application.get_env(:salix_im, :slow_s3_delay_ms, 0)

  def reset_log do
    table = ensure_log()
    :ets.delete_all_objects(table)
    :ok
  end

  @doc "Operations recorded so far, oldest first."
  def log do
    ensure_log()
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 3))
  end

  @doc "Operations recorded inside a monotonic millisecond window."
  def ops_between(from_ms, to_ms),
    do: Enum.filter(log(), fn {_op, _key, _pid, at, _caller} -> at >= from_ms and at <= to_ms end)

  @impl true
  def put(key, body, opts), do: slow(:put, key, fn -> @fake.put(key, body, opts) end)
  @impl true
  def put_stream(key, stream, opts),
    do: slow(:put, key, fn -> @fake.put_stream(key, stream, opts) end)

  @impl true
  def multipart_create(key, opts),
    do: slow(:put, key, fn -> @fake.multipart_create(key, opts) end)

  @impl true
  def multipart_upload_part(key, id, n, body),
    do: slow(:put, key, fn -> @fake.multipart_upload_part(key, id, n, body) end)

  @impl true
  def multipart_complete(key, id, parts),
    do: slow(:put, key, fn -> @fake.multipart_complete(key, id, parts) end)

  @impl true
  def multipart_abort(key, id), do: slow(:delete, key, fn -> @fake.multipart_abort(key, id) end)
  @impl true
  def multipart_uploads(key, opts),
    do: slow(:list, key, fn -> @fake.multipart_uploads(key, opts) end)

  @impl true
  def get(key, opts), do: slow(:get, key, fn -> @fake.get(key, opts) end)
  @impl true
  def stream(key, opts), do: slow(:get, key, fn -> @fake.stream(key, opts) end)
  @impl true
  def head(key), do: slow(:head, key, fn -> @fake.head(key) end)
  @impl true
  def delete(key, opts), do: slow(:delete, key, fn -> @fake.delete(key, opts) end)
  @impl true
  def list(prefix, opts), do: slow(:list, prefix, fn -> @fake.list(prefix, opts) end)

  defp slow(op, key, fun) do
    case delay_ms() do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end

    :ets.insert(ensure_log(), {op, key, self(), System.monotonic_time(:millisecond), caller()})
    fun.()
  end

  # The first stack frame outside the store layer, for attribution.
  defp caller do
    {:current_stacktrace, frames} = Process.info(self(), :current_stacktrace)

    frames
    |> Enum.drop_while(fn {mod, _fun, _arity, _loc} ->
      mod in [Process, __MODULE__, SalixStore.S3, SalixStore.CasRecord, SalixStore.Inflight] or
        String.starts_with?(Atom.to_string(mod), "Elixir.SalixStore.S3.")
    end)
    |> Enum.take(6)
    |> Enum.map_join(" < ", fn {mod, fun, arity, _loc} -> "#{inspect(mod)}.#{fun}/#{arity}" end)
  end

  defp ensure_log do
    case :ets.whereis(@log) do
      :undefined ->
        try do
          :ets.new(@log, [:named_table, :public, :duplicate_bag, write_concurrency: true])
        rescue
          ArgumentError -> @log
        end

      _ ->
        @log
    end
  end
end
