defmodule SalixStore.BoundedJsonlTest do
  use SystemsClock.Case, async: false

  alias SalixStore.{BoundedJsonl, S3}

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  @opts [max_lines: 10, max_bytes: 10_000, identity_fields: ~w(message_id)]

  test "append returns the settled rows and bytes so callers need no read-back" do
    key = "bounded_jsonl_test/settled.jsonl"
    first = %{"message_id" => "m-1", "seq" => 1}
    second = %{"message_id" => "m-2", "seq" => 2}

    assert {:ok, %{rows: [^first], body: body}} = BoundedJsonl.append(key, first, @opts)
    assert {:ok, %{body: ^body}} = S3.get(key)

    assert {:ok, %{rows: [^first, ^second], body: body}} =
             BoundedJsonl.append(key, second, @opts)

    assert {:ok, %{body: ^body}} = S3.get(key)
  end

  test "a duplicate append returns the already-present object, unmodified" do
    key = "bounded_jsonl_test/duplicate.jsonl"
    record = %{"message_id" => "m-1", "seq" => 1}

    assert {:ok, %{body: body}} = BoundedJsonl.append(key, record, @opts)

    assert {:ok, %{rows: [^record], body: ^body}} =
             BoundedJsonl.append(key, %{"message_id" => "m-1", "seq" => 9}, @opts)

    assert {:ok, %{body: ^body}} = S3.get(key)
  end
end
