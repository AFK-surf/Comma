defmodule SalixIM.Triage.RecoveryTest do
  use SystemsClock.Case, async: false

  alias SalixIM.Triage.Recovery
  alias SalixStore.{CasRecord, S3}

  setup do
    previous_triage_backend = SystemsRuntime.get_env(:salix_store, :triage_record_backend)
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    S3.Fake.reset()

    on_exit(fn ->
      if previous_triage_backend do
        SystemsRuntime.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      else
        SystemsRuntime.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    :ok
  end

  test "rotates bucket and fence lanes under one page budget" do
    namespace = "triage-recovery-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    bucket_prefix = SalixStore.TriageKeys.ctl_im_triage_buckets_prefix(namespace)
    fence_prefix = SalixStore.TriageKeys.ctl_im_triage_bucket_seals_prefix(namespace)

    create_records(bucket_prefix, "bucket", 3)
    create_records(fence_prefix, "fence", 3)

    cursor = Recovery.cursor(idle_ms: 5_000)

    assert {:ok, :buckets, first, cursor, 0, 0} = Recovery.step(namespace, 2, cursor)
    assert ordinals(first) == [1, 2]

    assert {:ok, :buckets, second, cursor, 0, 0} = Recovery.step(namespace, 2, cursor)
    assert ordinals(second) == [3]

    assert {:ok, :fences, third, cursor, 0, 0} = Recovery.step(namespace, 2, cursor)
    assert ordinals(third) == [1, 2]

    assert {:ok, :fences, fourth, cursor, 5_000, 0} = Recovery.step(namespace, 2, cursor)
    assert ordinals(fourth) == [3]
    assert cursor.lane == :buckets
    assert cursor.continuation == nil
  end

  defp create_records(prefix, kind, count) do
    for ordinal <- 1..count do
      assert {:ok, _created} =
               CasRecord.create(prefix <> "#{kind}-#{ordinal}", %{
                 "kind" => kind,
                 "ordinal" => ordinal
               })
    end
  end

  defp ordinals(records),
    do: Enum.map(records, fn {_key, record} -> record["ordinal"] end)
end
