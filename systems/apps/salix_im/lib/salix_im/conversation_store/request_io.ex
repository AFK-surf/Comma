defmodule SalixIM.ConversationStore.RequestIO do
  @moduledoc false
  alias SalixStore.S3
  @key __MODULE__
  @limit 32

  # Bounded observations of the serialized owner. Conditional writes still go to storage.
  # A failed/ambiguous write discards every observation before settlement/retry.
  def run(memo, fun) do
    previous = Process.put(@key, memo)

    try do
      result = fun.()
      {result, Process.get(@key)}
    after
      if is_nil(previous), do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  def reset, do: if(capture(), do: Process.put(@key, %{}))
  def capture, do: Process.get(@key)
  def merge(nil), do: :ok

  def merge(memo) do
    if current = capture(), do: Process.put(@key, Map.merge(current, memo))
    :ok
  end

  def get(key, opts \\ []) do
    memo = capture()

    case memo && Map.fetch(memo, {key, opts}) do
      {:ok, result} -> result
      _ -> remember(key, opts, S3.get(key, opts))
    end
  end

  def prefetch(keys) do
    if capture() do
      results =
        keys
        |> Enum.uniq()
        |> Enum.reject(&Map.has_key?(capture(), {&1, []}))
        |> Task.async_stream(fn key -> {key, S3.get(key)} end,
          max_concurrency: 6,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.to_list()

      Enum.reduce(results, :ok, fn
        {:ok, {key, result}}, acc ->
          remember(key, [], result)
          if match?({:ok, _}, result) or result == {:error, :not_found}, do: acc, else: result

        {:exit, reason}, _ ->
          {:error, {:read_failed, reason}}
      end)
    else
      :ok
    end
  end

  def put(key, body, opts \\ []) do
    case S3.put(key, body, opts) do
      {:ok, %{etag: etag}} = result ->
        forget(key)
        remember(key, [], {:ok, %{body: body, etag: etag, meta: %{}}})
        result

      other ->
        if capture(), do: Process.put(@key, %{})
        other
    end
  end

  def delete(key, opts \\ []) do
    result = S3.delete(key, opts)
    if capture(), do: Process.put(@key, %{})
    result
  end

  defdelegate list(key, opts \\ []), to: S3

  defp remember(key, opts, result) do
    if memo = capture() do
      if match?({:ok, _}, result) or result == {:error, :not_found} do
        memo = if map_size(memo) >= @limit, do: %{}, else: memo
        Process.put(@key, Map.put(memo, {key, opts}, result))
      end
    end

    result
  end

  defp forget(key) do
    if memo = capture() do
      Process.put(@key, Map.reject(memo, fn {{object, _}, _} -> object == key end))
    end
  end
end
