defmodule SalixStore.S3.SettleTest do
  use ExUnit.Case, async: false

  alias SalixStore.S3
  alias SalixStore.S3.Settle

  @key "settle-test/object"

  setup do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    :ok
  end

  describe "cas_put/4" do
    test "the metadata variant returns the committed ETag without another read" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      SalixStore.S3.Fake.reset_read_log()

      assert {:ok, committed_etag, :ok} = Settle.cas_put_with_etag(@key, "next", etag)
      refute {:get, @key} in SalixStore.S3.Fake.read_log()
      assert {:ok, %{etag: ^committed_etag, body: "next"}} = S3.get(@key)
    end

    test "the metadata variant returns the exact read-back ETag after ambiguity" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, @key})

      assert {:ok, committed_etag, :ambiguous_settled} =
               Settle.cas_put_with_etag(@key, "next", etag)

      assert {:ok, %{etag: ^committed_etag, body: "next"}} = S3.get(@key)
    end

    test "an ambiguous-but-landed PUT settles as ok by read-back" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, @key})

      assert :ok = Settle.cas_put(@key, "next", etag)
      assert {:ok, %{body: "next"}} = S3.get(@key)
    end

    test "an ambiguous-lost PUT retries the same bytes and lands" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      SalixStore.S3.Fake.set_fault({:ambiguous_before, :put, @key})

      assert :ok = Settle.cas_put(@key, "next", etag)
      assert {:ok, %{body: "next"}} = S3.get(@key)
    end

    test "a transient read-back failure after a landed ambiguous PUT stays inside the budget" do
      # P1-7: landed PUT + one flaky GET must not surface an ordinary error —
      # the caller would re-materialize non-deduped records.
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, @key})
      SalixStore.S3.Fake.set_fault({:fail, 503, :get, @key})

      assert :ok = Settle.cas_put(@key, "next", etag)
    end

    test "a foreign object reports precondition_failed into the rebase path" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      {:ok, _} = S3.put(@key, "taken over")

      assert {:error, :precondition_failed} = Settle.cas_put(@key, "next", etag)
    end

    test "an original request that lands AFTER the settlement read is not a conflict" do
      # The interleaving a read-back cannot fence: PUT#1 comes back ambiguous
      # while still in flight, settlement reads the unchanged base, the
      # original then lands, and the same-bytes retry takes a stale 412 for
      # our own write. Reporting that 412 as a conflict makes the caller
      # rebase and re-materialize a dedupe-less batch.
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      SalixStore.S3.Fake.set_fault({:apply_after_next_get, :put, @key})

      assert :ok = Settle.cas_put(@key, "next", etag)
      assert {:ok, %{body: "next"}} = S3.get(@key)
    end

    test "budget exhaustion is an explicit indeterminate, not a generic error" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")

      for _ <- 1..2 do
        SalixStore.S3.Fake.set_fault({:ambiguous_before, :put, @key})
      end

      assert {:error, :settlement_indeterminate} =
               Settle.cas_put(@key, "next", etag, attempts: 1)
    end

    test "the final read-only budget returns the original candidate and its ETag" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      S3.Fake.reset_put_log()
      S3.Fake.set_fault({:ambiguous_after, :put, @key})
      for _ <- 1..4, do: S3.Fake.set_fault({:fail, 503, :get, @key})

      assert {:ok, landed_etag, :ambiguous_settled} =
               Settle.cas_put_with_etag(@key, "candidate", etag, final_readback_attempts: 4)

      assert {:ok, %{etag: ^landed_etag, body: "candidate"}} = S3.get(@key)
      assert S3.Fake.put_log() == [@key]
    end

    test "exhausted final read-back stays indeterminate without another write" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      S3.Fake.reset_put_log()
      S3.Fake.reset_read_log()
      S3.Fake.set_fault({:ambiguous_after, :put, @key})
      for _ <- 1..8, do: S3.Fake.set_fault({:fail, 503, :get, @key})

      assert {:error, :settlement_indeterminate} =
               Settle.cas_put_with_etag(@key, "candidate", etag, final_readback_attempts: 4)

      assert S3.Fake.read_log() == List.duplicate({:get, @key}, 8)
      assert S3.Fake.put_log() == [@key]
    end

    for mode <- [:update, :create], budget <- [1, 4] do
      test "final read-back preserves uncertainty for a delayed #{mode} with budget #{budget}" do
        base =
          if unquote(mode) == :update do
            {:ok, %{etag: etag}} = S3.put(@key, "base")
            etag
          end

        S3.Fake.reset_put_log()
        S3.Fake.reset_read_log()
        S3.Fake.set_fault({:apply_after_next_get, :put, @key})
        for _ <- 1..4, do: S3.Fake.set_fault({:fail, 503, :get, @key})

        result =
          Settle.cas_put_with_etag(@key, "candidate", base,
            final_readback_attempts: unquote(budget)
          )

        if unquote(budget) == 1 do
          assert result == {:error, :settlement_indeterminate}
          assert length(S3.Fake.read_log()) == 5
        else
          assert {:ok, landed_etag, :ambiguous_settled} = result
          assert length(S3.Fake.read_log()) == 6
          assert {:ok, %{etag: ^landed_etag}} = S3.get(@key)
        end

        assert {:ok, %{body: "candidate"}} = S3.get(@key)
        assert S3.Fake.put_log() == [@key]
      end
    end
  end

  describe "create_once/4" do
    test "first write creates" do
      assert :created = Settle.create_once(@key, "bytes", Settle.byte_settle("bytes"))
    end

    test "a 412 against our own identical bytes converges as landed" do
      {:ok, _} = S3.put(@key, "bytes")

      assert :landed = Settle.create_once(@key, "bytes", Settle.byte_settle("bytes"))
    end

    test "a 412 against foreign bytes reports exists with the read-back" do
      {:ok, _} = S3.put(@key, "someone else")

      assert {:exists, %{body: "someone else"}} =
               Settle.create_once(@key, "bytes", Settle.byte_settle("bytes"))
    end

    test "an ambiguous-but-landed create settles as landed" do
      SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, @key})

      assert :landed = Settle.create_once(@key, "bytes", Settle.byte_settle("bytes"))
      assert {:ok, %{body: "bytes"}} = S3.get(@key)
    end

    test "an ambiguous-lost create retries and lands within the budget" do
      SalixStore.S3.Fake.set_fault({:ambiguous_before, :put, @key})

      assert :created = Settle.create_once(@key, "bytes", Settle.byte_settle("bytes"))
    end

    test "a transient read-back failure during settlement stays inside the budget" do
      SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, @key})
      SalixStore.S3.Fake.set_fault({:fail, 503, :get, @key})

      assert :landed = Settle.create_once(@key, "bytes", Settle.byte_settle("bytes"))
    end

    test "the settle_fn decides ownership — identity, not bytes" do
      # A fork target recognizes itself by persisted identity even though
      # every attempt's bytes drift.
      {:ok, _} = S3.put(@key, "attempt-one-bytes req-A")

      settle = fn %{body: got} ->
        if String.contains?(got, "req-A"), do: :own, else: :foreign
      end

      assert :landed = Settle.create_once(@key, "attempt-two-bytes req-A", settle)
    end
  end
end
