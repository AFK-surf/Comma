defmodule SalixStore.BlobStreamTest do
  use SystemsClock.Case, async: false

  alias SalixStore.{Blob, S3}

  defmodule RaisingFirstPartBackend do
    def multipart_create(key, opts), do: S3.Fake.multipart_create(key, opts)

    def multipart_upload_part(_key, _upload_id, 1, _body),
      do: raise("injected first-part backend failure")

    def multipart_abort(key, upload_id), do: S3.Fake.multipart_abort(key, upload_id)
    def get(key, opts), do: S3.Fake.get(key, opts)
    def delete(key, opts), do: S3.Fake.delete(key, opts)
  end

  defmodule ExitingFirstPartBackend do
    def multipart_create(key, opts), do: S3.Fake.multipart_create(key, opts)

    def multipart_upload_part(_key, _upload_id, 1, _body),
      do: exit(:injected_first_part_backend_exit)

    def multipart_abort(key, upload_id), do: S3.Fake.multipart_abort(key, upload_id)
    def get(key, opts), do: S3.Fake.get(key, opts)
    def delete(key, opts), do: S3.Fake.delete(key, opts)
  end

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    case SystemsRuntime.Proc.whereis(S3.Fake) do
      nil -> start_supervised!(S3.Fake)
      _pid -> S3.Fake.reset()
    end

    on_exit(fn ->
      if is_nil(previous_backend) do
        SystemsRuntime.delete_env(:salix_store, :s3_backend)
      else
        SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
      end
    end)

    :ok
  end

  test "a part of a body is read by ref from where it is asked, and nothing past its end" do
    {:ok, ref} = Blob.put_stream("agt_test", ["0123456789"])

    assert Blob.read_range("agt_test", ref, 0, 4) == {:ok, "0123"}
    assert Blob.read_range("agt_test", ref, 8, 4) == {:ok, "89"}
    assert Blob.read_range("agt_test", ref, 10, 4) == {:ok, ""}
  end

  test "a body sent in parts, each a request of its own, is stored whole for its agent only" do
    part_size = Blob.upload_part_size()
    first = :binary.copy("a", part_size)
    body = first <> "tail"

    {:ok, upload} = Blob.begin_parts("agt_test", byte_size(body))

    assert Blob.put_part("agt_other", upload, 1, first) == {:error, :not_found}
    assert Blob.put_part("agt_test", upload, 2, "tai") == {:error, :invalid_part}
    assert Blob.put_part("agt_test", upload, 3, "tail") == {:error, :invalid_part}
    assert {:ok, last} = Blob.put_part("agt_test", upload, 2, "tail")
    assert {:ok, head} = Blob.put_part("agt_test", upload, 1, first)
    assert Blob.finish_parts("agt_test", upload, [head]) == {:error, :upload_incomplete}

    assert {:ok, ref} = Blob.finish_parts("agt_test", upload, [head, last])
    assert ref.size == byte_size(body)
    assert ref.hash == SalixStore.Crypto.hex(body)
    {:ok, stream, _size} = Blob.stream("agt_test", ref)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
    assert S3.Fake.pending_multipart_uploads() == 0

    # Still a preparation the sweeper owns until a manifest commits it.
    {:ok, %{body: intent}} = S3.get(SalixStore.Keys.prepared_blob_cleanup(ref.uuid))
    assert %{"status" => "prepared", "upload_id" => nil} = Jason.decode!(intent)
    assert Blob.put_part("agt_test", upload, 2, "tail") == {:error, :not_found}
  end

  test "an enumerable exception aborts the latest multipart upload state" do
    first_part = String.duplicate("x", 5 * 1024 * 1024)

    stream =
      Stream.concat(
        [first_part],
        Stream.map([:raise], fn :raise -> raise "source stream failed" end)
      )

    assert {:error, %RuntimeError{message: "source stream failed"}} =
             Blob.put_stream("agt_test", stream)

    assert S3.Fake.dump() == %{}
    assert S3.Fake.pending_multipart_uploads() == 0

    assert {:ok, ref} = Blob.put_stream("agt_test", [first_part, "retry-complete"])
    assert map_size(S3.Fake.dump()) == 1
    assert S3.Fake.pending_multipart_uploads() == 0

    assert :ok = Blob.discard(ref)
    assert S3.Fake.dump() == %{}
  end
end
