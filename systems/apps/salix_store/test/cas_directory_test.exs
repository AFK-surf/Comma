defmodule SalixStore.CasDirectoryTest do
  @moduledoc """
  The single-object CAS directory: bounded id → record maps for small
  collections, with enforced limits and ambiguous-write read-back.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.{CasDirectory, S3}

  @dir "ctl/test_cas_directory/dir.json"

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  test "put/get/list/delete round-trip through one object" do
    assert {:ok, %{"v" => 1}} = CasDirectory.put(@dir, "a", %{"v" => 1})
    assert {:ok, %{"v" => 2}} = CasDirectory.put(@dir, "b", %{"v" => 2})

    assert {:ok, %{"v" => 1}} = CasDirectory.get(@dir, "a")
    assert {:ok, [{"a", %{"v" => 1}}, {"b", %{"v" => 2}}]} = CasDirectory.list(@dir)

    # Listing is exactly one GET — the whole point.
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _} = CasDirectory.list(@dir)
    assert SalixStore.S3.Fake.read_log() == [{:get, @dir}]

    assert :ok = CasDirectory.delete(@dir, "a")
    assert {:error, :not_found} = CasDirectory.get(@dir, "a")
    assert {:ok, [{"b", _}]} = CasDirectory.list(@dir)
  end

  test "an ambiguous CAS that landed is settled by read-back" do
    assert {:ok, _} = CasDirectory.put(@dir, "a", %{"v" => 1})

    SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, @dir})
    assert {:ok, %{"v" => 2}} = CasDirectory.put(@dir, "a", %{"v" => 2})
    assert {:ok, %{"v" => 2}} = CasDirectory.get(@dir, "a")
  end

  describe "transact/3" do
    test "decision and write are one CAS: commit, abort, and no-op" do
      assert {:ok, :claimed} =
               CasDirectory.transact(@dir, fn entries ->
                 case entries["x"] do
                   nil -> {:commit, Map.put(entries, "x", %{"owner" => "a"}), :claimed}
                   %{"owner" => "a"} -> {:abort, :already_mine}
                   _ -> {:abort, :conflict}
                 end
               end)

      assert {:ok, %{"owner" => "a"}} = CasDirectory.get(@dir, "x")

      # A conflicting claim aborts without writing.
      SalixStore.S3.Fake.reset_put_log()

      assert {:ok, :conflict} =
               CasDirectory.transact(@dir, fn entries ->
                 case entries["x"] do
                   nil -> {:commit, Map.put(entries, "x", %{"owner" => "b"}), :claimed}
                   %{"owner" => "b"} -> {:abort, :already_mine}
                   _ -> {:abort, :conflict}
                 end
               end)

      assert SalixStore.S3.Fake.put_log() == []
      assert {:ok, %{"owner" => "a"}} = CasDirectory.get(@dir, "x")
    end

    test "a landed write reported as 412 does not re-run a non-idempotent reducer" do
      assert {:ok, _} = CasDirectory.put(@dir, "counter", %{"n" => 0})

      # The adapter's documented outcome: attempt 1 lands, the transport
      # retry gets a stale-conditional 412. The increment must apply ONCE.
      SalixStore.S3.Fake.set_fault({:precondition_after, :put, @dir})

      assert {:ok, :incremented} =
               CasDirectory.transact(@dir, fn entries ->
                 n = get_in(entries, ["counter", "n"]) || 0
                 {:commit, Map.put(entries, "counter", %{"n" => n + 1}), :incremented}
               end)

      assert {:ok, %{"n" => 1}} = CasDirectory.get(@dir, "counter")
    end

    test "settlement is by op token, not byte comparison: a competing writer's identical transform is a real conflict" do
      assert {:ok, _} = CasDirectory.put(@dir, "counter", %{"n" => 0})
      calls = SystemsRuntime.Counters.new(1, [])

      # The reducer's first evaluation simulates a competing writer landing
      # the SAME transform between our read and our CAS (its object carries
      # its own op token). Our PUT then 412s WITHOUT landing; read-back must
      # see a foreign token — never adopt the byte-twin — and re-run.
      assert {:ok, :incremented} =
               CasDirectory.transact(@dir, fn entries ->
                 SystemsRuntime.Counters.add(calls, 1, 1)
                 n = get_in(entries, ["counter", "n"]) || 0

                 if SystemsRuntime.Counters.get(calls, 1) == 1 do
                   {:ok, %{body: body}} = S3.get(@dir)
                   {:ok, decoded} = Jason.decode(body)

                   competing =
                     decoded
                     |> Map.put("entries", %{"counter" => %{"n" => n + 1}})
                     |> Map.put("op", "competing-writer-op")
                     |> Map.update("ops", ["competing-writer-op"], &["competing-writer-op" | &1])

                   {:ok, _} = S3.put(@dir, Jason.encode!(competing))
                 end

                 {:commit, Map.put(entries, "counter", %{"n" => n + 1}), :incremented}
               end)

      # Both increments survive: the competing writer's and ours.
      assert SystemsRuntime.Counters.get(calls, 1) == 2
      assert {:ok, %{"n" => 2}} = CasDirectory.get(@dir, "counter")
    end

    test "an ambiguous write that did NOT land is not adopted and not re-run" do
      assert {:ok, _} = CasDirectory.put(@dir, "counter", %{"n" => 0})
      calls = SystemsRuntime.Counters.new(1, [])

      SalixStore.S3.Fake.set_fault({:ambiguous_before, :put, @dir})

      assert {:error, {:ambiguous, :injected}} =
               CasDirectory.transact(@dir, fn entries ->
                 SystemsRuntime.Counters.add(calls, 1, 1)
                 n = get_in(entries, ["counter", "n"]) || 0
                 {:commit, Map.put(entries, "counter", %{"n" => n + 1}), :incremented}
               end)

      assert SystemsRuntime.Counters.get(calls, 1) == 1
      assert {:ok, %{"n" => 0}} = CasDirectory.get(@dir, "counter")
    end
  end
end
