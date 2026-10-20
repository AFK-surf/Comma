defmodule SalixStore.StorageSnapshotTest do
  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  alias SalixStore.{S3, StorageSnapshot}

  defmodule MeteringFake do
    def meter_storage_sample(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_store, :storage_snapshot_test_pid),
        {:storage_fact, fact}
      )

      :ok
    end
  end

  setup do
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_metering = SystemsRuntime.get_env(:salix_store, :storage_metering_mod)
    prev_pid = SystemsRuntime.get_env(:salix_store, :storage_snapshot_test_pid)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_store, :storage_metering_mod, MeteringFake)
    SystemsRuntime.put_env(:salix_store, :storage_snapshot_test_pid, SystemsRuntime.Proc.self())

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    if SystemsRuntime.ETS.info(SalixStore.StorageSnapshot.TierCache) != :undefined do
      SystemsRuntime.ETS.delete_all_objects(SalixStore.StorageSnapshot.TierCache)
    end

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
      restore_env(:storage_metering_mod, prev_metering)
      restore_env(:storage_snapshot_test_pid, prev_pid)
    end)

    :ok
  end

  test "samples a bounded prefix and emits byte-second storage fact" do
    assert {:ok, _} = S3.put("billing/prefix/a.txt", "abc")
    assert {:ok, _} = S3.put("billing/prefix/b.txt", "hello")
    assert {:ok, _} = S3.put("billing/prefix/c.txt", "ignored")

    assert {:ok, fact} =
             StorageSnapshot.sample_prefix(%{
               prefix: "billing/prefix/",
               provider: "aws",
               storage_tier: "standard",
               sample_window_seconds: 60,
               max_objects: 2,
               now: 1_780_000_000_000,
               owner_snapshot: %{
                 "billing_account_id" => "ba_storage",
                 "surface" => "comma",
                 "salix_tenant_id" => "tenant_1",
                 "salix_group_id" => "group_1"
               }
             })

    assert fact.bytes == 8
    assert fact.object_count == 2
    assert fact.byte_seconds == 480
    assert fact.quantity == 480
    assert fact.entrypoint == "storage_snapshot"
    assert "truncated_object_list" in fact.quality

    settle_receive({:storage_fact, emitted})
    assert emitted.source_key == fact.source_key
    assert emitted.owner_snapshot["billing_account_id"] == "ba_storage"
  end

  test "looks up storage tier through a bounded provider hook and caches it" do
    assert {:ok, _} = S3.put("tiered/a.txt", "abc")
    test_pid = SystemsRuntime.Proc.self()

    lookup = fn _prefix, _objects ->
      SystemsRuntime.Proc.send(test_pid, :tier_lookup)
      {:ok, %{storage_tier: "standard_ia", tier_source: "provider"}}
    end

    assert {:ok, first} =
             StorageSnapshot.sample_prefix(%{
               prefix: "tiered/",
               provider: "aws",
               tier_lookup_fun: lookup,
               tier_cache_ttl_ms: 60_000,
               now: 1_780_000_000_000
             })

    assert first.storage_tier == "standard_ia"
    assert first.tier_source == "provider"
    assert first.tier_cache_hit == false
    assert first.quality == []
    assert_received :tier_lookup

    assert {:ok, second} =
             StorageSnapshot.sample_prefix(%{
               prefix: "tiered/",
               provider: "aws",
               tier_lookup_fun: lookup,
               now: 1_780_000_001_000
             })

    assert second.storage_tier == "standard_ia"
    assert second.tier_source == "provider"
    assert second.tier_cache_hit == true
    refute_received :tier_lookup
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_store, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_store, key, value)
end
