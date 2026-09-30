defmodule SalixStore.S3ContractTest do
  @moduledoc """
  The S3 conditional-write contract, run against BOTH backends to guarantee the
  Fake is a faithful stand-in for MinIO/S3. Every protocol module depends on
  these exact semantics, so this is the bedrock test.

  Each `backend` block re-points `:s3_backend` and exercises:
  create-once (If-None-Match:*), CAS (If-Match), conditional DELETE, ranged GET,
  HEAD, LIST pagination, multipart-upload reconciliation, and the not-found /
  precondition-failed / not-modified tagged errors.
  """
  use ExUnit.Case, async: false

  alias SalixStore.S3

  @backends [
    {SalixStore.S3.AWS, "MinIO"},
    {SalixStore.S3.Fake, "Fake"}
  ]

  for {backend, name} <- @backends do
    describe "#{name} backend" do
      setup do
        prev = Application.get_env(:salix_store, :s3_backend)
        Application.put_env(:salix_store, :s3_backend, unquote(backend))

        if unquote(backend) == SalixStore.S3.Fake do
          start_supervised!(SalixStore.S3.Fake)
        end

        on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
        :ok
      end

      test "put/get round-trips body, etag and metadata" do
        key = key("rt")
        assert {:ok, %{etag: etag}} = S3.put(key, "hello", meta: %{"writer" => "n1"})
        assert is_binary(etag)
        assert {:ok, %{body: "hello", etag: ^etag, meta: meta}} = S3.get(key)
        assert meta["writer"] == "n1"
      end

      test "create-once: If-None-Match:* succeeds then 412s" do
        key = key("createonce")
        assert {:ok, %{etag: _}} = S3.put(key, "v1", if_none_match: "*")
        assert {:error, :precondition_failed} = S3.put(key, "v2", if_none_match: "*")
        # original body untouched
        assert {:ok, %{body: "v1"}} = S3.get(key)
      end

      test "CAS: If-Match succeeds with live etag, 412s with stale etag" do
        key = key("cas")
        {:ok, %{etag: e0}} = S3.put(key, "v0")
        assert {:ok, %{etag: e1}} = S3.put(key, "v1", if_match: e0)
        assert e1 != e0
        # stale etag rejected
        assert {:error, :precondition_failed} = S3.put(key, "v2", if_match: e0)
        # current value is v1
        assert {:ok, %{body: "v1"}} = S3.get(key)
      end

      test "CAS: concurrent writers using the same etag produce one winner" do
        key = key("cas-race")
        {:ok, %{etag: e0}} = S3.put(key, "v0")

        results =
          ["left", "right"]
          |> Task.async_stream(
            fn body -> S3.put(key, body, if_match: e0) end,
            max_concurrency: 2,
            timeout: 5_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.count(results, &match?({:ok, %{etag: _}}, &1)) == 1
        assert Enum.count(results, &match?({:error, :precondition_failed}, &1)) == 1
        assert {:ok, %{body: body}} = S3.get(key)
        assert body in ["left", "right"]
      end

      test "conditional delete: If-Match removes only on match" do
        key = key("del")
        {:ok, %{etag: e0}} = S3.put(key, "x")
        {:ok, %{etag: e1}} = S3.put(key, "y", if_match: e0)
        assert {:error, :precondition_failed} = S3.delete(key, if_match: e0)
        assert :ok = S3.delete(key, if_match: e1)
        assert {:error, :not_found} = S3.get(key)
      end

      test "get/head on missing key return :not_found; unconditional delete is idempotent" do
        key = key("missing")
        assert {:error, :not_found} = S3.get(key)
        assert {:error, :not_found} = S3.head(key)
        # S3 DELETE is idempotent — deleting a missing key succeeds (204).
        assert :ok = S3.delete(key)
        # but a *conditional* delete of a missing key fails the precondition.
        assert {:error, :precondition_failed} = S3.delete(key, if_match: "\"deadbeef\"")
      end

      test "head returns size and etag" do
        key = key("head")
        {:ok, %{etag: etag}} = S3.put(key, "abcdef")
        assert {:ok, %{etag: ^etag, size: 6}} = S3.head(key)
      end

      test "ranged get returns a byte slice" do
        key = key("range")
        S3.put(key, "0123456789")
        assert {:ok, %{body: "234"}} = S3.get(key, range: {2, 3})
      end

      test "if-none-match etag returns :not_modified" do
        key = key("nm")
        {:ok, %{etag: etag}} = S3.put(key, "z")
        assert {:error, :not_modified} = S3.get(key, if_none_match: etag)
      end

      test "list returns objects under a prefix, sorted, with pagination" do
        prefix = key("list") <> "/"
        for i <- 1..5, do: S3.put("#{prefix}#{String.pad_leading("#{i}", 3, "0")}", "v#{i}")

        {:ok, all} = S3.list_all(prefix)
        keys = Enum.map(all, & &1.key)
        assert length(keys) == 5
        assert keys == Enum.sort(keys)

        # paginate 2 at a time
        {:ok, %{objects: page1, next: token}} = S3.list(prefix, max_keys: 2)
        assert length(page1) == 2
        assert is_binary(token)
        {:ok, all2} = S3.list_all(prefix, max_keys: 2)
        assert Enum.map(all2, & &1.key) == keys
      end

      test "incomplete multipart uploads can be listed and aborted by exact key" do
        object_key = key("multipart-reconcile")
        assert {:ok, upload_id} = S3.multipart_create(object_key)

        assert {:ok, %{uploads: uploads, next: nil}} =
                 S3.multipart_uploads(object_key, max_uploads: 8)

        assert Enum.any?(uploads, &(&1.key == object_key and &1.upload_id == upload_id))
        assert :ok = S3.multipart_abort(object_key, upload_id)
        assert {:ok, %{uploads: [], next: nil}} = S3.multipart_uploads(object_key, max_uploads: 8)
      end
    end
  end

  defp key(tag), do: "itest/#{tag}/#{System.unique_integer([:positive])}"
end
