defmodule BridgeForTeams.Salix.ReadCacheTest do
  # Not async: shares the singleton ETS table started in the supervision tree.
  use ExUnit.Case, async: false

  alias BridgeForTeams.Salix.ReadCache

  # Every test uses a unique ref-based key, so tests can't collide even if an
  # on_exit invalidate were skipped.
  defp key, do: {:read_cache_test, make_ref()}

  defp counting(result_fun) do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      result_fun.(:counters.get(counter, 1))
    end

    {fun, fn -> :counters.get(counter, 1) end}
  end

  test "read-through: computes once, then serves the cached value" do
    key = key()
    {fun, calls} = counting(fn n -> {:ok, n} end)

    assert {:ok, 1} = ReadCache.fetch(key, 60_000, fun)
    assert {:ok, 1} = ReadCache.fetch(key, 60_000, fun)
    assert calls.() == 1
  end

  test "expired entries are recomputed" do
    key = key()
    {fun, calls} = counting(fn n -> {:ok, n} end)

    assert {:ok, 1} = ReadCache.fetch(key, 1, fun)
    Process.sleep(5)
    assert {:ok, 2} = ReadCache.fetch(key, 60_000, fun)
    assert calls.() == 2
  end

  test "invalidate drops the entry so the next fetch recomputes" do
    key = key()
    {fun, calls} = counting(fn n -> {:ok, n} end)

    assert {:ok, 1} = ReadCache.fetch(key, 60_000, fun)
    assert :ok = ReadCache.invalidate(key)
    assert {:ok, 2} = ReadCache.fetch(key, 60_000, fun)
    assert calls.() == 2
  end

  test "invalidating an absent key is a no-op" do
    assert :ok = ReadCache.invalidate(key())
  end

  test "{:error, _} results are returned but never cached" do
    key = key()

    {fun, calls} =
      counting(fn
        1 -> {:error, :unavailable}
        n -> {:ok, n}
      end)

    assert {:error, :unavailable} = ReadCache.fetch(key, 60_000, fun)
    # The error was not pinned: the next fetch recomputes and caches the ok.
    assert {:ok, 2} = ReadCache.fetch(key, 60_000, fun)
    assert {:ok, 2} = ReadCache.fetch(key, 60_000, fun)
    assert calls.() == 2
  end

  test "bare :error results are returned but never cached" do
    key = key()

    {fun, calls} =
      counting(fn
        1 -> :error
        n -> {:ok, n}
      end)

    assert :error = ReadCache.fetch(key, 60_000, fun)
    assert {:ok, 2} = ReadCache.fetch(key, 60_000, fun)
    assert calls.() == 2
  end

  test "an invalidate that lands during a fill is not undone by the fill's insert" do
    key = key()
    {fun, calls} = counting(fn n -> {:ok, n} end)

    # Deterministic replay of the race: the invalidation arrives after the
    # filler computed its (now stale) value but before it inserts.
    assert {:ok, :stale} =
             ReadCache.fetch(key, 60_000, fn ->
               :ok = ReadCache.invalidate(key)
               {:ok, :stale}
             end)

    # The stale value was returned but never pinned: the next fetch recomputes
    # and its fresh value caches normally.
    assert {:ok, 1} = ReadCache.fetch(key, 60_000, fun)
    assert {:ok, 1} = ReadCache.fetch(key, 60_000, fun)
    assert calls.() == 1
  end

  test "non-tuple ok-ish values (nil, lists) are cached like any value" do
    key = key()
    {fun, calls} = counting(fn _n -> nil end)

    assert ReadCache.fetch(key, 60_000, fun) == nil
    assert ReadCache.fetch(key, 60_000, fun) == nil
    assert calls.() == 1
  end
end
