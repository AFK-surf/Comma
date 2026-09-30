defmodule BridgeForTeams.CacheTest do
  # Not async: shares the singleton ETS table started in the supervision tree.
  use ExUnit.Case, async: false

  alias BridgeForTeams.Cache

  test "put/get/delete round-trip" do
    key = {:cache_test, make_ref()}
    assert :error = Cache.get(key)
    assert :ok = Cache.put(key, 42)
    assert {:ok, 42} = Cache.get(key)
    assert :ok = Cache.delete(key)
    assert :error = Cache.get(key)
  end

  test "ttl expiry" do
    key = {:cache_ttl, make_ref()}
    assert :ok = Cache.put(key, "v", ttl: 1)
    Process.sleep(5)
    assert :error = Cache.get(key)
  end

  test "no ttl never expires" do
    key = {:cache_inf, make_ref()}
    assert :ok = Cache.put(key, "v")
    Process.sleep(5)
    assert {:ok, "v"} = Cache.get(key)
  end
end
