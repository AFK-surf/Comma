defmodule SalixStore.CasRecordTest do
  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  alias SalixStore.{CasRecord, JSON, S3}

  @key "ctl/test_cas_record/record.json"

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous) end)
    :ok
  end

  test "ensure, update, read, and no-op share one CAS record path" do
    assert {:ok, %{"revision" => 1}} =
             CasRecord.ensure(@key, fn -> %{"revision" => 1} end)

    assert {:ok, %{"revision" => 1}} =
             CasRecord.ensure(@key, fn -> %{"revision" => 99} end)

    S3.Fake.reset_put_log()

    assert {:ok, %{"revision" => 1}} =
             CasRecord.update(@key, &{:unchanged, &1}, create: false)

    assert S3.Fake.put_log() == []

    assert {:ok, %{"revision" => 2}} =
             CasRecord.update(@key, &Map.update!(&1, "revision", fn revision -> revision + 1 end))

    assert {:ok, %{"revision" => 2}} = CasRecord.get(@key)

    assert {:error, :not_found} =
             CasRecord.update(@key <> ".missing", & &1, create: false)
  end

  test "a guard is rechecked before every CAS retry" do
    assert {:ok, %{"revision" => 1}} = CasRecord.create(@key, %{"revision" => 1})
    test_pid = SystemsRuntime.Proc.self()

    reducer = fn
      %{"revision" => 1} = current ->
        assert {:ok, _} = S3.put(@key, Jason.encode!(%{"revision" => 2, "writer" => "other"}))
        Map.put(current, "revision", 2)

      %{"revision" => 2, "writer" => "other"} = current ->
        current |> Map.put("revision", 3) |> Map.put("writer", "guarded")
    end

    guard = fn ->
      SystemsRuntime.Proc.send(test_pid, :cas_guard_checked)
      :ok
    end

    assert {:ok, %{"revision" => 3, "writer" => "guarded"}} =
             CasRecord.update(@key, reducer, guard: guard)

    settle_receive(:cas_guard_checked)
    settle_receive(:cas_guard_checked)
    settle_refute_receive(:cas_guard_checked)
  end
end
