defmodule SalixStore.BlobStreamTest do
  use ExUnit.Case, async: false

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
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    case Process.whereis(S3.Fake) do
      nil -> start_supervised!(S3.Fake)
      _pid -> S3.Fake.reset()
    end

    on_exit(fn ->
      if is_nil(previous_backend) do
        Application.delete_env(:salix_store, :s3_backend)
      else
        Application.put_env(:salix_store, :s3_backend, previous_backend)
      end
    end)

    :ok
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

  test "a throw after the first uploaded part aborts the current multipart state" do
    first_part = String.duplicate("x", 5 * 1024 * 1024)

    stream =
      Stream.concat(
        [first_part],
        Stream.map([:throw], fn :throw -> throw(:source_stream_stopped) end)
      )

    assert {:error, {:throw, :source_stream_stopped}} = Blob.put_stream("agt_test", stream)
    assert S3.Fake.pending_multipart_uploads() == 0
    assert S3.Fake.dump() == %{}
  end

  test "a backend raise during the first part aborts the checkpointed multipart upload" do
    Application.put_env(:salix_store, :s3_backend, RaisingFirstPartBackend)

    assert {:error, %RuntimeError{message: "injected first-part backend failure"}} =
             Blob.put_stream("agt_test", [String.duplicate("x", 5 * 1024 * 1024)])

    assert S3.Fake.pending_multipart_uploads() == 0
    assert S3.Fake.dump() == %{}
  end

  test "a backend exit during the first part aborts the checkpointed multipart upload" do
    Application.put_env(:salix_store, :s3_backend, ExitingFirstPartBackend)

    assert {:error, {:exit, :injected_first_part_backend_exit}} =
             Blob.put_stream("agt_test", [String.duplicate("x", 5 * 1024 * 1024)])

    assert S3.Fake.pending_multipart_uploads() == 0
    assert S3.Fake.dump() == %{}
  end
end
