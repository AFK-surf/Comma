defmodule BillingCore.FeeControl.ServerTest do
  use ExUnit.Case, async: true

  alias BillingCore.FeeControl.Server
  @moduletag :capture_log

  setup do
    %{server: start_supervised!({Server, name: __MODULE__})}
  end

  @tag billing_isolation: true
  test "a held account query does not block another account's cached or enforced checks", %{
    server: server
  } do
    owner = self()
    cached = attrs("cached", fn -> %{balance_snapshot: 100} end)
    assert {:ok, _} = Server.check(cached, server: server)
    slow = Task.async(fn -> Server.check(attrs("slow", held_query(owner)), server: server) end)
    assert_receive {:query_held, worker}

    try do
      assert {:ok, %{cache_hit: true, query_performed: false}} =
               Server.check(cached, server: server, timeout: 500)

      # Real enforcement must still query and reject insufficient credits.
      enforce =
        attrs("other", fn -> %{balance_snapshot: 0, account_status: "active"} end)
        |> Map.put(:mode, :enforce)

      assert {:ok, %{allowed?: false, query_performed: true, reason: "insufficient_credits"}} =
               Server.check(enforce, server: server, timeout: 500)
    after
      send(worker, :release)
      Task.await(slow)
    end
  end

  test "an older refresh cannot overwrite a newer result for the same cache key", %{
    server: server
  } do
    owner = self()
    cached = Map.put(attrs("shared", fn -> %{balance_snapshot: 0} end), :now, 100)
    assert {:ok, _} = Server.check(cached, server: server)
    refresh = Map.put(cached, :force_refresh, true)

    slow =
      Task.async(fn ->
        Server.check(%{refresh | query_fun: held_query(owner)}, server: server)
      end)

    assert_receive {:query_held, worker}

    try do
      assert {:ok, %{balance_snapshot: 0}} =
               Server.check(refresh,
                 server: server,
                 timeout: 500
               )
    after
      send(worker, :release)
      Task.await(slow)
    end

    assert {:ok, %{cache_hit: true, balance_snapshot: 0}} =
             Server.check(%{cached | query_fun: fn -> flunk("cache miss") end}, server: server)
  end

  test "query failure is isolated and does not erase another account's cache", %{server: server} do
    cached = attrs("cached", fn -> %{balance_snapshot: 100} end)
    assert {:ok, _} = Server.check(cached, server: server)

    assert {:error, :fee_control_check_failed} =
             Server.check(attrs("broken", fn -> raise "query failed" end), server: server)

    assert {:ok, %{cache_hit: true}} = Server.check(cached, server: server)
  end

  test "a timed-out query worker retires while other checks remain available", %{server: server} do
    owner = self()

    caller =
      Task.async(fn ->
        try do
          Server.check(attrs("slow", held_query(owner)), server: server, timeout: 100)
        catch
          :exit, {:timeout, _} -> :caller_timeout
        end
      end)

    assert_receive {:query_held, worker}
    monitor = Process.monitor(worker)
    assert Task.await(caller) in [:caller_timeout, {:error, :fee_control_check_timeout}]
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000

    assert {:ok, _} =
             Server.check(attrs("other", fn -> %{balance_snapshot: 100} end), server: server)
  end

  defp attrs(account, query) do
    %{
      billing_account_id: account,
      provider: "test",
      sku: "tokens",
      estimated_credits: 1,
      query_fun: query
    }
  end

  defp held_query(owner) do
    fn ->
      send(owner, {:query_held, self()})

      receive do
        :release -> %{balance_snapshot: 100}
      after
        5_000 -> raise "query barrier was not released"
      end
    end
  end
end
