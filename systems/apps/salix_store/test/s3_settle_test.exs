defmodule SalixStore.S3.SettleTest do
  use SystemsClock.Case, async: false

  alias SalixStore.S3
  alias SalixStore.S3.Settle

  @key "settle-test/object"

  setup do
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    :ok
  end

  describe "cas_put/4" do

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

    test "a foreign object reports precondition_failed into the rebase path" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")
      {:ok, _} = S3.put(@key, "taken over")

      assert {:error, :precondition_failed} = Settle.cas_put(@key, "next", etag)
    end

    test "budget exhaustion is an explicit indeterminate, not a generic error" do
      {:ok, %{etag: etag}} = S3.put(@key, "base")

      for _ <- 1..2 do
        SalixStore.S3.Fake.set_fault({:ambiguous_before, :put, @key})
      end

      assert {:error, :settlement_indeterminate} =
               Settle.cas_put(@key, "next", etag, attempts: 1)
    end
  end

  describe "create_once/4" do
    test "a 412 against our own identical bytes converges as landed" do
      {:ok, _} = S3.put(@key, "bytes")

      assert :landed = Settle.create_once(@key, "bytes", Settle.byte_settle("bytes"))
    end

    test "a 412 against foreign bytes reports exists with the read-back" do
      {:ok, _} = S3.put(@key, "someone else")

      assert {:exists, %{body: "someone else"}} =
               Settle.create_once(@key, "bytes", Settle.byte_settle("bytes"))
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
