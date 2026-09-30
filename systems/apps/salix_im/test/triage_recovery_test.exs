defmodule SalixIM.Triage.RecoveryTest do
  use ExUnit.Case, async: false

  alias SalixIM.Triage.Recovery
  alias SalixStore.{CasRecord, S3}

  setup do
    previous_triage_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    S3.Fake.reset()

    on_exit(fn ->
      if previous_triage_backend do
        Application.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      else
        Application.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    :ok
  end

  test "rotates bucket and fence lanes under one page budget" do
    namespace = "triage-recovery-#{System.unique_integer([:positive])}"
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

  test "advances past one malformed record without exceeding the page budget" do
    namespace = "triage-recovery-poison-#{System.unique_integer([:positive])}"
    prefix = SalixStore.TriageKeys.ctl_im_triage_buckets_prefix(namespace)

    assert {:ok, _created} = CasRecord.create(prefix <> "1", %{"ordinal" => 1})
    assert {:ok, _put} = S3.put(prefix <> "2", "[]")
    assert {:ok, _created} = CasRecord.create(prefix <> "3", %{"ordinal" => 3})

    cursor = Recovery.cursor(idle_ms: 1_000)
    assert {:ok, :buckets, first, cursor, 0, 1} = Recovery.step(namespace, 2, cursor)
    assert ordinals(first) == [1]

    assert {:ok, :buckets, second, cursor, 0, 0} = Recovery.step(namespace, 2, cursor)
    assert ordinals(second) == [3]
    assert cursor.lane == :fences
  end

  test "rejects invalid budgets before touching storage" do
    cursor = Recovery.cursor()
    assert {:error, _next_cursor, 100} = Recovery.step("namespace", 0, cursor)
    assert S3.Fake.read_log() == []
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
