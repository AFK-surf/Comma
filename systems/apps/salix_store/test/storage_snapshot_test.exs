defmodule SalixStore.StorageSnapshotTest do
  use ExUnit.Case, async: false

  alias SalixStore.{S3, StorageSnapshot}

  defmodule MeteringFake do
    def meter_storage_sample(fact) do
      send(
        Application.fetch_env!(:salix_store, :storage_snapshot_test_pid),
        {:storage_fact, fact}
      )

      :ok
    end
  end

  setup do
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_metering = Application.get_env(:salix_store, :storage_metering_mod)
    prev_pid = Application.get_env(:salix_store, :storage_snapshot_test_pid)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_store, :storage_metering_mod, MeteringFake)
    Application.put_env(:salix_store, :storage_snapshot_test_pid, self())

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    if :ets.info(SalixStore.StorageSnapshot.TierCache) != :undefined do
      :ets.delete_all_objects(SalixStore.StorageSnapshot.TierCache)
    end

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, prev_backend)
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

    assert_receive {:storage_fact, emitted}
    assert emitted.source_key == fact.source_key
    assert emitted.owner_snapshot["billing_account_id"] == "ba_storage"
  end

  test "looks up storage tier through a bounded provider hook and caches it" do
    assert {:ok, _} = S3.put("tiered/a.txt", "abc")
    test_pid = self()

    lookup = fn _prefix, _objects ->
      send(test_pid, :tier_lookup)
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

  test "storage tier lookup timeout records quality instead of guessing" do
    assert {:ok, _} = S3.put("slow-tier/a.txt", "abc")

    assert {:ok, fact} =
             StorageSnapshot.sample_prefix(%{
               prefix: "slow-tier/",
               provider: "aws",
               tier_lookup_fun: fn _prefix ->
                 Process.sleep(50)
                 "standard"
               end,
               tier_lookup_timeout_ms: 1
             })

    assert fact.storage_tier == "unknown"
    assert fact.tier_source == "unknown"
    assert "storage_tier_lookup_timeout" in fact.quality
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_store, key)
  defp restore_env(key, value), do: Application.put_env(:salix_store, key, value)
end
